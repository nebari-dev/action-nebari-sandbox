#!/usr/bin/env bash
# Publish the sandbox gateway CA so consumers can trust its TLS (#69).
#
# NIC's gateway cert is signed by the cert-manager `selfsigned-issuer`, so app
# images with standard roots don't trust `https://<domain>`. cert-manager writes
# the trust anchor into the gateway TLS secret's `ca.crt` (for a selfSigned
# issuer that equals the leaf itself). We expose it two ways:
#   1. A file on the runner + `ca-cert-path` output (runner-side `curl --cacert`,
#      and a source for consumers to build their own mounts).
#   2. A well-known ConfigMap `nebari-sandbox-ca` (key ca.crt) in `kube-public`,
#      which any consumer can replicate into their namespace and mount.
#
# Read-only against the cluster; on a missing secret it warns and emits an empty
# output rather than failing (e.g. a consumer nic-config using a custom cert).

set -euo pipefail

GITOPS_DIR="${GITOPS_DIR:-}"
# Default gateway TLS secret + namespace NIC uses (pkg/config: nebari-gateway-tls;
# the Certificate lives in envoy-gateway-system).
SECRET_NS="${GATEWAY_TLS_NAMESPACE:-envoy-gateway-system}"
SECRET_NAME="${GATEWAY_TLS_SECRET:-nebari-gateway-tls}"
CA_PATH="${GITOPS_DIR:-/tmp}/sandbox-ca.crt"

echo "::group::Publish sandbox gateway CA"

# The cert is issued during foundational install; poll briefly in case this runs
# right after the gate. Poll shape is overridable (env) so the skip path is
# fast to unit-test.
CA_POLL_ATTEMPTS="${CA_POLL_ATTEMPTS:-6}"
CA_POLL_INTERVAL="${CA_POLL_INTERVAL:-5}"
CA_B64=""
for i in $(seq 1 "${CA_POLL_ATTEMPTS}"); do
  CA_B64="$(kubectl -n "${SECRET_NS}" get secret "${SECRET_NAME}" \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
  # Fall back to tls.crt if ca.crt is empty (defensive).
  if [[ -z "${CA_B64}" ]]; then
    CA_B64="$(kubectl -n "${SECRET_NS}" get secret "${SECRET_NAME}" \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)"
  fi
  [[ -n "${CA_B64}" ]] && break
  echo "Waiting for ${SECRET_NS}/${SECRET_NAME} ... (attempt ${i}/${CA_POLL_ATTEMPTS})"
  sleep "${CA_POLL_INTERVAL}"
done

if [[ -z "${CA_B64}" ]]; then
  echo "::warning::Gateway TLS secret ${SECRET_NS}/${SECRET_NAME} not found or has no ca.crt/tls.crt; skipping CA publish. ca-cert-path output will be empty."
  echo "ca-cert-path=" >> "${GITHUB_OUTPUT}"
  echo "::endgroup::"
  exit 0
fi

echo "${CA_B64}" | base64 -d > "${CA_PATH}"
echo "Wrote CA to ${CA_PATH} ($(wc -c < "${CA_PATH}") bytes)"
echo "ca-cert-path=${CA_PATH}" >> "${GITHUB_OUTPUT}"

# Well-known in-cluster copy. kube-public is readable by all authenticated
# subjects — the conventional home for cluster-wide info.
kubectl -n kube-public create configmap nebari-sandbox-ca \
  --from-file=ca.crt="${CA_PATH}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Published ConfigMap kube-public/nebari-sandbox-ca (key ca.crt)."
echo "  Consumers: kubectl get configmap nebari-sandbox-ca -n kube-public -o jsonpath='{.data.ca\.crt}'"
echo "  then mount it and set SSL_CERT_FILE / REQUESTS_CA_BUNDLE / NODE_EXTRA_CA_CERTS."
echo "::endgroup::"
