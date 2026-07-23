#!/usr/bin/env bash
# Benchmark helper: block until the nebi pack's workload is actually running,
# then let it settle, so the resource-monitor window around it captures the
# pack's real steady-state footprint (not the empty-Application "Healthy" that
# ArgoCD reports before any pod exists). On timeout it dumps enough state to
# diagnose why the pack did not reconcile.
#
# Env:
#   NAMESPACE     where the pack runs (default nebari-system)
#   PACK_APP      ArgoCD Application name (default nebi-pack)
#   PACK_SELECTOR label selector for the pack's pods
#                 (default app.kubernetes.io/instance=nebi-pack)
#   READY_TIMEOUT kubectl wait timeout once pods exist (default 8m)
#   SETTLE_SECONDS steady-state sampling tail (default 60)
#   APPEAR_ATTEMPTS poll iterations (x10s) for pods to appear (default 42 = 7m)
set -uo pipefail

NAMESPACE="${NAMESPACE:-nebari-system}"
PACK_APP="${PACK_APP:-nebi-pack}"
PACK_SELECTOR="${PACK_SELECTOR:-app.kubernetes.io/instance=nebi-pack}"
READY_TIMEOUT="${READY_TIMEOUT:-8m}"
SETTLE_SECONDS="${SETTLE_SECONDS:-60}"
APPEAR_ATTEMPTS="${APPEAR_ATTEMPTS:-42}"

refresh() {  # nudge ArgoCD to reconcile now instead of on its poll cycle
  kubectl -n argocd annotate "application/$1" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
}

dump_diagnostics() {
  echo "::group::pack reconcile diagnostics"
  echo "--- Applications (argocd) ---"
  kubectl -n argocd get applications \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null || true
  echo "--- Application/${PACK_APP} conditions + operation message ---"
  kubectl -n argocd get "application/${PACK_APP}" -o jsonpath='{.status.conditions}{"\n"}{.status.operationState.message}{"\n"}{.status.operationState.syncResult.resources[*].message}{"\n"}' 2>/dev/null || echo "(Application ${PACK_APP} does not exist)"
  echo "--- NebariApp CRs ---"
  kubectl get nebariapps.nebari.dev -A 2>/dev/null || kubectl get nebariapp -A 2>/dev/null || echo "(no NebariApp CRD/CRs)"
  echo "--- pods in ${NAMESPACE} ---"
  kubectl -n "${NAMESPACE}" get pods 2>/dev/null | tail -30 || true
  echo "--- recent warning events in ${NAMESPACE} ---"
  kubectl -n "${NAMESPACE}" get events --field-selector type=Warning 2>/dev/null | tail -20 || true
  echo "::endgroup::"
}

# Nudge the App-of-Apps so it picks up apps/${PACK_APP}.yaml immediately, then
# the pack Application once it exists.
refresh nebari-root
echo "Waiting for pack pods (${PACK_SELECTOR}) to appear in ${NAMESPACE}..."
appeared=0
for i in $(seq 1 "${APPEAR_ATTEMPTS}"); do
  refresh "${PACK_APP}"
  n=$(kubectl -n "${NAMESPACE}" get pod -l "${PACK_SELECTOR}" --no-headers 2>/dev/null | grep -c . || true)
  if [ "${n:-0}" -gt 0 ]; then echo "  ${n} pod(s) after $((i*10))s"; appeared=1; break; fi
  sleep 10
done

if [ "${appeared}" -eq 0 ]; then
  echo "::warning::no pack pods appeared after $((APPEAR_ATTEMPTS*10))s"
  dump_diagnostics
else
  if ! kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
       -l "${PACK_SELECTOR}" --timeout="${READY_TIMEOUT}"; then
    echo "::warning::pack pods did not all reach Ready within ${READY_TIMEOUT}"
    dump_diagnostics
  fi
  kubectl -n "${NAMESPACE}" get pod -l "${PACK_SELECTOR}" -o wide || true
fi

# Steady-state settle so the peak reflects resident usage, not just startup.
echo "Settling ${SETTLE_SECONDS}s for steady-state sampling..."
sleep "${SETTLE_SECONDS}"
