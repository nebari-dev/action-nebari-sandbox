#!/usr/bin/env bash
set -euo pipefail

echo "::group::Extract platform outputs"

# Keycloak admin password
KEYCLOAK_PASS="$(kubectl -n keycloak get secret keycloak-admin-credentials \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)" || true

# ArgoCD admin password
ARGOCD_PASS="$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)" || true

# Gateway IP from MetalLB (wait up to 60s for an external IP)
GATEWAY_IP=""
for i in $(seq 1 12); do
  GATEWAY_IP="$(kubectl get svc -A \
    -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' \
    2>/dev/null)" || true
  if [[ -n "${GATEWAY_IP}" ]]; then
    break
  fi
  echo "Waiting for LoadBalancer IP... (attempt ${i}/12)"
  sleep 5
done

echo "Keycloak admin password: ${KEYCLOAK_PASS:-(not found)}"
echo "ArgoCD admin password: ${ARGOCD_PASS:-(not found)}"
echo "Gateway IP: ${GATEWAY_IP:-(not found)}"

echo "::endgroup::"

# Mask secrets in workflow logs
if [[ -n "${KEYCLOAK_PASS}" ]]; then
  echo "::add-mask::${KEYCLOAK_PASS}"
fi
if [[ -n "${ARGOCD_PASS}" ]]; then
  echo "::add-mask::${ARGOCD_PASS}"
fi

echo "keycloak-admin-password=${KEYCLOAK_PASS}" >> "${GITHUB_OUTPUT}"
echo "argocd-admin-password=${ARGOCD_PASS}" >> "${GITHUB_OUTPUT}"
echo "gateway-ip=${GATEWAY_IP}" >> "${GITHUB_OUTPUT}"
