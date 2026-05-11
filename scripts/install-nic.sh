#!/usr/bin/env bash
# Install the `nic` binary from one of:
#   - "latest"        : resolve the latest GitHub release and download its
#                       pre-built linux_x86_64 binary (default, fastest).
#   - "vX.Y.Z"        : download that specific release's binary.
#   - "."             : build from $GITHUB_WORKSPACE (for NIC's own self-tests
#                       where the action consumer has the NIC repo checked out).
#   - anything else   : treat as a git ref (branch, tag, sha), clone and build
#                       from source. Requires Go in the consumer's workflow.
set -euo pipefail

NIC_VERSION="${NIC_VERSION:-latest}"
NIC_REPO="nebari-dev/nebari-infrastructure-core"
NIC_INSTALL="/usr/local/bin/nic"
ARCH="linux_x86_64"

_resolve_latest_tag() {
  curl -fsSL "https://api.github.com/repos/${NIC_REPO}/releases/latest" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])"
}

_download_binary() {
  local tag="$1"
  local version="${tag#v}"
  local tarball="nebari-infrastructure-core_${version}_${ARCH}.tar.gz"
  local url="https://github.com/${NIC_REPO}/releases/download/${tag}/${tarball}"

  echo "Downloading ${tarball}"
  local tmp="/tmp/nic-download"
  rm -rf "${tmp}" && mkdir -p "${tmp}"
  curl -fsSL "${url}" -o "${tmp}/nic.tar.gz"
  tar -xzf "${tmp}/nic.tar.gz" -C "${tmp}"

  local bin
  bin=$(find "${tmp}" -maxdepth 3 -type f \( -name nic -o -name 'nic-*' \) | head -1)
  if [ -z "${bin}" ]; then
    echo "::error::no nic binary found in extracted archive"
    ls -laR "${tmp}"
    exit 1
  fi
  sudo install -m 755 "${bin}" "${NIC_INSTALL}"
  rm -rf "${tmp}"
}

_build_from_source() {
  local src="$1"
  if ! command -v go >/dev/null 2>&1; then
    echo "::error::nic-version=${NIC_VERSION} requires a source build, but Go is not installed."
    echo "Add \`actions/setup-go@v6\` to your workflow before this action, or use a release tag instead."
    exit 1
  fi
  ( cd "${src}" && CGO_ENABLED=0 go build -trimpath -o "${NIC_INSTALL}" ./cmd/nic )
}

main() {
  echo "::group::Install NIC (nic-version=${NIC_VERSION})"

  local resolved="${NIC_VERSION}"
  if [ "${NIC_VERSION}" = "latest" ]; then
    resolved=$(_resolve_latest_tag)
    echo "Resolved 'latest' -> ${resolved}"
  fi

  if [[ "${resolved}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
    _download_binary "${resolved}"
  elif [ "${resolved}" = "." ]; then
    local src="${GITHUB_WORKSPACE:-$(pwd)}"
    echo "Building NIC from workspace: ${src}"
    _build_from_source "${src}"
  else
    # Treat as a git ref (branch, tag without v-prefix, commit sha).
    local src="/tmp/nebari-infrastructure-core"
    rm -rf "${src}"
    echo "Cloning ${NIC_REPO}@${resolved} for source build"
    git clone --branch "${resolved}" --depth 1 "https://github.com/${NIC_REPO}.git" "${src}"
    _build_from_source "${src}"
  fi

  echo "nic installed at $(which nic)"
  nic version

  echo "::endgroup::"
}

main
