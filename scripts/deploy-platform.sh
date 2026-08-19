#!/usr/bin/env bash
set -euo pipefail

# Deploy the Nebari foundational platform via NIC's `local` provider: NIC
# provisions its own kind cluster, MetalLB, and a local GitOps repo (at
# ~/.nic/gitops/<project_name>) as part of `nic deploy`. The action no longer
# creates the cluster itself -- that inverts the old k3d/`existing` flow, so
# the cluster/gitops/kubeconfig only exist after this step runs, and their
# derived paths are emitted as step outputs at the end.

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required}"

# ── timing helpers ────────────────────────────────────────────────────────────
_TIMING_FILE="/tmp/nebari-timing-${CLUSTER_NAME}.tsv"
_now_ms()        { date +%s%3N; }
_record_timing() {          # label start_ms end_ms
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "${_TIMING_FILE}"
}
# ─────────────────────────────────────────────────────────────────────────────

# If the consumer supplied a NIC config path, pass it straight through to
# `nic deploy -f`. Otherwise generate the default. Consumer-supplied configs
# are the consumer's responsibility: for the action's outputs to resolve, the
# config's `project_name` must equal `cluster-name`, and it must use the
# `local` cluster + `local` repository providers.
if [[ -n "${NIC_CONFIG:-}" ]]; then
  if [[ ! -f "${NIC_CONFIG}" ]]; then
    echo "::error::nic-config points to non-existent file: ${NIC_CONFIG}" >&2
    exit 1
  fi
  CONFIG_FILE="${NIC_CONFIG}"
  echo "::group::Using consumer-supplied NIC config: ${CONFIG_FILE}"
  cat "${CONFIG_FILE}"
  echo "::endgroup::"
else
  CONFIG_FILE="/tmp/nic-config-${CLUSTER_NAME}.yaml"
  echo "::group::Generate NIC config"
  # `cluster.local` -> NIC provisions kind + MetalLB (address pool auto-derived
  # from the kind Docker network). `repository.local` -> NIC creates and mounts
  # the GitOps repo at its default path (~/.nic/gitops/<project_name>); no
  # file:// url, argocd_auth placeholder, or storage_class shim needed anymore.
  cat > "${CONFIG_FILE}" << EOF
project_name: ${CLUSTER_NAME}
domain: nebari.local
certificate:
  type: selfsigned
cluster:
  local: {}
repository:
  local: {}
EOF
  echo "Config written to ${CONFIG_FILE}:"
  cat "${CONFIG_FILE}"
  echo "::endgroup::"
fi

echo "::group::Deploy Nebari platform via NIC (local provider: kind)"
_NIC_LOG_FILE="/tmp/nic-deploy-${CLUSTER_NAME}.log"
# Tee NIC's structured JSON logs so collect-deploy-timings.py can parse phase
# pairs. pipefail (set above) preserves nic's exit code.
_nic_start=$(_now_ms)
nic deploy -f "${CONFIG_FILE}" --timeout 15m 2>&1 | tee "${_NIC_LOG_FILE}"
if [[ "${NEBARI_TIMING_REPORT:-false}" == "true" ]]; then
  _nic_end=$(_now_ms)
  _record_timing "nic deploy (total)" "${_nic_start}" "${_nic_end}"
fi
echo "::endgroup::"

# ── Derive outputs (cluster + gitops now exist) ───────────────────────────────
echo "::group::Resolve cluster outputs"
# NIC names the kind cluster and the gitops repo after the config's
# project_name, which is not necessarily the cluster-name input (a
# consumer-supplied config can differ). Parse it from the config so the derived
# paths are always correct; fall back to CLUSTER_NAME.
PROJECT="$(awk -F':' '/^project_name:/{gsub(/[[:space:]"'\'']/,"",$2); print $2; exit}' "${CONFIG_FILE}")"
PROJECT="${PROJECT:-${CLUSTER_NAME}}"

KUBECONFIG_PATH="${HOME}/.kube/config"
# Write a kubeconfig for the kind cluster NIC just created and make it the
# kubeconfig later steps (and the consumer) use.
nic kubeconfig -f "${CONFIG_FILE}" -o "${KUBECONFIG_PATH}"
echo "KUBECONFIG=${KUBECONFIG_PATH}" >> "${GITHUB_ENV}"
kubectl config use-context "kind-${PROJECT}" 2>/dev/null || true

# NIC's local repository provider defaults to ~/.nic/gitops/<project_name>.
GITOPS_DIR="${HOME}/.nic/gitops/${PROJECT}"

{
  echo "kubeconfig=${KUBECONFIG_PATH}"
  echo "cluster-name=${PROJECT}"
  echo "gitops-dir=${GITOPS_DIR}"
} >> "${GITHUB_OUTPUT}"
echo "kubeconfig: ${KUBECONFIG_PATH}"
echo "gitops-dir: ${GITOPS_DIR}"
echo "::endgroup::"
