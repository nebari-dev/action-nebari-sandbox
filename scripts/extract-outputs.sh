#!/usr/bin/env bash
set -euo pipefail

echo "::group::Extract platform outputs"

# Keycloak admin password
KEYCLOAK_PASS="$(kubectl -n keycloak get secret keycloak-admin-credentials \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)" || true

# ArgoCD admin password
ARGOCD_PASS="$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)" || true

# Gateway IP from MetalLB. Scoped to envoy-gateway-system, where NIC's Envoy
# Gateway controller creates the LoadBalancer service for the Nebari Gateway.
# Avoids picking up unrelated LoadBalancer services elsewhere in the cluster.
GATEWAY_IP=""
for i in $(seq 1 12); do
  GATEWAY_IP="$(kubectl get svc -n envoy-gateway-system \
    -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' \
    2>/dev/null)" || true
  if [[ -n "${GATEWAY_IP}" ]]; then
    break
  fi
  echo "Waiting for LoadBalancer IP... (attempt ${i}/12)"
  sleep 5
done

# Register masks BEFORE echoing — ::add-mask:: only filters subsequent
# log output, not retroactively.
[[ -n "${KEYCLOAK_PASS}" ]] && echo "::add-mask::${KEYCLOAK_PASS}"
[[ -n "${ARGOCD_PASS}" ]] && echo "::add-mask::${ARGOCD_PASS}"

echo "Keycloak admin password: ${KEYCLOAK_PASS:-(not found)}"
echo "ArgoCD admin password: ${ARGOCD_PASS:-(not found)}"
echo "Gateway IP: ${GATEWAY_IP:-(not found)}"

echo "::endgroup::"

echo "keycloak-admin-password=${KEYCLOAK_PASS}" >> "${GITHUB_OUTPUT}"
echo "argocd-admin-password=${ARGOCD_PASS}" >> "${GITHUB_OUTPUT}"
echo "gateway-ip=${GATEWAY_IP}" >> "${GITHUB_OUTPUT}"
