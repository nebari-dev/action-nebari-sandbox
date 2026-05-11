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
  --k3s-arg "--disable=servicelb@server:0"         # let MetalLB own LoadBalancer services
  --wait
  --timeout 120s
)

# K3S_TOKEN is set by restore-cluster.sh when bringing up a cluster that will
# have its volume replaced from a snapshot — k3s decrypts the snapshot's
# bootstrap data with this token, so the fresh provision must use the same
# value. Unset for normal create flows.
if [[ -n "${K3S_TOKEN:-}" ]]; then
  K3D_ARGS+=(--token "${K3S_TOKEN}")
fi

# Source of truth for derived names (also exported as action outputs below).
NETWORK_NAME="nebari-${CLUSTER_NAME}-net"
GITOPS_DIR="/tmp/nebari-gitops-${CLUSTER_NAME}"

if [[ "${PROFILE}" == "platform" ]]; then
  # NIC's local provider uses MetalLB with a hardcoded 192.168.1.100-110 pool.
  # Create a Docker network matching that subnet so MetalLB IPs are routable.
  if ! docker network inspect "${NETWORK_NAME}" &>/dev/null; then
    echo "Creating Docker network '${NETWORK_NAME}' (192.168.1.0/24)..."
    docker network create --subnet 192.168.1.0/24 --gateway 192.168.1.1 "${NETWORK_NAME}"
  fi
  K3D_ARGS+=(--network "${NETWORK_NAME}")

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

if [[ "${PROFILE}" == "platform" ]]; then
  echo "::group::Create 'standard' StorageClass (workaround)"

  # NIC's local provider hardcodes StorageClass "standard", but k3s only ships
  # "local-path". Create a "standard" class backed by the same provisioner.
  # TODO: Remove once nebari-dev/nebari-infrastructure-core#201 merges and
  #       NIC supports configuring storage_class per provider.
  kubectl apply -f - <<'SC'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
SC

  echo "::endgroup::"
fi

# Set outputs
KUBECONFIG_PATH="${HOME}/.kube/config"
k3d kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-merge-default

echo "kubeconfig=${KUBECONFIG_PATH}" >> "${GITHUB_OUTPUT}"
echo "cluster-name=${CLUSTER_NAME}" >> "${GITHUB_OUTPUT}"

# Platform-only outputs reflect resources that were actually created.
if [[ "${PROFILE}" == "platform" ]]; then
  echo "network-name=${NETWORK_NAME}" >> "${GITHUB_OUTPUT}"
  echo "gitops-dir=${GITOPS_DIR}" >> "${GITHUB_OUTPUT}"
fi
