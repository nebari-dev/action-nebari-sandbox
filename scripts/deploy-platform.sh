#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required}"
GITOPS_DIR="/tmp/nebari-gitops-${CLUSTER_NAME}"
CONFIG_FILE="/tmp/nic-config-${CLUSTER_NAME}.yaml"

echo "::group::Generate NIC config"

cat > "${CONFIG_FILE}" << EOF
project_name: ${CLUSTER_NAME}
domain: nebari.local
certificate:
  type: selfsigned
kube_context: "k3d-${CLUSTER_NAME}"
git_repository:
  url: "file://${GITOPS_DIR}"
  branch: main
cluster:
  local:
    node_selectors:
      general:
        kubernetes.io/os: linux
      user:
        kubernetes.io/os: linux
      worker:
        kubernetes.io/os: linux
EOF

echo "Config written to ${CONFIG_FILE}:"
cat "${CONFIG_FILE}"

echo "::endgroup::"

echo "::group::Deploy Nebari platform via NIC"

# NIC creates the gitops directory with explicit owner-only permissions
# (0750 dirs, 0600 files). On Linux, the ArgoCD repo-server pod (uid 999)
# accesses this via a hostPath bind mount and can't read those files.
# umask doesn't help because NIC sets permissions explicitly in Go code.
#
# Run a background loop that continuously fixes permissions while NIC deploys.
# This ensures ArgoCD can read the repo as soon as it starts, rather than
# after NIC's internal 5-minute LB wait times out.
(
  while true; do
    chmod -R a+rX "${GITOPS_DIR}" 2>/dev/null || true
    sleep 2
  done
) &
CHMOD_PID=$!
trap "kill ${CHMOD_PID} 2>/dev/null || true" EXIT

nic deploy -f "${CONFIG_FILE}" --timeout 15m

# Final permission fix to catch anything written during the last seconds
chmod -R a+rX "${GITOPS_DIR}"

kill "${CHMOD_PID}" 2>/dev/null || true

echo "::endgroup::"
