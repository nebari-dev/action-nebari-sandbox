#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required}"
K8S_VERSION="${K8S_VERSION:?K8S_VERSION is required}"
PROFILE="${PROFILE:-cluster-only}"

echo "::group::Create k3d cluster '${CLUSTER_NAME}' (profile: ${PROFILE})"

# Delete the cluster if it already exists (idempotent re-runs)
if k3d cluster list -o json | python3 -c "
import sys, json
clusters = json.load(sys.stdin)
sys.exit(0 if any(c['name'] == '${CLUSTER_NAME}' for c in clusters) else 1)
" 2>/dev/null; then
  echo "Cluster '${CLUSTER_NAME}' already exists, deleting first..."
  k3d cluster delete "${CLUSTER_NAME}"
fi

K3D_ARGS=(
  --image "rancher/k3s:v${K8S_VERSION}-k3s1"
  --no-lb                                          # don't run k3d's serverlb proxy
  --k3s-arg "--disable=traefik@server:0"           # Nebari uses Envoy Gateway instead
  # servicelb (klipper) stays ENABLED: with the `existing` provider NIC does
  # not deploy MetalLB, so klipper assigns the Envoy Gateway's LoadBalancer
  # IP (the k3d node IP, routable from the Linux runner).
  --wait
  --timeout 120s
)

# Source of truth for derived names (also exported as action outputs below).
GITOPS_DIR="/tmp/nebari-gitops-${CLUSTER_NAME}"

if [[ "${PROFILE}" == "platform" ]]; then
  # Mount the gitops directory so ArgoCD repo-server can access file:// repos.
  mkdir -p "${GITOPS_DIR}"
  K3D_ARGS+=(--volume "${GITOPS_DIR}:${GITOPS_DIR}")
fi

k3d cluster create "${CLUSTER_NAME}" "${K3D_ARGS[@]}"

echo "::endgroup::"

echo "::group::Verify cluster is ready"

# Wait for all nodes to be Ready
kubectl wait --for=condition=Ready nodes --all --timeout=60s

# Show cluster info
kubectl cluster-info
kubectl get nodes -o wide

echo "::endgroup::"

# The `existing` provider exposes storage_class, so deploy-platform.sh points
# NIC at k3s's built-in "local-path" class directly — no StorageClass shim
# needed (the old "standard" workaround is gone).

# Set outputs
KUBECONFIG_PATH="${HOME}/.kube/config"
k3d kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-merge-default

echo "kubeconfig=${KUBECONFIG_PATH}" >> "${GITHUB_OUTPUT}"
echo "cluster-name=${CLUSTER_NAME}" >> "${GITHUB_OUTPUT}"

# Platform-only outputs reflect resources that were actually created.
if [[ "${PROFILE}" == "platform" ]]; then
  echo "gitops-dir=${GITOPS_DIR}" >> "${GITHUB_OUTPUT}"
fi
