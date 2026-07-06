#!/usr/bin/env bash
# Make the external Nebari hostnames resolve from INSIDE the cluster (#69).
#
# Keycloak's OIDC discovery document advertises the external issuer
# `https://keycloak.<domain>`, so a consumer pod doing server-side OIDC must
# fetch that exact hostname. But `*.<domain>` doesn't resolve inside the cluster
# (the README only reaches the gateway from the runner via `curl --resolve`).
#
# k3s CoreDNS imports an optional `coredns-custom` ConfigMap (mounted at
# /etc/coredns/custom, `import .../*.server`). We add a server block that
# answers the whole `<domain>` zone with the gateway LoadBalancer IP using the
# `template` plugin (the only stock plugin that supports wildcard responses).
#
# Only keycloak.<domain>/argocd.<domain>/<domain> have valid TLS SANs today
# (NIC's gateway cert has no wildcard SAN), so hosts outside those resolve but
# fail TLS at handshake — see the action README / issue #69.

set -euo pipefail

DOMAIN="${DOMAIN:-}"
GATEWAY_IP="${GATEWAY_IP:-}"

if [[ -z "${DOMAIN}" ]]; then
  echo "::warning::in-cluster DNS: no domain resolved (GITOPS_DIR/nic-config.yaml had no domain); skipping."
  exit 0
fi
if [[ -z "${GATEWAY_IP}" ]]; then
  echo "::warning::in-cluster DNS: gateway-ip is empty (klipper may not have assigned a LoadBalancer IP); skipping. Pods will not resolve ${DOMAIN}."
  exit 0
fi
if [[ ! "${GATEWAY_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::warning::in-cluster DNS: gateway-ip '${GATEWAY_IP}' is not an IPv4 address; skipping."
  exit 0
fi

echo "::group::Set up in-cluster DNS for *.${DOMAIN} -> ${GATEWAY_IP}"

SERVER_FILE="$(mktemp)"
trap 'rm -f "${SERVER_FILE}"' EXIT
# A/AAAA: answer every name in the zone with the gateway IP. AAAA returns an
# empty NOERROR so dual-stack / happy-eyeballs resolvers don't stall or SERVFAIL.
cat > "${SERVER_FILE}" <<EOF
${DOMAIN}:53 {
    errors
    template IN A ${DOMAIN} {
        answer "{{ .Name }} 60 IN A ${GATEWAY_IP}"
    }
    template IN AAAA ${DOMAIN} {
        rcode NOERROR
    }
}
EOF

echo "coredns-custom server block (nebari-sandbox.server):"
sed 's/^/  /' "${SERVER_FILE}"

# Merge-patch so we don't clobber any coredns-custom keys a consumer set. If the
# ConfigMap doesn't exist yet, patch fails and we create it.
if ! kubectl -n kube-system get configmap coredns-custom >/dev/null 2>&1; then
  kubectl -n kube-system create configmap coredns-custom \
    --from-file=nebari-sandbox.server="${SERVER_FILE}"
else
  kubectl -n kube-system create configmap coredns-custom \
    --from-file=nebari-sandbox.server="${SERVER_FILE}" \
    --dry-run=client -o yaml \
    | kubectl -n kube-system patch configmap coredns-custom --type merge --patch-file /dev/stdin
fi

# Restart CoreDNS so new pods mount the ConfigMap immediately, rather than
# waiting up to ~60s for the kubelet volume sync + reload plugin. Completes in
# seconds, before any consumer workload exists, so the DNS blip is harmless.
kubectl -n kube-system rollout restart deployment/coredns
kubectl -n kube-system rollout status deployment/coredns --timeout=120s

echo "In-cluster DNS ready: *.${DOMAIN} resolves to ${GATEWAY_IP} for pods."
echo "  Note: only keycloak.${DOMAIN}, argocd.${DOMAIN}, and ${DOMAIN} have valid TLS SANs."
echo "::endgroup::"
