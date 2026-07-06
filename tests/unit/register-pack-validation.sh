#!/usr/bin/env bash
# Unit test (no cluster): add-software-pack/register-pack.sh input validation.
#
# register-pack.sh rejects bad inputs before it touches the gitops tree. This
# exercises each rejection branch, including the reserved-name guard that stops
# `app-name: apps` from copying a chart into the App-of-Apps watch directory.
# All assertions are offline — the script fails validation before any git/kubectl.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/add-software-pack/register-pack.sh"

fails=0
# assert_exit <expected: pass|fail> <description> -- <env assignments...>
run_case() {
  local expect="$1" desc="$2"; shift 3   # drop the literal --
  if env "$@" bash "${SCRIPT}" >/dev/null 2>&1; then
    got=pass
  else
    got=fail
  fi
  if [[ "${got}" == "${expect}" ]]; then
    echo "  ok    ${desc} (${got})"
  else
    echo "::error::${desc}: expected ${expect}, got ${got}"
    fails=$((fails + 1))
  fi
}

# Build a valid fixture: a gitops working tree with apps/, a chart dir, a manifest.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
# register-pack.sh writes its step outputs to $GITHUB_OUTPUT; provide one so the
# valid (non-rejection) case can run to completion outside GitHub Actions.
export GITHUB_OUTPUT="${WORK}/gh_output"
GITOPS="${WORK}/gitops"
mkdir -p "${GITOPS}/apps"
( cd "${GITOPS}" && git init -q && git config user.email ci@test && git config user.name ci )
mkdir -p "${WORK}/chart"
echo "placeholder: true" > "${WORK}/chart/values.yaml"
MANIFEST="${WORK}/application.yaml"
echo "kind: Application" > "${MANIFEST}"

BASE=(GITOPS_DIR="${GITOPS}" CHART_SOURCE="${WORK}/chart" APPLICATION_MANIFEST="${MANIFEST}")

# Reserved / traversal names must be rejected (the H5 bug + path-safety).
run_case fail "app-name 'apps' is rejected"        -- "${BASE[@]}" APP_NAME=apps
run_case fail "app-name 'manifests' is rejected"    -- "${BASE[@]}" APP_NAME=manifests
run_case fail "app-name '.git' is rejected"         -- "${BASE[@]}" APP_NAME=.git
run_case fail "app-name with slash is rejected"     -- "${BASE[@]}" APP_NAME=a/b
run_case fail "app-name '..' is rejected"           -- "${BASE[@]}" APP_NAME=..
# Missing / wrong inputs must be rejected.
run_case fail "missing gitops apps/ is rejected"    -- GITOPS_DIR="${WORK}" CHART_SOURCE="${WORK}/chart" APPLICATION_MANIFEST="${MANIFEST}" APP_NAME=ok
run_case fail "non-existent chart-source rejected"  -- "${BASE[@]}" CHART_SOURCE="${WORK}/nope" APP_NAME=ok
run_case fail "non-existent manifest rejected"      -- "${BASE[@]}" APPLICATION_MANIFEST="${WORK}/nope.yaml" APP_NAME=ok
# A clean, valid invocation must succeed (and must NOT have written into apps/).
run_case pass "valid inputs succeed"                -- "${BASE[@]}" APP_NAME=my-app

# Guard against the exact H5 collision: nothing should have landed in apps/ except
# the rendered my-app.yaml (from the valid case); the chart dir must be sibling.
if [[ -e "${GITOPS}/apps/values.yaml" || -d "${GITOPS}/apps/apps" ]]; then
  echo "::error::chart content leaked into the apps/ directory"
  fails=$((fails + 1))
fi

if (( fails > 0 )); then
  echo "register-pack-validation: ${fails} case(s) failed"
  exit 1
fi
echo "register-pack-validation: all cases passed"
