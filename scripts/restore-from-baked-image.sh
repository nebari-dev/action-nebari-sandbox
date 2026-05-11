#!/usr/bin/env bash
# Spike (#33): bring up a platform-profile cluster from a pre-baked image.
#
# Mechanism: k3d cluster create --image=<custom> --token=<known>. k3d's
# anonymous volume is auto-populated from the image's /var/lib/rancher/k3s
# layer; k3s reads the state and resumes. The hostPath gitops mount must
# also be reconstructed (it lives outside the image; pass GITOPS_BUNDLE
# pointing at a gitops.tar.zst).
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required}"
IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG is required}"
TOKEN_FILE="${TOKEN_FILE:?TOKEN_FILE is required}"
GITOPS_BUNDLE="${GITOPS_BUNDLE:-}"   # optional; restored if set
K8S_VERSION="${K8S_VERSION:-1.32.4}"

GITOPS_DIR="/tmp/nebari-gitops-${CLUSTER_NAME}"
NETWORK_NAME="nebari-${CLUSTER_NAME}-net"

_t() { date +%s; }
RESTORE_START=$(_t)

K3S_TOKEN="$(tr -d '\n' < "${TOKEN_FILE}")"
[ -n "${K3S_TOKEN}" ] || { echo "::error::empty token in ${TOKEN_FILE}"; exit 1; }

if [ -n "${GITOPS_BUNDLE}" ]; then
  echo "::group::Restore GitOps repo (hostPath, lives outside the image)"
  T=$(_t)
  rm -rf "${GITOPS_DIR}"
  mkdir -p "${GITOPS_DIR}"
  zstd -d "${GITOPS_BUNDLE}" -c | tar -C "${GITOPS_DIR}" -xf - --strip-components=1
  chmod -R a+rX "${GITOPS_DIR}"
  echo "gitops restore: $(($(_t) - T))s"
  echo "::endgroup::"
fi

echo "::group::Recreate Docker network (192.168.1.0/24 for MetalLB)"
docker network rm "${NETWORK_NAME}" 2>/dev/null || true
docker network create --subnet 192.168.1.0/24 --gateway 192.168.1.1 "${NETWORK_NAME}"
echo "::endgroup::"

echo "::group::k3d cluster create from baked image"
T=$(_t)
K3D_ARGS=(
  --image "${IMAGE_TAG}"
  --token "${K3S_TOKEN}"
  --no-lb
  --k3s-arg "--disable=traefik@server:0"
  --k3s-arg "--disable=servicelb@server:0"
  --network "${NETWORK_NAME}"
  --wait
  --timeout 120s
)
if [ -n "${GITOPS_BUNDLE}" ]; then
  K3D_ARGS+=(--volume "${GITOPS_DIR}:${GITOPS_DIR}")
fi
k3d cluster create "${CLUSTER_NAME}" "${K3D_ARGS[@]}"
echo "k3d cluster create: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Merge kubeconfig + verify"
k3d kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-merge-default
kubectl get nodes
echo
echo "--- pods (first 20) ---"
# Use awk for line-cap instead of `| head -20` to avoid SIGPIPE under pipefail.
kubectl get pods -A 2>&1 | awk 'NR <= 20'
echo
echo "--- argocd Applications ---"
kubectl get applications -n argocd 2>/dev/null || echo "(no Applications visible)"
echo "::endgroup::"

echo "::group::Wait for pods to become Ready (so we can measure full restore cost)"
T=$(_t)
kubectl wait --for=condition=Ready pods --all -A --timeout=180s 2>&1 | tail -3 || true
echo "pod ready wait: $(($(_t) - T))s"
echo
echo "--- pod state after wait ---"
kubectl get pods -A 2>&1 | awk 'NR <= 30'
echo "::endgroup::"

TOTAL=$(($(_t) - RESTORE_START))
echo "::notice::Total restore wall-clock: ${TOTAL}s"
