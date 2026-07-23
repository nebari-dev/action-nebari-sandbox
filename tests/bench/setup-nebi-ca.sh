#!/usr/bin/env bash
# Benchmark prerequisite: materialize the `nebi-org-ca` configmap the nebi pack
# mounts (orgCABundle.configMapName). The bundle is the runner's system CA set
# PLUS the self-signed *.nebari.local gateway cert, so the nebi server's OIDC
# verifier can reach https://keycloak.nebari.local over TLS without an x509
# error. In a real deploy an operator/admin seeds this; here we build it inline.
#
# Env:
#   NAMESPACE            target namespace for the configmap (default nebari-system)
#   GATEWAY_TLS_SECRET   gateway TLS secret name (default nebari-gateway-tls)
#   GATEWAY_TLS_NAMESPACE  where that secret lives (default envoy-gateway-system)
set -euo pipefail

NAMESPACE="${NAMESPACE:-nebari-system}"
GATEWAY_TLS_SECRET="${GATEWAY_TLS_SECRET:-nebari-gateway-tls}"
# NIC's Certificate lives in envoy-gateway-system, not the pack's namespace.
GATEWAY_TLS_NAMESPACE="${GATEWAY_TLS_NAMESPACE:-envoy-gateway-system}"
SYSTEM_CA="${SYSTEM_CA:-/etc/ssl/certs/ca-certificates.crt}"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
bundle="${workdir}/ca-bundle.crt"

# System CAs first (so public issuers still verify), then the gateway cert.
if [[ -f "${SYSTEM_CA}" ]]; then
  cat "${SYSTEM_CA}" > "${bundle}"
else
  echo "::warning::system CA bundle ${SYSTEM_CA} not found; bundle will contain only the gateway cert"
  : > "${bundle}"
fi

# Append the gateway CA (ca.crt if the secret carries one, else the leaf cert).
gw_ca="$(kubectl get secret "${GATEWAY_TLS_SECRET}" -n "${GATEWAY_TLS_NAMESPACE}" \
  -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
if [[ -z "${gw_ca}" ]]; then
  gw_ca="$(kubectl get secret "${GATEWAY_TLS_SECRET}" -n "${GATEWAY_TLS_NAMESPACE}" \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)"
fi
if [[ -z "${gw_ca}" ]]; then
  echo "::error::could not read ca.crt or tls.crt from secret ${GATEWAY_TLS_SECRET} in ${GATEWAY_TLS_NAMESPACE}"
  exit 1
fi
printf '%s' "${gw_ca}" | base64 -d >> "${bundle}"

kubectl create configmap nebi-org-ca -n "${NAMESPACE}" \
  --from-file=ca-bundle.crt="${bundle}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "nebi-org-ca configmap created in ${NAMESPACE} ($(grep -c 'BEGIN CERTIFICATE' "${bundle}") certs)"
