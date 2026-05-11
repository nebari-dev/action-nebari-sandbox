#!/usr/bin/env bash
# Spike (#33): restore a k3d cluster's state from a volume-snapshot bundle
# produced by snapshot-cluster.sh.
#
# Iteration 2 approach: provision a fresh k3d cluster (which creates the
# server container + its volume), stop it immediately, wipe the volume,
# extract the snapshot tarball into the volume, then start the cluster so
# k3s reads the restored state on boot.
#
# IMPORTANT: the cluster name on restore must match the cluster name at
# snapshot time. The ArgoCD app repo URL is `file:///tmp/nebari-gitops-<cluster>`
# baked into the snapshot's sqlite state; node identity in k3s also depends
# on the deterministic k3d container name `k3d-<cluster>-server-0`.
set -euo pipefail

BUNDLE_DIR="${1:?usage: restore-cluster.sh <bundle-dir> <cluster-name>}"
CLUSTER="${2:?}"
SERVER="k3d-${CLUSTER}-server-0"
GITOPS_DIR="/tmp/nebari-gitops-${CLUSTER}"
NETWORK="nebari-${CLUSTER}-net"
K8S_IMAGE="rancher/k3s:v1.32.4-k3s1"

[ -d "${BUNDLE_DIR}" ] || { echo "Bundle dir not found: ${BUNDLE_DIR}"; exit 1; }
[ -f "${BUNDLE_DIR}/k3s-state.tar.zst" ] || { echo "Missing k3s-state.tar.zst"; exit 1; }
[ -f "${BUNDLE_DIR}/gitops.tar.zst" ] || { echo "Missing gitops.tar.zst"; exit 1; }

_t() { date +%s; }
RESTORE_START=$(_t)

echo "::group::Inspect bundle"
ls -lh "${BUNDLE_DIR}"
cat "${BUNDLE_DIR}/metadata.txt" 2>/dev/null || echo "(no metadata file)"
echo "::endgroup::"

echo "::group::Restore GitOps repo to ${GITOPS_DIR}"
T=$(_t)
mkdir -p "$(dirname "${GITOPS_DIR}")"
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

echo "::group::Provision fresh k3d cluster (will overwrite state next)"
T=$(_t)
k3d cluster create "${CLUSTER}" \
  --image "${K8S_IMAGE}" \
  --no-lb \
  --k3s-arg "--disable=traefik@server:0" \
  --k3s-arg "--disable=servicelb@server:0" \
  --network "${NETWORK}" \
  --volume "${GITOPS_DIR}:${GITOPS_DIR}" \
  --wait \
  --timeout 90s
echo "k3d create (fresh): $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Stop cluster (so we can overwrite the volume)"
T=$(_t); k3d cluster stop "${CLUSTER}"; echo "stop: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Wipe + restore k3s state into server volume"
T=$(_t)
# Stream the decompressed tarball into a busybox sidecar that shares the
# server container's volumes. Sidecar wipes the existing /var/lib/rancher/k3s
# contents and extracts the snapshot in place.
zstd -d "${BUNDLE_DIR}/k3s-state.tar.zst" -c \
  | docker run --rm -i --volumes-from "${SERVER}" busybox \
      sh -c 'set -e; rm -rf /var/lib/rancher/k3s/* /var/lib/rancher/k3s/.??* 2>/dev/null || true; tar -C /var/lib/rancher/k3s -xf -'
echo "wipe+restore: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Start cluster with restored state"
T=$(_t); k3d cluster start "${CLUSTER}"; echo "start: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Merge kubeconfig"
k3d kubeconfig merge "${CLUSTER}" --kubeconfig-merge-default
echo "::endgroup::"

echo "::group::Wait for node Ready (briefly)"
kubectl wait --for=condition=Ready nodes --all --timeout=60s || echo "(node not Ready yet)"
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
