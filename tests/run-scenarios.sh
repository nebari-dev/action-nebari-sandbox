#!/usr/bin/env bash
# Test harness: runs every scenario under tests/scenarios/ against the cluster
# bootstrapped by the platform action. Each .sh file is an independent scenario
# — drop one in to add a test, no workflow edit required.
#
# Scenarios share the bootstrapped cluster, so they run sequentially in
# alphabetical order. Each scenario is responsible for its own setup; assume
# nothing about state left by previous scenarios. Exits non-zero if any fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="${SCRIPT_DIR}/scenarios"

if [[ ! -d "${SCENARIO_DIR}" ]]; then
  echo "::error::Scenario directory not found: ${SCENARIO_DIR}"
  exit 1
fi

shopt -s nullglob
scenarios=("${SCENARIO_DIR}"/*.sh)
shopt -u nullglob

if [[ ${#scenarios[@]} -eq 0 ]]; then
  echo "No scenarios found in ${SCENARIO_DIR}."
  exit 0
fi

passed=()
failed=()

for scenario in "${scenarios[@]}"; do
  name="$(basename "$scenario" .sh)"
  echo "::group::Scenario: ${name}"
  if bash "$scenario"; then
    passed+=("$name")
    echo "::endgroup::"
    echo "  PASS  ${name}"
  else
    failed+=("$name")
    echo "::endgroup::"
    echo "::error::Scenario failed: ${name}"
  fi
done

echo
echo "Scenario summary: ${#passed[@]} passed, ${#failed[@]} failed (of ${#scenarios[@]} total)"

if [[ ${#failed[@]} -gt 0 ]]; then
  printf '  FAIL  %s\n' "${failed[@]}"
  exit 1
fi
