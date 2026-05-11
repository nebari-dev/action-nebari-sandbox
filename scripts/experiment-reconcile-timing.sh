#!/usr/bin/env bash
# Validation experiment for #33: app reconcile timing.
#
# Polls the restored cluster after restore-cluster.sh completes, measuring:
#   - Time until all 14 foundational Applications report status.sync.status=Synced
#   - Time until all 14 report status.health.status=Healthy
#   - Time until all pods across foundational namespaces are Ready
#
# Reports to $GITHUB_STEP_SUMMARY. Useful for answering the open question
# from #33's analysis: how long after `cluster Ready` until tests can
# actually run against the platform?
set -euo pipefail

CLUSTER="${1:?usage: experiment-reconcile-timing.sh <cluster>}"
SERVER="k3d-${CLUSTER}-server-0"
KC="kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml"
TIMEOUT_S="${TIMEOUT_S:-300}"

_t() { date +%s; }
START=$(_t)
declare -A FIRST_SEEN

probe_apps() {
  docker exec "${SERVER}" sh -c "${KC} get applications -n argocd \
    -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.status.sync.status}{\"\\t\"}{.status.health.status}{\"\\n\"}{end}'" \
    2>/dev/null || true
}

probe_pods() {
  docker exec "${SERVER}" sh -c "${KC} get pods -A \
    --field-selector=status.phase!=Succeeded \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{\"\\t\"}{.metadata.name}{\"\\t\"}{.status.phase}{\"\\n\"}{end}'" \
    2>/dev/null || true
}

echo "::group::Polling for reconcile (timeout ${TIMEOUT_S}s)"

ALL_SYNCED_AT=""
ALL_HEALTHY_AT=""
ALL_PODS_READY_AT=""

while (( $(_t) - START < TIMEOUT_S )); do
  ELAPSED=$(( $(_t) - START ))

  APPS=$(probe_apps)
  PODS=$(probe_pods)

  if [ -z "${APPS}" ]; then
    printf '  t=%3ds  (waiting for Applications to appear)\n' "${ELAPSED}"
    sleep 5
    continue
  fi

  TOTAL_APPS=$(echo "${APPS}" | wc -l)
  N_SYNCED=$(echo "${APPS}" | awk -F'\t' '$2 == "Synced"' | wc -l)
  N_HEALTHY=$(echo "${APPS}" | awk -F'\t' '$3 == "Healthy"' | wc -l)

  PENDING_PODS=$(echo "${PODS}" | awk -F'\t' '$3 != "Running" && $3 != ""' | wc -l)

  printf '  t=%3ds  synced=%d/%d  healthy=%d/%d  pods-pending=%d\n' \
    "${ELAPSED}" "${N_SYNCED}" "${TOTAL_APPS}" "${N_HEALTHY}" "${TOTAL_APPS}" "${PENDING_PODS}"

  if [ -z "${ALL_SYNCED_AT}" ] && [ "${N_SYNCED}" -eq "${TOTAL_APPS}" ] && [ "${TOTAL_APPS}" -gt 0 ]; then
    ALL_SYNCED_AT="${ELAPSED}"
    echo "  >>> all ${TOTAL_APPS} apps Synced at t=${ELAPSED}s"
  fi
  if [ -z "${ALL_HEALTHY_AT}" ] && [ "${N_HEALTHY}" -eq "${TOTAL_APPS}" ] && [ "${TOTAL_APPS}" -gt 0 ]; then
    ALL_HEALTHY_AT="${ELAPSED}"
    echo "  >>> all ${TOTAL_APPS} apps Healthy at t=${ELAPSED}s"
  fi
  if [ -z "${ALL_PODS_READY_AT}" ] && [ "${PENDING_PODS}" -eq 0 ]; then
    ALL_PODS_READY_AT="${ELAPSED}"
    echo "  >>> all pods Running at t=${ELAPSED}s"
  fi

  if [ -n "${ALL_SYNCED_AT}" ] && [ -n "${ALL_HEALTHY_AT}" ] && [ -n "${ALL_PODS_READY_AT}" ]; then
    echo "All convergence targets met."
    break
  fi

  sleep 5
done

echo "::endgroup::"

echo "::group::Final pod + Application state"
echo "--- Applications ---"
docker exec "${SERVER}" ${KC} get applications -n argocd
echo "--- Pods (foundational namespaces) ---"
docker exec "${SERVER}" ${KC} get pods -A --field-selector=status.phase!=Succeeded
echo "::endgroup::"

{
  echo "## Reconcile timing"
  echo
  echo "| Target | Elapsed since restore completed |"
  echo "|---|---:|"
  echo "| All Applications Synced  | ${ALL_SYNCED_AT:-not reached within ${TIMEOUT_S}s}s |"
  echo "| All Applications Healthy | ${ALL_HEALTHY_AT:-not reached within ${TIMEOUT_S}s}s |"
  echo "| All pods Running         | ${ALL_PODS_READY_AT:-not reached within ${TIMEOUT_S}s}s |"
  echo
  echo "Restore script's wall-clock + this delay is the realistic time to 'cluster usable by tests'."
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
