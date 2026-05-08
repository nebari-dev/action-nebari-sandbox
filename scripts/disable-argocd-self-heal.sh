#!/usr/bin/env bash
# Strip ArgoCD selfHeal from foundational Applications so test code can mutate
# platform state (e.g. swap a dev image into nebari-landing-webapi) without
# ArgoCD reverting the change on its next reconcile. Intended for ephemeral
# CI clusters; the default platform behavior keeps selfHeal on.
set -euo pipefail

echo "::group::Disable ArgoCD selfHeal on foundational Applications"

# Filter to Applications that already have automated sync configured. Patching
# an unmanaged Application would *promote* it to automated-without-selfHeal,
# which is not what we want. NIC's foundational set all have automated sync.
mapfile -t apps < <(
  kubectl get applications -n argocd -o json \
    | jq -r '.items[] | select(.spec.syncPolicy.automated != null) | .metadata.name'
)

if [[ ${#apps[@]} -eq 0 ]]; then
  echo "No Applications with automated sync found in argocd namespace."
  echo "::endgroup::"
  exit 0
fi

for app in "${apps[@]}"; do
  kubectl patch application "$app" -n argocd --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}' >/dev/null
  echo "  patched: $app"
done

echo "Disabled selfHeal on ${#apps[@]} Application(s)."
echo "::endgroup::"
