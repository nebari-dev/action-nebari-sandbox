#!/usr/bin/env bash
# Unit test (no cluster): the #69 scripts must SKIP cleanly (not error, not touch
# the cluster) when their preconditions aren't met.
#   - setup-in-cluster-dns.sh: skip on empty domain / empty or non-IPv4 gateway IP
#     BEFORE any kubectl call.
#   - publish-ca.sh: when the gateway TLS secret is unreadable, emit an empty
#     ca-cert-path output and exit 0.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Stub kubectl that fails loudly if reached — proves the DNS guards skip before
# touching the cluster, and simulates "secret not found" for publish-ca.
STUB="$(mktemp -d)"
trap 'rm -rf "${STUB}"' EXIT
cat > "${STUB}/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "STUB kubectl called: $*" >&2
exit 0   # get returns success with empty stdout -> looks like "no such data"
EOF
chmod +x "${STUB}/kubectl"
export PATH="${STUB}:${PATH}"

fails=0
GHOUT="$(mktemp)"

# --- setup-in-cluster-dns.sh: must skip (exit 0) and NOT call kubectl ---
dns_skip() {
  local desc="$1"; shift
  local out
  out="$(env "$@" bash "${REPO_ROOT}/scripts/setup-in-cluster-dns.sh" 2>&1)" || {
    echo "::error::${desc}: expected exit 0 (skip), got failure. Output: ${out}"; fails=$((fails + 1)); return; }
  if grep -q "STUB kubectl called" <<<"${out}"; then
    echo "::error::${desc}: reached kubectl instead of skipping"; fails=$((fails + 1)); return; fi
  echo "  ok    ${desc} (skipped before kubectl)"
}
# These guards reject BEFORE any kubectl call.
dns_skip "empty domain"          DOMAIN="" GATEWAY_IP="10.0.0.5"
dns_skip "invalid domain"        DOMAIN="foo{}bar" GATEWAY_IP="10.0.0.5"
dns_skip "non-IPv4 gateway ip"   DOMAIN="nebari.local" GATEWAY_IP="not-an-ip"

# Empty gateway-ip now SELF-POLLS (stubbed kubectl returns empty) and then skips
# cleanly. It legitimately calls kubectl here, so assert exit 0 only, with the
# poll shrunk to one instant attempt.
if env DOMAIN="nebari.local" GATEWAY_IP="" DNS_POLL_ATTEMPTS=1 DNS_POLL_INTERVAL=0 \
     bash "${REPO_ROOT}/scripts/setup-in-cluster-dns.sh" >/dev/null 2>&1; then
  echo "  ok    empty gateway ip self-polls then skips (exit 0)"
else
  echo "::error::empty gateway ip: expected exit 0 (skip after poll)"; fails=$((fails + 1))
fi

# --- publish-ca.sh: secret unreadable -> empty ca-cert-path output, exit 0 ---
: > "${GHOUT}"
if env GITHUB_OUTPUT="${GHOUT}" GITOPS_DIR="${STUB}" CA_POLL_ATTEMPTS=1 CA_POLL_INTERVAL=0 \
     bash "${REPO_ROOT}/scripts/publish-ca.sh" >/dev/null 2>&1; then
  if grep -qx "ca-cert-path=" "${GHOUT}"; then
    echo "  ok    publish-ca skips with empty ca-cert-path when secret is unreadable"
  else
    echo "::error::publish-ca did not emit an empty ca-cert-path; got: $(cat "${GHOUT}")"; fails=$((fails + 1))
  fi
else
  echo "::error::publish-ca exited non-zero when the gateway secret was unreadable (should skip)"; fails=$((fails + 1))
fi
rm -f "${GHOUT}"

if (( fails > 0 )); then
  echo "oidc-reachability-guards: ${fails} case(s) failed"
  exit 1
fi
echo "oidc-reachability-guards: all cases passed"
