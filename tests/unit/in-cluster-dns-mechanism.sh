#!/usr/bin/env bash
# Unit test (no cluster): setup-in-cluster-dns.sh must write the zone into the
# file CoreDNS actually reads, must never hand CoreDNS a Corefile that lost what
# it had, and must put the old one back if CoreDNS will not load the new one.
#
# Background: the script used to write a `coredns-custom` ConfigMap, which only
# k3s CoreDNS imports. On kind that was a silent no-op -- created, never read,
# reported ready (#104). The assertions here are about WHAT ends up in the
# Corefile, not merely that a write happened, because a Corefile can parse
# perfectly and still serve nothing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/setup-in-cluster-dns.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A kubeadm/kind Corefile: single .:53 block.
cat > "${WORK}/corefile" <<'EOF'
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

# Stub kubectl: serves the Corefile fixture named by $COREFILE, records every
# mutation in $CALLS, and keeps the rendered Corefile in $RENDERED so tests can
# assert on content. Failure injection via $PATCH_FAILS / $ROLLOUT_FAILS;
# $RESTORE_FAILS fails only the SECOND patch, i.e. the restore.
cat > "${WORK}/kubectl" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
# Read stdin only where the real kubectl would: `--patch-file /dev/stdin` does,
# `create --from-file` and `--type json -p` do not. Draining unconditionally
# deadlocks paths with no upstream pipe; never draining gives the upstream
# `kubectl create` EPIPE, which `set -o pipefail` turns into a flaky failure.
drain_if_patch_file() { case "${ARGS}" in *--patch-file*) cat >/dev/null ;; esac; }
case "${ARGS}" in
  *"get configmap coredns -o jsonpath"*)
    [[ -n "${COREFILE:-}" ]] && cat "${COREFILE}" || exit 1 ;;
  *--from-file=Corefile=*)
    f="${ARGS##*--from-file=Corefile=}"; f="${f%% *}"
    cp "${f}" "${RENDERED}"
    echo "WRITE" >> "${CALLS}"
    printf 'apiVersion: v1\nkind: ConfigMap\n' ;;
  *"patch configmap coredns "*)
    drain_if_patch_file
    echo "PATCH" >> "${CALLS}"
    n=$(grep -c PATCH "${CALLS}" 2>/dev/null || true)
    # 1 = the change, 2 = the restore. Separate knobs so each failure is
    # exercised on its own; one knob failing both lets a mutant that stops
    # checking either survive.
    [[ "${n}" -le 1 && "${PATCH_FAILS:-no}" == yes ]] && exit 1
    [[ "${n}" -ge 2 && "${RESTORE_PATCH_FAILS:-no}" == yes ]] && exit 1
    exit 0 ;;
  *"rollout status"*)
    echo "ROLLOUT-STATUS" >> "${CALLS}"
    n=$(grep -c ROLLOUT-STATUS "${CALLS}" 2>/dev/null || true)
    [[ "${n}" -le 1 && "${ROLLOUT_FAILS:-no}" == yes ]] && exit 1
    [[ "${n}" -ge 2 && "${RESTORE_ROLLOUT_FAILS:-no}" == yes ]] && exit 1
    exit 0 ;;
  *"rollout restart"*) echo "ROLLOUT-RESTART" >> "${CALLS}" ;;
  *) echo "OTHER ${ARGS}" >> "${CALLS}" ;;
esac
EOF
chmod +x "${WORK}/kubectl"
export PATH="${WORK}:${PATH}"

fails=0
CALLS=""; RENDERED=""; OUT=""; RC=0

# drive <corefile-or-empty> [VAR=VALUE ...]
drive() {
  local corefile="$1"; shift
  CALLS="${WORK}/calls"; RENDERED="${WORK}/rendered"
  : > "${CALLS}"; : > "${RENDERED}"
  RC=0
  OUT="$(env CALLS="${CALLS}" RENDERED="${RENDERED}" COREFILE="${corefile}" \
    DOMAIN="nebari.local" GATEWAY_IP="10.0.0.5" "$@" bash "${SCRIPT}" 2>&1)" || RC=$?
}

ok()   { echo "  ok    $1"; }
bad()  { echo "::error::$1"; fails=$((fails + 1)); }

# ── The happy path, asserted on content ──────────────────────────────────────
drive "${WORK}/corefile"
if (( RC != 0 )); then
  bad "kind: expected exit 0, got ${RC}. Output: ${OUT}"
elif ! grep -q "PATCH" "${CALLS}"; then
  bad "kind: the Corefile was never patched. Calls: $(tr '\n' ',' < "${CALLS}")"
else
  ok "the zone is written into the Corefile"
fi

# The property that matters most: we ADD to the Corefile, never replace it. A
# Corefile carrying only our block parses fine and serves nothing, so the
# rollout check cannot catch it -- only this can.
if grep -qF "kubernetes cluster.local" "${RENDERED}" \
   && [[ "$(grep -cE '^[[:space:]]*\.:53[[:space:]]*\{' "${RENDERED}")" == 1 ]] \
   && [[ "$(grep -c '^nebari.local:53 {' "${RENDERED}")" == 1 ]]; then
  ok "merged Corefile keeps the original .:53 block and adds the zone once"
else
  bad "merged Corefile lost the original block or duplicated the zone"
  cat "${RENDERED}" || true
fi

# Braces must balance, or CoreDNS gets a file it cannot parse. This is what
# kills an off-by-one in however the merge is done.
if [[ "$(grep -c '{' "${RENDERED}")" == "$(grep -c '}' "${RENDERED}")" ]]; then
  ok "merged Corefile has balanced braces"
else
  bad "merged Corefile has unbalanced braces: $(grep -c '{' "${RENDERED}") open vs $(grep -c '}' "${RENDERED}") close"
fi

# The gateway IP has to actually reach the answer template.
if grep -qF 'answer "{{ .Name }} 60 IN A 10.0.0.5"' "${RENDERED}"; then
  ok "the zone answers with the gateway IP"
else
  bad "the rendered zone does not answer with the gateway IP"
fi

# AAAA and ANY must answer empty NOERROR. Without them a dual-stack resolver
# stalls on the AAAA lookup and an HTTPS/SVCB (type 65) query gets SERVFAIL from
# an authoritative zone with no fallthrough -- both look like the DNS being
# broken rather than the record being absent.
if grep -qE 'template IN AAAA nebari\.local' "${RENDERED}" \
   && grep -qE 'template IN ANY nebari\.local' "${RENDERED}" \
   && [[ "$(grep -c 'rcode NOERROR' "${RENDERED}")" == 2 ]]; then
  ok "AAAA and ANY answer empty NOERROR rather than SERVFAIL"
else
  bad "the zone is missing the AAAA/ANY empty-NOERROR templates"
fi

# The closing log names where it wrote, so a no-op cannot report success.
if grep -q "In-cluster DNS ready via the coredns Corefile" <<<"${OUT}"; then
  ok "closing log names the file it wrote"
else
  bad "expected the closing log to name the coredns Corefile"
fi

# It must NOT write coredns-custom: that is the k3s convention kind ignores,
# and writing it was #104.
if grep -q "coredns-custom" "${CALLS}"; then
  bad "wrote coredns-custom, which kind's CoreDNS never reads (#104)"
else
  ok "does not write coredns-custom"
fi

# ── An existing zone for the domain is left alone, in every legal spelling ───
# Adding ours beside one of these defines the zone twice; CoreDNS then refuses
# to load and takes all cluster DNS with it.
for spelling in \
  'nebari.local {' \
  'nebari.local:53 {' \
  'nebari.local. {' \
  'nebari.local example.org {' \
  'example.org nebari.local {'; do
  printf '%s\n    errors\n}\n\n' "${spelling}" | cat - "${WORK}/corefile" \
    > "${WORK}/corefile-existing"
  drive "${WORK}/corefile-existing"
  if (( RC == 0 )) && ! grep -q "PATCH" "${CALLS}" \
     && grep -q "::warning::.*already defines a nebari.local zone" <<<"${OUT}"; then
    ok "leaves an existing zone alone: ${spelling}"
  else
    bad "should have skipped an existing '${spelling}' zone without patching (rc=${RC}, calls=$(tr '\n' ',' < "${CALLS}"))"
  fi
done

# A more specific zone is a different zone and must not block us.
printf 'sub.nebari.local:53 {\n    errors\n}\n\n' | cat - "${WORK}/corefile" \
  > "${WORK}/corefile-subzone"
drive "${WORK}/corefile-subzone"
if (( RC == 0 )) && grep -q "PATCH" "${CALLS}"; then
  ok "a more specific zone (sub.<domain>) does not block the change"
else
  bad "sub.nebari.local should not have counted as our zone (rc=${RC}, calls=$(tr '\n' ',' < "${CALLS}"))"
fi

# ── Never hand CoreDNS a Corefile that is worse than what it had ─────────────
# Reachable when the Corefile we read is already damaged: the merge inherits the
# damage, and a file CoreDNS cannot parse (or one with no default server block)
# must not be applied.
printf '.:53 {\n    errors\n' > "${WORK}/corefile-unbalanced"
drive "${WORK}/corefile-unbalanced"
if (( RC == 0 )) && ! grep -q "PATCH" "${CALLS}" \
   && grep -q "::warning::.*unbalanced braces" <<<"${OUT}"; then
  ok "refuses to apply a Corefile with unbalanced braces"
else
  bad "an unbalanced Corefile should be refused, not applied (rc=${RC}, calls=$(tr '\n' ',' < "${CALLS}"))"
fi

printf 'example.org:53 {\n    errors\n}\n' > "${WORK}/corefile-no-default"
drive "${WORK}/corefile-no-default"
if (( RC == 0 )) && ! grep -q "PATCH" "${CALLS}" \
   && grep -q "::warning::.*lost the default server block" <<<"${OUT}"; then
  ok "refuses to apply a Corefile with no default .:53 block"
else
  bad "a Corefile without .:53 should be refused (rc=${RC}, calls=$(tr '\n' ',' < "${CALLS}"))"
fi

# ── Guards skip before touching the cluster ──────────────────────────────────
for bad_input in 'DOMAIN=' 'DOMAIN=foo{}bar' 'GATEWAY_IP=' 'GATEWAY_IP=not-an-ip'; do
  CALLS="${WORK}/calls.guard"; : > "${CALLS}"
  if env CALLS="${CALLS}" RENDERED="${WORK}/r" COREFILE="${WORK}/corefile" \
       DOMAIN="nebari.local" GATEWAY_IP="10.0.0.5" "${bad_input}" \
       bash "${SCRIPT}" >/dev/null 2>&1 && [[ ! -s "${CALLS}" ]]; then
    ok "skips before kubectl on ${bad_input}"
  else
    bad "${bad_input}: expected a clean skip with no kubectl calls"
  fi
done

drive ""
if (( RC == 0 )) && [[ ! -s "${CALLS}" ]] \
   && grep -q "::warning::.*could not read the coredns ConfigMap" <<<"${OUT}"; then
  ok "an unreadable Corefile warns and mutates nothing"
else
  bad "unreadable Corefile should warn and mutate nothing (rc=${RC})"
fi

# ── Failure paths: degrade, and be honest when we cannot ─────────────────────
drive "${WORK}/corefile" PATCH_FAILS=yes
if (( RC == 0 )) && ! grep -q "ROLLOUT-RESTART" "${CALLS}" \
   && grep -q "::warning::.*could not patch" <<<"${OUT}"; then
  ok "a failed patch warns and skips without restarting CoreDNS"
else
  bad "failed patch should warn and skip (rc=${RC}, calls=$(tr '\n' ',' < "${CALLS}"))"
fi

drive "${WORK}/corefile" ROLLOUT_FAILS=yes
if (( RC == 0 )) && grep -q "Previous Corefile restored" <<<"${OUT}"; then
  ok "a CoreDNS that will not come back is rolled back, and the run continues"
else
  bad "failed rollout should restore and exit 0 (rc=${RC}). Output: ${OUT}"
fi
if grep -qF "kubernetes cluster.local" "${RENDERED}" \
   && ! grep -q "^nebari.local:53 {" "${RENDERED}"; then
  ok "the restored Corefile is the original, without our block"
else
  bad "rollback did not restore the original Corefile"
fi

# The important one: if the restore ITSELF fails, cluster DNS may be down. That
# has to be an error, not a reassuring warning over a green job.
# Both halves of the restore have to be verified independently: writing the old
# Corefile back is not the same as CoreDNS actually loading it.
drive "${WORK}/corefile" ROLLOUT_FAILS=yes RESTORE_PATCH_FAILS=yes
if (( RC != 0 )) && grep -q "::error::.*could not be restored" <<<"${OUT}"; then
  ok "a restore whose patch fails errors out instead of claiming DNS is fine"
else
  bad "a failed restore patch must exit non-zero with an ::error:: (rc=${RC}). Output: ${OUT}"
fi

drive "${WORK}/corefile" ROLLOUT_FAILS=yes RESTORE_ROLLOUT_FAILS=yes
if (( RC != 0 )) && grep -q "::error::.*could not be restored" <<<"${OUT}"; then
  ok "a restore CoreDNS still will not load errors out"
else
  bad "a restore whose rollout never becomes ready must exit non-zero (rc=${RC}). Output: ${OUT}"
fi

if (( fails > 0 )); then
  echo "in-cluster-dns-mechanism: ${fails} case(s) failed"
  exit 1
fi
echo "in-cluster-dns-mechanism: all cases passed"
