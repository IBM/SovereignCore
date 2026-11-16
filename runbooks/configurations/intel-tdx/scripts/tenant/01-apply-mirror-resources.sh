#!/usr/bin/env bash
# Apply coco-prefixed mirror mappings and CatalogSources to the tenant.
# Prerequisites: oc, yq; site config and generated hub oc-mirror cluster resources.
# Effects: Default lists resources; APPLY=true applies them and waits for packages; IDMS/ITMS reboot the SNO.
# Exit: 0 success; nonzero on missing resources, guard, apply or package wait failure.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  OC  oc targeting the TENANT  (oc --kubeconfig=$TENANT_KUBECONFIG)
#  MIRROR_HOME  SovereignCore mirror root  (site MIRROR_HOME)
#  WORKDIR  oc-mirror workspace  ($MIRROR_HOME/config/coco-pattern-workspace)
#  CR_DIR  generated cluster-resources dir  ($WORKDIR/working-dir/cluster-resources)
#  WANT  packagemanifests to wait for (sandboxed-containers-operator nfd intel-device-plugins-operator intel-tdx-dcap-operator)
#  APPLY  true to apply (default false = list the resources only)

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/site.sh"
OC="${OC:-oc --kubeconfig=${TENANT_KUBECONFIG}}"
WORKDIR="${WORKDIR:-${MIRROR_HOME}/config/coco-pattern-workspace}"
CR_DIR="${CR_DIR:-${WORKDIR}/working-dir/cluster-resources}"
WANT="${WANT:-sandboxed-containers-operator nfd intel-device-plugins-operator intel-tdx-dcap-operator}"
APPLY="${APPLY:-false}"

msg()  { printf '\033[1;34m[01-mirror-res]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[01-mirror-res] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[01-mirror-res] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cluster-guard.sh"
cluster_guard tenant "${OC}"

[ -d "${CR_DIR}" ] || die "no cluster-resources at ${CR_DIR}. Run scripts/mirror-coco-pattern.sh first (it generates them), or set CR_DIR."

msg "cluster-resources to apply (from ${CR_DIR}):"
ls -1 "${CR_DIR}" | grep -E '^(cs-|idms-|itms-)' | sed 's/^/    /' >&2 || true

if [ "${APPLY}" != "true" ]; then
  msg "APPLY=false: tenant NOT modified."
  msg "  Re-run with APPLY=true to apply (IDMS/ITMS apply reboots the tenant SNO)."
  exit 0
fi

warn "Applying IDMS/ITMS triggers a reboot of the tenant SNO (full API outage)."

apply_renamed_mirrorset() {
  local f="$1"
  sed -E 's/^([[:space:]]{2}name:[[:space:]]*)((idms|itms)-)/\1coco-\2/' "${f}" | ${OC} apply -f -
}

shopt -s nullglob
for f in "${CR_DIR}"/idms-*.yaml "${CR_DIR}"/itms-*.yaml; do
  msg "oc apply (renamed to coco-*) -f $(basename "${f}")"
  apply_renamed_mirrorset "${f}"
done
for f in "${CR_DIR}"/cs-*.yaml; do
  msg "oc apply -f $(basename "${f}")"
  ${OC} apply -f "${f}"
  # The index tag moves on each mirror run but the spec does not change: recreate the pod to re-pull it.
  ${OC} delete pod -n openshift-marketplace -l "olm.catalogSource=$(basename "${f}" .yaml)" --ignore-not-found
done
shopt -u nullglob

# oc-mirror can write a tag mirror for a deeper source (nvcr.io/nvidia/cloud-native) than its digest
# mirror (nvcr.io/nvidia). registries.conf uses the most specific source, so digest pulls under it would
# skip the mirror and go to the internet. Give every tag-only source a digest mirror as well.
IDMS_F="$(ls "${CR_DIR}"/idms-*.yaml 2>/dev/null | head -1)"
ITMS_F="$(ls "${CR_DIR}"/itms-*.yaml 2>/dev/null | head -1)"
if [ -n "${ITMS_F}" ]; then
  extra="$(yq ea '([select(fileIndex == 0) | .spec.imageDigestMirrors[]?.source]) as $have
    | select(fileIndex == 1) | [.spec.imageTagMirrors[] | select(.source as $s | $have | contains([$s]) | not)]' \
    "${IDMS_F:-/dev/null}" "${ITMS_F}" -o=json -I=0)"
  if [ "${extra}" != "[]" ]; then
    msg "oc apply ImageDigestMirrorSet coco-idms-tag-sources ($(jq -r 'map(.source) | join(" ")' <<<"${extra}"))"
    jq -n --argjson m "${extra}" '{apiVersion: "config.openshift.io/v1", kind: "ImageDigestMirrorSet",
      metadata: {name: "coco-idms-tag-sources"}, spec: {imageDigestMirrors: $m}}' | ${OC} apply -f -
  fi
fi

msg "Applied. Waiting for the tenant's packagemanifests to resolve..."
for i in $(seq 1 30); do
  missing=""
  for p in ${WANT}; do
    ${OC} get packagemanifest "${p}" -n openshift-marketplace >/dev/null 2>&1 || missing="${missing} ${p}"
  done
  if [ -z "${missing}" ]; then
    msg "PASS: all expected packagemanifests available:${WANT}"
    msg "Next: 02-ensure-gitops-repo-creds.sh"
    exit 0
  fi
  sleep 10
done
warn "Still missing:${missing}"
warn "Check the new CatalogSource pods: ${OC} get pods -n openshift-marketplace"
exit 1
