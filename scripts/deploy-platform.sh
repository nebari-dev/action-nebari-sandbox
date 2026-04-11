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

# NIC creates the gitops directory with restrictive permissions (750 for dirs,
# 600 for files). On Linux, the ArgoCD repo-server pod (uid 999) accesses this
# via a hostPath bind mount and needs read access. Fix permissions so the
# non-root argocd user can read the repo through the mount.
echo "Fixing gitops directory permissions for ArgoCD repo-server..."
chmod -R a+rX "${GITOPS_DIR}"

echo "::endgroup::"
