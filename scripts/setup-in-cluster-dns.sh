#!/usr/bin/env bash
# Make the external Nebari hostnames resolve from INSIDE the cluster (#69).
#
# Keycloak's OIDC discovery document advertises the external issuer
# `https://keycloak.<domain>`, so a consumer pod doing server-side OIDC must
# fetch that exact hostname. But `*.<domain>` doesn't resolve inside the cluster
# (the README only reaches the gateway from the runner via `curl --resolve`).
#
# Which file CoreDNS reads depends on the distribution, so we detect it:
#
#   - k3s CoreDNS imports an optional `coredns-custom` ConfigMap (mounted at
#     /etc/coredns/custom, `import .../*.server`). Write there, because k3s
#     reconciles its packaged manifests and would revert a Corefile edit.
#   - kind/kubeadm CoreDNS has no such import and no custom mount, so the only
#     file it reads is the `Corefile` key itself. Writing `coredns-custom`
#     there is a silent no-op (this was #104): the ConfigMap is created,
#     CoreDNS restarts, and nothing changes.
#
# Either way the block answers the whole `<domain>` zone with the gateway
# LoadBalancer IP using the `template` plugin (the only stock plugin that
# supports wildcard responses).
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
# The domain is interpolated straight into the Corefile below, so reject anything
# that isn't a plain hostname. A consumer nic-config domain with Corefile
# metacharacters ({ } ;) would otherwise produce a malformed block that fails
# CoreDNS's reload and hard-fails the run — skip cleanly with a clear reason.
if [[ ! "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "::warning::in-cluster DNS: domain '${DOMAIN}' is not a plain hostname; skipping."
  exit 0
fi

# Self-poll the gateway LB IP rather than trusting only the passed-in value.
# extract-outputs captures gateway-ip once, ~60s after deploy; if klipper was
# slow then, the value is empty and this feature would silently never apply.
# Re-poll here (same query extract-outputs uses) so a late LB assignment is
# still picked up.
# Poll shape overridable (env) so the skip path is fast to unit-test.
DNS_POLL_ATTEMPTS="${DNS_POLL_ATTEMPTS:-12}"
DNS_POLL_INTERVAL="${DNS_POLL_INTERVAL:-5}"
if [[ -z "${GATEWAY_IP}" ]]; then
  echo "gateway-ip not passed in; polling for the LoadBalancer IP..."
  for i in $(seq 1 "${DNS_POLL_ATTEMPTS}"); do
    GATEWAY_IP="$(kubectl get svc -n envoy-gateway-system \
      -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' \
      2>/dev/null)" || true
    [[ -n "${GATEWAY_IP}" ]] && break
    echo "Waiting for LoadBalancer IP... (attempt ${i}/${DNS_POLL_ATTEMPTS})"
    sleep "${DNS_POLL_INTERVAL}"
  done
fi
if [[ -z "${GATEWAY_IP}" ]]; then
  echo "::warning::in-cluster DNS: gateway-ip is empty (klipper never assigned a LoadBalancer IP); skipping. Pods will not resolve ${DOMAIN}."
  exit 0
fi
if [[ ! "${GATEWAY_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::warning::in-cluster DNS: gateway-ip '${GATEWAY_IP}' is not an IPv4 address; skipping."
  exit 0
fi

echo "::group::Set up in-cluster DNS for *.${DOMAIN} -> ${GATEWAY_IP}"

SERVER_FILE="$(mktemp)"
# NEW_COREFILE and ORIG_COREFILE are only used on the Corefile path below;
# declare them here so a single trap covers every temp file.
NEW_COREFILE=""
ORIG_COREFILE=""
trap 'rm -f "${SERVER_FILE}" "${NEW_COREFILE}" "${ORIG_COREFILE}"' EXIT
# A: answer every name in the zone with the gateway IP. AAAA returns an empty
# NOERROR so dual-stack / happy-eyeballs resolvers don't stall. The IN ANY
# catch-all makes any other qtype (SRV/TXT/HTTPS/SVCB type 65) return empty
# NOERROR too, instead of SERVFAIL, since this is an authoritative zone with no
# fallthrough.
# MARKER lets a re-run find and replace the block we wrote, instead of merely
# noticing that some block for the zone exists. Without it the step is
# presence-based: a stale gateway IP would be kept, and a zone written without
# an explicit `:53` would be missed and then duplicated, which CoreDNS refuses
# to load ("cannot serve ... it is already defined") and which would take all
# cluster DNS down with it.
MARKER="# nebari-sandbox: managed zone block (replaced on re-run)"
cat > "${SERVER_FILE}" <<EOF
${MARKER}
${DOMAIN}:53 {
    errors
    template IN A ${DOMAIN} {
        answer "{{ .Name }} 60 IN A ${GATEWAY_IP}"
    }
    template IN AAAA ${DOMAIN} {
        rcode NOERROR
    }
    template IN ANY ${DOMAIN} {
        rcode NOERROR
    }
}
EOF

echo "server block for the ${DOMAIN} zone:"
sed 's/^/  /' "${SERVER_FILE}"

# Read the live Corefile to decide which mechanism this cluster's CoreDNS
# actually honors. Unreadable means we cannot tell, so skip like an extractor
# rather than mutating a ConfigMap that may never be read.
COREFILE="$(kubectl -n kube-system get configmap coredns \
  -o jsonpath='{.data.Corefile}' 2>/dev/null || true)"
if [[ -z "${COREFILE}" ]]; then
  echo "::warning::in-cluster DNS: could not read the coredns ConfigMap in kube-system; skipping. Pods will not resolve ${DOMAIN}."
  echo "::endgroup::"
  exit 0
fi

# Roll back whatever we changed, so a CoreDNS that will not load leaves the
# cluster's DNS as it was rather than broken. Set per branch below.
rollback() { :; }

# The `.server` glob specifically: that is the key name we write, and a Corefile
# importing only `*.override` would never read it. Testing for the directory
# alone would reintroduce #104 in a different disguise.
if grep -qF 'import /etc/coredns/custom/*.server' <<<"${COREFILE}"; then
  MECHANISM="coredns-custom ConfigMap (k3s-style import)"
  rollback() {
    kubectl -n kube-system patch configmap coredns-custom --type json \
      -p '[{"op":"remove","path":"/data/nebari-sandbox.server"}]' >/dev/null 2>&1 || true
  }
  # Merge-patch so we don't clobber any coredns-custom keys a consumer set. If
  # the ConfigMap doesn't exist yet, patch fails and we create it.
  if ! kubectl -n kube-system get configmap coredns-custom >/dev/null 2>&1; then
    kubectl -n kube-system create configmap coredns-custom \
      --from-file=nebari-sandbox.server="${SERVER_FILE}"
  else
    kubectl -n kube-system create configmap coredns-custom \
      --from-file=nebari-sandbox.server="${SERVER_FILE}" \
      --dry-run=client -o yaml \
      | kubectl -n kube-system patch configmap coredns-custom --type merge --patch-file /dev/stdin
  fi
else
  MECHANISM="coredns Corefile server block"
  # No `.server` import, so the Corefile is the only thing CoreDNS reads.
  # Prepend the zone as an additional server block; zone matching is
  # most-specific, so position relative to `.:53` does not matter.

  # A zone for this domain that we did not write belongs to whoever did. Adding
  # ours alongside it would define the zone twice and CoreDNS would refuse to
  # start, so leave it alone and say why. Matches `<domain> {` and
  # `<domain>:<port> {`, which is why the presence check is not a plain grep.
  DOMAIN_RE="^[[:space:]]*${DOMAIN//./\\.}(:[0-9]+)?[[:space:]]*\\{"
  if grep -qE "${DOMAIN_RE}" <<<"${COREFILE}" && ! grep -qF "${MARKER}" <<<"${COREFILE}"; then
    echo "::warning::in-cluster DNS: the Corefile already defines a ${DOMAIN} zone that this action did not write; leaving it untouched. Pods will resolve ${DOMAIN} however that block says."
    echo "::endgroup::"
    exit 0
  fi

  ORIG_COREFILE="$(mktemp)"
  printf '%s\n' "${COREFILE}" > "${ORIG_COREFILE}"
  rollback() {
    kubectl -n kube-system create configmap coredns \
      --from-file=Corefile="${ORIG_COREFILE}" \
      --dry-run=client -o yaml \
      | kubectl -n kube-system patch configmap coredns --type merge --patch-file /dev/stdin \
      >/dev/null 2>&1 || true
  }

  # Drop a block we wrote previously, so a re-run converges on the current
  # gateway IP instead of keeping a stale one. Our block starts at MARKER and
  # ends at the next `}` in column 0.
  NEW_COREFILE="$(mktemp)"
  {
    cat "${SERVER_FILE}"
    printf '\n'
    awk -v marker="${MARKER}" '
      $0 == marker { skipping = 1; next }
      skipping && /^}/ { skipping = 0; next }
      skipping { next }
      { print }
    ' "${ORIG_COREFILE}"
  } > "${NEW_COREFILE}"

  # Patch only the Corefile key, so any other key in the ConfigMap survives.
  if ! kubectl -n kube-system create configmap coredns \
      --from-file=Corefile="${NEW_COREFILE}" \
      --dry-run=client -o yaml \
      | kubectl -n kube-system patch configmap coredns --type merge --patch-file /dev/stdin; then
    echo "::warning::in-cluster DNS: could not patch the coredns Corefile; skipping. Pods will not resolve ${DOMAIN}."
    echo "::endgroup::"
    exit 0
  fi
fi

# Restart CoreDNS so new pods pick up the updated config immediately, rather than
# waiting up to ~60s for the kubelet volume sync + reload plugin.
#
# This runs while the foundational stack is still converging, so a CoreDNS that
# comes back unhealthy would break DNS for everything and surface as an
# unrelated-looking ArgoCD or Keycloak failure. Roll back and skip instead: this
# is an optional convenience, and per CONTRIBUTING it must degrade rather than
# fail the consumer's run.
if ! kubectl -n kube-system rollout restart deployment/coredns \
   || ! kubectl -n kube-system rollout status deployment/coredns --timeout=120s; then
  echo "::warning::in-cluster DNS: CoreDNS did not become ready after the change; rolling back so cluster DNS keeps working. Pods will not resolve ${DOMAIN}."
  rollback
  kubectl -n kube-system rollout restart deployment/coredns >/dev/null 2>&1 || true
  kubectl -n kube-system rollout status deployment/coredns --timeout=120s >/dev/null 2>&1 || true
  echo "::endgroup::"
  exit 0
fi

echo "In-cluster DNS ready via ${MECHANISM}: *.${DOMAIN} resolves to ${GATEWAY_IP} for pods."
echo "  Note: only keycloak.${DOMAIN}, argocd.${DOMAIN}, and ${DOMAIN} have valid TLS SANs."
echo "::endgroup::"
