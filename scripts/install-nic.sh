#!/usr/bin/env bash
set -euo pipefail

# Build NIC from main. file:// git support (nebari-dev/nebari-infrastructure-core#136)
# was merged into main on 2026-04-29 and the local_git branch was deleted.
# TODO: switch to downloading a pre-built binary once a NIC release ships
#       that includes PR #136 (track: nebari-dev/action-nebari-sandbox#12).
NIC_REPO="https://github.com/nebari-dev/nebari-infrastructure-core.git"
NIC_BRANCH="main"
NIC_SRC="/tmp/nebari-infrastructure-core"

echo "::group::Install NIC (branch: ${NIC_BRANCH})"

if [[ -d "${NIC_SRC}" ]]; then
  rm -rf "${NIC_SRC}"
fi

git clone --branch "${NIC_BRANCH}" --depth 1 "${NIC_REPO}" "${NIC_SRC}"

cd "${NIC_SRC}"
CGO_ENABLED=0 go build -trimpath -o /usr/local/bin/nic ./cmd/nic

echo "NIC installed at $(which nic)"
nic version || true

echo "::endgroup::"
