# Action tests

The `test-action.yml` workflow bootstraps the platform stack once, then runs
every scenario under `tests/scenarios/` against the live cluster via
`tests/run-scenarios.sh`. One bootstrap, many tests.

## Adding a scenario

Drop a new `.sh` file in `tests/scenarios/`. The harness picks it up
automatically — no workflow edit required.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Your scenario does its own setup (invoke a script under scripts/, patch a
# resource, whatever the flag does), then asserts the resulting state. Exit
# non-zero on failure — the harness reports it.

"${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel)}/scripts/some-flag.sh"

# Then assert.
kubectl get something -o json | jq ...
```

Conventions:

- **Name the file after the flag or behavior under test.** Keeps `tests/scenarios/`
  searchable as the action grows. Example: `argocd-self-heal-disable.sh`.
- **Self-contained setup.** Scenarios run sequentially in alphabetical order
  against a shared cluster. Don't assume a clean slate; if your scenario needs
  a specific precondition, set it up inside the scenario.
- **Use `${GITHUB_WORKSPACE}`** to reference scripts in the repo. Falls back to
  `git rev-parse --show-toplevel` for local runs.
- **Fail loudly.** `set -euo pipefail` at the top, print what was checked and
  why it failed.

## Running locally

Bootstrap the platform with `act` or by running the scripts directly, then:

```bash
bash tests/run-scenarios.sh
```
