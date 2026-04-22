#!/usr/bin/env bash
set -euo pipefail

echo "=== Awaiting workloads in namespace: ${NAMESPACE} (timeout: ${TIMEOUT}s, max-restarts: ${MAX_RESTARTS}) ==="

for kind in deployment daemonset statefulset; do
  names=$(kubectl get "$kind" -n "$NAMESPACE" --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true)
  for name in $names; do
    echo "  rollout status: ${kind}/${name}"
    kubectl rollout status "${kind}/${name}" -n "$NAMESPACE" --timeout="${TIMEOUT}s"
  done
done

if [[ "${MAX_RESTARTS}" -ge 0 ]]; then
  echo "Checking container restart counts (max: ${MAX_RESTARTS})..."
  # Collect any container whose restartCount exceeds the limit
  exceeded=$(
    kubectl get pods -n "$NAMESPACE" -o json \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for pod in data['items']:
  pod_name = pod['metadata']['name']
  for cs in pod.get('status', {}).get('containerStatuses', []):
    rc = cs.get('restartCount', 0)
    if rc > int('${MAX_RESTARTS}'):
      print(f\"{pod_name}/{cs['name']}: {rc} restarts\")
" 2>/dev/null || true
  )
  if [[ -n "$exceeded" ]]; then
    echo "ERROR: containers exceeded max-restarts=${MAX_RESTARTS}:"
    echo "$exceeded"
    exit 1
  fi
fi

echo "All workloads in ${NAMESPACE} are ready."
