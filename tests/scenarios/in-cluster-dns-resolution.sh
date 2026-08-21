#!/usr/bin/env bash
# Scenario: in-cluster-dns-resolution (issue #104)
#
# The in-cluster DNS feature (#69) exists so a consumer pod doing server-side
# OIDC can fetch the external issuer Keycloak advertises. That only works if
# `keycloak.<domain>` resolves to the gateway from INSIDE the cluster, and that
# is the one thing nothing verified: setup-in-cluster-dns.sh wrote a
# `coredns-custom` ConfigMap, which only k3s CoreDNS imports, so on kind it was
# a silent no-op while the step still logged "In-cluster DNS ready".
#
# Resolve the name from a pod and require the gateway IP back. Doubles as a
# regression check if the CoreDNS layout changes again under us.

set -euo pipefail

POD="dns-resolution-probe"
NS="default"

# --wait=false on teardown: don't slow the suite down waiting for termination.
cleanup() {
  kubectl delete pod "${POD}" -n "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The pre-run clear MUST wait: a pod still Terminating makes `kubectl run` fail
# with AlreadyExists. Reachable on a re-run against the same cluster, or after a
# cancelled job left the trap unfired.
clear_pod() {
  kubectl delete pod "${POD}" -n "${NS}" --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
}

# ── What the platform says it deployed ───────────────────────────────────────
# Prefer the action's own outputs when the harness passes them: asserting
# against what the action EMITTED catches a wrong derivation, whereas deriving
# both sides ourselves would make the same mistake twice and still pass.
# Fall back to reading the cluster so the scenario stays runnable standalone.
DOMAIN="${DOMAIN:-}"
if [[ -z "${DOMAIN}" ]]; then
  # NIC writes the scrubbed config to the root of the GitOps repo, and
  # Application/nebari-root points at that repo.
  ROOT_REPO_URL="$(kubectl get application/nebari-root -n argocd \
    -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || true)"
  GITOPS_DIR="${ROOT_REPO_URL#file://}"
  if [[ -z "${GITOPS_DIR}" || ! -f "${GITOPS_DIR}/nic-config.yaml" ]]; then
    echo "::error::no DOMAIN passed in and could not locate nic-config.yaml via Application/nebari-root (repoURL: ${ROOT_REPO_URL:-unset})"
    exit 1
  fi
  DOMAIN="$(awk -F':' '/^domain:/{gsub(/[[:space:]"'\'']/,"",$2); print $2; exit}' \
    "${GITOPS_DIR}/nic-config.yaml")"
fi
if [[ -z "${DOMAIN}" ]]; then
  echo "::error::could not determine the platform domain"
  exit 1
fi

# ── The address the zone should answer with ──────────────────────────────────
GATEWAY_IP="${GATEWAY_IP:-}"
if [[ -z "${GATEWAY_IP}" ]]; then
  GATEWAY_IP="$(kubectl get svc -n envoy-gateway-system \
    -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' \
    2>/dev/null || true)"
fi
if [[ -z "${GATEWAY_IP}" ]]; then
  echo "::error::no LoadBalancer IP in envoy-gateway-system; cannot verify what the zone should resolve to"
  exit 1
fi

HOST="keycloak.${DOMAIN}"
echo "Resolving ${HOST} from inside the cluster (expecting ${GATEWAY_IP})..."

# ── Resolve from a pod ───────────────────────────────────────────────────────
# Deliberately not `kubectl run --attach`: attach races container startup and
# falls back to streaming logs, which duplicates output and muddies failures.
# Start it, wait for it to finish, then read the logs.
clear_pod
kubectl run "${POD}" -n "${NS}" \
  --image=busybox:1.36 \
  --restart=Never \
  --image-pull-policy=IfNotPresent \
  --command -- nslookup "${HOST}" >/dev/null

# Poll shape overridable (env) so the failure paths are fast to test.
PROBE_ATTEMPTS="${PROBE_ATTEMPTS:-60}"
PROBE_INTERVAL="${PROBE_INTERVAL:-2}"
PHASE=""
for _ in $(seq 1 "${PROBE_ATTEMPTS}"); do
  PHASE="$(kubectl get pod "${POD}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${PHASE}" == "Succeeded" || "${PHASE}" == "Failed" ]] && break
  sleep "${PROBE_INTERVAL}"
done

OUT="$(kubectl logs "${POD}" -n "${NS}" 2>&1 || true)"
echo "${OUT}" | sed 's/^/  /'

if [[ "${PHASE}" != "Succeeded" && "${PHASE}" != "Failed" ]]; then
  echo "::error::probe pod never finished (last phase: ${PHASE:-none}); could not verify in-cluster DNS"
  kubectl describe pod "${POD}" -n "${NS}" || true
  exit 1
fi

# Distinguish the two failures by the probe's exit status, not by grepping the
# output for the hostname: busybox echoes the queried name inside its own
# "can't resolve" message, so a match there proves nothing about resolution.
# A failed lookup exits non-zero, which surfaces as pod phase Failed.
if [[ "${PHASE}" == "Failed" ]]; then
  echo "::error::${HOST} does not resolve from inside the cluster. The ${DOMAIN} zone is not configured in whatever CoreDNS actually reads (see #104)."
  exit 1
fi
if ! grep -qF "${GATEWAY_IP}" <<<"${OUT}"; then
  echo "::error::${HOST} resolves, but not to the gateway ${GATEWAY_IP}. The ${DOMAIN} zone is answering with the wrong address."
  exit 1
fi

echo "OK: ${HOST} resolves to ${GATEWAY_IP} from inside the cluster."
