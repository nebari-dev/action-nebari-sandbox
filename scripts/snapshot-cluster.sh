#!/usr/bin/env bash
# Snapshot a deployed platform-profile k3d cluster into a bundle directory.
#
# Captures everything needed by restore-cluster.sh to bring the same cluster
# back up on a different runner:
#   - image.tar.zst    : full /var/lib/rancher/k3s tree from the server's
#                        docker volume (containerd content store, k3s sqlite,
#                        kubelet state)
#   - gitops.tar.zst   : NIC's GitOps directory (hostPath bind, not in the
#                        volume; ArgoCD repo-server reads from here)
#   - k3s-token        : the cluster's bootstrap token. The restoring cluster
#                        must be initialized with the SAME token, otherwise
#                        k3s can't decrypt the snapshot's bootstrap data.
#   - metadata.txt     : human-readable provenance
#
# Required env:
#   CLUSTER_NAME       — name of the k3d cluster to snapshot
#   SNAPSHOT_PATH      — output directory (created if missing)
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required}"
SNAPSHOT_PATH="${SNAPSHOT_PATH:?SNAPSHOT_PATH is required}"

SERVER="k3d-${CLUSTER_NAME}-server-0"
GITOPS_DIR="/tmp/nebari-gitops-${CLUSTER_NAME}"
NETWORK_NAME="nebari-${CLUSTER_NAME}-net"

mkdir -p "${SNAPSHOT_PATH}"

_t() { date +%s; }

echo "::group::Stop cluster for consistent snapshot"
T=$(_t); k3d cluster stop "${CLUSTER_NAME}"; echo "stop: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Snapshot k3s state from server volume"
# Busybox sidecar with --volumes-from gets the docker volume mounted at the
# same path k3d uses (/var/lib/rancher/k3s). Tar to stdout, compress on host
# where zstd is known to be installed.
T=$(_t)
docker run --rm --volumes-from "${SERVER}" busybox \
  tar -C /var/lib/rancher/k3s -cf - . 2>/dev/null \
  | zstd -T0 --long=27 -o "${SNAPSHOT_PATH}/image.tar.zst"
echo "snapshot k3s state: $(($(_t) - T))s"
ls -lh "${SNAPSHOT_PATH}/image.tar.zst"
echo "::endgroup::"

echo "::group::Capture k3s bootstrap token"
# Bootstrap data in the snapshot is encrypted with the cluster's token.
# Restore needs to start a fresh cluster with the SAME token before
# overlaying the state, or k3s fatals on startup.
docker run --rm --volumes-from "${SERVER}" busybox \
  cat /var/lib/rancher/k3s/server/token 2>/dev/null > "${SNAPSHOT_PATH}/k3s-token"
TOKEN_BYTES=$(wc -c < "${SNAPSHOT_PATH}/k3s-token" || echo 0)
echo "token captured: ${TOKEN_BYTES} bytes"
[ "${TOKEN_BYTES}" -gt 0 ] || { echo "::error::empty token"; exit 1; }
echo "::endgroup::"

echo "::group::Snapshot GitOps repo (hostPath bind, separate from volume)"
T=$(_t)
tar -C "$(dirname "${GITOPS_DIR}")" -cf - "$(basename "${GITOPS_DIR}")" \
  | zstd -T0 --long=27 -o "${SNAPSHOT_PATH}/gitops.tar.zst"
echo "snapshot gitops: $(($(_t) - T))s"
ls -lh "${SNAPSHOT_PATH}/gitops.tar.zst"
echo "::endgroup::"

echo "::group::Restart cluster (snapshot is consumer-readable, source cluster keeps running)"
k3d cluster start "${CLUSTER_NAME}"
echo "::endgroup::"

cat > "${SNAPSHOT_PATH}/metadata.txt" <<META
cluster=${CLUSTER_NAME}
server_container=${SERVER}
gitops_dir=${GITOPS_DIR}
network=${NETWORK_NAME}
snapshot_taken_at=$(date -Iseconds)
action_ref=${GITHUB_SHA:-}
META
cat "${SNAPSHOT_PATH}/metadata.txt"
