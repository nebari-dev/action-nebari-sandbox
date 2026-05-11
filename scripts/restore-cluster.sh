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
[ -f "${BUNDLE_DIR}/k3s-token" ] || { echo "Missing k3s-token"; exit 1; }

# The fresh cluster must be initialized with the SAME bootstrap token that
# was used by the original cluster; otherwise the restored encrypted data
# can't be decrypted and k3s fatals on startup.
K3S_TOKEN_VALUE="$(tr -d '\n' < "${BUNDLE_DIR}/k3s-token")"
[ -n "${K3S_TOKEN_VALUE}" ] || { echo "Empty k3s token"; exit 1; }

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
  --token "${K3S_TOKEN_VALUE}" \
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

echo "::group::Start container directly (bypass k3d's blocking wait)"
T=$(_t)
# `k3d cluster start` hangs indefinitely if k3s can't come up with the
# restored state. Bypass that by starting the docker container directly
# and polling for k3s readiness ourselves, surfacing k3s logs along the way
# so we can see WHY it isn't coming up if it fails.
docker start "${SERVER}"
echo "container started in $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Poll for k3s readiness (using in-container kubectl)"
# Use kubectl from inside the server container, which reads /etc/rancher/k3s/k3s.yaml.
# Bypasses the host-side kubeconfig that k3d wrote with the FRESH cluster's CA
# (now stale because the wipe+restore replaced the server CA with the snapshot's).
KC="kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml"
POLL_START=$(_t)
READY=0
for i in $(seq 1 60); do
  if docker exec "${SERVER}" sh -c "${KC} get --raw=/readyz" >/dev/null 2>&1 && \
     docker exec "${SERVER}" sh -c "${KC} get nodes --no-headers" 2>/dev/null \
       | awk '{print $2}' | grep -q '^Ready$'; then
    READY=1
    echo "k3s Ready after $(($(_t) - POLL_START))s"
    break
  fi
  printf '  poll %d (%ds elapsed)\n' "$i" "$(($(_t) - POLL_START))"
  if (( i % 6 == 0 )); then
    echo "  --- recent container logs ---"
    docker logs --tail 30 "${SERVER}" 2>&1 | sed 's/^/  /'
  fi
  sleep 10
done

if (( READY == 0 )); then
  echo "::error::k3s did not become Ready within the poll window"
  echo "--- final container logs ---"
  docker logs --tail 200 "${SERVER}" 2>&1
fi
echo "::endgroup::"

echo "::group::Cluster state immediately after restore (via in-container kubectl)"
# Stale host kubeconfig: bypass it and run against the in-container k3s.yaml.
docker exec "${SERVER}" ${KC} get nodes -o wide
echo
echo "--- pods (all namespaces) ---"
docker exec "${SERVER}" ${KC} get pods -A
echo
echo "--- argocd applications ---"
docker exec "${SERVER}" ${KC} get applications -n argocd 2>/dev/null \
  || echo "(no Applications visible)"
echo
echo "--- namespaces ---"
docker exec "${SERVER}" ${KC} get namespaces
echo "::endgroup::"

TOTAL=$(($(_t) - RESTORE_START))
echo "total_restore_seconds=${TOTAL}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "::notice::Total restore wall-clock: ${TOTAL}s"
