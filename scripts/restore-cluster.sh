#!/usr/bin/env bash
# Spike (#33): restore a k3d cluster from a snapshot bundle produced by
# scripts/snapshot-cluster.sh. Loads the committed image, restores the
# GitOps hostPath dir, recreates the docker network with the same subnet,
# and brings up the cluster with the same k3d flags as create-cluster.sh.
set -euo pipefail

BUNDLE_DIR="${1:?usage: restore-cluster.sh <bundle-dir> <new-cluster-name>}"
CLUSTER="${2:?}"
GITOPS_DIR="/tmp/nebari-gitops-${CLUSTER}"
NETWORK="nebari-${CLUSTER}-net"

[ -d "${BUNDLE_DIR}" ] || { echo "Bundle dir not found: ${BUNDLE_DIR}"; exit 1; }
[ -f "${BUNDLE_DIR}/image.tar.zst" ] || { echo "Missing image.tar.zst"; exit 1; }
[ -f "${BUNDLE_DIR}/gitops.tar.zst" ] || { echo "Missing gitops.tar.zst"; exit 1; }

_t() { date +%s; }
RESTORE_START=$(_t)

echo "::group::Inspect bundle"
ls -lh "${BUNDLE_DIR}"
cat "${BUNDLE_DIR}/metadata.txt" 2>/dev/null || echo "(no metadata file)"
echo "::endgroup::"

echo "::group::Load snapshot image"
T=$(_t)
zstd -d "${BUNDLE_DIR}/image.tar.zst" -c | docker load
echo "load: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Restore GitOps repo to ${GITOPS_DIR}"
T=$(_t)
mkdir -p "$(dirname "${GITOPS_DIR}")"
# Strip the leading directory from the tar so the contents land at GITOPS_DIR
# regardless of what the original cluster's path looked like.
rm -rf "${GITOPS_DIR}"
mkdir -p "${GITOPS_DIR}"
zstd -d "${BUNDLE_DIR}/gitops.tar.zst" -c \
  | tar -C "${GITOPS_DIR}" -xf - --strip-components=1
chmod -R a+rX "${GITOPS_DIR}"
echo "gitops restore: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Recreate Docker network (192.168.1.0/24)"
docker network rm "${NETWORK}" 2>/dev/null || true
docker network create --subnet 192.168.1.0/24 --gateway 192.168.1.1 "${NETWORK}"
echo "::endgroup::"

echo "::group::Create k3d cluster from snapshot image"
T=$(_t)
k3d cluster create "${CLUSTER}" \
  --image "nebari-platform-snapshot:spike" \
  --no-lb \
  --k3s-arg "--disable=traefik@server:0" \
  --k3s-arg "--disable=servicelb@server:0" \
  --network "${NETWORK}" \
  --volume "${GITOPS_DIR}:${GITOPS_DIR}" \
  --wait \
  --timeout 120s
echo "k3d create: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Merge kubeconfig"
k3d kubeconfig merge "${CLUSTER}" --kubeconfig-merge-default
echo "::endgroup::"

echo "::group::Cluster state immediately after restore"
kubectl get nodes
echo
echo "--- pods (all namespaces) ---"
kubectl get pods -A
echo
echo "--- argocd applications ---"
kubectl get applications -n argocd 2>/dev/null || echo "(no Applications visible)"
echo "::endgroup::"

TOTAL=$(($(_t) - RESTORE_START))
echo "total_restore_seconds=${TOTAL}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "::notice::Total restore wall-clock: ${TOTAL}s"
