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
nic deploy -f "${CONFIG_FILE}" --timeout 15m
if [[ "${NEBARI_TIMING_REPORT:-false}" == "true" ]]; then
  _nic_end=$(_now_ms)
  _record_timing "nic deploy (total)" "${_nic_start}" "${_nic_end}"
fi

# Final permission fix to catch anything written during the last seconds
chmod -R a+rX "${GITOPS_DIR}"

kill "${CHMOD_PID}" 2>/dev/null || true

# When timing instrumentation is on, collect per-namespace container start
# times relative to nic deploy start. This reveals which workloads were the
# last to have their images pulled and start running inside the k3s nodes.
if [[ "${NEBARI_TIMING_REPORT:-false}" == "true" ]]; then
  echo "::group::Collect container start timestamps (timing instrumentation)"
  # Save kubectl output to a temp file first — piping kubectl directly into
  # `python3 - << 'HEREDOC'` causes a stdin conflict (the heredoc overrides
  # the pipe for Python's stdin, leaving json.load(sys.stdin) with empty input).
  _pods_tmp=$(mktemp /tmp/pods-json-XXXXXX)
  kubectl get pods -A -o json > "${_pods_tmp}" 2>/dev/null \
    || echo '{"items":[]}' > "${_pods_tmp}"
  {
    PODS_TMP_FILE="${_pods_tmp}" python3 << 'PYEOF'
import json, os, sys
from datetime import datetime, timezone

cluster_name = os.environ.get("CLUSTER_NAME", "nebari-test")
timing_file = f"/tmp/nebari-timing-{cluster_name}.tsv"

# Read nic_start_ms from the timing file (last "nic deploy (total)" entry start)
nic_start_ms = None
if os.path.exists(timing_file):
    with open(timing_file) as fh:
        for line in fh:
            parts = line.strip().split("\t")
            if len(parts) == 3 and parts[0] == "nic deploy (total)":
                nic_start_ms = int(parts[1])

if nic_start_ms is None:
    print("Could not find nic deploy start time in timing file, skipping.")
    sys.exit(0)

pods_file = os.environ.get("PODS_TMP_FILE", "")
if not pods_file or not os.path.exists(pods_file):
    print("No pod data file available, skipping.")
    sys.exit(0)

try:
    with open(pods_file) as fh:
        pods = json.load(fh)["items"]
except (json.JSONDecodeError, KeyError):
    print("Failed to parse pod data, skipping.")
    sys.exit(0)

# Collect the FIRST container-ready time per namespace
ns_first: dict[str, int] = {}
for pod in pods:
    ns = pod["metadata"]["namespace"]
    for cs in (pod.get("status") or {}).get("containerStatuses") or []:
        started_at = ((cs.get("state") or {}).get("running") or {}).get("startedAt")
        if started_at:
            dt = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
            started_ms = int(dt.timestamp() * 1000)
            delay_ms = max(0, started_ms - nic_start_ms)
            if ns not in ns_first or delay_ms < ns_first[ns]:
                ns_first[ns] = delay_ms

# Write one entry per namespace (first container ready = images pulled)
with open(timing_file, "a") as fh:
    for ns, delay_ms in sorted(ns_first.items(), key=lambda x: x[1]):
        start_ms = nic_start_ms
        end_ms = nic_start_ms + delay_ms
        fh.write(f"first container ready: {ns}\t{start_ms}\t{end_ms}\n")
        print(f"  {delay_ms:>8}ms  {ns}")
PYEOF
  } || echo "Warning: container start timestamp collection failed (non-fatal)"
  rm -f "${_pods_tmp}"
  echo "::endgroup::"
fi

echo "::endgroup::"
