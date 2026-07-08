# Contributing

This action is a set of composite steps (`action.yml`) that delegate to
`scripts/*.sh`, verified by tests in `tests/`. A few conventions are worth
knowing before you add a step or a test — they're currently followed by
convention rather than enforced, so this is the reference.

## Failure-mode taxonomy: gates fail, extractors warn

Every script falls into one of two families, and which one it is decides how it
handles a missing precondition:

- **Gates** assert that the platform is in the expected state. They **fail
  loudly** (`::error::` + non-zero exit) when it isn't. `wait-platform.sh` is the
  gate — it exists so consumers get one clean status check, so "found nothing to
  wait for" must be a failure, never a pass.
- **Extractors / optional features** read something out of the cluster or add a
  best-effort convenience. They **warn and skip** (`::warning::` + emit any empty
  output + `exit 0`) when their precondition is absent, and guard *before* any
  cluster mutation. `extract-outputs.sh`, `publish-ca.sh`, and
  `setup-in-cluster-dns.sh` are extractors — a missing secret, an unassigned
  LoadBalancer IP, or a consumer-managed DNS setup should degrade gracefully, not
  fail the whole run.

If you're unsure which family a new script is in, ask: "is this asserting the
platform is healthy, or producing a nice-to-have?" The first is a gate, the
second an extractor.

## Test tiers: where a test belongs

Three places, by what the test needs:

- **`tests/unit/*.sh`** — offline, no cluster. Input validation and script logic.
  Auto-discovered by `tests/run-unit.sh` (drop a file in, no workflow edit) and
  run on every PR by `test-units.yml` in seconds. Stub `kubectl` on `PATH` with a
  loud-failing shim to prove guards skip *before* touching the cluster, and pin
  the exact user-facing message where one exists.
- **`tests/scenarios/*.sh`** — live, against the bootstrapped platform cluster.
  Anything that needs real resources (an Application reaching Healthy, a pod
  resolving a hostname). Auto-discovered by `tests/run-scenarios.sh`, run inside
  the platform job. Assume nothing about state left by other scenarios; clean up
  after yourself.
- **Inline steps in `.github/workflows/test-action.yml`** — only for things the
  other two tiers can't reach: asserting `steps.sandbox.outputs.*` (step outputs
  aren't visible to scenarios) and bare-`cluster-only` negative paths (the only
  bare cluster in the suite).

## Script + workflow conventions

- `#!/usr/bin/env bash` + `set -euo pipefail` (test harnesses use `set -uo
  pipefail` deliberately, so they can collect per-test results).
- Inputs arrive as `SCREAMING_SNAKE` env vars from the step's `env:` block:
  required `${VAR:?msg}`, optional `${VAR:-default}`. Poll counts/intervals are
  env-overridable (e.g. `CA_POLL_ATTEMPTS`) so skip paths are unit-testable.
- Outputs: `echo "key=value" >> "$GITHUB_OUTPUT"`, and emit the (empty) output
  even on the skip path so downstream consumers see a defined value.
- Wrap logical phases in `::group::` / `::endgroup::`; register secrets with
  `::add-mask::` before echoing anything derived from them.
- Any workaround for an upstream (NIC) bug carries a comment explaining the
  mechanism, why it's safe, and when to remove it, plus a same-repo `#N` issue
  link (see the PR checklist).
- `action.yml` inputs/outputs are documented with folded scalars (`>`), and the
  README Inputs/Outputs tables are generated — never hand-edit between the
  `<!-- action-docs-* -->` markers. Regenerate with
  `npx --yes action-docs@2.4.0 --no-banner --update-readme README.md`; CI
  (`docs-check.yml`) fails on drift.

## Before opening a PR

- `bash tests/run-unit.sh` passes.
- If you changed `action.yml` inputs/outputs, regenerate the README tables.
- Fill in the PR template checklist.
