#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required}"
K8S_VERSION="${K8S_VERSION:?K8S_VERSION is required}"

echo "::group::Create k3d cluster '${CLUSTER_NAME}'"

# Delete the cluster if it already exists (idempotent re-runs)
if k3d cluster list -o json | python3 -c "
import sys, json
clusters = json.load(sys.stdin)
sys.exit(0 if any(c['name'] == '${CLUSTER_NAME}' for c in clusters) else 1)
" 2>/dev/null; then
  echo "Cluster '${CLUSTER_NAME}' already exists, deleting first..."
  k3d cluster delete "${CLUSTER_NAME}"
fi

k3d cluster create "${CLUSTER_NAME}" \
  --image "rancher/k3s:v${K8S_VERSION}-k3s1" \
  --no-lb \
  --k3s-arg "--disable=traefik@server:0" \
  --wait \
  --timeout 120s

echo "::endgroup::"

echo "::group::Verify cluster is ready"

# Wait for all nodes to be Ready
kubectl wait --for=condition=Ready nodes --all --timeout=60s

# Show cluster info
kubectl cluster-info
kubectl get nodes -o wide

echo "::endgroup::"

# Set outputs
KUBECONFIG_PATH="${HOME}/.kube/config"
k3d kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-merge-default

echo "kubeconfig=${KUBECONFIG_PATH}" >> "${GITHUB_OUTPUT}"
echo "cluster-name=${CLUSTER_NAME}" >> "${GITHUB_OUTPUT}"
