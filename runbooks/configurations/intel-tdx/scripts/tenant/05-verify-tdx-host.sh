#!/usr/bin/env bash
# Check that NFD found TDX on a tenant node and that the kata-cc runtime exists.
# Prerequisites: oc; site config, NFD, KataConfig.
# Effects: Read-only API checks.
# Exit: 0 checks pass; 1 error or failed readiness check.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  OC  oc targeting the TENANT  (oc --kubeconfig=$TENANT_KUBECONFIG)
#  NODE  node to inspect  (auto: the first/only node)

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/site.sh"
OC="${OC:-oc --kubeconfig=${TENANT_KUBECONFIG}}"
NODE="${NODE:-}"

msg()  { printf '\033[1;34m[05-tdx-host]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[05-tdx-host]  PASS:\033[0m %s\n' "$*" >&2; }
bad()  { printf '\033[1;31m[05-tdx-host]  FAIL:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[05-tdx-host] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cluster-guard.sh"
cluster_guard tenant "${OC}"

[ -n "${NODE}" ] || NODE="$(${OC} get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "${NODE}" ] || die "could not determine a node (set NODE=...)"
msg "tenant node: ${NODE}"

FAILED=0

if [ "$(${OC} get node "${NODE}" -o jsonpath='{.metadata.labels.intel\.feature\.node\.kubernetes\.io/tdx}' 2>/dev/null)" = "true" ]; then
  ok "node label intel.feature.node.kubernetes.io/tdx=true"
else
  bad "node label intel.feature.node.kubernetes.io/tdx is not 'true' (NFD has not detected TDX)"; FAILED=1
fi

if ${OC} get runtimeclass kata-cc >/dev/null 2>&1; then
  HANDLER="$(${OC} get runtimeclass kata-cc -o jsonpath='{.handler}' 2>/dev/null || true)"
  ok "RuntimeClass kata-cc present (handler=${HANDLER:-?})"
else
  bad "RuntimeClass kata-cc not found (KataConfig not reconciled yet)"; FAILED=1
fi

if [ "${FAILED}" -eq 0 ]; then
  ok "TDX node and kata-cc runtime ready. Next: 06 PCK certificates (dcap-pck.py provision)."
  exit 0
fi
die "TDX host verification FAILED (see FAIL lines above). Common cause: node has not rebooted with the baremetal MachineConfig (nohibernate + kvm_intel.tdx=1); check 'oc get mcp'."
