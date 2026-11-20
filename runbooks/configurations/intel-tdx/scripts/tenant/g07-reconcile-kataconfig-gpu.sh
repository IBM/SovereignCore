#!/usr/bin/env bash
# Reconcile KataConfig so the confidential-GPU runtime appears.
# Prerequisites: oc; site config, installed GPU operator and a node labelled nvidia.com/gpu.present=true.
# Effects: Default previews; APPLY=true annotates KataConfig if the GPU RuntimeClass is absent.
# Exit: 0 success; nonzero on missing GPU node, guard, annotation or wait failure.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  OC  oc targeting the TENANT  (oc --kubeconfig=$TENANT_KUBECONFIG)
#  RUNTIMECLASS  GPU runtime class to wait for  (kata-cc-nvidia-gpu)
#  KATACONFIG  KataConfig to nudge  (auto: the only one; else default-kata-config)
#  APPLY  true to annotate the KataConfig (default false = preview only)

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/site.sh"
OC="${OC:-oc --kubeconfig=${TENANT_KUBECONFIG}}"
RUNTIMECLASS="${RUNTIMECLASS:-kata-cc-nvidia-gpu}"
KATACONFIG="${KATACONFIG:-}"
APPLY="${APPLY:-false}"

msg()  { printf '\033[1;34m[g07-kata-gpu]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[g07-kata-gpu] WARN:\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[g07-kata-gpu]  PASS:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[g07-kata-gpu] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cluster-guard.sh"
cluster_guard tenant "${OC}"

GPU_NODES="$(${OC} get nodes -l nvidia.com/gpu.present=true \
             -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
if [ -z "${GPU_NODES}" ]; then
  die "no node labelled nvidia.com/gpu.present=true -- the H100/H200 node is not installed/enrolled yet, or the GPU Operator ClusterPolicy has not labelled it. Nothing to reconcile."
fi
msg "GPU node(s): ${GPU_NODES}"

if ${OC} get runtimeclass "${RUNTIMECLASS}" >/dev/null 2>&1; then
  HANDLER="$(${OC} get runtimeclass "${RUNTIMECLASS}" -o jsonpath='{.handler}' 2>/dev/null || true)"
  ok "RuntimeClass ${RUNTIMECLASS} already exists (handler=${HANDLER:-?}); no reconcile needed."
  exit 0
fi

if [ -z "${KATACONFIG}" ]; then
  KATACONFIG="$(${OC} get kataconfig -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "${KATACONFIG}" ] || KATACONFIG="default-kata-config"
fi
${OC} get kataconfig "${KATACONFIG}" >/dev/null 2>&1 \
  || die "KataConfig '${KATACONFIG}' not found (is sandboxed-containers deployed? set KATACONFIG=...)"

msg "RuntimeClass ${RUNTIMECLASS} absent; will nudge KataConfig '${KATACONFIG}' to re-reconcile."

if [ "${APPLY}" != "true" ]; then
  msg "APPLY=false: no change made."
  msg "  Re-run with APPLY=true to annotate kataconfig/${KATACONFIG} (kata-reconcile=<epoch>)."
  exit 0
fi

EPOCH="$(date +%s)"
${OC} annotate kataconfig "${KATACONFIG}" "kata-reconcile=${EPOCH}" --overwrite >/dev/null \
  || die "failed to annotate kataconfig/${KATACONFIG}"
ok "annotated kataconfig/${KATACONFIG} kata-reconcile=${EPOCH}."
msg "Watch for the RuntimeClass to appear, then run g08-verify-gpu-cc.sh:"
msg "  ${OC} get runtimeclass ${RUNTIMECLASS} -w"
