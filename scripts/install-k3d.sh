#!/usr/bin/env bash
set -euo pipefail

K3D_VERSION="${K3D_VERSION:?K3D_VERSION is required}"

echo "::group::Install k3d v${K3D_VERSION}"

# Skip if already installed at the correct version
if command -v k3d &>/dev/null; then
  installed="$(k3d version | head -1 | awk '{print $3}')"
  if [[ "${installed}" == "v${K3D_VERSION}" ]]; then
    echo "k3d v${K3D_VERSION} is already installed, skipping."
    echo "::endgroup::"
    exit 0
  fi
fi

curl -fsSL "https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh" | \
  TAG="v${K3D_VERSION}" bash

k3d version
echo "::endgroup::"
