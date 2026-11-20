#!/usr/bin/env bash
# Prepare tenant GitOps with read-only OCI credentials and merged hub TLS trust.
# Prerequisites: oc, python3; hub/tenant kubeconfigs, site config and TDX_REGISTRY_AUTH_FILE.
# Effects: Default previews; APPLY=true applies credentials/trust and optionally installs GitOps.
# Exit: 0 success; nonzero on prerequisites, guard, credential or apply failure.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  OC  oc targeting the TENANT (oc --kubeconfig=$TENANT_KUBECONFIG)
#  HUB_OC  oc targeting the HUB  (oc --kubeconfig=$HUB_KUBECONFIG)
#  ARGO_NS  ArgoCD namespace on both clusters  (openshift-gitops)
#  REPO_SECRET  ArgoCD OCI repo secret name  (quay-oci-repo-creds)
#  TLS_CM  ArgoCD repo TLS ConfigMap name  (argocd-tls-certs-cm)
#  TDX_REGISTRY_AUTH_FILE  dockerconfigjson with the TDX robots  (site value)
#  INSTALL_GITOPS  true to subscribe the GitOps operator if absent  (false)
#  GITOPS_SOURCE  GitOps catalog  (detected: the catalog whose package offers GITOPS_CSV in GITOPS_CHANNEL)
#  GITOPS_CHANNEL  Subscription channel for the GitOps operator  (gitops-1.19)
#  GITOPS_CSV  pinned CSV, same as the hub  (openshift-gitops-operator.v1.19.2)
#  APPLY  true to apply on the tenant (default false = preview only)

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/site.sh"
OC="${OC:-oc --kubeconfig=${TENANT_KUBECONFIG}}"
HUB_OC="${HUB_OC:-oc --kubeconfig=${HUB_KUBECONFIG}}"
ARGO_NS="${ARGO_NS:-openshift-gitops}"
REPO_SECRET="${REPO_SECRET:-quay-oci-repo-creds}"
TLS_CM="${TLS_CM:-argocd-tls-certs-cm}"
INSTALL_GITOPS="${INSTALL_GITOPS:-false}"
GITOPS_SOURCE="${GITOPS_SOURCE:-}"
GITOPS_CHANNEL="${GITOPS_CHANNEL:-gitops-1.19}"
GITOPS_CSV="${GITOPS_CSV:-openshift-gitops-operator.v1.19.2}"
GITOPS_OP_NS=openshift-gitops-operator
APPLY="${APPLY:-false}"

msg()  { printf '\033[1;34m[02-gitops]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[02-gitops] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[02-gitops] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cluster-guard.sh"
cluster_guard tenant "${OC}"
cluster_guard hub "${HUB_OC}"

command -v jq >/dev/null 2>&1 || die "'jq' not found in PATH"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
[ -n "${TDX_REGISTRY_AUTH_FILE:-}" ] && [ -r "${TDX_REGISTRY_AUTH_FILE}" ] \
  || die "TDX_REGISTRY_AUTH_FILE (${TDX_REGISTRY_AUTH_FILE:-unset}) is not readable: create it (docs/manual-install-hub.md, TDX registry credentials)"

TMPDIR="$(mktemp -d)"; trap 'rm -rf "${TMPDIR}"' EXIT; umask 077

strip_obj() {
  jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid,
          .metadata.creationTimestamp, .metadata.generation,
          .metadata.ownerReferences, .metadata.managedFields,
          .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
          .status)'
}

# An empty get argocd succeeds when the CRD exists; require an instance.
have_argocd() { [ -n "$(${OC} get argocd -n "${ARGO_NS}" -o name 2>/dev/null)" ]; }
if have_argocd; then
  msg "tenant openshift-gitops present."
else
  warn "tenant has no ArgoCD in ${ARGO_NS}."
  if [ "${INSTALL_GITOPS}" = "true" ] && [ "${APPLY}" = "true" ]; then
    # Catalog names differ between the hub and tenants; take the one that carries the pinned CSV.
    if [ -z "${GITOPS_SOURCE}" ]; then
      GITOPS_SOURCE="$(${OC} get packagemanifests -n openshift-marketplace -o json \
        | jq -r --arg ch "${GITOPS_CHANNEL}" --arg csv "${GITOPS_CSV}" '[.items[]
            | select(.metadata.name == "openshift-gitops-operator")
            | select(any(.status.channels[]; .name == $ch
                and (.currentCSV == $csv or any(.entries[]?; .name == $csv))))
            | .status.catalogSource] | sort | first // empty')"
      [ -n "${GITOPS_SOURCE}" ] || die "no catalog on the tenant offers ${GITOPS_CSV} in channel ${GITOPS_CHANNEL}; mirror it or set GITOPS_SOURCE (${OC} get packagemanifest openshift-gitops-operator -n openshift-marketplace)"
    fi
    msg "subscribing openshift-gitops-operator ${GITOPS_CSV} (source ${GITOPS_SOURCE}, channel ${GITOPS_CHANNEL})"
    ${OC} apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${GITOPS_OP_NS}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator-og
  namespace: ${GITOPS_OP_NS}
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: ${GITOPS_OP_NS}
spec:
  channel: ${GITOPS_CHANNEL}
  installPlanApproval: Manual
  name: openshift-gitops-operator
  source: ${GITOPS_SOURCE}
  sourceNamespace: openshift-marketplace
  startingCSV: ${GITOPS_CSV}
EOF
    msg "approving the InstallPlan for ${GITOPS_CSV} only..."
    IP=""
    for i in $(seq 1 60); do
      IP="$(${OC} get installplan -n "${GITOPS_OP_NS}" -o json \
            | jq -r --arg c "${GITOPS_CSV}" '.items[] | select(.spec.clusterServiceVersionNames | index($c)) | .metadata.name' | head -1)"
      [ -n "${IP}" ] && break
      sleep 5
    done
    [ -n "${IP}" ] || die "no InstallPlan for ${GITOPS_CSV}; check: ${OC} get sub -n ${GITOPS_OP_NS} openshift-gitops-operator -o yaml"
    ${OC} patch installplan "${IP}" -n "${GITOPS_OP_NS}" --type merge -p '{"spec":{"approved":true}}'
    msg "waiting for the ${ARGO_NS} namespace/ArgoCD to appear..."
    for i in $(seq 1 60); do
      have_argocd && { msg "openshift-gitops is up."; break; }
      sleep 5
    done
    have_argocd || die "GitOps did not come up; check the Subscription/CSV."
  else
    die "install the OpenShift GitOps operator first, or re-run with INSTALL_GITOPS=true APPLY=true."
  fi
fi

msg "reading hub ${ARGO_NS}/${REPO_SECRET}"
${HUB_OC} get secret "${REPO_SECRET}" -n "${ARGO_NS}" -o json 2>/dev/null | strip_obj > "${TMPDIR}/hub-secret.json" \
  || die "hub secret ${ARGO_NS}/${REPO_SECRET} not found (set HUB_OC / REPO_SECRET)"
python3 -I "${LIB}/registry-auth.py" repo-creds "${TMPDIR}/hub-secret.json" "${TDX_REGISTRY_AUTH_FILE}" \
  "${CHART_REGISTRY}/${OCI_ORG}" > "${TMPDIR}/repo-secret.json" || die "no TDX credential for ${CHART_REGISTRY}/${OCI_ORG}"
jq -e '.data.url // .stringData.url' "${TMPDIR}/repo-secret.json" >/dev/null 2>&1 \
  || warn "hub repo secret has no 'url' field -- copying it anyway"

HAVE_TLS=false
if ${HUB_OC} get configmap "${TLS_CM}" -n "${ARGO_NS}" >/dev/null 2>&1; then
  ${HUB_OC} get configmap "${TLS_CM}" -n "${ARGO_NS}" -o json | strip_obj > "${TMPDIR}/tls-cm.json"
  if [ "$(jq -r '.data | length' "${TMPDIR}/tls-cm.json")" != "0" ]; then HAVE_TLS=true; fi
fi
msg "repo credential built (hub fields, TDX robot credentials); TLS ConfigMap present with data: ${HAVE_TLS}"

if [ "${APPLY}" != "true" ]; then
  msg "APPLY=false: tenant NOT modified. Would apply into ${ARGO_NS}:"
  msg "    Secret/${REPO_SECRET}$( [ "${HAVE_TLS}" = true ] && echo " + ConfigMap/${TLS_CM}")"
  msg "  Re-run with APPLY=true to install the credential on the tenant."
  exit 0
fi

${OC} apply -n "${ARGO_NS}" -f "${TMPDIR}/repo-secret.json"
msg "applied ${ARGO_NS}/${REPO_SECRET} on the tenant."
if [ "${HAVE_TLS}" = true ]; then
  # Merge trust entries so other tenant registry CAs survive.
  if ${OC} get configmap "${TLS_CM}" -n "${ARGO_NS}" >/dev/null 2>&1; then
    ${OC} get configmap "${TLS_CM}" -n "${ARGO_NS}" -o json | strip_obj > "${TMPDIR}/tls-cur.json"
    jq -s '.[0].data as $h | .[1] | .data = ((.data // {}) + $h)' \
       "${TMPDIR}/tls-cm.json" "${TMPDIR}/tls-cur.json" > "${TMPDIR}/tls-merged.json"
    ${OC} apply -n "${ARGO_NS}" -f "${TMPDIR}/tls-merged.json"
  else
    ${OC} apply -n "${ARGO_NS}" -f "${TMPDIR}/tls-cm.json"
  fi
  msg "merged hub repo-TLS trust into ${ARGO_NS}/${TLS_CM}."
fi

msg "PASS: tenant openshift-gitops can now pull OCI charts from the hub Quay."
msg "Next: 03 and 03b, then deploy-coco-spoke.sh (step 04)"
