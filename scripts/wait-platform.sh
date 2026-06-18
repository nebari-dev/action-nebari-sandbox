#!/usr/bin/env bash
# Wait for all platform profile namespaces to reach a healthy rollout state.
# Designed to be the final step of the platform deploy so consumers get a
# single, clean status gate rather than managing per-namespace await steps.
set -euo pipefail

TIMEOUT="${AWAIT_TIMEOUT:-300}"

# Keycloak (KeycloakX, JVM) is the slowest foundational workload to boot and is
# resource-marginal on the default GitHub runner (4 vCPU / 16 GB, shared with
# k3d and the rest of the stack), so it intermittently misses the shared 300s
# readiness wall while everything else is ready (#67). Give it more headroom by
# default. The proper fix — right-sizing Keycloak's chart resources — lives
# upstream in NIC; this keeps the readiness gate from flaking while that lands.
# Never wait less for Keycloak than the base timeout.
KEYCLOAK_TIMEOUT="${KEYCLOAK_AWAIT_TIMEOUT:-600}"
(( KEYCLOAK_TIMEOUT < TIMEOUT )) && KEYCLOAK_TIMEOUT="${TIMEOUT}"

# Namespace order follows dependency: ArgoCD first (it drives the rest),
# then infra (cert-manager, Envoy), then workloads (Keycloak). MetalLB is no
# longer in the list — under the `existing` provider NIC doesn't deploy it;
# k3d's built-in servicelb (klipper) provides LoadBalancer IPs instead.
declare -A MAX_RESTARTS=(
  [argocd]=3
  [cert-manager]=3
  [envoy-gateway-system]=3
  [keycloak]=5
)

# Per-namespace readiness timeout. All share the base except Keycloak (above).
declare -A NS_TIMEOUT=(
  [argocd]="${TIMEOUT}"
  [cert-manager]="${TIMEOUT}"
  [envoy-gateway-system]="${TIMEOUT}"
  [keycloak]="${KEYCLOAK_TIMEOUT}"
)

overall_ok=true
total=0

for ns in argocd cert-manager envoy-gateway-system keycloak; do
  max_r="${MAX_RESTARTS[$ns]}"
  ns_timeout="${NS_TIMEOUT[$ns]}"
  echo "::group::  $ns  (timeout: ${ns_timeout}s  max-restarts: ${max_r})"

  ns_count=0
  for kind in deployment daemonset statefulset; do
    names=$(kubectl get "$kind" -n "$ns" --no-headers \
      -o custom-columns=':metadata.name' 2>/dev/null || true)
    for name in $names; do
      printf '  %-12s  %s/%s\n' "waiting..." "$kind" "$name"
      if kubectl rollout status "$kind/$name" -n "$ns" \
          --timeout="${ns_timeout}s" 2>&1 | sed 's/^/    /'; then
        printf '  %-12s  %s/%s\n' "ready" "$kind" "$name"
        (( ns_count++ )) || true
        (( total++ )) || true
      else
        printf '  %-12s  %s/%s\n' "FAILED" "$kind" "$name"
        overall_ok=false
      fi
    done
  done

  # Restart count guard
  exceeded=$(
    kubectl get pods -n "$ns" -o json \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for pod in data['items']:
  for cs in pod.get('status', {}).get('containerStatuses', []):
    rc = cs.get('restartCount', 0)
    if rc > int('${max_r}'):
      print(f\"  {pod['metadata']['name']} / {cs['name']}: {rc} restarts (limit {${max_r}})\")
" 2>/dev/null || true
  )
  if [[ -n "$exceeded" ]]; then
    echo "  Restart limit exceeded:"
    echo "$exceeded"
    overall_ok=false
  fi

  echo "  ${ns_count} resource(s) ready in ${ns}"
  echo "::endgroup::"
done

if [[ "$overall_ok" != "true" ]]; then
  echo "::error::One or more platform workloads failed to become ready."
  exit 1
fi

echo "All platform workloads ready — ${total} resources across 4 namespaces."
