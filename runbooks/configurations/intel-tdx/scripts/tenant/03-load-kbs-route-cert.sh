#!/usr/bin/env bash
# Copy the hub KBS certificate byte-for-byte into tenant Vault kbsRouteCert.
# Prerequisites: oc; site config, hub Secret access and tenant ESO/ClusterSecretStore write access.
# Effects: Default reads/previews; APPLY=true writes through transient Secret/PushSecret objects, then deletes them.
# Exit: 0 success; nonzero on guard, Secret, store or PushSecret failure.
# Certificate bytes are measured; after rotation copy the certificate and rerun coco-initdata.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  OC  oc targeting the TENANT  (oc --kubeconfig=$TENANT_KUBECONFIG)
#  OC_HUB  oc targeting the HUB  (oc --kubeconfig=$HUB_KUBECONFIG)
#  KBS_CERT_NS/KBS_CERT_SECRET  hub Secret holding tls.crt  (imperative/kbs-tls-self-signed)
#  CSS_NAME, CLUSTER_NAME, TV_NS, TIMEOUT  see scripts/lib/tenant-vault.sh
#  APPLY  true to write the tenant Vault (default false = read + preview only)

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/site.sh"
OC="${OC:-oc --kubeconfig=${TENANT_KUBECONFIG}}"
OC_HUB="${OC_HUB:-oc --kubeconfig=${HUB_KUBECONFIG}}"
KBS_CERT_NS="${KBS_CERT_NS:-imperative}"
KBS_CERT_SECRET="${KBS_CERT_SECRET:-kbs-tls-self-signed}"
APPLY="${APPLY:-false}"

msg()  { printf '\033[1;34m[03-kbs-cert]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[03-kbs-cert] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[03-kbs-cert] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cluster-guard.sh"
cluster_guard tenant "${OC}"
cluster_guard hub "${OC_HUB}"
command -v openssl >/dev/null 2>&1 || die "'openssl' not found in PATH"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/tenant-vault.sh"

tv_init
tv_b64 "${KBS_CERT_NS}" "${KBS_CERT_SECRET}" tls.crt | base64 -d \
  | openssl x509 -noout -subject -issuer -enddate 2>/dev/null | sed 's/^/    /' >&2 \
  || die "hub ${KBS_CERT_NS}/${KBS_CERT_SECRET} tls.crt is not a PEM certificate"
tv_push "${KBS_CERT_NS}" "${KBS_CERT_SECRET}" tls.crt certificate kbsRouteCert
[ "${APPLY}" != true ] || msg "The tenant coco-initdata kbs-route-cert ExternalSecret syncs it into kbs-tls-self-signed."
