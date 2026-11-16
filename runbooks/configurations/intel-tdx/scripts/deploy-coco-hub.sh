#!/usr/bin/env bash
# Render the hub AppProject and root OCI ArgoCD Application.
# Prerequisites: oc, yq; published charts, mirrored catalogs/images, GitOps OCI credentials and TLS trust.
# Effects: Default prints manifests; APPLY=true applies them; RETIRE_PATTERN=true also deletes the Pattern CR.
# Exit: 0 success; nonzero on configuration, cluster guard or apply failure.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site name or config path (required)
#  QUAY_HOST  in-cluster Quay host  (site CHART_REGISTRY)
#  CLUSTER_DOMAIN  global.clusterDomain; localClusterDomain = apps.<it> (site HUB_DOMAIN)
#  EXTRA_PARAMS  more "global.key=value" root parameters, space-separated (unset)
#  OCI_ORG  repo path prefix under the registry  (sovcloud/coco)
#  CLUSTERGROUP_VER  clustergroup chart version  (upstream/lock)
#  ARGO_NS  hub ArgoCD namespace (global.vpArgoNamespace)  (openshift-gitops)
#  APP_NAME  root Application name  (coco-pattern-hub)
#  APP_PROJECT  AppProject for the root app  (coco-pattern)
#  VALUES_GLOBAL  global values file  (abs or REPO_DIR-relative) (deploy/hub/values-global.yaml)
#  VALUES_CG  clusterGroup values file (abs or rel)  (deploy/hub/values-baremetal.yaml)
#  REPO_DIR  pattern repo checkout  (auto: this script's repo root)
#  OC  hub client  (site MIRROR_HOME/bin/oc --kubeconfig=<site HUB_KUBECONFIG>)
#  TARGET_CLUSTER  cluster guard target, hub or tenant (hub)
#  APPLY  apply (default false = print manifest only)
#  RETIRE_PATTERN  delete the failing `coco-pattern` Pattern CR  (false)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
. "${SCRIPT_DIR}/lib/site.sh"

QUAY_HOST="${QUAY_HOST:-${CHART_REGISTRY}}"
OCI_ORG="${OCI_ORG:-sovcloud/coco}"
CLUSTERGROUP_VER="${CLUSTERGROUP_VER:-$(awk '$1 == "clustergroup" { print $4 }' "${REPO_DIR}/upstream/lock")}"

ARGO_NS="${ARGO_NS:-openshift-gitops}"
APP_NAME="${APP_NAME:-coco-pattern-hub}"
APP_PROJECT="${APP_PROJECT:-coco-pattern}"

OC="${OC:-${MIRROR_HOME}/bin/oc --kubeconfig=${HUB_KUBECONFIG}}"
APPLY="${APPLY:-false}"
RETIRE_PATTERN="${RETIRE_PATTERN:-false}"

REPO_URL="${QUAY_HOST}/${OCI_ORG}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-${HUB_DOMAIN}}"
# hubClusterDomain always names the hub because it determines guests' KBS URL.
PARAMS="global.repoURL=${REPO_URL} global.originURL=${REPO_URL} global.multiSourceRepoUrl=${REPO_URL}
global.hubClusterDomain=apps.${HUB_DOMAIN} global.clusterDomain=${CLUSTER_DOMAIN}
global.localClusterDomain=apps.${CLUSTER_DOMAIN} ${EXTRA_PARAMS:-}"
VALUES_GLOBAL="${VALUES_GLOBAL:-${REPO_DIR}/deploy/hub/values-global.yaml}"
VALUES_CG="${VALUES_CG:-${REPO_DIR}/deploy/hub/values-baremetal.yaml}"
case "${VALUES_GLOBAL}" in /*) ;; *) VALUES_GLOBAL="${REPO_DIR}/${VALUES_GLOBAL}" ;; esac
case "${VALUES_CG}" in /*) ;; *) VALUES_CG="${REPO_DIR}/${VALUES_CG}" ;; esac

msg()  { printf '\033[1;34m[deploy-hub]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[deploy-hub] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
. "$(dirname "${BASH_SOURCE[0]}")/lib/cluster-guard.sh"

[ -f "${VALUES_GLOBAL}" ] || die "missing ${VALUES_GLOBAL}"
[ -f "${VALUES_CG}" ]     || die "missing ${VALUES_CG}"

indent() { sed 's/^/        /' "$1"; }
params() {
  local kv
  for kv in ${PARAMS}; do
    printf '      - name: %s\n        value: "%s"\n        forceString: true\n' "${kv%%=*}" "${kv#*=}"
  done
}

render() {
  cat <<EOF
---
# AppProject governing the root Application. Full permissions because the
# clustergroup chart creates cluster-scoped resources (Namespaces, CatalogSources,
# Subscriptions, ClusterRoleBindings, the per-pattern AppProjects) and child
# Applications across many namespaces.
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: ${APP_PROJECT}
  namespace: ${ARGO_NS}
spec:
  description: "CoCo pattern (OCI / git-less) root project"
  sourceRepos:
  - '*'
  destinations:
  - namespace: '*'
    server: '*'
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
  namespaceResourceWhitelist:
  - group: '*'
    kind: '*'
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: ${ARGO_NS}
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: ${APP_PROJECT}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${ARGO_NS}
  source:
    repoURL: ${REPO_URL}
    chart: clustergroup
    targetRevision: ${CLUSTERGROUP_VER}
    helm:
      # Site values (deploy/env/<site>/site.env); they override the inline values.
      parameters:
$(params)
      # Concatenation of VALUES_GLOBAL + VALUES_CG. Top-level
      # keys do not collide (global/main/secretStore vs clusterGroup). Kept in
      # sync automatically -- this manifest is generated from the repo files.
      values: |
$(indent "${VALUES_GLOBAL}")
$(indent "${VALUES_CG}")
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    retry:
      limit: 20
    syncOptions:
    - ServerSideApply=true
    - CreateNamespace=true
EOF
}

retire_pattern() {
  if [ "${RETIRE_PATTERN}" != "true" ]; then
    msg "Leaving the 'coco-pattern' Pattern CR in place (RETIRE_PATTERN=true to delete it)."
    msg "  NOTE: while it exists the patterns-operator keeps retrying its failing github clone;"
    msg "        that loop is harmless but noisy. Deleting it also removes the operator-created"
    msg "        clustergroup Application that tracks git. Our OCI root app is independent."
    return
  fi
  # Leave OC unquoted to split a multi-word client into command and arguments.
  if ${OC} get pattern coco-pattern -n openshift-operators >/dev/null 2>&1; then
    msg "Deleting the failing 'coco-pattern' Pattern CR (git bootstrap is bypassed)."
    # The Pattern webhook requires the pruning annotation before deletion.
    ${OC} annotate pattern coco-pattern -n openshift-operators \
      patterns.gitops.hybrid-cloud-patterns.io/prune="true" --overwrite >/dev/null
    ${OC} delete pattern coco-pattern -n openshift-operators --wait=false
  else
    msg "No 'coco-pattern' Pattern CR present; nothing to retire."
  fi
}

main() {
  msg "repo:      ${REPO_DIR}"
  msg "site:      ${SITE_ENV}"
  msg "chart:     ${REPO_URL}/clustergroup:${CLUSTERGROUP_VER}  (OCI)"
  msg "root app:  ${ARGO_NS}/${APP_NAME}  (project ${APP_PROJECT})"
  msg "mode:      APPLY=${APPLY}  RETIRE_PATTERN=${RETIRE_PATTERN}"

  if [ "${APPLY}" != "true" ]; then
    msg "APPLY=false: printing manifest only (review, then re-run with APPLY=true)."
    render
    return
  fi

  cluster_guard "${TARGET_CLUSTER:-hub}" "${OC}"
  # Sovereign Core provides these hub operators; the hub profile does not install them (ACM delivers the
  # pattern to tenants, Trustee issues its certificates through cert-manager). deploy-coco-spoke.sh reuses
  # this script with TARGET_CLUSTER=tenant, where neither is needed.
  local ns_pkg ns pkg
  [ "${TARGET_CLUSTER:-hub}" != hub ] || for ns_pkg in open-cluster-management/advanced-cluster-management cert-manager-operator/cert-manager-operator; do
    ns="${ns_pkg%/*}"; pkg="${ns_pkg#*/}"
    grep -q "/${pkg}\." <<<"$(${OC} get csv -n "${ns}" -o name 2>/dev/null)" \
      || die "no ${pkg} operator in namespace ${ns}: install Sovereign Core's platform operators first"
  done
  retire_pattern
  render | ${OC} apply -f -
  msg "Applied. Watch rollout:"
  msg "  ${OC} get application ${APP_NAME} -n ${ARGO_NS}"
  msg "  ${OC} get applications.argoproj.io -n ${ARGO_NS} -l validatedpatterns.io/pattern=coco-pattern"
}

main "$@"
