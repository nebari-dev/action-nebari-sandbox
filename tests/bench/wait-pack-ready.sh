#!/usr/bin/env bash
# Benchmark helper: block until the nebi pack's workload is actually running,
# then let it settle, so the resource-monitor window around it captures the
# pack's real steady-state footprint (not the empty-Application "Healthy" that
# ArgoCD reports before any pod exists).
#
# Env:
#   NAMESPACE     where the pack runs (default nebari-system)
#   PACK_SELECTOR label selector for the pack's pods
#                 (default app.kubernetes.io/instance=nebi-pack)
#   READY_TIMEOUT kubectl wait timeout once pods exist (default 8m)
#   SETTLE_SECONDS steady-state sampling tail (default 60)
set -uo pipefail

NAMESPACE="${NAMESPACE:-nebari-system}"
PACK_SELECTOR="${PACK_SELECTOR:-app.kubernetes.io/instance=nebi-pack}"
READY_TIMEOUT="${READY_TIMEOUT:-8m}"
SETTLE_SECONDS="${SETTLE_SECONDS:-60}"

# 1. Wait for ArgoCD to create at least one pack pod (reconcile latency).
echo "Waiting for pack pods (${PACK_SELECTOR}) to appear in ${NAMESPACE}..."
for i in $(seq 1 60); do
  n=$(kubectl -n "${NAMESPACE}" get pod -l "${PACK_SELECTOR}" --no-headers 2>/dev/null | grep -c . || true)
  [ "${n:-0}" -gt 0 ] && { echo "  ${n} pod(s) after $((i*10))s"; break; }
  sleep 10
done

# 2. Wait for them to become Ready. Don't hard-fail the benchmark if one lags;
#    report status and still take the settle sample (partial footprint > none).
if ! kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
     -l "${PACK_SELECTOR}" --timeout="${READY_TIMEOUT}"; then
  echo "::warning::pack pods did not all reach Ready within ${READY_TIMEOUT}"
fi
kubectl -n "${NAMESPACE}" get pod -l "${PACK_SELECTOR}" -o wide || true

# 3. Steady-state settle so the peak reflects resident usage, not just startup.
echo "Settling ${SETTLE_SECONDS}s for steady-state sampling..."
sleep "${SETTLE_SECONDS}"
