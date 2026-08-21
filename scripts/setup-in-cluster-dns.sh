#!/usr/bin/env bash
# Make the external Nebari hostnames resolve from INSIDE the cluster (#69).
#
# Keycloak's OIDC discovery document advertises the external issuer
# `https://keycloak.<domain>`, so a consumer pod doing server-side OIDC must
# fetch that exact hostname. But `*.<domain>` doesn't resolve inside the cluster
# (the README only reaches the gateway from the runner via `curl --resolve`).
#
# kind's CoreDNS comes from kubeadm: a single `coredns` ConfigMap whose
# `Corefile` key is the only thing it reads. We prepend a server block that
# answers the whole `<domain>` zone with the gateway LoadBalancer IP using the
# `template` plugin (the only stock plugin that supports wildcard responses).
# Zone matching is most-specific-first, so position relative to `.:53` does not
# matter.
#
# This deliberately does NOT write a `coredns-custom` ConfigMap. That is a k3s
# convention (k3s CoreDNS mounts it and does `import /etc/coredns/custom/*.server`,
# and reverts hand edits to its packaged Corefile). kind honors no such import,
# so writing there was a silent no-op -- created, never read, reported ready.
# That was #104. This action provisions kind and only kind: `action.yml` has no
# provider input, `deploy-platform.sh` hard-codes `cluster: local: {}` and the
# `kind-<project>` context, and the k3d path was deleted in #99. If a non-kind
# local provider ever returns, reintroduce the branch then rather than carrying
# a dead one now.
#
# Upstream: NIC owns the kind cluster, MetalLB, the gateway, and `domain` -- every
# input to this mapping -- so it could establish the zone at provision time with
# no read-modify-write at all. Tracked in nebari-dev/nebari-infrastructure-core#613;
# remove this script once a NIC release does it.
#
# Only keycloak.<domain>/argocd.<domain>/<domain> have valid TLS SANs today
# (NIC's gateway cert has no wildcard SAN), so hosts outside those resolve but
# fail TLS at handshake -- see the action README / issue #69.

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
# CoreDNS's reload and hard-fails the run -- skip cleanly with a clear reason.
if [[ ! "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "::warning::in-cluster DNS: domain '${DOMAIN}' is not a plain hostname; skipping."
  exit 0
fi
# Runs after wait-platform, so MetalLB has assigned the gateway address and the
# caller passes it through. No self-polling: an empty value here means the
# platform never got a LoadBalancer IP, which is a platform problem, not
# something to wait on again.
if [[ -z "${GATEWAY_IP}" ]]; then
  echo "::warning::in-cluster DNS: gateway-ip is empty (MetalLB never assigned a LoadBalancer IP); skipping. Pods will not resolve ${DOMAIN}."
  exit 0
fi
if [[ ! "${GATEWAY_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::warning::in-cluster DNS: gateway-ip '${GATEWAY_IP}' is not an IPv4 address; skipping."
  exit 0
fi

echo "::group::Set up in-cluster DNS for *.${DOMAIN} -> ${GATEWAY_IP}"

SERVER_FILE="$(mktemp)"
NEW_COREFILE=""
ORIG_COREFILE=""
trap 'rm -f "${SERVER_FILE}" "${NEW_COREFILE}" "${ORIG_COREFILE}"' EXIT

# A: answer every name in the zone with the gateway IP. AAAA returns an empty
# NOERROR so dual-stack / happy-eyeballs resolvers don't stall. The IN ANY
# catch-all makes any other qtype (SRV/TXT/HTTPS/SVCB type 65) return empty
# NOERROR too, instead of SERVFAIL, since this is an authoritative zone with no
# fallthrough.
cat > "${SERVER_FILE}" <<EOF
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

COREFILE="$(kubectl -n kube-system get configmap coredns \
  -o jsonpath='{.data.Corefile}' 2>/dev/null || true)"
if [[ -z "${COREFILE}" ]]; then
  echo "::warning::in-cluster DNS: could not read the coredns ConfigMap in kube-system; skipping. Pods will not resolve ${DOMAIN}."
  echo "::endgroup::"
  exit 0
fi

# Leave an existing zone for this domain alone, whoever wrote it. Defining the
# zone twice makes CoreDNS refuse to load ("cannot serve ... it is already
# defined"), which would take the `.:53` block -- all cluster DNS -- down with
# it. Matching only `<domain>:53` would miss the other legal spellings, so this
# covers the bare zone, an explicit port, the fully-qualified form, and a
# multi-zone block that merely includes our domain. A more specific zone
# (`sub.<domain>`) deliberately does not count: that is a different zone and
# does not conflict.
#
# The pattern errs toward matching, on purpose. A false positive costs us a
# change we could have made and says so in the warning; a false negative
# defines the zone twice and CoreDNS refuses to load, taking cluster DNS with
# it. It therefore also matches a nested `template IN A <domain> {` directive,
# which in practice means a block of ours is already in place -- so skipping is
# the right answer there too.
DOM_ESC="${DOMAIN//./\\.}"
ZONE_RE="^[[:space:]]*([^#{]*[[:space:]])?${DOM_ESC}\.?(:[0-9]+)?([[:space:]][^{]*)?[[:space:]]*\{"
if grep -qE "${ZONE_RE}" <<<"${COREFILE}"; then
  echo "::warning::in-cluster DNS: the Corefile already defines a ${DOMAIN} zone; leaving it untouched. Pods will resolve ${DOMAIN} however that block says, which may not be ${GATEWAY_IP}."
  echo "::endgroup::"
  exit 0
fi

ORIG_COREFILE="$(mktemp)"
printf '%s\n' "${COREFILE}" > "${ORIG_COREFILE}"
NEW_COREFILE="$(mktemp)"
cat "${SERVER_FILE}" "${ORIG_COREFILE}" > "${NEW_COREFILE}"

# Never hand CoreDNS a Corefile that lost what it already had. Prepending cannot
# drop anything, so this is belt-and-braces -- but the failure it guards against
# (a Corefile that parses fine and serves nothing) is invisible to the rollout
# check below, so it is worth asserting rather than trusting.
if ! grep -qE '^[[:space:]]*\.:53[[:space:]]*\{' "${NEW_COREFILE}" \
   || [[ "$(grep -c '{' "${NEW_COREFILE}")" != "$(grep -c '}' "${NEW_COREFILE}")" ]]; then
  echo "::warning::in-cluster DNS: the assembled Corefile lost the default server block or has unbalanced braces; refusing to apply it. Pods will not resolve ${DOMAIN}."
  echo "::endgroup::"
  exit 0
fi

# Patch only the Corefile key, so any other key in the ConfigMap survives.
apply_corefile() {
  kubectl -n kube-system create configmap coredns \
    --from-file=Corefile="$1" \
    --dry-run=client -o yaml \
    | kubectl -n kube-system patch configmap coredns --type merge --patch-file /dev/stdin
}

if ! apply_corefile "${NEW_COREFILE}"; then
  echo "::warning::in-cluster DNS: could not patch the coredns Corefile; skipping. Pods will not resolve ${DOMAIN}."
  echo "::endgroup::"
  exit 0
fi

# Restart CoreDNS so new pods pick up the updated config immediately, rather
# than waiting up to ~60s for the kubelet volume sync + reload plugin.
if kubectl -n kube-system rollout restart deployment/coredns \
   && kubectl -n kube-system rollout status deployment/coredns --timeout=120s; then
  echo "In-cluster DNS ready via the coredns Corefile: *.${DOMAIN} resolves to ${GATEWAY_IP} for pods."
  echo "  Note: only keycloak.${DOMAIN}, argocd.${DOMAIN}, and ${DOMAIN} have valid TLS SANs."
  echo "::endgroup::"
  exit 0
fi

# CoreDNS did not come back. Put the Corefile back: this is an optional
# convenience, and leaving cluster DNS broken would fail everything downstream
# with unrelated-looking errors.
echo "::warning::in-cluster DNS: CoreDNS did not become ready after the change; restoring the previous Corefile. Pods will not resolve ${DOMAIN}."
RESTORED=1
apply_corefile "${ORIG_COREFILE}" || RESTORED=0
kubectl -n kube-system rollout restart deployment/coredns >/dev/null 2>&1 || true
kubectl -n kube-system rollout status deployment/coredns --timeout=120s >/dev/null 2>&1 \
  || RESTORED=0

# Warn-and-skip is only honest while the damage is confined to this feature.
# An unverified restore means cluster DNS may be down, so the consumer has to
# hear about it as an error rather than read a reassuring warning.
if [[ "${RESTORED}" != 1 ]]; then
  echo "::error::in-cluster DNS: CoreDNS is broken and could not be restored. Cluster DNS is likely down; expect unrelated-looking failures until it is fixed. Inspect: kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'"
  echo "::endgroup::"
  exit 1
fi
echo "Previous Corefile restored; cluster DNS is back."
echo "::endgroup::"
exit 0
