#!/usr/bin/env bash
set -euo pipefail

# Build NIC from the local_git branch which adds file:// git support
# required for local ArgoCD deployments (nebari-dev/nebari-infrastructure-core#136).
NIC_REPO="https://github.com/nebari-dev/nebari-infrastructure-core.git"
NIC_BRANCH="local_git"
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
