#!/usr/bin/env bash
# Scenario: argocd-self-heal: false
# Invokes the patch script directly against the live cluster, then asserts
# every foundational Application has selfHeal=false. Tests the script's
# contract independent of the action's input wiring.
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel)}"

"${REPO_ROOT}/scripts/disable-argocd-self-heal.sh"

echo "Verifying selfHeal state on Applications..."

still_enabled=$(
  kubectl get applications -n argocd -o json \
    | jq -r '.items[]
        | select(.spec.syncPolicy.automated != null)
        | select(.spec.syncPolicy.automated.selfHeal != false)
        | .metadata.name'
)

if [[ -n "${still_enabled}" ]]; then
  echo "Applications still have selfHeal enabled:"
  echo "${still_enabled}" | sed 's/^/  /'
  exit 1
fi

count=$(
  kubectl get applications -n argocd -o json \
    | jq '[.items[] | select(.spec.syncPolicy.automated != null)] | length'
)

if [[ "${count}" -eq 0 ]]; then
  echo "No Applications with automated sync found — assertion would pass vacuously."
  exit 1
fi

echo "Verified ${count} Application(s) have selfHeal=false."
