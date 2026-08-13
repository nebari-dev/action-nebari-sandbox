#!/usr/bin/env bash
# Unit test (no cluster): scripts/wait-platform.sh must wait for rollout
# resources to APPEAR, not just to become ready. When the gate starts while
# the platform is still syncing (e.g. Keycloak's StatefulSet is created only
# after its database initializes), the namespace briefly has zero rollout
# resources. The gate used to treat that first empty look as "never installed"
# and fail a healthy in-progress deploy.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/wait-platform.sh"

STUB="$(mktemp -d)"
trap 'rm -rf "${STUB}"' EXIT
export STATE_DIR="${STUB}/state"
mkdir -p "${STATE_DIR}"

# Fake kubectl: every namespace has one immediately-visible deployment except
# keycloak, whose statefulset only appears from the Nth `get statefulset` call
# (KC_APPEAR_AFTER), mimicking a resource created mid-sync. Counter persists in
# STATE_DIR across invocations.
cat > "${STUB}/kubectl" <<'EOF'
#!/usr/bin/env bash
ns=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  [[ "${args[$i]}" == "-n" ]] && ns="${args[$((i+1))]}"
done
case "$1" in
  get)
    case "$2" in
      nodes|namespace) exit 0 ;;
      pods) echo '{"items":[]}'; exit 0 ;;
      deployment)
        case "$ns" in
          argocd) echo "argocd-server" ;;
          cert-manager) echo "cert-manager" ;;
          envoy-gateway-system) echo "envoy-gateway" ;;
        esac
        exit 0 ;;
      daemonset) exit 0 ;;
      statefulset)
        if [[ "$ns" == "keycloak" ]]; then
          count_file="${STATE_DIR}/kc-sts-calls"
          count=$(( $(cat "${count_file}" 2>/dev/null || echo 0) + 1 ))
          echo "${count}" > "${count_file}"
          (( count >= ${KC_APPEAR_AFTER:-3} )) && echo "keycloak-keycloakx"
        fi
        exit 0 ;;
    esac
    exit 0 ;;
  rollout)
    echo "rolled out"
    exit 0 ;;
esac
exit 0
EOF
chmod +x "${STUB}/kubectl"
export PATH="${STUB}:${PATH}"

fails=0

# --- Case 1: resource appears on the 3rd poll -> gate must succeed ----------
: > "${STATE_DIR}/kc-sts-calls" 2>/dev/null || true
rm -f "${STATE_DIR}/kc-sts-calls"
out="$(AWAIT_TIMEOUT=30 KEYCLOAK_AWAIT_TIMEOUT=30 WAIT_POLL_INTERVAL=1 \
       KC_APPEAR_AFTER=3 bash "${SCRIPT}" 2>&1)" && rc=0 || rc=$?
kc_calls="$(cat "${STATE_DIR}/kc-sts-calls" 2>/dev/null || echo 0)"
if (( rc != 0 )); then
  echo "::error::gate failed on a late-appearing statefulset (rc=${rc}). Output: ${out}"
  fails=$((fails + 1))
elif ! grep -q "statefulset/keycloak-keycloakx" <<<"${out}"; then
  echo "::error::gate passed but never waited on keycloak-keycloakx. Output: ${out}"
  fails=$((fails + 1))
elif (( kc_calls < 3 )); then
  echo "::error::expected >=3 statefulset polls before appearance; saw ${kc_calls}"
  fails=$((fails + 1))
else
  echo "  ok    late-appearing statefulset is awaited and gate passes"
fi

# --- Case 2: resources never appear -> gate still fails after the timeout ---
rm -f "${STATE_DIR}/kc-sts-calls"
out="$(AWAIT_TIMEOUT=3 KEYCLOAK_AWAIT_TIMEOUT=3 WAIT_POLL_INTERVAL=1 \
       KC_APPEAR_AFTER=9999 bash "${SCRIPT}" 2>&1)" && rc=0 || rc=$?
if (( rc == 0 )); then
  echo "::error::gate passed although keycloak never got any rollout resource"
  fails=$((fails + 1))
elif ! grep -q "no deployment/daemonset/statefulset found in keycloak" <<<"${out}"; then
  echo "::error::gate failed without the missing-workload message. Output: ${out}"
  fails=$((fails + 1))
else
  echo "  ok    never-appearing resources still fail the gate after the timeout"
fi

if (( fails > 0 )); then
  echo "wait-platform-appear-wait: ${fails} case(s) failed"
  exit 1
fi
echo "wait-platform-appear-wait: all cases passed"
