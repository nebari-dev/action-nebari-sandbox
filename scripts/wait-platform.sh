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
# Keycloak's slow JVM boot also crash-restarts a few times before it settles,
# so the shared restart budget trips (6 > 5) even when the pod ends up Ready
# (#79). Same root cause as the timeout headroom above — give it its own,
# overridable budget rather than failing a healthy cluster on the restart count.
declare -A MAX_RESTARTS=(
  [argocd]=3
  [cert-manager]=3
  [envoy-gateway-system]=3
  [keycloak]="${KEYCLOAK_MAX_RESTARTS:-8}"
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

# Preflight: make sure we can actually reach the cluster. Without this, a wrong
# KUBECONFIG/context (or a cluster that never came up) makes every `kubectl get`
# below error out, get swallowed, and report "0 resources" — which used to pass
# vacuously. Fail loudly and distinctly here instead.
if ! kubectl get nodes --request-timeout=20s >/dev/null 2>&1; then
  echo "::error::Cannot reach the cluster (kubectl get nodes failed). Check KUBECONFIG/context; the platform deploy may have failed before this step."
  exit 1
fi

for ns in argocd cert-manager envoy-gateway-system keycloak; do
  max_r="${MAX_RESTARTS[$ns]}"
  ns_timeout="${NS_TIMEOUT[$ns]}"
  echo "::group::  $ns  (timeout: ${ns_timeout}s  max-restarts: ${max_r})"

  ns_count=0
  found_any=false
  for kind in deployment daemonset statefulset; do
    names=$(kubectl get "$kind" -n "$ns" --no-headers \
      -o custom-columns=':metadata.name' 2>/dev/null || true)
    for name in $names; do
      found_any=true
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

  # Every foundational namespace is expected to have at least one rollout
  # resource (Deployment/DaemonSet/StatefulSet). Finding none means the
  # namespace is missing or NIC never installed its workloads — a failed deploy,
  # not "nothing to wait for". Treat it as a failure so the gate can't pass on
  # an empty cluster.
  if [[ "${found_any}" != "true" ]]; then
    echo "  no deployment/daemonset/statefulset found in ${ns}"
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
      echo "  (namespace ${ns} does not exist)"
    fi
    overall_ok=false
  fi

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
  echo "::error::One or more platform workloads failed to become ready (or were never installed)."
  exit 1
fi

echo "All platform workloads ready — ${total} resources across 4 namespaces."
