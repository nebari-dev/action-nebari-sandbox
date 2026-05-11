#!/usr/bin/env bash
# Spike (#33): capture a deployed k3d cluster for later restoration.
#
# Captures two artifacts into <output-dir>:
#   - image.tar.zst   — committed k3d server container as a docker image
#   - gitops.tar.zst  — the NIC-managed GitOps directory hostPath mount
#
# The gitops dir is captured separately because it's a hostPath bind into the
# k3d container, not part of the container's writable layer. Without it,
# ArgoCD's repo-server would fail to read the platform manifests on restore.
set -euo pipefail

CLUSTER="${1:?usage: snapshot-cluster.sh <cluster-name> <output-dir>}"
OUTPUT_DIR="${2:?}"
SERVER="k3d-${CLUSTER}-server-0"
GITOPS_DIR="/tmp/nebari-gitops-${CLUSTER}"
NETWORK="nebari-${CLUSTER}-net"

mkdir -p "${OUTPUT_DIR}"

_t() { date +%s; }

echo "::group::Stop cluster (clean shutdown for k3s state)"
T=$(_t); k3d cluster stop "${CLUSTER}"; echo "stop: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Commit server container"
T=$(_t); docker commit "${SERVER}" "nebari-platform-snapshot:spike"; echo "commit: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Save + compress image"
T=$(_t)
docker save nebari-platform-snapshot:spike | zstd -T0 -o "${OUTPUT_DIR}/image.tar.zst"
echo "save+zstd: $(($(_t) - T))s"
ls -lh "${OUTPUT_DIR}/image.tar.zst"
echo "::endgroup::"

echo "::group::Snapshot GitOps repo"
T=$(_t)
tar -C "$(dirname "${GITOPS_DIR}")" -cf - "$(basename "${GITOPS_DIR}")" \
  | zstd -T0 -o "${OUTPUT_DIR}/gitops.tar.zst"
echo "gitops save: $(($(_t) - T))s"
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
