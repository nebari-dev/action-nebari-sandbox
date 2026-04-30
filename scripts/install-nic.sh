#!/usr/bin/env bash
set -euo pipefail

# Build NIC from the feature/local-configurable-infra-settings branch, which
# makes StorageClass, MetalLB, and https_port configurable in the local provider
# config (nebari-dev/nebari-infrastructure-core#201).
#
# This branch is pinned here to provide an integration test environment for
# NIC PR #201 review. Once that PR merges into main (and eventually a new NIC
# release ships), this should be updated back to main / a tagged release.
# TODO: switch to downloading a pre-built binary once a NIC release ships
#       that includes PR #136 and PR #201 (track: nebari-dev/action-nebari-sandbox#12).
NIC_REPO="https://github.com/nebari-dev/nebari-infrastructure-core.git"
NIC_BRANCH="feature/local-configurable-infra-settings"
NIC_SRC="/tmp/nebari-infrastructure-core"

echo "::group::Install NIC (branch: ${NIC_BRANCH})"

if [[ -d "${NIC_SRC}" ]]; then
  rm -rf "${NIC_SRC}"
fi

git clone --branch "${NIC_BRANCH}" --depth 1 "${NIC_REPO}" "${NIC_SRC}"

cd "${NIC_SRC}"
CGO_ENABLED=0 go build -trimpath -o /usr/local/bin/nic ./cmd/nic

echo "NIC installed at $(which nic)"
nic version

echo "::endgroup::"
