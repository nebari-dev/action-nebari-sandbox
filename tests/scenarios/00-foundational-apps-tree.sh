#!/usr/bin/env bash
# Scenario: foundational-apps-tree drift guard (issue #61)
#
# The README documents the foundational GitOps layout — the set of *.yaml files
# NIC seeds into ${GITOPS_DIR}/apps/ (cert-manager.yaml, keycloak.yaml, ...).
# That list is hand-maintained and mirrors NIC's foundational app set, which
# lives upstream. When NIC adds, removes, or renames a foundational app, the
# README silently goes stale (it already did once: metallb.yaml was deleted by
# hand in the local->existing switch).
#
# This scenario fails CI when the documented set no longer matches a real
# platform deploy, so the tree can't rot unnoticed.
#
# It is prefixed `00-` so it runs FIRST: other scenarios (e.g.
# consumer-app-via-gitops) write into apps/ and clean up afterwards, but a
# partial failure could leave residue. Reading apps/ before any scenario
# mutates it guarantees we compare against the pristine post-deploy state.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
README="${REPO_ROOT}/README.md"

if [[ ! -f "${README}" ]]; then
  echo "::error::README.md not found at ${README}"
  exit 1
fi

# Derive GITOPS_DIR from the foundational App-of-Apps, same as the other
# scenarios: nebari-root's spec.source.repoURL is `file://<gitops-dir>`.
ROOT_REPO_URL=$(kubectl get application/nebari-root -n argocd \
  -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || true)
GITOPS_DIR="${ROOT_REPO_URL#file://}"

if [[ -z "${GITOPS_DIR}" || ! -d "${GITOPS_DIR}/apps" ]]; then
  echo "::error::Could not resolve ${GITOPS_DIR:-<unset>}/apps from Application/nebari-root.source.repoURL"
  echo "  repoURL: ${ROOT_REPO_URL:-(unset)}"
  exit 1
fi

# Documented set: the *.yaml files under `apps/` in the README's gitops tree.
# The block is fenced; apps/ children are indented 8 spaces, while siblings
# (manifests/, nic-config.yaml) sit at 4 spaces. Capture turns on at the
# `apps/` line and off at the next 4-space entry, and we take the first token
# of each line ending in .yaml.
documented=$(awk '
  /^    apps\// { capture=1; next }
  capture && /^    [A-Za-z]/ { capture=0 }
  capture && $1 ~ /\.yaml$/ { print $1 }
' "${README}" | sort)

if [[ -z "${documented}" ]]; then
  echo "::error::Parsed zero documented app filenames from the README apps/ tree — the block format may have changed; update this scenario's extractor."
  exit 1
fi

# Actual set: *.yaml directly under the live apps/ directory.
actual=$(cd "${GITOPS_DIR}/apps" && ls -1 ./*.yaml 2>/dev/null | sed 's#^\./##' | sort || true)

echo "Documented foundational apps (README):"
echo "${documented}" | sed 's/^/  /'
echo "Actual foundational apps (${GITOPS_DIR}/apps):"
echo "${actual}" | sed 's/^/  /'

if [[ "${documented}" == "${actual}" ]]; then
  echo "OK: README foundational-apps tree matches the live platform deploy."
  exit 0
fi

echo "::error::README foundational-apps tree is out of sync with the live deploy."
missing=$(comm -23 <(echo "${documented}") <(echo "${actual}") || true)
extra=$(comm -13 <(echo "${documented}") <(echo "${actual}") || true)
if [[ -n "${missing}" ]]; then
  echo "  Documented in README but NOT in the deploy (remove from README, or NIC dropped them):"
  echo "${missing}" | sed 's/^/    - /'
fi
if [[ -n "${extra}" ]]; then
  echo "  In the deploy but NOT documented (add to the README tree; NIC likely added them):"
  echo "${extra}" | sed 's/^/    - /'
fi
exit 1
