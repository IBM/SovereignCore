#!/usr/bin/env bash
# Report chart, object-manager and measured-initdata drift on hub and/or tenant.
# Prerequisites: oc, yq, jq; site config and authenticated kubeconfigs.
# Effects: Read-only; prints suggested commands without running them.
# Exit: 0 no drift; 2 drift; 1 error.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  TARGETS  clusters to check  ("hub tenant")
#  HUB_OC  hub client  (oc --kubeconfig=$HUB_KUBECONFIG)
#  TENANT_OC  tenant client  (oc --kubeconfig=$TENANT_KUBECONFIG)
#  ARGO_NS  namespace of the Applications  (openshift-gitops)
#  PINS  pin file  (<repo>/deploy/versions.yaml)
#  FIELDS  check field managers (one get per object)  (true)
#  MANAGER_RE  hand-edit managers (ERE)  (^(kubectl|oc)(-|$)|^Mozilla)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${REPO_DIR}/scripts/lib/site.sh"
TARGETS="${TARGETS:-hub tenant}"
HUB_OC="${HUB_OC:-oc --kubeconfig=${HUB_KUBECONFIG:-}}"
TENANT_OC="${TENANT_OC:-oc --kubeconfig=${TENANT_KUBECONFIG:-}}"
ARGO_NS="${ARGO_NS:-openshift-gitops}"
PINS="${PINS:-${REPO_DIR}/deploy/versions.yaml}"
FIELDS="${FIELDS:-true}"
MANAGER_RE="${MANAGER_RE:-^(kubectl|oc)(-|$)|^Mozilla}"

msg()   { printf '\033[1;34m[drift]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[drift] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
DRIFT=0
drift() { printf 'DRIFT  [%s] %s\n' "$1" "$2"; DRIFT=1; }
fix()   { printf '  fix  (%s) %s\n' "$1" "$2"; }
. "${REPO_DIR}/scripts/lib/cluster-guard.sh"
command -v jq >/dev/null || die "jq is required"
command -v yq >/dev/null || die "yq is required"

kget() { local cli="$1"; shift; ${cli} get "$@"; }

pins_json="$(yq -o=json '.' "${PINS}")"
declare -A INITDATA

check_cluster() {
  local role="$1" cli="$2" apps
  cluster_guard "${role}" "${cli}"
  apps="$(kget "${cli}" -n "${ARGO_NS}" applications.argoproj.io -o json)" \
    || die "[${role}] cannot list Applications in ${ARGO_NS}"
  local name chart rev pin sync health
  while IFS=$'\t' read -r name chart rev pin sync health; do
    printf 'app    [%s] %-28s %-26s %-16s pin %-16s %s/%s\n' "${role}" "${name}" "${chart}" "${rev}" "${pin}" "${sync}" "${health}"
    [ "${rev}" = "${pin}" ] || { drift "${role}" "${name}: chart ${chart} ${rev} live, ${pin} in deploy/versions.yaml"
      fix manual "re-deploy the profile (scripts/deploy-coco-${role/tenant/spoke}.sh) after the version procedure in docs/operations-runbook.md"; }
    if [ "${health}" = Degraded ] || [ "${health}" = Missing ]; then
      drift "${role}" "${name}: health ${health}"
      jq -r --arg a "${name}" '.items[] | select(.metadata.name == $a) | .status.resources[]?
        | select(.health.status == "Degraded" or .health.status == "Missing")
        | "         \(.health.status): \(.kind) \(.namespace // "-")/\(.name) \(.health.message // "")"' <<<"${apps}"
    fi
    if [ "${sync}" != Synced ]; then
      drift "${role}" "${name}: sync ${sync}"
      local out unsafe
      out="$(jq -r --arg a "${name}" '.items[] | select(.metadata.name == $a) | .status.resources[]?
        | select(.status == "OutOfSync") | "\(.kind) \(.namespace // "-")/\(.name)"' <<<"${apps}")"
      [ -z "${out}" ] || sed 's/^/         OutOfSync: /' <<<"${out}"
      fix safe "${cli} -n ${ARGO_NS} annotate application.argoproj.io/${name} argocd.argoproj.io/refresh=hard --overwrite   # re-compare only"
      unsafe="$(grep -E '^(MachineConfig|KubeletConfig|KataConfig) ' <<<"${out}" || true)"
      if [ "${chart}" = coco-initdata ]; then
        fix manual "coco-initdata changes the measured init_data: follow the coupled hub/tenant procedure in docs/operations-runbook.md"
      elif [ -n "${unsafe}" ]; then
        fix manual "the diff includes $(cut -d' ' -f1 <<<"${unsafe}" | sort -u | tr '\n' ' ')(node reboot): sync in a maintenance window"
      else
        fix safe "${cli} -n ${ARGO_NS} patch application.argoproj.io ${name} --type merge -p '{\"operation\":{\"initiatedBy\":{\"username\":\"report-drift\"},\"sync\":{}}}'   # review the diff first"
      fi
    fi
    [ "${FIELDS}" = true ] && check_fields "${role}" "${cli}" "${name}" "${apps}"
  done < <(jq -r --argjson pins "${pins_json}" '.items[] | select(.spec.source.chart as $c | $pins | has($c // ""))
      | [.metadata.name, .spec.source.chart, (.spec.source.targetRevision // "-"), $pins[.spec.source.chart],
         (.status.sync.status // "Unknown"), (.status.health.status // "Unknown")] | @tsv' <<<"${apps}")

  local cm h raw
  for cm in initdata debug-initdata; do
    if ! raw="$(kget "${cli}" -n imperative configmap "${cm}" -o jsonpath='{.data.INITDATA}' 2>/dev/null)" || [ -z "${raw}" ]; then
      h=missing
      drift "${role}" "ConfigMap imperative/${cm} missing, unreadable or without INITDATA"
      fix manual "check the coco-initdata app and its gzipper Job on the ${role}; never hand-edit the ConfigMap"
    elif ! h="$(base64 -d <<<"${raw}" 2>/dev/null | gzip -dc 2>/dev/null | sha256sum | cut -c1-16)" \
         || [ "${h}" = e3b0c44298fc1c14 ]; then
      h=invalid
      drift "${role}" "ConfigMap imperative/${cm}: INITDATA is not base64 gzip (or is empty)"
      fix manual "re-run the coco-initdata gzipper (sync the coco-initdata app on the ${role}); never hand-edit the ConfigMap"
    fi
    INITDATA["${role}/${cm}"]="${h}"
    printf 'hash   [%s] %-15s %s\n' "${role}" "${cm}" "${h}"
  done
}

check_fields() {
  local role="$1" cli="$2" app="$3" kind group ns name ref hits
  while IFS=$'\t' read -r kind group ns name; do
    ref="${kind}${group:+.${group}}/${name}"
    hits="$(kget "${cli}" ${ns:+-n "${ns}"} "${ref}" -o json --show-managed-fields 2>/dev/null \
      | jq -r --arg re "${MANAGER_RE}" '.metadata.managedFields[]? | select((.subresource // "") != "status")
          | select(.manager | test($re)) | "\(.manager) \(.operation) \(.time)"' 2>/dev/null || true)"
    [ -z "${hits}" ] && continue
    drift "${role}" "${app}: ${ref}${ns:+ (ns ${ns})} has fields owned by a hand tool: $(tr '\n' ';' <<<"${hits}")"
    fix safe "${cli} get ${ns:+-n ${ns} }${ref} --show-managed-fields -o yaml   # see what was changed"
    fix manual "revert it by syncing ${app} (ArgoCD re-applies the chart values), or move the change into the chart values"
  done < <(jq -r --arg a "${app}" '.items[] | select(.metadata.name == $a) | .status.resources[]?
      | select(.hook != true) | [.kind, (.group // ""), (.namespace // ""), .name] | @tsv' <<<"$4")
}

for t in ${TARGETS}; do
  case "${t}" in
    hub)    check_cluster hub "${HUB_OC}" ;;
    tenant) check_cluster tenant "${TENANT_OC}" ;;
    *) die "unknown target '${t}' (hub, tenant)" ;;
  esac
done

if [ -n "${INITDATA[hub/initdata]:-}" ] && [ -n "${INITDATA[tenant/initdata]:-}" ]; then
  for cm in initdata debug-initdata; do
    if [ "${INITDATA[hub/${cm}]}" = "${INITDATA[tenant/${cm}]}" ]; then
      printf 'hash   %s hub == tenant\n' "${cm}"
    else
      drift hub+tenant "${cm} differs: hub ${INITDATA[hub/${cm}]}, tenant ${INITDATA[tenant/${cm}]} (guests get PolicyDenied)"
      fix manual "pin coco-initdata to the same version on the hub and the tenant (docs/operations-runbook.md); never hand-edit the ConfigMap"
    fi
  done
fi

if [ "${DRIFT}" = 0 ]; then msg "no drift"; exit 0; fi
msg "drift found (commands above are printed only; nothing was changed)"
exit 2
