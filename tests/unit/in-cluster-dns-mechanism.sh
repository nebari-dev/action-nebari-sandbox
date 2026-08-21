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
# Read stdin only when the real kubectl would: `--patch-file /dev/stdin` does,
# `--type json -p '...'` does not. Draining unconditionally deadlocks the
# rollback path (no pipe upstream); not draining at all gives the upstream
# `kubectl create` EPIPE, which `set -o pipefail` turns into a flaky failure.
drain_if_patch_file() {
  case "${ARGS}" in *--patch-file*) cat >/dev/null ;; esac
}
case "${ARGS}" in
  *"get configmap coredns -o jsonpath"*)
    [[ -n "${COREFILE:-}" ]] && cat "${COREFILE}" || exit 1 ;;
  *"get configmap coredns-custom"*)
    [[ "${CUSTOM_EXISTS:-no}" == yes ]] && exit 0 || exit 1 ;;
  *--from-file=Corefile=*)
    # `create --from-file` does not read stdin. Keep the rendered Corefile so
    # the test can assert on its CONTENT, not merely that a write happened.
    f="${ARGS##*--from-file=Corefile=}"; f="${f%% *}"
    cp "${f}" "${RENDERED}"
    echo "WRITE corefile" >> "${CALLS}"
    printf 'apiVersion: v1\nkind: ConfigMap\n' ;;
  *"create configmap coredns-custom"*)
    echo "WRITE coredns-custom" >> "${CALLS}" ;;
  *"patch configmap coredns "*)
    drain_if_patch_file
    echo "PATCH corefile" >> "${CALLS}"
    [[ "${PATCH_FAILS:-no}" == yes ]] && exit 1 || exit 0 ;;
  *"patch configmap coredns-custom"*)
    drain_if_patch_file
    echo "PATCH coredns-custom" >> "${CALLS}" ;;
  *"rollout status"*)
    echo "ROLLOUT-STATUS" >> "${CALLS}"
    [[ "${ROLLOUT_FAILS:-no}" == yes ]] && exit 1 || exit 0 ;;
  *"rollout restart"*)                echo "ROLLOUT-RESTART" >> "${CALLS}" ;;
  *)                                  echo "OTHER ${ARGS}" >> "${CALLS}" ;;
esac
EOF
chmod +x "${WORK}/kubectl"
export PATH="${WORK}:${PATH}"

fails=0

# run <desc> <corefile-or-empty> <custom-exists> -- <expect-substr>...
# run_case <desc> <corefile> <custom-exists> [VAR=VALUE ...] -- <expect>...
# An expectation of "!X" asserts X did NOT happen.
run_case() {
  local desc="$1" corefile="$2" custom="$3"; shift 3
  local -a overrides=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do overrides+=("$1"); shift; done
  shift  # drop the --
  local calls="${WORK}/calls.$$"
  RENDERED="${WORK}/rendered.$$"
  : > "${calls}"
  : > "${RENDERED}"
  local out
  if ! out="$(env CALLS="${calls}" COREFILE="${corefile}" CUSTOM_EXISTS="${custom}" \
        RENDERED="${RENDERED}" DOMAIN="nebari.local" GATEWAY_IP="10.0.0.5" \
        "${overrides[@]}" bash "${SCRIPT}" 2>&1)"; then
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

# The highest-blast-radius property: the merged Corefile must still contain the
# ORIGINAL server block. Getting this wrong replaces cluster DNS rather than
# extending it, and asserting only on which ConfigMap was written would not
# notice.
if grep -qF "kubernetes cluster.local" "${RENDERED}" \
   && [[ "$(grep -c '^\.:53 {' "${RENDERED}")" == 1 ]] \
   && [[ "$(grep -c '^nebari.local:53 {' "${RENDERED}")" == 1 ]]; then
  echo "  ok    merged Corefile keeps the original .:53 block and adds the zone once"
else
  echo "::error::merged Corefile lost the original block or duplicated the zone"
  cat "${RENDERED}" || true
  fails=$((fails + 1))
fi

# k3s: the zone must land in coredns-custom, because k3s reverts Corefile edits.
run_case "k3s writes coredns-custom, not the Corefile" \
  "${WORK}/corefile-k3s" no -- "WRITE coredns-custom" "!PATCH corefile"

run_case "k3s patches an existing coredns-custom" \
  "${WORK}/corefile-k3s" yes -- "PATCH coredns-custom" "!PATCH corefile"

# Idempotency: a second run must not append the zone again.
MARKER="# nebari-sandbox: managed zone block (replaced on re-run)"
{ printf '%s\nnebari.local:53 {\n    errors\n    template IN A nebari.local {\n        answer "{{ .Name }} 60 IN A 10.9.9.9"\n    }\n}\n\n' "${MARKER}"
  cat "${WORK}/corefile-kind"; } > "${WORK}/corefile-kind-patched"
# A block we wrote before must be REPLACED, so a changed gateway IP converges
# instead of being silently kept, and the zone is never defined twice (CoreDNS
# refuses to load a duplicate zone and takes all cluster DNS down with it).
run_case "our stale block is replaced, not duplicated or kept" \
  "${WORK}/corefile-kind-patched" no -- "PATCH corefile"
if [[ "$(grep -c '^nebari.local:53 {' "${RENDERED}")" == 1 ]] \
   && grep -qF "10.0.0.5" "${RENDERED}" \
   && ! grep -qF "10.9.9.9" "${RENDERED}"; then
  echo "  ok    stale gateway IP converged, zone defined exactly once"
else
  echo "::error::re-run did not converge: expected one nebari.local:53 block carrying 10.0.0.5, not 10.9.9.9"
  grep -nE 'nebari.local:53|answer' "${RENDERED}" || true
  fails=$((fails + 1))
fi

# A zone for the domain that we did NOT write belongs to whoever did; adding
# ours beside it would define the zone twice.
printf 'nebari.local {\n    errors\n}\n\n' | cat - "${WORK}/corefile-kind" \
  > "${WORK}/corefile-foreign-zone"
run_case "a foreign zone block is left alone" \
  "${WORK}/corefile-foreign-zone" no -- "!PATCH corefile" "!ROLLOUT-RESTART"

# Extractor semantics: an unreadable Corefile means we cannot tell which
# mechanism applies, so skip cleanly WITHOUT mutating anything.
run_case "unreadable Corefile skips without mutating" \
  "" no -- "!PATCH corefile" "!WRITE coredns-custom" "!ROLLOUT-RESTART"

# ...and says so, since a silent no-op is what #104 was.
if CALLS="${WORK}/calls.warn" COREFILE="" DOMAIN="nebari.local" GATEWAY_IP="10.0.0.5" \
     bash "${SCRIPT}" 2>&1 | grep -q '::warning::.*could not read the coredns ConfigMap'; then
  echo "  ok    unreadable Corefile warns"
else
  echo "::error::unreadable Corefile: expected a ::warning:: naming the coredns ConfigMap"
  fails=$((fails + 1))
fi

# Extractor contract (CONTRIBUTING): a mutation that fails must warn and skip,
# not fail the run -- and a CoreDNS that will not come back must be rolled back
# rather than left broken while the platform is still converging.
run_case "a failed Corefile patch warns and skips" \
  "${WORK}/corefile-kind" no PATCH_FAILS=yes -- "!ROLLOUT-RESTART"
run_case "a failed rollout rolls the Corefile back" \
  "${WORK}/corefile-kind" no ROLLOUT_FAILS=yes -- "PATCH corefile"
if grep -qF "kubernetes cluster.local" "${RENDERED}" \
   && ! grep -qF "nebari-sandbox" "${RENDERED}"; then
  echo "  ok    rollback restored a Corefile without our block"
else
  echo "::error::rollback did not restore the original Corefile"
  fails=$((fails + 1))
fi

# The closing log names the mechanism, which is what stops a no-op from
# masquerading as success. Pin it.
if CALLS="${WORK}/calls.mech" RENDERED="${WORK}/rendered.mech" \
     COREFILE="${WORK}/corefile-kind" DOMAIN="nebari.local" GATEWAY_IP="10.0.0.5" \
     bash "${SCRIPT}" 2>&1 | grep -q "In-cluster DNS ready via coredns Corefile server block"; then
  echo "  ok    closing log names the mechanism used"
else
  echo "::error::expected the closing log to name the mechanism it wrote through"
  fails=$((fails + 1))
fi

if (( fails > 0 )); then
  echo "in-cluster-dns-mechanism: ${fails} case(s) failed"
  exit 1
fi
echo "in-cluster-dns-mechanism: all cases passed"
