#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required}"
GITOPS_DIR="${GITOPS_DIR:?GITOPS_DIR is required (set by create-cluster step)}"

# ── timing helpers ────────────────────────────────────────────────────────────
_TIMING_FILE="/tmp/nebari-timing-${CLUSTER_NAME}.tsv"
_now_ms()        { date +%s%3N; }
_record_timing() {          # label start_ms end_ms
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "${_TIMING_FILE}"
}
# ─────────────────────────────────────────────────────────────────────────────

# If the consumer supplied a NIC config path, pass it straight through to
# `nic deploy -f`. Otherwise generate the default at /tmp/nic-config-*.yaml.
# Consumer-supplied configs are the consumer's responsibility — if they
# override fields like `cluster.existing.context` or
# `git_repository.url`, they must match what the action provisioned.
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
  cat > "${CONFIG_FILE}" << EOF
project_name: ${CLUSTER_NAME}
domain: nebari.local
certificate:
  type: selfsigned
git_repository:
  url: "file://${GITOPS_DIR}"
  branch: main
  # Workaround for a misleading NIC WARN ("no valid credentials found for
  # git repository") that fires on every platform run. NIC's ArgoCD-install
  # path tries to provision repo credentials unconditionally, including for
  # file:// URLs where authentication is not meaningful. Without these two
  # fields, the deploy logs an alarming warning that has nothing to do with
  # the actual run state. Pointing argocd_auth at a known-placeholder env
  # var (exported below) satisfies the check; the resulting Secret is
  # harmless dead weight because ArgoCD's repo-server does not authenticate
  # file:// reads. Remove once the upstream check is scoped to non-file
  # schemes.
  argocd_auth:
    token_env: NEBARI_SANDBOX_GIT_PLACEHOLDER_TOKEN
cluster:
  existing:
    # The action provisions the k3d cluster itself, so NIC connects to it as a
    # pre-existing cluster (the `existing` provider) rather than creating one.
    # `context` is the k3d-merged kubeconfig context; the kubeconfig path falls
    # back to KUBECONFIG/~/.kube/config, which create-cluster.sh merged into.
    context: "k3d-${CLUSTER_NAME}"
    # k3s ships only the "local-path" StorageClass; point NIC at it directly.
    # The `existing` provider exposes storage_class (the `local` provider did
    # not), so no "standard" StorageClass shim is needed anymore.
    storage_class: local-path
EOF
  echo "Config written to ${CONFIG_FILE}:"
  cat "${CONFIG_FILE}"
  echo "::endgroup::"
fi

echo "::group::Deploy Nebari platform via NIC"

# SPIKE (#80): the background `chmod -R a+rX` loop that used to run here is
# removed. NIC's gitops repo used to be written owner-only (0750/0600), so the
# non-root ArgoCD repo-server (uid 999) couldn't read it through the hostPath
# mount. NIC PR #448 fixes this at the source: on Init and every commit to a
# local file:// repo, NIC makes the repo root + `.git` group/other-readable
# (additively, .git-only), which is all repo-server reads. So the loop is
# redundant when running a NIC build that includes #448 (nic-version=main here).
_nic_start=$(_now_ms)
# Tee NIC's structured JSON logs to a file so collect-deploy-timings.py can
# parse phase pairs ("Installing Argo CD" → "Argo CD installed", etc.) for
# the per-phase NIC breakdown. Tee is a no-op when timing-report is off
# (file just sits in /tmp). pipefail (set above) preserves nic's exit code.
_NIC_LOG_FILE="/tmp/nic-deploy-${CLUSTER_NAME}.log"
# Placeholder credential matching the argocd_auth.token_env in the
# auto-generated config above. See the comment there for why this exists.
# Harmless if the consumer supplies their own nic-config that doesn't
# reference this var: NIC just doesn't read it.
export NEBARI_SANDBOX_GIT_PLACEHOLDER_TOKEN="placeholder-not-used-for-file-urls"
nic deploy -f "${CONFIG_FILE}" --timeout 15m 2>&1 | tee "${_NIC_LOG_FILE}"
if [[ "${NEBARI_TIMING_REPORT:-false}" == "true" ]]; then
  _nic_end=$(_now_ms)
  _record_timing "nic deploy (total)" "${_nic_start}" "${_nic_end}"
fi

# SPIKE (#80): the final `chmod -R a+rX` + loop teardown are gone too - NIC #448
# leaves .git readable after its commits, so no post-deploy fixup is needed.

# Deploy-phase timing collection (kubelet Pulled events, ArgoCD app sync,
# NIC log phase parsing) runs as a dedicated post-await step in action.yml
# so all foundational Applications have had time to converge before we read
# their `status.operationState`.

echo "::endgroup::"
