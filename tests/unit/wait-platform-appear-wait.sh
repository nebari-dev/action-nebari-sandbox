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

FAILS=0

ok()   { echo "  ok    $*"; }
fail() { echo "::error::$*"; FAILS=$((FAILS + 1)); }

# Fake kubectl on PATH: every namespace has one immediately-visible deployment
# except keycloak, whose statefulset only appears from the Nth `get statefulset`
# call (KC_APPEAR_AFTER), mimicking a resource created mid-sync. The call
# counter persists in STATE_DIR across invocations.
install_kubectl_stub() {
  STUB_DIR="$(mktemp -d)"
  trap 'rm -rf "${STUB_DIR}"' EXIT
  export STATE_DIR="${STUB_DIR}/state"
  mkdir -p "${STATE_DIR}"

  cat > "${STUB_DIR}/kubectl" <<'EOF'
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
          metallb-system) echo "metallb-controller" ;;
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
  chmod +x "${STUB_DIR}/kubectl"
  export PATH="${STUB_DIR}:${PATH}"
}

# Run the gate with a fresh stub state. Args: <timeout-seconds> <appear-after>.
# Results land in the globals GATE_RC and GATE_OUT (command substitution eats
# a function's exit code under `set -e`, so a return value can't carry both).
run_gate() {
  local timeout="$1" appear_after="$2"
  rm -f "${STATE_DIR}/kc-sts-calls"
  GATE_RC=0
  GATE_OUT="$(AWAIT_TIMEOUT="${timeout}" KEYCLOAK_AWAIT_TIMEOUT="${timeout}" \
              WAIT_POLL_INTERVAL=1 KC_APPEAR_AFTER="${appear_after}" \
              bash "${SCRIPT}" 2>&1)" || GATE_RC=$?
}

kc_poll_count() { cat "${STATE_DIR}/kc-sts-calls" 2>/dev/null || echo 0; }

test_late_appearing_statefulset_is_awaited() {
  run_gate 30 3   # statefulset appears on the 3rd poll -> gate must succeed
  if (( GATE_RC != 0 )); then
    fail "gate failed on a late-appearing statefulset (rc=${GATE_RC}). Output: ${GATE_OUT}"
  elif ! grep -q "statefulset/keycloak-keycloakx" <<<"${GATE_OUT}"; then
    fail "gate passed but never waited on keycloak-keycloakx. Output: ${GATE_OUT}"
  elif (( $(kc_poll_count) < 3 )); then
    fail "expected >=3 statefulset polls before appearance; saw $(kc_poll_count)"
  else
    ok "late-appearing statefulset is awaited and gate passes"
  fi
}

test_never_appearing_resources_still_fail() {
  run_gate 3 9999   # statefulset never appears -> gate must fail after timeout
  if (( GATE_RC == 0 )); then
    fail "gate passed although keycloak never got any rollout resource"
  elif ! grep -q "no deployment/daemonset/statefulset found in keycloak" <<<"${GATE_OUT}"; then
    fail "gate failed without the missing-workload message. Output: ${GATE_OUT}"
  else
    ok "never-appearing resources still fail the gate after the timeout"
  fi
}

main() {
  install_kubectl_stub
  test_late_appearing_statefulset_is_awaited
  test_never_appearing_resources_still_fail

  if (( FAILS > 0 )); then
    echo "wait-platform-appear-wait: ${FAILS} case(s) failed"
    exit 1
  fi
  echo "wait-platform-appear-wait: all cases passed"
}

main "$@"
