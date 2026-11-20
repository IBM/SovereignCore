#!/usr/bin/env bash
# Copy the hub mirror CA byte-for-byte into tenant Vault mirrorCA.
# Prerequisites: oc; site config, hub Secret access and tenant ESO/ClusterSecretStore write access.
# Effects: Default reads/previews; APPLY=true writes through transient Secret/PushSecret objects, then deletes them.
# Exit: 0 success; nonzero on guard, Secret, store or PushSecret failure.
# CA bytes are measured; tenant Vault access is restricted to its cluster-name subtree.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  OC  oc targeting the TENANT  (oc --kubeconfig=$TENANT_KUBECONFIG)
#  OC_HUB  oc targeting the HUB (reads the source Secret)  (oc --kubeconfig=$HUB_KUBECONFIG)
#  MIRROR_CA_NS/MIRROR_CA_NAME  hub mirror CA, key pem  (imperative/registry-ca)
#  CSS_NAME, CLUSTER_NAME, TV_NS, TIMEOUT  see scripts/lib/tenant-vault.sh
#  APPLY  true to write the tenant Vault (default false = read + preview only)

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/site.sh"
OC="${OC:-oc --kubeconfig=${TENANT_KUBECONFIG}}"
OC_HUB="${OC_HUB:-oc --kubeconfig=${HUB_KUBECONFIG}}"
MIRROR_CA_NS="${MIRROR_CA_NS:-imperative}"
MIRROR_CA_NAME="${MIRROR_CA_NAME:-registry-ca}"
APPLY="${APPLY:-false}"

msg()  { printf '\033[1;34m[03b-vaultaas]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[03b-vaultaas] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cluster-guard.sh"
cluster_guard tenant "${OC}"
cluster_guard hub "${OC_HUB}"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/tenant-vault.sh"

tv_init
tv_push "${MIRROR_CA_NS}" "${MIRROR_CA_NAME}" pem ca mirrorCA
