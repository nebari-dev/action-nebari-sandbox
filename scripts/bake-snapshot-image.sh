#!/usr/bin/env bash
# Spike (#33): build a custom k3s image with the cluster snapshot baked in.
#
# Mechanism (different from the tarball-bundle approach):
#   1. Stop the source cluster cleanly.
#   2. Extract /var/lib/rancher/k3s from the server's docker volume.
#   3. Capture the cluster's k3s token (still required — bootstrap data is
#      encrypted with it).
#   4. Build a Dockerfile FROM the same rancher/k3s base, COPY the snapshot
#      tree into the image's /var/lib/rancher/k3s layer.
#   5. Tag the result as the output image name.
#
# Restore path on the consumer side:
#   k3d cluster create --image=<this-image> --token=<captured>
#   k3d's anonymous volume gets auto-populated from the image layer on first
#   mount; k3s reads the restored state and resumes. No wipe+restore dance.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required}"
IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG is required (e.g. nebari-snapshot:spike)}"
K8S_VERSION="${K8S_VERSION:?K8S_VERSION is required (matches the base rancher/k3s tag)}"
OUTPUT_TOKEN_FILE="${OUTPUT_TOKEN_FILE:-/tmp/nebari-snapshot-token}"

SERVER="k3d-${CLUSTER_NAME}-server-0"
BUILD_DIR="/tmp/nebari-snapshot-image"

_t() { date +%s; }

echo "::group::Stop source cluster for consistent snapshot"
T=$(_t); k3d cluster stop "${CLUSTER_NAME}"; echo "stop: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Prepare build context"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/state"

# Extract the k3s state tree out of the server's anonymous docker volume.
# Excludes:
#   - overlayfs `work` dirs: mode 000 by design, no useful content, overlayfs
#     recreates them on mount.
#   - containerd runtime task state: ephemeral, contains live task handles.
#   - tmpmounts: temporary mount points, recreated on demand.
T=$(_t)
docker run --rm --volumes-from "${SERVER}" -v "${BUILD_DIR}:/output" busybox \
  sh -c '
    tar -C /var/lib/rancher/k3s \
        --exclude="agent/containerd/io.containerd.snapshotter.*/snapshots/*/work" \
        --exclude="agent/containerd/io.containerd.runtime.*" \
        --exclude="agent/containerd/tmpmounts" \
        -cf - . \
      | tar -C /output/state -xf -
  ' 2>/dev/null
# Strip device files: containerd snapshots include /dev/null etc inside the
# image rootfs, and docker build's COPY can't recreate device nodes without
# privileged mode. k3s recreates these on container startup anyway. Also
# strip sockets and fifos for the same reason.
sudo find "${BUILD_DIR}/state" \( -type c -o -type b -o -type s -o -type p \) -delete 2>/dev/null || true
echo "extract state: $(($(_t) - T))s"
sudo du -sh "${BUILD_DIR}/state" 2>/dev/null || true
echo "::endgroup::"

# IMPORTANT: don't chown the build context to the runner user. The state
# tree contains files owned by various UIDs (postgres=999, etc.) and those
# original ownerships must be preserved into the image layer or postgres
# refuses to start on restore. Use `sudo docker build` instead so the CLI
# can read the root-owned context without changing ownership.

echo "::group::Capture bootstrap token"
docker run --rm --volumes-from "${SERVER}" busybox \
  cat /var/lib/rancher/k3s/server/token 2>/dev/null > "${OUTPUT_TOKEN_FILE}"
TOKEN_BYTES=$(wc -c < "${OUTPUT_TOKEN_FILE}" || echo 0)
echo "token captured: ${TOKEN_BYTES} bytes -> ${OUTPUT_TOKEN_FILE}"
[ "${TOKEN_BYTES}" -gt 0 ] || { echo "::error::empty token"; exit 1; }
echo "::endgroup::"

echo "::group::Write Dockerfile"
cat > "${BUILD_DIR}/Dockerfile" <<DOCKERFILE
# Bake a platform-profile snapshot into the rancher/k3s base layer. When k3d
# creates its anonymous volume on first cluster start, the volume is
# auto-populated from this layer's /var/lib/rancher/k3s tree. k3s then sees
# the pre-existing state and resumes without rerunning nic deploy.
FROM rancher/k3s:v${K8S_VERSION}-k3s1
COPY state /var/lib/rancher/k3s
DOCKERFILE
cat "${BUILD_DIR}/Dockerfile"
echo "::endgroup::"

echo "::group::docker build snapshot image (as root so per-file UIDs survive)"
T=$(_t)
sudo docker build -t "${IMAGE_TAG}" "${BUILD_DIR}" >/dev/null
echo "docker build: $(($(_t) - T))s"
docker image ls "${IMAGE_TAG}"
echo "::endgroup::"

echo "::group::Restart source cluster (snapshot baked, source keeps running)"
k3d cluster start "${CLUSTER_NAME}"
echo "::endgroup::"

rm -rf "${BUILD_DIR}"
