#!/usr/bin/env bash
# Wait for all platform profile namespaces to reach a healthy rollout state.
# Designed to be the final step of the platform deploy so consumers get a
# single, clean status gate rather than managing per-namespace await steps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  # Assumed contract: every foundational namespace ships at least one of these
  # three kinds. A component that ever shipped as only a Job/CronJob/bare Pod
  # would need adding here, else this gate would false-fail a healthy cluster
  # (#76).
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

  # Restart count guard: flag containers that have restarted more than this
  # namespace's budget. The logic lives in check-restart-count.py (limit passed
  # as an argument, unit-tested offline) rather than python inlined into shell
  # (#84). kubectl failures on a missing namespace are swallowed here (found_any
  # above already handles that case); python is only run on non-empty JSON, so a
  # real parse error surfaces instead of being hidden.
  pods_json="$(kubectl get pods -n "$ns" -o json 2>/dev/null || true)"
  if [[ -n "${pods_json}" ]]; then
    exceeded="$(printf '%s' "${pods_json}" | python3 "${SCRIPT_DIR}/check-restart-count.py" "${max_r}")"
    if [[ -n "${exceeded}" ]]; then
      echo "  Restart limit exceeded:"
      echo "${exceeded}"
      overall_ok=false
    fi
  fi

  echo "  ${ns_count} resource(s) ready in ${ns}"
  echo "::endgroup::"
done

if [[ "$overall_ok" != "true" ]]; then
  echo "::error::One or more platform workloads failed to become ready (or were never installed)."
  exit 1
fi

echo "All platform workloads ready — ${total} resources across 4 namespaces."
