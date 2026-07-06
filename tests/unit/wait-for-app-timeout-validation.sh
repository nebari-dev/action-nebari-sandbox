#!/usr/bin/env bash
# Unit test (no cluster): add-software-pack/wait-for-app.sh timeout validation.
#
# wait-for-app.sh normalizes/validates WAIT_TIMEOUT up front (#64) before any
# kubectl call, so the rejection branch is testable offline. A malformed
# duration must fail fast with the validation error, NOT reach `kubectl`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/add-software-pack/wait-for-app.sh"

# Force any accidental kubectl call to fail instantly, so if validation ever
# regresses (letting a bad value through) the test still fails rather than
# hanging on a real annotate/wait.
export KUBECONFIG=/dev/null
STUB="$(mktemp -d)"
trap 'rm -rf "${STUB}"' EXIT
cat > "${STUB}/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "STUB kubectl called: $*" >&2
exit 97
EOF
chmod +x "${STUB}/kubectl"
export PATH="${STUB}:${PATH}"

fails=0
# assert that an invalid timeout is rejected with the validation message and
# WITHOUT the kubectl stub ever being reached.
assert_rejected() {
  local val="$1"
  local out rc
  out="$(WAIT_TIMEOUT="${val}" APP_NAME=x bash "${SCRIPT}" 2>&1)" && rc=0 || rc=$?
  if (( rc == 0 )); then
    echo "::error::wait-timeout '${val}' was accepted; expected rejection"; fails=$((fails + 1)); return
  fi
  if grep -q "STUB kubectl called" <<<"${out}"; then
    echo "::error::wait-timeout '${val}' reached kubectl before failing validation"; fails=$((fails + 1)); return
  fi
  if ! grep -q "wait-timeout must be" <<<"${out}"; then
    echo "::error::wait-timeout '${val}' failed, but not with the validation message. Output: ${out}"; fails=$((fails + 1)); return
  fi
  echo "  ok    '${val}' rejected before kubectl with the validation message"
}

# Note: an empty WAIT_TIMEOUT is NOT invalid — `${WAIT_TIMEOUT:-5m}` defaults it
# to 5m — so it's intentionally not in this list.
for bad in "1h30m" "5min" "abc" "30x"; do
  assert_rejected "${bad}"
done

if (( fails > 0 )); then
  echo "wait-for-app-timeout-validation: ${fails} case(s) failed"
  exit 1
fi
echo "wait-for-app-timeout-validation: all cases passed"
