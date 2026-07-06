#!/usr/bin/env bash
# Harness for the offline unit tests under tests/unit/. Unlike tests/scenarios/
# (which run against a bootstrapped platform cluster), these need no cluster and
# run in seconds on every PR — they cover input validation and script logic in
# scripts/ and add-software-pack/. Each .sh file is an independent test; drop one
# in to add coverage, no workflow edit required. Exits non-zero if any fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${SCRIPT_DIR}/unit"

shopt -s nullglob
tests=("${UNIT_DIR}"/*.sh)
shopt -u nullglob

if [[ ${#tests[@]} -eq 0 ]]; then
  echo "No unit tests found in ${UNIT_DIR}."
  exit 0
fi

passed=() failed=()
for t in "${tests[@]}"; do
  name="$(basename "$t" .sh)"
  echo "::group::Unit: ${name}"
  if bash "$t"; then
    passed+=("$name"); echo "::endgroup::"; echo "  PASS  ${name}"
  else
    failed+=("$name"); echo "::endgroup::"; echo "::error::Unit test failed: ${name}"
  fi
done

echo
echo "Unit summary: ${#passed[@]} passed, ${#failed[@]} failed (of ${#tests[@]} total)"
if [[ ${#failed[@]} -gt 0 ]]; then
  printf '  FAIL  %s\n' "${failed[@]}"
  exit 1
fi
