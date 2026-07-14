#!/usr/bin/env bash
# Install the `nic` binary from one of:
#   - "latest"        : resolve the latest GitHub release and download its
#                       pre-built binary for the current OS/arch (default).
#   - "vX.Y.Z"        : download that specific release's binary.
#   - "."             : build from $GITHUB_WORKSPACE (for NIC's own self-tests
#                       where the action consumer has the NIC repo checked out).
#   - anything else   : treat as a git ref (branch, tag, sha), clone and build
#                       from source. Requires Go in the consumer's workflow.
#
# If NIC_BINARY is set, it takes precedence: the given prebuilt binary is
# installed and NIC_VERSION is ignored (unless NIC_VERSION was also set to a
# non-default value, which is a conflict). Lets a workflow build nic once and
# reuse it across jobs instead of rebuilding each time.
set -euo pipefail

NIC_VERSION="${NIC_VERSION:-latest}"
NIC_BINARY="${NIC_BINARY:-}"
NIC_REPO="nebari-dev/nebari-infrastructure-core"
NIC_INSTALL="/usr/local/bin/nic"

# Build the curl auth args once. GITHUB_TOKEN is exported by the action's
# `env:` block (uses github.token). Authenticated requests get 5000/hr
# instead of 60/hr per IP — matters on self-hosted runners that share IPs.
_curl_auth_args() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    printf -- '-H\nAuthorization: Bearer %s\n' "${GITHUB_TOKEN}"
  fi
}

# Map uname output to the suffix goreleaser uses for NIC's release archives.
# Naming: nebari-infrastructure-core_<version>_<os>_<arch>.tar.gz
_detect_arch_suffix() {
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "${arch}" in
    x86_64|amd64)   arch="x86_64" ;;
    aarch64|arm64)  arch="arm64" ;;
    *)
      echo "::warning::unrecognized arch '${arch}', falling back to x86_64" >&2
      arch="x86_64"
      ;;
  esac
  printf '%s_%s' "${os}" "${arch}"
}

_resolve_latest_tag() {
  local tag
  # Read the auth args into an array so they survive the curl call.
  local -a auth_args=()
  while IFS= read -r line; do auth_args+=("${line}"); done < <(_curl_auth_args)
  tag=$(
    curl -fsSL "${auth_args[@]}" \
      "https://api.github.com/repos/${NIC_REPO}/releases/latest" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])"
  ) || {
    echo "::error::could not resolve latest NIC release tag from api.github.com" >&2
    echo "  set NIC_VERSION to a specific tag (e.g. v0.3.0) to skip the API call." >&2
    exit 1
  }
  printf '%s' "${tag}"
}

# Verify the downloaded tarball against the release's checksums.txt.
# Fails loud if the asset isn't in the checksum file or the SHA doesn't match.
_verify_checksum() {
  local tag="$1" tarball="$2" download_path="$3"
  local -a auth_args=()
  while IFS= read -r line; do auth_args+=("${line}"); done < <(_curl_auth_args)

  local checksums_url="https://github.com/${NIC_REPO}/releases/download/${tag}/checksums.txt"
  local checksums="${download_path}.checksums.txt"
  curl -fsSL "${auth_args[@]}" "${checksums_url}" -o "${checksums}"

  local expected
  expected=$(awk -v name="${tarball}" '$2 == name {print $1}' "${checksums}")
  if [ -z "${expected}" ]; then
    echo "::error::no checksum entry for ${tarball} in ${checksums_url}" >&2
    cat "${checksums}" >&2
    exit 1
  fi

  local actual
  actual=$(sha256sum "${download_path}" | awk '{print $1}')
  if [ "${expected}" != "${actual}" ]; then
    echo "::error::checksum mismatch for ${tarball}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    exit 1
  fi
  echo "checksum verified (${expected})"
}

_download_binary() {
  local tag="$1"
  local version="${tag#v}"
  local arch
  arch=$(_detect_arch_suffix)
  local tarball="nebari-infrastructure-core_${version}_${arch}.tar.gz"
  local url="https://github.com/${NIC_REPO}/releases/download/${tag}/${tarball}"

  local tmp="/tmp/nic-download"
  rm -rf "${tmp}" && mkdir -p "${tmp}"

  echo "Downloading ${tarball}"
  local -a auth_args=()
  while IFS= read -r line; do auth_args+=("${line}"); done < <(_curl_auth_args)
  curl -fsSL "${auth_args[@]}" "${url}" -o "${tmp}/nic.tar.gz"

  _verify_checksum "${tag}" "${tarball}" "${tmp}/nic.tar.gz"

  tar -xzf "${tmp}/nic.tar.gz" -C "${tmp}"

  # Goreleaser puts the binary at the archive root. We only look for an
  # exact `nic` filename to avoid accidentally picking up completion scripts
  # or docs (e.g. nic-completion.bash) that might ship alongside.
  local bin
  bin=$(find "${tmp}" -maxdepth 3 -type f -name nic | head -1)
  if [ -z "${bin}" ]; then
    echo "::error::no nic binary found in extracted archive" >&2
    ls -laR "${tmp}" >&2
    exit 1
  fi
  sudo install -m 755 "${bin}" "${NIC_INSTALL}"
  rm -rf "${tmp}"
}

_build_from_source() {
  local src="$1"
  if ! command -v go >/dev/null 2>&1; then
    echo "::error::nic-version=${NIC_VERSION} requires a source build, but Go is not installed." >&2
    echo "  Add \`actions/setup-go@v6\` to your workflow before this action, or use a release tag instead." >&2
    exit 1
  fi
  ( cd "${src}" && CGO_ENABLED=0 go build -trimpath -o "${NIC_INSTALL}" ./cmd/nic )
}

# Install a consumer-supplied prebuilt nic binary (the nic-binary input). Lets a
# workflow build nic once (e.g. a single build job) and hand the path to the
# action in each downstream job, rather than the action building from source
# every time.
_install_prebuilt() {
  local src="$1"
  if [ ! -f "${src}" ]; then
    echo "::error::nic-binary points to a non-existent file: ${src}" >&2
    exit 1
  fi
  echo "::group::Install NIC (prebuilt binary: ${src})"
  sudo install -m 755 "${src}" "${NIC_INSTALL}"
  echo "nic installed at $(which nic)"
  nic version
  echo "::endgroup::"
}

main() {
  # nic-binary wins over nic-version. Setting both to meaningful values is a
  # conflict: nic-version defaults to 'latest', so treat anything other than
  # that as an explicit (conflicting) choice and fail fast.
  if [ -n "${NIC_BINARY}" ]; then
    if [ "${NIC_VERSION}" != "latest" ]; then
      echo "::error::set only one of nic-binary and nic-version (got nic-binary='${NIC_BINARY}', nic-version='${NIC_VERSION}'). Leave nic-version unset when using nic-binary." >&2
      exit 1
    fi
    _install_prebuilt "${NIC_BINARY}"
    return
  fi

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
    # Treat as a git ref. Use --branch= (with `=`) so a value starting with
    # `--` would be unambiguously parsed as the option's value, not a new flag.
    local src="/tmp/nebari-infrastructure-core"
    rm -rf "${src}"
    echo "Cloning ${NIC_REPO}@${resolved} for source build"
    git clone --depth 1 "--branch=${resolved}" "https://github.com/${NIC_REPO}.git" "${src}"
    _build_from_source "${src}"
  fi

  echo "nic installed at $(which nic)"
  nic version

  echo "::endgroup::"
}

main
