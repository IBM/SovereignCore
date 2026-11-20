#!/usr/bin/env bash
# Check GPU CC mode, policy readiness, runtime, pgpu capacity and vfio cdev.
# Prerequisites: oc; site config, converged GPU ClusterPolicy and reconciled KataConfig.
# Effects: Read-only; prints remediation commands without running them.
# Exit: 0 ready; 1 error or failed readiness check.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  OC  oc targeting the TENANT (oc --kubeconfig=$TENANT_KUBECONFIG)
#  RUNTIMECLASS  GPU runtime class  (kata-cc-nvidia-gpu)
#  GPU_RESOURCE  pass-through GPU resource name  (nvidia.com/pgpu)
#  CLUSTERPOLICY  GPU Operator ClusterPolicy name  (gpu-cluster-policy)
#  CLUSTERPOLICY_KIND  qualified kind, avoids the Kyverno short-name clash (clusterpolicies.nvidia.com)
#  GPU_NS  GPU Operator namespace  (nvidia-gpu-operator)

set -euo pipefail

RUNTIMECLASS="${RUNTIMECLASS:-kata-cc-nvidia-gpu}"
GPU_RESOURCE="${GPU_RESOURCE:-nvidia.com/pgpu}"
CLUSTERPOLICY="${CLUSTERPOLICY:-gpu-cluster-policy}"

msg()  { printf '\033[1;34m[g08-gpu-cc]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[g08-gpu-cc] WARN:\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[g08-gpu-cc]  PASS:\033[0m %s\n' "$*" >&2; }
bad()  { printf '\033[1;31m[g08-gpu-cc]  FAIL:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[g08-gpu-cc] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# A missing startup cdev and a device lost at runtime have distinct plugin log messages.
vfio_cdev_missing() {
  grep -aqE 'Unable to add device path to fsnotify watcher|Marking device unhealthy: /dev/vfio/' <<<"$1"
}

(return 0 2>/dev/null) && return 0

. "$(dirname "${BASH_SOURCE[0]}")/../lib/site.sh"
OC="${OC:-oc --kubeconfig=${TENANT_KUBECONFIG}}"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cluster-guard.sh"
cluster_guard tenant "${OC}"

GPU_NS="${GPU_NS:-nvidia-gpu-operator}"

FAILED=0

NODE="$(${OC} get nodes -l nvidia.com/gpu.present=true \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "${NODE}" ]; then
  ok "GPU node: ${NODE} (nvidia.com/gpu.present=true)"
else
  die "no node labelled nvidia.com/gpu.present=true -- GPU node not installed/enrolled, or ClusterPolicy has not labelled it. Cannot verify GPU CC."
fi

LBLS="$(${OC} get node "${NODE}" -o jsonpath='{.metadata.labels}' 2>/dev/null || true)"
if grep -aqE '"nvidia\.com/(cc\.mode\.state|cc\.mode|gpu\.cc\.enabled|cc\.enabled)":"(on|true|enabled)"' <<<"${LBLS}"; then
  ok "GPU confidential-compute mode is ON (nvidia.com/cc.mode.state=on)"
else
  bad "GPU is not in CC mode (no nvidia.com/cc.mode.state=on). On a host without TDX the cc-manager logs 'Overriding default CC mode: on to off because the host does not support CC' -- check 05-verify-tdx-host.sh first."; FAILED=1
fi
if grep -aq '"nvidia.com/cc.ready.state":"true"' <<<"${LBLS}"; then
  ok "GPU reports CC ready state (nvidia.com/cc.ready.state=true)"
else
  warn "nvidia.com/cc.ready.state is not 'true' (cc-manager may still be applying). Verify with: nvidia-smi conf-compute -f inside a GPU pod."
fi

# Qualify NVIDIA ClusterPolicy: Kyverno owns the same short name.
CLUSTERPOLICY_KIND="${CLUSTERPOLICY_KIND:-clusterpolicies.nvidia.com}"
if ${OC} get "${CLUSTERPOLICY_KIND}" "${CLUSTERPOLICY}" >/dev/null 2>&1; then
  STATE="$(${OC} get "${CLUSTERPOLICY_KIND}" "${CLUSTERPOLICY}" -o jsonpath='{.status.state}' 2>/dev/null || true)"
  if [ "${STATE}" = "ready" ]; then
    ok "ClusterPolicy ${CLUSTERPOLICY} state=ready"
  else
    bad "ClusterPolicy ${CLUSTERPOLICY} state='${STATE:-<none>}' (expected ready); GPU Operator still converging"; FAILED=1
  fi
else
  bad "ClusterPolicy ${CLUSTERPOLICY} not found (nvidia-gpu app not synced / GPU Operator CSV not Succeeded)"; FAILED=1
fi

if ${OC} get runtimeclass "${RUNTIMECLASS}" >/dev/null 2>&1; then
  HANDLER="$(${OC} get runtimeclass "${RUNTIMECLASS}" -o jsonpath='{.handler}' 2>/dev/null || true)"
  ok "RuntimeClass ${RUNTIMECLASS} present (handler=${HANDLER:-?})"
else
  bad "RuntimeClass ${RUNTIMECLASS} not found -- run g07-reconcile-kataconfig-gpu.sh (APPLY=true) and wait for it."; FAILED=1
fi

PGPU="$(${OC} get node "${NODE}" -o jsonpath="{.status.allocatable.${GPU_RESOURCE//./\\.}}" 2>/dev/null || true)"
if [ -n "${PGPU}" ] && [ "${PGPU}" != "0" ]; then
  ok "node advertises ${GPU_RESOURCE}=${PGPU}"
else
  bad "node does not advertise ${GPU_RESOURCE} (kata sandbox device plugin not ready / GPU not vfio-bound)"; FAILED=1
fi

# Check the cdev because pgpu can remain advertised after the device disappears.
DP_POD="$(${OC} get pods -n "${GPU_NS}" -l app=nvidia-kata-sandbox-device-plugin-daemonset \
          --field-selector spec.nodeName="${NODE}" -o name 2>/dev/null | head -n1 || true)"
DP_LOG=""
[ -z "${DP_POD}" ] || DP_LOG="$(${OC} logs -n "${GPU_NS}" "${DP_POD}" -c nvidia-kata-sandbox-device-plugin-ctr 2>/dev/null || true)"
if [ -z "${DP_LOG}" ]; then
  warn "cannot read the kata sandbox device plugin log on ${NODE}; vfio cdev not checked. Check on the node: ls /dev/vfio/devices/"
elif vfio_cdev_missing "${DP_LOG}"; then
  bad "vfio cdev /dev/vfio/devices/vfioN is missing on ${NODE} (sandbox device plugin: 'Unable to add device path to fsnotify watcher'). Confidential-GPU pods cannot cold-plug the GPU. Fix (docs/troubleshooting.md, 'vfio cdev missing after a reboot'):
    ${OC} delete pod -n ${GPU_NS} -l name=nvidia-vfio-manager
    ${OC} debug node/${NODE} -q -- chroot /host ls /dev/vfio/devices/
    ${OC} delete pod -n ${GPU_NS} -l app=nvidia-kata-sandbox-device-plugin-daemonset
  then re-run this script."; FAILED=1
else
  ok "vfio cdev present (no missing-path error in ${DP_POD#pod/} log)"
fi

if [ "${FAILED}" -eq 0 ]; then
  ok "GPU confidential-compute host is ready. Next: sync the gpu-workload app and verify the guest attests (08-verify-attestation.sh) with a GPU evidence."
  exit 0
fi
die "GPU CC verification FAILED (see FAIL lines). See docs/troubleshooting.md."
