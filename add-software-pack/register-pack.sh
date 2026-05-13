#!/usr/bin/env bash
# Register a consumer Application + chart content into the platform's GitOps
# repo. Runs the four-step ritual: copy → envsubst → commit → chmod. Called
# by add-software-pack/action.yml; see that file's input descriptions for
# semantics.

set -euo pipefail

: "${GITOPS_DIR:?GITOPS_DIR is required}"
: "${APP_NAME:?APP_NAME is required}"
: "${CHART_SOURCE:?CHART_SOURCE is required}"
: "${APPLICATION_MANIFEST:?APPLICATION_MANIFEST is required}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-}"

# ── Validate inputs ──────────────────────────────────────────────────────────
[[ -d "${GITOPS_DIR}" ]] \
  || { echo "::error::gitops-dir does not exist: ${GITOPS_DIR}"; exit 1; }
[[ -d "${GITOPS_DIR}/apps" ]] \
  || { echo "::error::${GITOPS_DIR}/apps does not exist — was the parent action run with profile: platform?"; exit 1; }
[[ -d "${CHART_SOURCE}" ]] \
  || { echo "::error::chart-source is not a directory: ${CHART_SOURCE}"; exit 1; }
[[ -f "${APPLICATION_MANIFEST}" ]] \
  || { echo "::error::application-manifest is not a file: ${APPLICATION_MANIFEST}"; exit 1; }

# Reject app-names that could escape the gitops-dir. Path traversal here would
# let a caller scribble outside the gitops tree, so be strict.
if [[ "${APP_NAME}" =~ [/\\] || "${APP_NAME}" == "." || "${APP_NAME}" == ".." ]]; then
  echo "::error::app-name must be a simple identifier (no slashes or relative-path segments): ${APP_NAME}"
  exit 1
fi

CHART_DEST="${GITOPS_DIR}/${APP_NAME}"
APP_DEST="${GITOPS_DIR}/apps/${APP_NAME}.yaml"

echo "::group::add-software-pack: register ${APP_NAME}"
echo "  gitops-dir:           ${GITOPS_DIR}"
echo "  chart-source:         ${CHART_SOURCE} → ${CHART_DEST}"
echo "  application-manifest: ${APPLICATION_MANIFEST} → ${APP_DEST}"

# ── 1. Copy chart content ────────────────────────────────────────────────────
mkdir -p "${CHART_DEST}"
# Trailing /. so we copy the directory's contents, not the directory itself.
cp -r "${CHART_SOURCE}/." "${CHART_DEST}/"

# ── 2. envsubst Application manifest ─────────────────────────────────────────
# Export GITOPS_DIR so the consumer's manifest can reference it without
# requiring them to export it manually before invoking this action.
export GITOPS_DIR
envsubst < "${APPLICATION_MANIFEST}" > "${APP_DEST}"

# ── 3. Commit. Scoped to this repo's config — never touches global git. ──────
git -C "${GITOPS_DIR}" config user.email "${GIT_AUTHOR_EMAIL:-add-software-pack@action-nebari-sandbox}"
git -C "${GITOPS_DIR}" config user.name  "${GIT_AUTHOR_NAME:-add-software-pack}"
git -C "${GITOPS_DIR}" add -A
git -C "${GITOPS_DIR}" commit -m "${COMMIT_MESSAGE:-add ${APP_NAME}}"

# ── 4. chmod fixup. argocd-repo-server runs as uid 999 inside the cluster ────
# and can't read files written with default runner-uid-only perms.
chmod -R a+rX "${GITOPS_DIR}"

echo "::endgroup::"

# ── Outputs ──────────────────────────────────────────────────────────────────
{
  echo "chart-dest=${CHART_DEST}"
  echo "application-dest=${APP_DEST}"
} >> "${GITHUB_OUTPUT}"

echo "Registered ${APP_NAME}: ArgoCD will reconcile through nebari-root → ${APP_NAME} on its next cycle."
