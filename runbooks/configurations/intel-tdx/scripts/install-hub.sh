#!/usr/bin/env bash
# Install the hub end to end: manual hub steps 2 and 4-12, one resumable step per step script.
# Prerequisites: everything in docs/install.md "Before you start" plus site config (step 1) and a hub
#   kubeconfig with trusted TLS (step 3). Inputs only you can supply stop the run with instructions.
# Usage: APPLY=true install-hub.sh [--resume | --from <step> | --only <step> | --restart]; without APPLY it prints the plan.
# Effects: runs the steps in order; disruptive steps are marked in the plan (control-plane reboot,
#   node reboots, Trustee/QGS/sample/Vault restarts). --resume continues at the failed or paused step.
# Exit: 0 all steps done; 3 paused for outside input (then --resume); 1 failure; 2 bad options.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required)
#  APPLY  true to run (false: plan only)
#  STATE  finished-step file  (~/.coco-pattern/install-hub.done)
#  INTEL_PCS_API_KEY  Intel PCS API key for the PCK certificates (else ~/.coco-pattern/pccs_api_key)
#  VAULT_TDX  false: never label namespace vault, Vault stays on the default runtime (true)
#  VAULT_SETTLE, VAULT_WAIT  seconds after deleting a Vault pod, minutes per Vault health wait (20, 15)
#  SKIP_MIRROR, OFFLINE, UPSTREAM_CACHE, MCP_TIMEOUT, APP_TIMEOUT  passed to the step scripts / waits

set -euo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${S}/lib/site.sh"
# The mirror tools (oc-mirror, mirror-registry) as a fallback: the caller's PATH wins.
PATH="${PATH}:${MIRROR_HOME}/bin"
INSTALL_TAG=install-hub
STATE="${STATE:-${HOME}/.coco-pattern/install-hub.done}"
STATE_ID="hub=${EXPECT_HUB_API_SERVER} site=${SITE_ENV}"
CP="${HOME}/.coco-pattern"
HUB_OC="${HUB_OC:-oc --kubeconfig=${HUB_KUBECONFIG}}"
. "${S}/lib/install.sh"
. "${S}/lib/cluster-guard.sh"
cluster_guard hub "${HUB_OC}"
for t in oc helm yq jq python3 openssl veritas cosign; do command -v "$t" >/dev/null || die "$t not found"; done

STAGES=(
  "build|build the charts (2)|"
  "mirror|mirror operators and images, apply mirror sets (4)|control-plane rolling reboot"
  "mirror-wait|wait for the MachineConfigPools (4)|"
  "pcs-key|check the Intel PCS API key (5a)|"
  "registry-auth|check the TDX registry credential (5b)|"
  "fw-refvals|collect firmware reference values (5c)|"
  "registry-config|collect guest image-pull configuration (5d)|"
  "dcap-tools|fetch Intel PcsClientTool (5e)|"
  "collateral|collect TDX verification collateral from Intel PCS (5e)|"
  "vault|load the hub Vault (6)|"
  "publish|publish the charts (7)|"
  "deploy|deploy the hub (8)|node reboots"
  "deploy-wait|wait for kata-cc, TDX nodes, platform registration and ArgoCD sync (8)|"
  "refvals-check|firmware refvals reached RVPS (9)|"
  "trustee-restart|restart Trustee (9)|attestation gap"
  "pck|PCK certificates for every hub platform (10)|QGS restart"
  "accept|restart and accept the samples (11)|sample restarts"
  "vault-tdx|move Vault server pods into TDX (12)|Vault pods, one at a time"
)

stage_build()       { "${S}/build-upstream.sh"; }
stage_mirror()      { APPLY=true "${S}/mirror-coco-pattern.sh"; }
stage_mirror_wait() { wait_mcp "${HUB_OC}"; }

stage_pcs_key() {
  umask 077; mkdir -p "${CP}"
  [ -n "${INTEL_PCS_API_KEY:-}" ] || [ -s "${CP}/pccs_api_key" ] \
    || pause "write your Intel PCS API key to ${CP}/pccs_api_key (mode 0600; docs/install.md#intel-pcs-api-key)"
}
stage_registry_auth() {
  [ -s "${TDX_REGISTRY_AUTH_FILE:-}" ] \
    || { pause "create the read-only TDX registry credential at TDX_REGISTRY_AUTH_FILE (docs/install.md#tdx-registry-credentials)"; return; }
  python3 "${S}/lib/registry-auth.py" check "${TDX_REGISTRY_AUTH_FILE}"
  # The example guests (samples, Vault in TDX, confidential LLM, CUGA agent) pull from these orgs.
  local miss host cmds=""
  miss="$(python3 "${S}/lib/registry-auth.py" lacks "${TDX_REGISTRY_AUTH_FILE}" \
    "${CHART_REGISTRY}"/{sovcloud,aiiaas-models,rhaiis} "${MIRROR_REGISTRY}"/{ubi9,hashicorp})"
  [ -n "${miss}" ] || return 0
  for host in $(cut -d/ -f1 <<<"${miss}" | sort -u); do
    cmds+="
  QUAY_HOST=${host} ORGS=\"$(awk -F/ -v h="${host}" '$1 == h {printf "%s%s", s, $2; s=" "}' <<<"${miss}")\" QUAY_TOKEN_FILE=<org:admin token for ${host}> APPLY=true ./scripts/create-tdx-registry-credentials.sh"
  done
  pause "the TDX registry credential lacks orgs the example guests pull from (docs/install.md#tdx-registry-credentials):${cmds}"
}
# Collect into a new file and merge, so a rerun keeps tenant values merged by install-tenant.sh.
stage_fw_refvals() {
  local fw="${CP}/firmware-reference-values.json" new="${CP}/firmware-reference-values.hub-new.json"
  KUBECONFIG="${HUB_KUBECONFIG}" python3 "${S}/../build/pattern/scripts/collect_firmware_refvals.py" --platform baremetal -t tdx \
    -p "${MIRROR_HOME}/config/pull-secret.json" --values-file "${VALUES_CG:-${S}/../deploy/hub/values-baremetal.yaml}" -o "${new}"
  if [ -s "${fw}" ]; then merge_refvals "${fw}" "${new}" > "${fw}.tmp"; else cp "${new}" "${fw}.tmp"; fi
  mv "${fw}.tmp" "${fw}"; rm -f "${new}"
}
stage_registry_config() { "${S}/collect-registry-config.sh"; }
stage_dcap_tools()      { python3 "${DCAP}/dcap-pck.py" tools; }
# No API key: TCB info, QE identity and CRLs for every TDX platform come from Intel's public endpoints.
stage_collateral()      { "${DCAP}/collect-dcap-collateral.sh" --pcsclient-dir "${DCAP_PCSCLIENT_DIR}"; }
stage_vault()           { APPLY=true "${S}/load-existing-vault.sh"; }
stage_publish()         { SKIP_BUILD=true "${S}/publish-coco-charts.sh"; }
stage_deploy()          { APPLY=true "${S}/deploy-coco-hub.sh"; }
stage_deploy_wait() {
  wait_tdx_runtime "${HUB_OC}" \
    && wait_apps "${HUB_OC}" "${APP_NAME:-coco-pattern-hub}" "${VALUES_CG:-${S}/../deploy/hub/values-baremetal.yaml}"
}

stage_refvals_check() {
  wait_for "ExternalSecret firmware-refvals-eso" 15 \
    ${HUB_OC} wait externalsecret/firmware-refvals-eso -n trustee-operator-system --for=condition=Ready --timeout=30s
  wait_for "firmware refvals in RVPS" 15 rvps_has_fw "${HUB_OC}"
}
stage_trustee_restart() { trustee_restart "${HUB_OC}"; }

stage_pck() { pck_provision "${HUB_KUBECONFIG}" "${CP}/dcap-pck/hub"; }

# The hub runs the same CPU samples as a tenant, so tenant step 08's checks apply with the hub as target.
stage_accept() {
  EXPECT_TENANT_API_SERVER="${EXPECT_HUB_API_SERVER}" OC="${HUB_OC}" APPLY=true \
    "${S}/tenant/08-verify-attestation.sh"
}

VAULT_SEL=app.kubernetes.io/name=vault,component=server
_vault_ready_tdx() {
  [ "$(${HUB_OC} get pod "$1" -n vault -o jsonpath='{.spec.runtimeClassName} {.status.containerStatuses[0].ready} {.metadata.labels.vault-sealed}')" \
    = "kata-cc true false" ]
}
# Every StatefulSet replica Ready, unsealed and not terminating: deleting one then keeps raft quorum.
_vault_quorum_ok() {
  local want; want="$(${HUB_OC} get sts vault -n vault -o jsonpath='{.spec.replicas}')"
  [ -n "${want}" ] && [ "$(${HUB_OC} get pod -n vault -l "${VAULT_SEL}" -o json | jq '[.items[]
      | select(.metadata.deletionTimestamp == null and .metadata.labels["vault-sealed"] == "false"
               and (.status.containerStatuses[0].ready // false))] | length')" = "${want}" ]
}
stage_vault_tdx() {
  [ "${VAULT_TDX:-true}" = true ] || { warn "VAULT_TDX=false: namespace vault not labelled; Vault stays on the default runtime"; return 0; }
  local p
  ${HUB_OC} get cm initdata -n vault >/dev/null || die "no ConfigMap vault/initdata yet (Kyverno propagation)"
  # The Kyverno rule only applies in a namespace with this label; removing it is the way back.
  ${HUB_OC} label namespace vault coco.io/confidential-workloads=enabled --overwrite
  while :; do
    wait_for "Vault quorum: every replica Ready and unsealed" "${VAULT_WAIT:-15}" _vault_quorum_ok \
      || die "Vault is not fully healthy; not restarting any Vault pod (docs/troubleshooting.md#vault-pod-does-not-start-in-tdx)"
    # Next pod outside TDX: standbys first, the active pod last; re-read every round.
    p="$(${HUB_OC} get pod -n vault -l "${VAULT_SEL}" -o json | jq -r '[.items[] | select(.spec.runtimeClassName != "kata-cc")]
      | sort_by(.metadata.labels["vault-active"] == "true") | .[0].metadata.name // ""')"
    [ -n "${p}" ] || { msg "all Vault server pods run in TDX"; return 0; }
    msg "restarting ${p}"
    ${HUB_OC} delete pod "${p}" -n vault --wait=false
    sleep "${VAULT_SETTLE:-20}"
    wait_for "${p} Ready, unsealed, kata-cc" "${VAULT_WAIT:-15}" _vault_ready_tdx "${p}" \
      || die "${p} did not come back in TDX; see docs/troubleshooting.md#vault-pod-does-not-start-in-tdx before touching other Vault pods"
  done
}

run_stages "$@"
