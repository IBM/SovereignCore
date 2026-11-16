#!/usr/bin/env bash
# Verify tenant confidential samples attest and obtain KBS resources.
# Prerequisites: oc; site config, deployed tenant samples and hub KBS log access.
# Effects: Default previews; APPLY=true restarts samples and gates on Ready; NO_RESTART=true forces preview.
# Exit: 0 success; 1 missing sample, failed rollout or other error.
# Hub KBS logs are shared across tenants and cannot prove this tenant attested.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  OC  oc targeting the TENANT  (oc --kubeconfig=$TENANT_KUBECONFIG)
#  HUB_OC  oc targeting the HUB  (oc --kubeconfig=$HUB_KUBECONFIG)
#  TRUSTEE_NS  Trustee namespace on the hub  (trustee-operator-system)
#  TRUSTEE_DEPLOY  Trustee deployment name  (trustee-deployment)
#  TAIL  Trustee log lines shown in the preview  (4000)
#  WAIT  seconds each sample rollout may take  (240)
#  APPLY  true to restart the samples and verify (default false = preview)
#  NO_RESTART  force read-only preview (false)

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/site.sh"
OC="${OC:-oc --kubeconfig=${TENANT_KUBECONFIG}}"
HUB_OC="${HUB_OC:-oc --kubeconfig=${HUB_KUBECONFIG}}"
TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"
TRUSTEE_DEPLOY="${TRUSTEE_DEPLOY:-trustee-deployment}"
TAIL="${TAIL:-4000}"
WAIT="${WAIT:-240}"
APPLY="${APPLY:-false}"
[ "${NO_RESTART:-false}" != "true" ] || APPLY=false

msg()  { printf '\033[1;34m[08-attest]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[08-attest] WARN:\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[08-attest]  PASS:\033[0m %s\n' "$*" >&2; }
bad()  { printf '\033[1;31m[08-attest]  FAIL:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[08-attest] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cluster-guard.sh"
cluster_guard tenant "${OC}"
cluster_guard hub "${HUB_OC}"

SAMPLES="hello-openshift/secure hello-openshift/insecure-policy kbs-access/kbs-access-curl"

FAILED=0
PRESENT=()
for nd in ${SAMPLES}; do
  if ${OC} get deploy "${nd##*/}" -n "${nd%%/*}" >/dev/null 2>&1; then PRESENT+=("${nd}")
  else bad "sample deploy/${nd##*/} missing in ${nd%%/*} (spoke sample apps not synced?)"; FAILED=1; fi
done

SINCE="$(date -u -d '5 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "${APPLY}" = "true" ]; then
  for nd in ${PRESENT[@]+"${PRESENT[@]}"}; do
    ${OC} rollout restart "deploy/${nd##*/}" -n "${nd%%/*}" >/dev/null \
      || { bad "rollout restart of ${nd} failed"; FAILED=1; }
  done
  msg "waiting up to ${WAIT}s per sample for the restarted pods to become Ready"
  for nd in ${PRESENT[@]+"${PRESENT[@]}"}; do
    if ${OC} rollout status "deploy/${nd##*/}" -n "${nd%%/*}" --timeout="${WAIT}s" >/dev/null 2>&1; then
      ok "${nd}: restarted pods Ready (guest attested and got its resources)"
    else
      bad "${nd}: restarted pods not Ready within ${WAIT}s"; FAILED=1
    fi
  done
  LOG="$(${HUB_OC} logs -n "${TRUSTEE_NS}" "deploy/${TRUSTEE_DEPLOY}" --since-time="${SINCE}" 2>/dev/null || true)"
  WINDOW="since ${SINCE}"
else
  for nd in ${PRESENT[@]+"${PRESENT[@]}"}; do
    msg "would restart ${nd} (now ready $(${OC} get deploy "${nd##*/}" -n "${nd%%/*}" \
      -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo '?'))"
  done
  LOG="$(${HUB_OC} logs -n "${TRUSTEE_NS}" "deploy/${TRUSTEE_DEPLOY}" --tail="${TAIL}" 2>/dev/null || true)"
  WINDOW="last ${TAIL} lines"
fi

# Use a here-string to avoid SIGPIPE under pipefail; -a accepts ANSI log bytes.
cnt() { grep -acE "$1" <<<"${LOG}" || true; }
if [ -z "${LOG}" ]; then
  warn "could not read the Trustee log on the hub (HUB_OC / TRUSTEE_NS / TRUSTEE_DEPLOY); no context"
else
  msg "hub Trustee log context (all guests, ${WINDOW}):" \
      "attest 200: $(cnt '"POST /kbs/v0/attest[^"]*" 200'), resource 200: $(cnt '"GET /kbs/v0/resource/[^"]*" 200')," \
      "PolicyDeny: $(cnt 'PolicyDeny'), UpToDate: $(cnt 'tcb_status.*UpToDate')"
fi

msg "sample pod status (tenant):"
${OC} get pods -n hello-openshift 2>/dev/null | sed 's/^/    /' >&2 || true
${OC} get pods -n kbs-access 2>/dev/null | sed 's/^/    /' >&2 || true

if [ "${FAILED}" -ne 0 ]; then
  [ "$(cnt 'PolicyDeny')" = 0 ] || msg "hint: PolicyDeny in the hub log: check step 03 cert bytes (init_data) and step 07 firmware refvals."
  die "attestation verification FAILED (see FAIL lines). See docs/troubleshooting.md."
fi
if [ "${APPLY}" != "true" ]; then
  msg "APPLY=false: preview only, nothing restarted, no new attestation verified. Re-run with APPLY=true."
  exit 0
fi
ok "END-TO-END: tenant guests attest to the central Trustee and run confidentially."
