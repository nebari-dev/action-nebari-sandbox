#!/usr/bin/env bash
# Unit test (no cluster, no network): install-nic.sh's nic-binary guard paths.
# These branches exit before any download/build/sudo, so they're offline-safe.
# The happy path (installing a real binary) needs sudo + a live binary and is
# exercised in the platform CI job, not here.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/install-nic.sh"
fails=0

# nic-binary + a non-default nic-version -> conflict, exit non-zero.
out="$(NIC_BINARY=/tmp/nope-nic NIC_VERSION=v0.3.0 bash "${SCRIPT}" 2>&1)" && rc=0 || rc=$?
if (( rc != 0 )) && grep -q "set only one of nic-binary and nic-version" <<<"${out}"; then
  echo "  ok    nic-binary + explicit nic-version is rejected"
else
  echo "::error::expected conflict error; rc=${rc} out=${out}"; fails=$((fails + 1))
fi

# nic-binary pointing at a missing file (nic-version left at default) -> exit
# non-zero with the non-existent-file error, BEFORE any download/sudo.
out="$(NIC_BINARY=/tmp/definitely-not-here-nic bash "${SCRIPT}" 2>&1)" && rc=0 || rc=$?
if (( rc != 0 )) && grep -q "nic-binary points to a non-existent file" <<<"${out}"; then
  echo "  ok    missing nic-binary file is rejected before download/sudo"
else
  echo "::error::expected non-existent-file error; rc=${rc} out=${out}"; fails=$((fails + 1))
fi

if (( fails > 0 )); then
  echo "install-nic-binary: ${fails} case(s) failed"
  exit 1
fi
echo "install-nic-binary: all cases passed"
