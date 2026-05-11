#!/usr/bin/env bash
# Spike (#33): snapshot a deployed k3d cluster's STATE for later restoration.
#
# Iteration 2: snapshot the docker VOLUME that k3d mounts at
# /var/lib/rancher/k3s, not the container's writable layer. The earlier
# `docker commit` approach captured a near-empty image because containerd's
# content store, k3s sqlite DB, and kubelet state all live in the volume,
# not the container image.
#
# Captures two artifacts into <output-dir>:
#   - k3s-state.tar.zst — full /var/lib/rancher/k3s tree from the server volume
#   - gitops.tar.zst    — NIC's GitOps directory (hostPath bind on the host,
#                          not in the volume; ArgoCD's file:// repo source)
set -euo pipefail

CLUSTER="${1:?usage: snapshot-cluster.sh <cluster-name> <output-dir>}"
OUTPUT_DIR="${2:?}"
SERVER="k3d-${CLUSTER}-server-0"
GITOPS_DIR="/tmp/nebari-gitops-${CLUSTER}"
NETWORK="nebari-${CLUSTER}-net"

mkdir -p "${OUTPUT_DIR}"

_t() { date +%s; }

echo "::group::Stop cluster (clean shutdown for k3s sqlite/etcd)"
T=$(_t); k3d cluster stop "${CLUSTER}"; echo "stop: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Snapshot k3s state from server volume"
# Use a busybox sidecar that shares the server container's volumes. Tar the
# /var/lib/rancher/k3s tree to stdout, compress on host where zstd is known
# to be installed (avoids apk install inside the sidecar).
T=$(_t)
docker run --rm --volumes-from "${SERVER}" busybox \
  tar -C /var/lib/rancher/k3s -cf - . 2>/dev/null \
  | zstd -T0 -o "${OUTPUT_DIR}/k3s-state.tar.zst"
echo "snapshot k3s state: $(($(_t) - T))s"
ls -lh "${OUTPUT_DIR}/k3s-state.tar.zst"
echo "::endgroup::"

echo "::group::Capture k3s bootstrap token"
# k3s encrypts cluster bootstrap data (CA, certs, etcd/sqlite keys) with a
# token at /var/lib/rancher/k3s/server/token. On restore we have to use the
# SAME token for the fresh cluster init, otherwise the restored encrypted
# data can't be decrypted by the new server and k3s fatals on startup with
# "bootstrap data already found and encrypted with different token".
docker run --rm --volumes-from "${SERVER}" busybox \
  cat /var/lib/rancher/k3s/server/token 2>/dev/null > "${OUTPUT_DIR}/k3s-token"
TOKEN_BYTES=$(wc -c < "${OUTPUT_DIR}/k3s-token" || echo 0)
echo "token captured: ${TOKEN_BYTES} bytes"
[ "${TOKEN_BYTES}" -gt 0 ] || { echo "::error::empty token"; exit 1; }
echo "::endgroup::"

echo "::group::Snapshot GitOps repo (hostPath bind, separate from volume)"
T=$(_t)
tar -C "$(dirname "${GITOPS_DIR}")" -cf - "$(basename "${GITOPS_DIR}")" \
  | zstd -T0 -o "${OUTPUT_DIR}/gitops.tar.zst"
echo "snapshot gitops: $(($(_t) - T))s"
ls -lh "${OUTPUT_DIR}/gitops.tar.zst"
echo "::endgroup::"

echo "::group::Record metadata"
cat > "${OUTPUT_DIR}/metadata.txt" <<META
cluster=${CLUSTER}
server_container=${SERVER}
gitops_dir=${GITOPS_DIR}
network=${NETWORK}
k8s_version=$(kubectl version --client -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('clientVersion',{}).get('gitVersion','?'))" 2>/dev/null || echo "?")
snapshot_taken_at=$(date -Iseconds)
META
cat "${OUTPUT_DIR}/metadata.txt"
echo "::endgroup::"
