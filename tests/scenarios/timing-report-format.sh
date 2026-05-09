#!/usr/bin/env bash
# Scenario: timing-report.py output formatting
# Feeds a synthetic TSV covering all three label categories (phase / image-pull
# / argocd-sync) into timing-report.py and asserts the rendered markdown has
# the expected sections. Tests the python logic without requiring the action
# to be invoked with `timing-report: 'true'`.
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel)}"

CLUSTER_NAME="timing-report-test-$$"
TIMING_FILE="/tmp/nebari-timing-${CLUSTER_NAME}.tsv"
SUMMARY_FILE="$(mktemp /tmp/timing-summary-XXXXXX.md)"

cleanup() { rm -f "${TIMING_FILE}" "${SUMMARY_FILE}"; }
trap cleanup EXIT

# Synthetic TSV: one of each label category. start/end in ms.
# Use deterministic values so we can grep for exact durations.
cat > "${TIMING_FILE}" <<'EOF'
nic deploy (total)	1000000	1142000
image-pull: keycloak/keycloak/keycloak:25.0	1010000	1023200
image-pull: argocd/argoproj/argocd:v2.13.0	1010000	1014200
argocd-sync: keycloak	1050000	1073400
argocd-sync: argocd	1050000	1054200
EOF

CLUSTER_NAME="${CLUSTER_NAME}" \
GITHUB_STEP_SUMMARY="${SUMMARY_FILE}" \
  python3 "${REPO_ROOT}/scripts/timing-report.py"

echo "--- rendered summary ---"
cat "${SUMMARY_FILE}"
echo "--- end summary ---"

# Assertions — each section header present
assert_contains() {
  local needle="$1"
  if ! grep -qF "${needle}" "${SUMMARY_FILE}"; then
    echo "ASSERT FAILED: expected substring not found: ${needle}"
    exit 1
  fi
}

assert_contains "## CI Timing Report"
assert_contains "### Phases"
assert_contains "### Image pulls"
assert_contains "### ArgoCD app sync convergence"

# Phase row + total
assert_contains "| nic deploy (total) | 2m 22s |"
assert_contains "**Total**"

# Image pulls sorted by duration desc — keycloak pull (13.2s) before argocd pull (4.2s)
keycloak_line=$(grep -nF "keycloak/keycloak:25.0" "${SUMMARY_FILE}" | head -1 | cut -d: -f1)
argocd_pull_line=$(grep -nF "argoproj/argocd:v2.13.0" "${SUMMARY_FILE}" | head -1 | cut -d: -f1)
if [[ "${keycloak_line}" -ge "${argocd_pull_line}" ]]; then
  echo "ASSERT FAILED: image pulls not sorted by duration desc"
  exit 1
fi

# ArgoCD syncs sorted desc — keycloak sync (23.4s) before argocd sync (4.2s)
keycloak_sync_line=$(grep -nE "^\| keycloak \|" "${SUMMARY_FILE}" | tail -1 | cut -d: -f1)
argocd_sync_line=$(grep -nE "^\| argocd \|" "${SUMMARY_FILE}" | tail -1 | cut -d: -f1)
if [[ "${keycloak_sync_line}" -ge "${argocd_sync_line}" ]]; then
  echo "ASSERT FAILED: argocd syncs not sorted by duration desc"
  exit 1
fi

echo "OK: all sections present, sorting correct."
