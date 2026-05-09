#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required}"
GITOPS_DIR="${GITOPS_DIR:?GITOPS_DIR is required (set by create-cluster step)}"
CONFIG_FILE="/tmp/nic-config-${CLUSTER_NAME}.yaml"

# ── timing helpers ────────────────────────────────────────────────────────────
_TIMING_FILE="/tmp/nebari-timing-${CLUSTER_NAME}.tsv"
_now_ms()        { date +%s%3N; }
_record_timing() {          # label start_ms end_ms
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "${_TIMING_FILE}"
}
# ─────────────────────────────────────────────────────────────────────────────

echo "::group::Generate NIC config"

cat > "${CONFIG_FILE}" << EOF
project_name: ${CLUSTER_NAME}
domain: nebari.local
certificate:
  type: selfsigned
git_repository:
  url: "file://${GITOPS_DIR}"
  branch: main
cluster:
  local:
    # NIC's local provider reads kube_context from cluster.local.kube_context
    # (not the top-level NebariConfig.kube_context, which is for "bring your
    # own cluster" mode that skips infra provisioning).
    kube_context: "k3d-${CLUSTER_NAME}"
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

_nic_start=$(_now_ms)
# Tee NIC's structured JSON logs to a file so collect-deploy-timings.py can
# parse phase pairs ("Installing Argo CD" → "Argo CD installed", etc.) for
# the per-phase NIC breakdown. Tee is a no-op when timing-report is off
# (file just sits in /tmp). pipefail (set above) preserves nic's exit code.
_NIC_LOG_FILE="/tmp/nic-deploy-${CLUSTER_NAME}.log"
nic deploy -f "${CONFIG_FILE}" --timeout 15m 2>&1 | tee "${_NIC_LOG_FILE}"
if [[ "${NEBARI_TIMING_REPORT:-false}" == "true" ]]; then
  _nic_end=$(_now_ms)
  _record_timing "nic deploy (total)" "${_nic_start}" "${_nic_end}"
fi

# Final permission fix to catch anything written during the last seconds
chmod -R a+rX "${GITOPS_DIR}"

kill "${CHMOD_PID}" 2>/dev/null || true

# Deploy-phase timing collection (kubelet Pulled events, ArgoCD app sync,
# NIC log phase parsing) runs as a dedicated post-await step in action.yml
# so all foundational Applications have had time to converge before we read
# their `status.operationState`.

echo "::endgroup::"
