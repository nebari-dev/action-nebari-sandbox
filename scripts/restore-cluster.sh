#!/usr/bin/env bash
# Restore a platform-profile k3d cluster from a snapshot bundle produced by
# snapshot-cluster.sh.
#
# Flow:
#   1. Read the snapshot's k3s token. The fresh cluster must be initialized
#      with the SAME token or k3s can't decrypt the snapshot's bootstrap data.
#   2. Delegate cluster provisioning to create-cluster.sh (single source of
#      truth for k3d flags, network setup, gitops dir mount). K3S_TOKEN is
#      passed through env.
#   3. Stop the just-provisioned (empty) cluster.
#   4. Wipe its /var/lib/rancher/k3s volume and extract the snapshot tarball
#      into it via a busybox sidecar.
#   5. Restore the GitOps hostPath dir from the snapshot.
#   6. Start the cluster. k3s reads the restored state on boot and resumes.
#   7. Refresh the host kubeconfig from inside the running server — the
#      cluster's CA changed when we replaced the state, so the kubeconfig
#      k3d wrote during step 2 is stale.
#
# Required env (some come from action.yml, some derived):
#   CLUSTER_NAME, K8S_VERSION, PROFILE, SNAPSHOT_PATH
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required}"
SNAPSHOT_PATH="${SNAPSHOT_PATH:?SNAPSHOT_PATH is required}"
SERVER="k3d-${CLUSTER_NAME}-server-0"
GITOPS_DIR="/tmp/nebari-gitops-${CLUSTER_NAME}"

[ -d "${SNAPSHOT_PATH}" ] || { echo "::error::SNAPSHOT_PATH not a directory: ${SNAPSHOT_PATH}"; exit 1; }
for f in image.tar.zst gitops.tar.zst k3s-token; do
  [ -f "${SNAPSHOT_PATH}/${f}" ] || { echo "::error::missing ${f} in snapshot bundle"; exit 1; }
done

_t() { date +%s; }
RESTORE_START=$(_t)

echo "::group::Inspect snapshot bundle"
ls -lh "${SNAPSHOT_PATH}/"
cat "${SNAPSHOT_PATH}/metadata.txt" 2>/dev/null || true
echo "::endgroup::"

echo "::group::Restore GitOps repo to ${GITOPS_DIR}"
T=$(_t)
mkdir -p "$(dirname "${GITOPS_DIR}")"
rm -rf "${GITOPS_DIR}"
mkdir -p "${GITOPS_DIR}"
zstd -d "${SNAPSHOT_PATH}/gitops.tar.zst" -c \
  | tar -C "${GITOPS_DIR}" -xf - --strip-components=1
chmod -R a+rX "${GITOPS_DIR}"
echo "gitops restore: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Provision empty k3d cluster (with snapshot's token)"
T=$(_t)
# Delegate to the standard create flow so cluster topology, network, and
# storage class match what snapshot-cluster.sh originally captured. K3S_TOKEN
# is read by create-cluster.sh and threaded into `k3d cluster create --token`.
K3S_TOKEN="$(tr -d '\n' < "${SNAPSHOT_PATH}/k3s-token")" \
  "$(dirname "$0")/create-cluster.sh"
echo "provision: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Stop cluster so we can replace the volume contents"
T=$(_t); k3d cluster stop "${CLUSTER_NAME}"; echo "stop: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Wipe + restore k3s state into server volume"
T=$(_t)
zstd -d "${SNAPSHOT_PATH}/image.tar.zst" -c \
  | docker run --rm -i --volumes-from "${SERVER}" busybox \
      sh -c 'set -e; rm -rf /var/lib/rancher/k3s/* /var/lib/rancher/k3s/.??* 2>/dev/null || true; tar -C /var/lib/rancher/k3s -xf -'
echo "wipe+restore: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Start cluster with restored state"
T=$(_t)
# Bypass k3d cluster start's blocking wait — it polls the API server from the
# host, but the host kubeconfig is stale (was written with the fresh CA;
# server now has the snapshot's CA). Start via docker, poll in-container.
docker start "${SERVER}"
echo "container start: $(($(_t) - T))s"
echo "::endgroup::"

echo "::group::Wait for k3s to be ready (in-container kubectl)"
T=$(_t)
KC="kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml"
READY=0
for i in $(seq 1 60); do
  if docker exec "${SERVER}" sh -c "${KC} get --raw=/readyz" >/dev/null 2>&1 && \
     docker exec "${SERVER}" sh -c "${KC} get nodes --no-headers" 2>/dev/null \
       | awk '{print $2}' | grep -q '^Ready$'; then
    READY=1
    echo "k3s Ready after $(($(_t) - T))s"
    break
  fi
  printf '  poll %d (%ds)\n' "${i}" "$(($(_t) - T))"
  sleep 5
done
if [ "${READY}" -ne 1 ]; then
  echo "::error::k3s did not become Ready within the poll window"
  docker logs --tail 100 "${SERVER}" 2>&1 | sed 's/^/  /'
  exit 1
fi
echo "::endgroup::"

echo "::group::Refresh host kubeconfig with restored cluster's CA"
# The kubeconfig k3d wrote during the empty-cluster provision step has the
# fresh cluster's CA, which is now stale because we replaced the state. Pull
# the in-container kubeconfig (which always reflects the live CA), rewrite
# the server URL to the k3d-mapped host port, and merge into the host's
# default location so downstream steps and consumers see a working config.
KUBECONFIG_PATH="${HOME}/.kube/config"
mkdir -p "$(dirname "${KUBECONFIG_PATH}")"

# Map the k3d server's exposed API port back to the host.
SERVER_PORT=$(docker port "${SERVER}" 6443/tcp | head -1 | awk -F: '{print $NF}')
[ -n "${SERVER_PORT}" ] || { echo "::error::could not determine API host port"; exit 1; }

# Read the cluster's own kubeconfig, rewrite the in-container 127.0.0.1:6443
# server URL to the host-side mapping that k3d exposes.
docker exec "${SERVER}" cat /etc/rancher/k3s/k3s.yaml \
  | sed -E "s|server: https://127\.0\.0\.1:[0-9]+|server: https://0.0.0.0:${SERVER_PORT}|" \
  > "${KUBECONFIG_PATH}.restored"

# Merge into the default kubeconfig path so the host's `kubectl` works.
# We do not call `k3d kubeconfig merge` because that reads from k3d's stored
# metadata (written at create time, before the wipe), so it'd write the wrong
# CA again.
mv "${KUBECONFIG_PATH}.restored" "${KUBECONFIG_PATH}"
chmod 600 "${KUBECONFIG_PATH}"
echo "host kubeconfig refreshed (server: https://0.0.0.0:${SERVER_PORT})"
echo "::endgroup::"

echo "::group::Smoke check restored cluster (host kubectl)"
kubectl get nodes
kubectl get pods -A | head -20
echo "::endgroup::"

# Surface the same outputs as create-cluster.sh so downstream steps don't
# care which path produced the cluster.
NETWORK_NAME="nebari-${CLUSTER_NAME}-net"
{
  echo "kubeconfig=${KUBECONFIG_PATH}"
  echo "cluster-name=${CLUSTER_NAME}"
  echo "network-name=${NETWORK_NAME}"
  echo "gitops-dir=${GITOPS_DIR}"
} >> "${GITHUB_OUTPUT}"

TOTAL=$(($(_t) - RESTORE_START))
echo "::notice::Total restore wall-clock: ${TOTAL}s"
