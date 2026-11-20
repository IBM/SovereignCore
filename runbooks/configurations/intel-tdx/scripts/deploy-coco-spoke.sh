#!/usr/bin/env bash
# Render the tenant AppProject and root OCI ArgoCD Application.
# Prerequisites: oc, yq; tenant mirror/pull/GitOps credentials, KBS certificate in tenant Vault.
# Effects: Default prints manifests; APPLY=true applies them. MachineConfig changes trigger node reboots.
# Exit: 0 success; nonzero on configuration, cluster guard or apply failure.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  OC  oc targeting the TENANT  (oc --kubeconfig=<site TENANT_KUBECONFIG>)
#  APP_NAME  root Application name  (coco-pattern-spoke)
#  VALUES_CG  clusterGroup values file  (deploy/spoke/values-baremetal-spoke.yaml)
#  VALUES_GLOBAL  global values file  (deploy/spoke/values-global-spoke.yaml)
#  APPS_DOMAIN  tenant ingress domain (read from tenant API)
#  APPLY  apply (default false = print manifest only)
#  TENANT_AGENT_NAMESPACE  CUGA agent namespace; set: adds deploy/spoke/values-cuga-agent.yaml to VALUES_CG (site value)
#  ARGOCD_CONTROLLER_MEMORY  minimum memory limit of the tenant ArgoCD application controller (8Gi, as the hub)
# Other deploy-coco-hub.sh environment overrides also apply.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/site.sh"

export OC="${OC:-oc --kubeconfig=${TENANT_KUBECONFIG}}"
export APP_NAME="${APP_NAME:-coco-pattern-spoke}"
export APP_PROJECT="${APP_PROJECT:-coco-pattern}"
export VALUES_CG="${VALUES_CG:-deploy/spoke/values-baremetal-spoke.yaml}"
export VALUES_GLOBAL="${VALUES_GLOBAL:-deploy/spoke/values-global-spoke.yaml}"
export RETIRE_PATTERN="${RETIRE_PATTERN:-false}"

# Derive the tenant domain from its cluster so Vault paths match the tenant subtree.
export TARGET_CLUSTER=tenant
. "${SCRIPT_DIR}/lib/cluster-guard.sh"
cluster_guard tenant "${OC}"
APPS_DOMAIN="${APPS_DOMAIN:-$(${OC} get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')}"
[ -n "${APPS_DOMAIN}" ] || { echo "deploy-coco-spoke: cannot read the tenant ingress domain via OC" >&2; exit 1; }
export CLUSTER_DOMAIN="${APPS_DOMAIN#apps.}"
echo "deploy-coco-spoke: tenant clusterDomain=${CLUSTER_DOMAIN} (from ${OC})" >&2
case "${VALUES_CG}" in /*) SRC_CG="${VALUES_CG}" ;; *) SRC_CG="${SCRIPT_DIR}/../${VALUES_CG}" ;; esac
if [ -n "${TENANT_AGENT_NAMESPACE:-}" ]; then
  echo "deploy-coco-spoke: adding the CUGA agent in ${TENANT_AGENT_NAMESPACE} to ${VALUES_CG}" >&2
  AGENT_CG="$(mktemp)"; trap 'rm -f "${AGENT_CG}"' EXIT
  AGENT_VALUES="${SCRIPT_DIR}/../deploy/spoke/values-cuga-agent.yaml" \
    yq --from-file "${SCRIPT_DIR}/lib/add-agent.yq" "${SRC_CG}" > "${AGENT_CG}"
  export VALUES_CG="${AGENT_CG}"
  export EXTRA_PARAMS="${EXTRA_PARAMS:-} global.tenantAgentNamespace=${TENANT_AGENT_NAMESPACE}"
fi

# The GitOps default (2Gi) is OOMKilled on a full Sovereign Core tenant while it diffs the pattern
# (kyverno CRDs); raise only the controller's memory limit, never lower it.
if [ "${APPLY:-false}" = true ]; then
  want="${ARGOCD_CONTROLLER_MEMORY:-8Gi}"
  have="$(${OC} get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.controller.resources.limits.memory}')" \
    || { echo "deploy-coco-spoke: cannot read ArgoCD openshift-gitops in openshift-gitops" >&2; exit 1; }
  bytes() { case "$1" in *i) numfmt --from=iec-i "$1" ;; *) numfmt --from=si "$1" ;; esac; }
  if [ -z "${have}" ] || [ "$(bytes "${have}")" -lt "$(bytes "${want}")" ]; then
    echo "deploy-coco-spoke: ArgoCD application controller memory limit ${have:-unset} -> ${want}" >&2
    ${OC} patch argocd openshift-gitops -n openshift-gitops --type merge \
      -p "{\"spec\":{\"controller\":{\"resources\":{\"limits\":{\"memory\":\"${want}\"}}}}}" >/dev/null
  fi
fi

"${SCRIPT_DIR}/deploy-coco-hub.sh" "$@"
