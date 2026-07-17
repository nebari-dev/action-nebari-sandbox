#!/usr/bin/env bash
# Unit test (no cluster): scripts/check-restart-count.py flags containers over
# the restart budget and ignores those under it. This logic used to be python
# inlined into wait-platform.sh; extracting it (#84) is what makes it testable
# here without a live cluster.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/check-restart-count.py"
fails=0

fixture() {
  cat <<'JSON'
{"items":[
  {"metadata":{"name":"pod-a"},"status":{"containerStatuses":[
    {"name":"main","restartCount":9},
    {"name":"side","restartCount":2}
  ]}},
  {"metadata":{"name":"pod-b"},"status":{"containerStatuses":[
    {"name":"main","restartCount":0}
  ]}}
]}
JSON
}

# limit 5: only pod-a/main (9) is over.
out="$(fixture | python3 "${SCRIPT}" 5)"
if grep -q "pod-a / main: 9 restarts (limit 5)" <<<"${out}" \
   && ! grep -q "side" <<<"${out}" && ! grep -q "pod-b" <<<"${out}"; then
  echo "  ok    flags only containers over the limit"
else
  echo "::error::expected only pod-a/main flagged; got: ${out}"; fails=$((fails + 1))
fi

# limit 9: 9 is not > 9, so nothing exceeds -> empty output.
out="$(fixture | python3 "${SCRIPT}" 9)"
[[ -z "${out}" ]] && echo "  ok    no output when nothing exceeds the limit" \
  || { echo "::error::expected no offenders at limit 9; got: ${out}"; fails=$((fails + 1)); }

# empty items -> empty output, exit 0.
out="$(echo '{"items":[]}' | python3 "${SCRIPT}" 5)"
[[ -z "${out}" ]] && echo "  ok    empty items -> no output" \
  || { echo "::error::empty items produced output: ${out}"; fails=$((fails + 1)); }

# missing arg -> non-zero exit (usage error).
if echo '{"items":[]}' | python3 "${SCRIPT}" >/dev/null 2>&1; then
  echo "::error::missing max_restarts arg should exit non-zero"; fails=$((fails + 1))
else
  echo "  ok    missing arg exits non-zero"
fi

if (( fails > 0 )); then
  echo "check-restart-count: ${fails} case(s) failed"
  exit 1
fi
echo "check-restart-count: all cases passed"
