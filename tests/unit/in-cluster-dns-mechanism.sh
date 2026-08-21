#!/usr/bin/env bash
# Unit test (no cluster): setup-in-cluster-dns.sh must write the zone to the
# file CoreDNS actually reads, which differs by distribution (#104).
#
#   - kind/kubeadm: no custom import exists, so the zone goes into the Corefile.
#   - k3s: CoreDNS imports /etc/coredns/custom/*.server, and k3s reconciles its
#     packaged manifests, so the zone goes into the coredns-custom ConfigMap.
#
# Writing coredns-custom on kind was the #104 no-op: created, never read.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/setup-in-cluster-dns.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A kubeadm/kind Corefile: single .:53 block, no custom import.
cat > "${WORK}/corefile-kind" <<'EOF'
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf
    cache 30
    loop
    reload
    loadbalance
}
EOF

# A k3s Corefile: NodeHosts plus the two custom imports.
cat > "${WORK}/corefile-k3s" <<'EOF'
.:53 {
    errors
    health
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
      pods insecure
      fallthrough in-addr.arpa ip6.arpa
    }
    hosts /etc/coredns/NodeHosts {
      ttl 60
      reload 15s
      fallthrough
    }
    prometheus :9153
    forward . /etc/resolv.conf
    cache 30
    loop
    reload
    loadbalance
    import /etc/coredns/custom/*.override
}
import /etc/coredns/custom/*.server
EOF

# Stub kubectl that logs every mutation to $CALLS so we can assert on WHICH
# ConfigMap was written, and serves the Corefile fixture named by $COREFILE.
cat > "${WORK}/kubectl" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
case "${ARGS}" in
  *"get configmap coredns -o jsonpath"*)
    [[ -n "${COREFILE:-}" ]] && cat "${COREFILE}" || exit 1 ;;
  *"get configmap coredns-custom"*)
    [[ "${CUSTOM_EXISTS:-no}" == yes ]] && exit 0 || exit 1 ;;
  *"create configmap coredns "*)
    echo "WRITE corefile" >> "${CALLS}"
    printf 'apiVersion: v1\nkind: ConfigMap\n' ;;
  *"create configmap coredns-custom"*)
    echo "WRITE coredns-custom" >> "${CALLS}" ;;
  *"patch configmap coredns "*)
    # Drain stdin like the real `--patch-file /dev/stdin` does: exiting without
    # reading gives the upstream `kubectl create` EPIPE, and the script's
    # `set -o pipefail` would then fail the pipeline intermittently.
    cat >/dev/null
    echo "PATCH corefile" >> "${CALLS}" ;;
  *"patch configmap coredns-custom"*)
    cat >/dev/null
    echo "PATCH coredns-custom" >> "${CALLS}" ;;
  *rollout*)                          echo "ROLLOUT" >> "${CALLS}" ;;
  *)                                  echo "OTHER ${ARGS}" >> "${CALLS}" ;;
esac
EOF
chmod +x "${WORK}/kubectl"
export PATH="${WORK}:${PATH}"

fails=0

# run <desc> <corefile-or-empty> <custom-exists> -- <expect-substr>...
run_case() {
  local desc="$1" corefile="$2" custom="$3"; shift 3; shift  # drop the --
  local calls="${WORK}/calls.$$"
  : > "${calls}"
  local out
  if ! out="$(CALLS="${calls}" COREFILE="${corefile}" CUSTOM_EXISTS="${custom}" \
        DOMAIN="nebari.local" GATEWAY_IP="10.0.0.5" bash "${SCRIPT}" 2>&1)"; then
    echo "::error::${desc}: script exited non-zero (extractors must skip, not fail). Output: ${out}"
    fails=$((fails + 1)); return
  fi
  local want
  for want in "$@"; do
    if [[ "${want}" == "!"* ]]; then
      if grep -qF "${want:1}" "${calls}"; then
        echo "::error::${desc}: expected NOT to see '${want:1}' but did. Calls: $(tr '\n' ',' < "${calls}")"
        fails=$((fails + 1)); return
      fi
    elif ! grep -qF "${want}" "${calls}"; then
      echo "::error::${desc}: expected call '${want}'. Calls: $(tr '\n' ',' < "${calls}")"
      fails=$((fails + 1)); return
    fi
  done
  echo "  ok    ${desc}"
}

# kind: the zone must land in the Corefile, and coredns-custom must be left
# alone -- writing it there is the #104 no-op.
run_case "kind writes the Corefile, not coredns-custom" \
  "${WORK}/corefile-kind" no -- "PATCH corefile" "!WRITE coredns-custom" "!PATCH coredns-custom"

# k3s: the zone must land in coredns-custom, because k3s reverts Corefile edits.
run_case "k3s writes coredns-custom, not the Corefile" \
  "${WORK}/corefile-k3s" no -- "WRITE coredns-custom" "!PATCH corefile"

run_case "k3s patches an existing coredns-custom" \
  "${WORK}/corefile-k3s" yes -- "PATCH coredns-custom" "!PATCH corefile"

# Idempotency: a second run must not append the zone again.
cat "${WORK}/corefile-kind" > "${WORK}/corefile-kind-patched"
printf 'nebari.local:53 {\n    errors\n}\n\n' | cat - "${WORK}/corefile-kind" \
  > "${WORK}/corefile-kind-patched"
run_case "existing zone is left unchanged (re-run is not additive)" \
  "${WORK}/corefile-kind-patched" no -- "!PATCH corefile" "!ROLLOUT"

# Extractor semantics: an unreadable Corefile means we cannot tell which
# mechanism applies, so skip cleanly WITHOUT mutating anything.
run_case "unreadable Corefile skips without mutating" \
  "" no -- "!PATCH corefile" "!WRITE coredns-custom" "!ROLLOUT"

# ...and says so, since a silent no-op is what #104 was.
if CALLS="${WORK}/calls.warn" COREFILE="" DOMAIN="nebari.local" GATEWAY_IP="10.0.0.5" \
     bash "${SCRIPT}" 2>&1 | grep -q '::warning::.*could not read the coredns ConfigMap'; then
  echo "  ok    unreadable Corefile warns"
else
  echo "::error::unreadable Corefile: expected a ::warning:: naming the coredns ConfigMap"
  fails=$((fails + 1))
fi

if (( fails > 0 )); then
  echo "in-cluster-dns-mechanism: ${fails} case(s) failed"
  exit 1
fi
echo "in-cluster-dns-mechanism: all cases passed"
