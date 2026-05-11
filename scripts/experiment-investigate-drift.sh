#!/usr/bin/env bash
# Validation experiment for #33: investigate why some Applications stay
# OutOfSync after snapshot restore.
#
# Reconcile-timing run 25668972215 found that cluster-issuers, gateway-config,
# and httproutes persistently report status.sync.status=OutOfSync after
# restore-cluster.sh completes, and don't converge within a 5-minute window.
# This script dumps what ArgoCD actually thinks is drifting so we can decide
# whether it's:
#   - benign normalization noise (fix at sync policy level)
#   - cluster-specific identifiers that change on rebuild (fix at snapshot
#     layer by normalizing or excluding from the diff)
#   - genuine missing resources (need to force-sync, or fix the snapshot to
#     capture them properly)
set -euo pipefail

CLUSTER="${1:?usage: experiment-investigate-drift.sh <cluster>}"
SERVER="k3d-${CLUSTER}-server-0"
KC="kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml"

probe_apps_status() {
  docker exec "${SERVER}" sh -c "${KC} get applications -n argocd \
    -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.status.sync.status}{\"\\t\"}{.status.health.status}{\"\\n\"}{end}'" \
    2>/dev/null
}

echo "::group::Application sync/health overview"
probe_apps_status
echo "::endgroup::"

OUTOFSYNC_APPS=$(probe_apps_status | awk -F'\t' '$2 != "Synced" {print $1}')

if [ -z "${OUTOFSYNC_APPS}" ]; then
  echo "All Applications are Synced. Nothing to investigate."
  exit 0
fi

echo "OutOfSync Applications: $(echo "${OUTOFSYNC_APPS}" | tr '\n' ' ')"
echo

for app in ${OUTOFSYNC_APPS}; do
  echo "::group::Application: ${app}"

  echo "--- status.sync ---"
  docker exec "${SERVER}" ${KC} get application "${app}" -n argocd \
    -o jsonpath='{.status.sync}{"\n"}' 2>/dev/null | python3 -m json.tool 2>/dev/null \
    || docker exec "${SERVER}" ${KC} get application "${app}" -n argocd -o jsonpath='{.status.sync}'

  echo
  echo "--- status.conditions ---"
  docker exec "${SERVER}" ${KC} get application "${app}" -n argocd \
    -o jsonpath='{.status.conditions}' 2>/dev/null | python3 -m json.tool 2>/dev/null \
    || echo "(no conditions)"

  echo
  echo "--- status.resources (per-resource sync/health) ---"
  docker exec "${SERVER}" ${KC} get application "${app}" -n argocd \
    -o jsonpath='{range .status.resources[*]}{.kind}/{.name}{"\t"}{.namespace}{"\t"}{.status}{"\t"}{.health.status}{"\n"}{end}' \
    2>/dev/null \
    | column -t -s $'\t' || echo "(no resources)"

  echo
  echo "--- status.operationState.message (last sync operation) ---"
  docker exec "${SERVER}" ${KC} get application "${app}" -n argocd \
    -o jsonpath='{.status.operationState.message}{"\n"}' 2>/dev/null

  echo
  echo "::endgroup::"
done

echo "::group::Recent argocd-server / argocd-application-controller logs (last 60 lines each)"
echo "--- argocd-application-controller ---"
docker exec "${SERVER}" ${KC} logs -n argocd statefulset/argocd-application-controller --tail=60 2>&1 \
  | grep -Ei "(error|warn|outofsync|diff|reconcile|${OUTOFSYNC_APPS//[$'\n']/|})" | head -40 \
  || echo "(no relevant log lines)"

echo
echo "--- argocd-server ---"
docker exec "${SERVER}" ${KC} logs -n argocd deployment/argocd-server --tail=60 2>&1 \
  | grep -Ei "(error|warn|outofsync|diff)" | head -20 \
  || echo "(no relevant log lines)"
echo "::endgroup::"

# Workaround attempt: trigger a hard refresh by annotating the Application.
# This forces ArgoCD to recompute the diff from a fresh fetch of the git source.
echo "::group::Attempt hard refresh on OutOfSync apps"
for app in ${OUTOFSYNC_APPS}; do
  echo "annotating ${app} with argocd.argoproj.io/refresh=hard"
  docker exec "${SERVER}" ${KC} annotate application "${app}" -n argocd \
    "argocd.argoproj.io/refresh=hard" --overwrite || true
done
echo
echo "Sleeping 60s, then checking if status changed..."
sleep 60
echo "Post-refresh status:"
probe_apps_status
echo "::endgroup::"

# Last resort: explicit sync. Reveals whether the OutOfSync state is fixable
# by re-applying, or whether something deeper is wrong.
echo "::group::Attempt explicit sync via Application spec edit"
for app in ${OUTOFSYNC_APPS}; do
  echo "patching ${app} to trigger sync"
  docker exec "${SERVER}" ${KC} patch application "${app}" -n argocd \
    --type merge --patch '{"operation":{"sync":{"prune":false,"revision":"HEAD"}}}' \
    2>&1 | sed 's/^/  /' || true
done
echo
echo "Sleeping 90s, then checking final status..."
sleep 90
echo "Post-sync status:"
probe_apps_status
echo "::endgroup::"

{
  echo "## Drift investigation summary"
  echo
  echo "Apps that started OutOfSync (post-restore, after reconcile-timing's 5min window):"
  echo
  for app in ${OUTOFSYNC_APPS}; do echo "- \`${app}\`"; done
  echo
  echo "Post-investigation status (after hard-refresh + explicit sync attempts):"
  echo
  echo '```'
  probe_apps_status
  echo '```'
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
