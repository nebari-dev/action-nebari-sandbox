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

nic deploy -f "${CONFIG_FILE}" --timeout 15m

echo "::endgroup::"
