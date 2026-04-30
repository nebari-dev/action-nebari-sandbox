#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required}"
K8S_VERSION="${K8S_VERSION:?K8S_VERSION is required}"
PROFILE="${PROFILE:-cluster-only}"

# ── timing helpers ────────────────────────────────────────────────────────────
_TIMING_FILE="/tmp/nebari-timing-${CLUSTER_NAME}.tsv"
_now_ms()        { date +%s%3N; }
_record_timing() {          # label start_ms end_ms
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "${_TIMING_FILE}"
}
# ─────────────────────────────────────────────────────────────────────────────

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

# When timing instrumentation is requested, pre-pull the k3s image explicitly
# so we can separate pull latency from cluster initialisation time.
if [[ "${NEBARI_TIMING_REPORT:-false}" == "true" ]]; then
  echo "::group::Pre-pull k3s image (timing instrumentation)"
  _t0=$(_now_ms)
  docker pull "rancher/k3s:v${K8S_VERSION}-k3s1"
  _t1=$(_now_ms)
  _record_timing "k3s image pull (docker hub)" "${_t0}" "${_t1}"
  echo "k3s image pull: $(( (_t1 - _t0) / 1000 ))s"
  echo "::endgroup::"
fi

_k3d_start=$(_now_ms)
k3d cluster create "${CLUSTER_NAME}" "${K3D_ARGS[@]}"
if [[ "${NEBARI_TIMING_REPORT:-false}" == "true" ]]; then
  _record_timing "k3d cluster create" "${_k3d_start}" "$(_now_ms)"
fi

echo "::endgroup::"

echo "::group::Verify cluster is ready"

# Wait for all nodes to be Ready
_kw_start=$(_now_ms)
kubectl wait --for=condition=Ready nodes --all --timeout=60s
if [[ "${NEBARI_TIMING_REPORT:-false}" == "true" ]]; then
  _record_timing "kubectl wait nodes ready" "${_kw_start}" "$(_now_ms)"
fi

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
