#!/usr/bin/env bash
# Onboard one tenant end to end: manual tenant steps 00-08 (plus the GPU steps with PROFILE=gpu),
#   one resumable step per step script.
# Prerequisites: the hub is installed (scripts/install-hub.sh) and docs/install.md "Before you start" holds.
#   Inputs only you can supply (GPU RIM values) stop the run with instructions.
# Usage: APPLY=true install-tenant.sh [--resume | --from <step> | --only <step> | --restart]; without APPLY it prints the plan.
# Effects: runs the steps in order; disruptive steps are marked in the plan (tenant reboots, QGS and hub Trustee
#   restarts, sample and LLM restarts). --resume continues at the failed or paused step.
# Exit: 0 all steps done; 3 paused for outside input (then --resume); 1 failure; 2 bad options.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; TENANT_KUBECONFIG, TENANT_CLUSTER, EXPECT_TENANT_API_SERVER)
#  PROFILE  cpu or gpu  (cpu)
#  APPLY  true to run (false: plan only)
#  STATE  finished-step file  (~/.coco-pattern/install-tenant-<TENANT_CLUSTER>.done)
#  INTEL_PCS_API_KEY  Intel PCS API key for the PCK certificates (else ~/.coco-pattern/pccs_api_key)
#  MOVE_LLM  gpu: false skips recreating the LLM pods in TDX (true)
#  MOVE_AGENT  true recreates the CUGA agent in TDX (false)
#  MCP_TIMEOUT, APP_TIMEOUT  wait limits in minutes (120, 60)

set -euo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${S}/lib/site.sh"
# The mirror tools (oc-mirror, mirror-registry) as a fallback: the caller's PATH wins.
PATH="${PATH}:${MIRROR_HOME}/bin"
INSTALL_TAG=install-tenant
PROFILE="${PROFILE:-cpu}"
CP="${HOME}/.coco-pattern"
STATE="${STATE:-${CP}/install-tenant-${TENANT_CLUSTER}.done}"
PCK_DIR="${CP}/dcap-pck/${TENANT_CLUSTER}"
STATE_ID="tenant=${EXPECT_TENANT_API_SERVER} hub=${EXPECT_HUB_API_SERVER} profile=${PROFILE}"
OC="${OC:-oc --kubeconfig=${TENANT_KUBECONFIG}}"
HUB_OC="${HUB_OC:-oc --kubeconfig=${HUB_KUBECONFIG}}"
. "${S}/lib/install.sh"
. "${S}/lib/cluster-guard.sh"
cluster_guard tenant "${OC}"
cluster_guard hub "${HUB_OC}"
for t in oc jq python3 curl veritas cosign; do command -v "$t" >/dev/null || die "$t not found"; done
case "${PROFILE}" in
  cpu) VALUES_CG=deploy/spoke/values-baremetal-spoke.yaml; REBOOTS=reboot ;;
  gpu) VALUES_CG=deploy/spoke/values-baremetal-spoke-gpu.yaml; REBOOTS="2-3 reboots" ;;
  *) die "PROFILE=${PROFILE}: want cpu or gpu" ;;
esac
export VALUES_CG
[ -s "${TDX_REGISTRY_AUTH_FILE:-}" ] || die "TDX_REGISTRY_AUTH_FILE missing (docs/install.md#tdx-registry-credentials)"

STAGES=(
  "pull-creds|merge TDX registry credentials into the pull secret (00)|kubelet config roll"
  "pull-creds-wait|wait for the MachineConfigPools (00)|"
  "mirror|mirror mappings and CatalogSources (01)|reboot"
  "mirror-wait|wait for the MachineConfigPools (01)|"
  "gitops|GitOps repository credentials (02)|"
  "kbs-cert|copy the KBS certificate into tenant Vault (03)|"
  "mirror-ca|copy the mirror CA into tenant Vault (03b)|"
)
[ "${PROFILE}" = gpu ] && STAGES+=(
  "gpu-rim|GPU RIM values from the connected host (G2)|"
  "gpu-registry-config|registry configuration with tenant mirrors (G3)|"
  "gpu-vault|load GPU refvals and registry config on the hub (G4)|"
  "gpu-trustee-restart|restart hub Trustee with the GPU refvals (G4)|attestation gap"
  "handover|hand the NVIDIA stack over (G5)|"
)
STAGES+=(
  "deploy|deploy the tenant (04, ${PROFILE} profile)|${REBOOTS}"
  "deploy-wait|wait for kata-cc, TDX nodes, QGS and ArgoCD sync (04)|"
)
[ "${PROFILE}" = gpu ] && STAGES+=(
  "gpu-runtime|reconcile the GPU RuntimeClass (G7)|"
  "gpu-check|check the GPU host (G8)|"
)
STAGES+=(
  "host-check|check TDX on every node (05)|"
  "pck|PCK certificates for every tenant platform (06)|QGS restart"
  "refvals-collect|collect tenant firmware refvals (07)|"
  "refvals-load|merge them into the hub file and Vault if they differ (07)|"
  "refvals-restart|restart hub Trustee if refvals changed (07)|attestation gap if changed"
  "verify|restart and verify the samples (08)|sample restarts"
)
[ "${PROFILE}" = gpu ] && STAGES+=(
  "llm|move the LLM into TDX (G10)|LLM outage until the guest pull ends"
)
STAGES+=(
  "agent|move the CUGA agent into TDX (G11)|agent login outage until the guest is Ready"
)

stage_pull_creds()      { APPLY=true "${S}/tenant/00-add-mirror-pull-creds.sh"; }
stage_pull_creds_wait() { wait_mcp "${OC}"; }
stage_mirror()          { APPLY=true "${S}/tenant/01-apply-mirror-resources.sh"; }
stage_mirror_wait()     { wait_mcp "${OC}"; }
stage_gitops()          { APPLY=true "${S}/tenant/02-ensure-gitops-repo-creds.sh"; }
stage_kbs_cert()        { APPLY=true "${S}/tenant/03-load-kbs-route-cert.sh"; }
stage_mirror_ca()       { APPLY=true "${S}/tenant/03b-copy-hub-secrets-to-vaultaas.sh"; }

stage_gpu_rim() {
  [ -s "${CP}/gpu-reference-values.json" ] || pause "GPU RIM values come from a host with NVIDIA RIM/OCSP access (docs/manual-install-tenant-gpu.md#g2-gpu-reference-values):
  DRIVER_VERSION=<kata-guest-driver> VBIOS_VERSION=<GPU-VBIOS> ./scripts/collect-gpu-refvals.sh
  then copy gpu-reference-values.json to ${CP}/ on this host"
}
stage_gpu_registry_config() { EXTRA_KUBECONFIGS="${TENANT_KUBECONFIG}" "${S}/collect-registry-config.sh"; }
stage_gpu_vault()           { ONLY=gpuReferenceValues,registryConfig APPLY=true "${S}/load-existing-vault.sh"; }
stage_gpu_trustee_restart() {
  wait_for "ExternalSecret gpu-refvals-eso" 15 \
    ${HUB_OC} wait externalsecret/gpu-refvals-eso -n trustee-operator-system --for=condition=Ready --timeout=30s
  trustee_restart "${HUB_OC}"
}
stage_handover()    { APPLY=true "${S}/tenant/g05-handover-nvidia-gpu.sh"; }
stage_deploy()      { APPLY=true "${S}/deploy-coco-spoke.sh"; }
stage_deploy_wait() {
  local cg="${S}/../${VALUES_CG}" rc=0
  wait_tdx_runtime "${OC}"
  # With an agent, deploy-coco-spoke.sh deployed the profile plus the agent's apps.
  if [ -n "${TENANT_AGENT_NAMESPACE:-}" ]; then
    cg="$(mktemp)"
    AGENT_VALUES="${S}/../deploy/spoke/values-cuga-agent.yaml" \
      yq --from-file "${S}/lib/add-agent.yq" "${S}/../${VALUES_CG}" > "${cg}"
  fi
  wait_apps "${OC}" "${APP_NAME:-coco-pattern-spoke}" "${cg}" || rc=$?
  [ -z "${TENANT_AGENT_NAMESPACE:-}" ] || rm -f "${cg}"
  [ "${rc}" -eq 0 ] || return "${rc}"
  # The GPU profile renders IOMMU and kubelet MachineConfigs separately.
  [ "${PROFILE}" != gpu ] || wait_mcp "${OC}"
}
stage_gpu_runtime() { APPLY=true "${S}/tenant/g07-reconcile-kataconfig-gpu.sh"; }
stage_gpu_check()   { "${S}/tenant/g08-verify-gpu-cc.sh"; }

stage_host_check() {
  local n nodes; nodes="$(tdx_nodes "${OC}")"
  [ -n "${nodes}" ] || die "no tenant node has intel.feature.node.kubernetes.io/tdx=true"
  for n in ${nodes}; do NODE="${n}" APPLY=true "${S}/tenant/05-verify-tdx-host.sh"; done
}
stage_pck() { pck_provision "${TENANT_KUBECONFIG}" "${PCK_DIR}"; }

HUB_FW="${CP}/firmware-reference-values.json"
TEN_FW="${CP}/firmware-reference-values-${TENANT_CLUSTER}.json"
FW_CHANGED="${STATE%.done}.refvals-changed"
stage_refvals_collect() {
  KUBECONFIG="${TENANT_KUBECONFIG}" python3 "${S}/../build/pattern/scripts/collect_firmware_refvals.py" --platform baremetal -t tdx \
    -p "${MIRROR_HOME}/config/pull-secret.json" --values-file "${S}/../${VALUES_CG}" -o "${TEN_FW}"
}
stage_refvals_load() {
  local merged; merged="$(merge_refvals "${HUB_FW}" "${TEN_FW}")"
  if [ "${merged}" != "$(jq -S . "${HUB_FW}")" ]; then
    cp -p "${HUB_FW}" "${HUB_FW}.bak-$(date -u +%Y%m%dT%H%M%SZ)"
    # Marker first, then an atomic replace: an interrupted run still loads Vault on --resume.
    touch "${FW_CHANGED}"
    printf '%s\n' "${merged}" > "${HUB_FW}.tmp" && mv "${HUB_FW}.tmp" "${HUB_FW}"
    msg "merged tenant values into ${HUB_FW} (backup next to it)"
  elif [ ! -e "${FW_CHANGED}" ]; then
    msg "tenant firmware refvals already in the hub file"; return 0
  fi
  # Also reached on --resume after a failed load: the marker says the hub file changed.
  ONLY=firmwareReferenceValues APPLY=true "${S}/load-existing-vault.sh"
}
stage_refvals_restart() {
  [ -e "${FW_CHANGED}" ] || { msg "refvals unchanged: no Trustee restart"; return 0; }
  wait_for "tenant firmware refvals in RVPS" 15 rvps_has_fw "${HUB_OC}" "${TEN_FW}"
  trustee_restart "${HUB_OC}"
  rm -f "${FW_CHANGED}"
}

stage_verify() { APPLY=true "${S}/tenant/08-verify-attestation.sh"; }

stage_llm() {
  [ "${MOVE_LLM:-true}" = true ] || { warn "MOVE_LLM=false: LLM pods not recreated"; return 0; }
  if [ -z "$(${OC} get pod -n llms -l kserve.io/component=workload -o name 2>/dev/null)" ]; then
    warn "no LLM pod in llms: nothing to move; run scripts/tenant/g10-move-llm-to-cc.sh after deploying one"
    return 0
  fi
  APPLY=true "${S}/tenant/g10-move-llm-to-cc.sh"
}

stage_agent() {
  [ "${MOVE_AGENT:-false}" = true ] || { warn "MOVE_AGENT=false: CUGA agent not recreated (set MOVE_AGENT=true to move it)"; return 0; }
  [ -n "${TENANT_AGENT_NAMESPACE:-}" ] || { warn "TENANT_AGENT_NAMESPACE empty: the tenant was deployed without the CUGA agent"; return 0; }
  if [ -z "$(${OC} get pod -n "${TENANT_AGENT_NAMESPACE}" -l app.kubernetes.io/name=cuga -o name 2>/dev/null)" ]; then
    warn "no CUGA agent in ${TENANT_AGENT_NAMESPACE}: nothing to move; rerun --from agent after creating one"
    return 0
  fi
  APPLY=true "${S}/tenant/workaround-cuga-jwt-leeway.sh"
  NS="${TENANT_AGENT_NAMESPACE}" SELECTOR=app.kubernetes.io/name=cuga RUNTIMECLASS=kata-cc GPU=false \
    APPLY=true "${S}/tenant/g10-move-llm-to-cc.sh"
}

run_stages "$@"
