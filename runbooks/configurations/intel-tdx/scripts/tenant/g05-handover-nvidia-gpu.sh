#!/usr/bin/env bash
# Hand one tenant NVIDIA stack from Sovereign Core policy ownership to CoCo.
# Prerequisites: oc, jq; site config and hub ManagedCluster/ACM policy access.
# Effects: Default shows state; APPLY=true changes placement/labels and waits; ROLLBACK=true reverses the handover.
# Exit: 0 success; nonzero on guard, mutation or policy-removal timeout.
# IBM deploy-plugin re-applies the PlacementRule; rerun this script afterwards.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  HUB_OC  oc targeting the HUB  (oc --kubeconfig=$HUB_KUBECONFIG)
#  CLUSTER  ManagedCluster name  (site TENANT_CLUSTER)
#  APPLY  true to change the hub (default false = show state only)
#  ROLLBACK  with APPLY=true, remove tenant label; drop exclusion only if unused (false)

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/site.sh"
HUB_OC="${HUB_OC:-oc --kubeconfig=${HUB_KUBECONFIG}}"
CLUSTER="${CLUSTER:-${TENANT_CLUSTER}}"
APPLY="${APPLY:-false}"
ROLLBACK="${ROLLBACK:-false}"

NS=openshift-acm-policies
PR=nvidia-gpu-configuration
KEY=coco.io/gpu-cc
POLICIES=(nvidia-gpu-configuration nvidia-gpu-catalogsource)

msg()  { printf '\033[1;34m[g05-handover]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[g05-handover] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cluster-guard.sh"
cluster_guard hub "${HUB_OC}"

${HUB_OC} get managedcluster "${CLUSTER}" >/dev/null 2>&1 || die "ManagedCluster ${CLUSTER} not found on the hub"
${HUB_OC} get placementrule "${PR}" -n "${NS}" >/dev/null 2>&1 || die "PlacementRule ${NS}/${PR} not found"

expr_index() {
  ${HUB_OC} get placementrule "${PR}" -n "${NS}" -o json \
    | jq -r --arg k "${KEY}" '.spec.clusterSelector.matchExpressions // [] | to_entries[] | select(.value.key == $k) | .key'
}
replicated() {
  local p out=""
  for p in "${POLICIES[@]}"; do
    ${HUB_OC} get policies.policy.open-cluster-management.io "${NS}.${p}" -n "${CLUSTER}" >/dev/null 2>&1 && out+="${p} "
  done
  printf '%s' "${out}"
}

IDX="$(expr_index)"
LBL="$(${HUB_OC} get managedcluster "${CLUSTER}" -o jsonpath="{.metadata.labels.coco\.io/gpu-cc}")"
msg "PlacementRule exclusion: ${IDX:+present (index ${IDX})}${IDX:-absent}; ${CLUSTER} ${KEY}=${LBL:-<unset>}"
msg "NVIDIA policies replicated to ${CLUSTER}: $(replicated || true)"

if [ "${APPLY}" != "true" ]; then
  msg "APPLY=false: hub NOT modified. Re-run with APPLY=true (ROLLBACK=true to undo)."
  exit 0
fi

if [ "${ROLLBACK}" = "true" ]; then
  # Keep the shared exclusion while any other CC-GPU tenant is labelled.
  ${HUB_OC} label managedcluster "${CLUSTER}" "${KEY}-" >/dev/null
  msg "rolled back: Sovereign Core will re-enforce its NVIDIA policies on ${CLUSTER} (host driver, CC off)."
  others="$(${HUB_OC} get managedcluster -l "${KEY}=true" -o name | sed 's|.*/||' | grep -vxF "${CLUSTER}" | tr '\n' ' ' || true)"
  if [ -n "${others}" ]; then
    msg "PlacementRule exclusion KEPT: still used by ${others}"
  elif [ -n "${IDX}" ]; then
    ${HUB_OC} patch placementrule "${PR}" -n "${NS}" --type=json \
      -p "[{\"op\":\"remove\",\"path\":\"/spec/clusterSelector/matchExpressions/${IDX}\"}]" >/dev/null
    msg "PlacementRule exclusion removed: no other ManagedCluster has ${KEY}=true."
  fi
  exit 0
fi

[ -n "${IDX}" ] || ${HUB_OC} patch placementrule "${PR}" -n "${NS}" --type=json \
  -p "[{\"op\":\"add\",\"path\":\"/spec/clusterSelector/matchExpressions/-\",\"value\":{\"key\":\"${KEY}\",\"operator\":\"NotIn\",\"values\":[\"true\"]}}]" >/dev/null
${HUB_OC} label managedcluster "${CLUSTER}" "${KEY}=true" --overwrite >/dev/null

for _ in $(seq 1 30); do
  left="$(replicated)"
  [ -z "${left}" ] && { msg "handover done: no Sovereign Core NVIDIA policy on ${CLUSTER}."; exit 0; }
  sleep 10
done
die "still replicated to ${CLUSTER} after 5 min: ${left}"
