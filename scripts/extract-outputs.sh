#!/usr/bin/env bash
set -euo pipefail

echo "::group::Extract platform outputs"

# Keycloak master-realm admin password
KEYCLOAK_PASS="$(kubectl -n keycloak get secret keycloak-admin-credentials \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)" || true

# Keycloak nebari-realm admin password. Provisioned by NIC's realm-setup
# PostSync hook (Job/keycloak-realm-setup), which runs async after Keycloak
# becomes Ready. Poll briefly so consumers whose realm setup completes
# within a normal window get a populated output; consumers whose setup runs
# longer fall back to reading the secret themselves after their own
# wait-for-realm step (see #27).
REALM_PASS=""
for i in $(seq 1 6); do
  REALM_PASS="$(kubectl -n keycloak get secret nebari-realm-admin-credentials \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)" || true
  if [[ -n "${REALM_PASS}" ]]; then
    break
  fi
  echo "Waiting for nebari-realm-admin-credentials... (attempt ${i}/6)"
  sleep 5
done

# ArgoCD admin password
ARGOCD_PASS="$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)" || true

# Gateway IP from k3d's servicelb (klipper). Scoped to envoy-gateway-system,
# where NIC's Envoy Gateway controller creates the LoadBalancer service for the
# Nebari Gateway. klipper populates status.loadBalancer.ingress[0].ip with the
# k3d node IP. Avoids picking up unrelated LoadBalancer services elsewhere.
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

# Keycloak external issuer URL. Derived from the domain in the NIC config
# NIC wrote to the gitops repo, matching NIC's own formula
# (pkg/argocd/writer.go: `https://keycloak.<domain><KeycloakBasePath>`,
# where KeycloakBasePath is empty for the existing provider).
KEYCLOAK_ISSUER_URL=""
if [[ -n "${GITOPS_DIR:-}" && -f "${GITOPS_DIR}/nic-config.yaml" ]]; then
  DOMAIN="$(awk '/^domain:/ {gsub(/["'"'"']/, "", $2); print $2; exit}' \
    "${GITOPS_DIR}/nic-config.yaml")"
  if [[ -n "${DOMAIN}" ]]; then
    KEYCLOAK_ISSUER_URL="https://keycloak.${DOMAIN}"
  fi
fi

# Register masks BEFORE echoing — ::add-mask:: only filters subsequent
# log output, not retroactively.
[[ -n "${KEYCLOAK_PASS}" ]] && echo "::add-mask::${KEYCLOAK_PASS}"
[[ -n "${REALM_PASS}" ]] && echo "::add-mask::${REALM_PASS}"
[[ -n "${ARGOCD_PASS}" ]] && echo "::add-mask::${ARGOCD_PASS}"

echo "Keycloak admin password (master): ${KEYCLOAK_PASS:-(not found)}"
echo "Keycloak admin password (nebari realm): ${REALM_PASS:-(not found; realm-setup job may still be running — see #27)}"
echo "ArgoCD admin password: ${ARGOCD_PASS:-(not found)}"
echo "Gateway IP: ${GATEWAY_IP:-(not found)}"
echo "Keycloak issuer URL: ${KEYCLOAK_ISSUER_URL:-(not found; GITOPS_DIR/nic-config.yaml missing or has no domain field)}"

echo "::endgroup::"

{
  echo "keycloak-admin-password=${KEYCLOAK_PASS}"
  echo "keycloak-realm-admin-password=${REALM_PASS}"
  echo "argocd-admin-password=${ARGOCD_PASS}"
  echo "gateway-ip=${GATEWAY_IP}"
  echo "keycloak-issuer-url=${KEYCLOAK_ISSUER_URL}"
} >> "${GITHUB_OUTPUT}"
