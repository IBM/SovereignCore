#!/usr/bin/env bash
# Recreate the tenant LLM pods (or, with GPU=false, the CUGA agent) under the confidential admission policies.
# Prerequisites: oc; GPU and attestation checks pass, GPU refvals loaded, KBS registry-config includes tenant mirrors.
# Effects: Default shows pods; APPLY=true deletes selected pods and checks replacement mutation, without waiting for Ready.
# Exit: 0 success; nonzero on prerequisites, guard, deletion or mutation failure.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  OC  oc targeting the TENANT (oc --kubeconfig=$TENANT_KUBECONFIG)
#  NS  LLM namespace  (llms)
#  SELECTOR  workload pod selector  (kserve.io/component=workload)
#  RUNTIMECLASS  expected runtime class  (kata-cc-nvidia-gpu)
#  GPU  false for CPU-only workloads: skips the GPU rule and nvidia.com/pgpu checks  (true)
#  APPLY  true to recreate the pods  (false)

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/site.sh"
OC="${OC:-oc --kubeconfig=${TENANT_KUBECONFIG}}"
NS="${NS:-llms}"
SELECTOR="${SELECTOR:-kserve.io/component=workload}"
RUNTIMECLASS="${RUNTIMECLASS:-kata-cc-nvidia-gpu}"
APPLY="${APPLY:-false}"
GPU="${GPU:-true}"

msg() { printf '\033[1;34m[g10-llm-cc]\033[0m %s\n' "$*" >&2; }
ok()  { printf '\033[1;32m[g10-llm-cc]  PASS:\033[0m %s\n' "$*" >&2; }
bad() { printf '\033[1;31m[g10-llm-cc]  FAIL:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[g10-llm-cc] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cluster-guard.sh"
cluster_guard tenant "${OC}"

show() {
  ${OC} get pod -n "${NS}" -l "${SELECTOR}" \
    -o custom-columns='NAME:.metadata.name,RUNTIME:.spec.runtimeClassName,PHASE:.status.phase,CREATED:.metadata.creationTimestamp'
}

${OC} get runtimeclass "${RUNTIMECLASS}" >/dev/null 2>&1 || die "RuntimeClass ${RUNTIMECLASS} missing -- run g07/g08 first"
[ "${GPU}" != true ] || ${OC} get clusterpolicy inject-coco-initdata -o json \
  | jq -e '.spec.rules[] | select(.name == "confidential-gpu-runtime")' >/dev/null 2>&1 \
  || die "Kyverno rule confidential-gpu-runtime not installed (coco-kyverno-policies confidentialGpu.namespaces)"

OLD="$(${OC} get pod -n "${NS}" -l "${SELECTOR}" -o jsonpath='{.items[*].metadata.name}')"
[ -n "${OLD}" ] || die "no ${SELECTOR} pod in ${NS}"
show

if [ "${APPLY}" != "true" ]; then
  msg "APPLY=false: nothing changed. Re-run with APPLY=true to recreate the pod(s) above."
  exit 0
fi

# shellcheck disable=SC2086
${OC} delete pod -n "${NS}" ${OLD} --wait=false
msg "deleted ${OLD}; waiting for the replacement pod to be created"

NEW=""
for _ in $(seq 1 30); do
  NEW="$(${OC} get pod -n "${NS}" -l "${SELECTOR}" -o json \
    | jq -r --arg old " ${OLD} " '.items[] | .metadata.name as $n | select($old | contains(" " + $n + " ") | not) | $n' | head -1)"
  [ -n "${NEW}" ] && break
  sleep 5
done
[ -n "${NEW}" ] || die "no replacement pod after 150s"

P="$(${OC} get pod -n "${NS}" "${NEW}" -o json)"
FAILED=0
[ "$(jq -r '.spec.runtimeClassName // ""' <<<"${P}")" = "${RUNTIMECLASS}" ] \
  && ok "${NEW}: runtimeClassName ${RUNTIMECLASS}" || { bad "${NEW}: runtimeClassName not ${RUNTIMECLASS}"; FAILED=1; }
[ "${GPU}" != true ] || { jq -e '[.spec.containers[].resources.limits // {} | has("nvidia.com/pgpu")] | any' <<<"${P}" >/dev/null \
  && ! jq -e '[.spec.containers[].resources.limits // {} | has("nvidia.com/gpu")] | any' <<<"${P}" >/dev/null \
  && ok "${NEW}: requests nvidia.com/pgpu (no nvidia.com/gpu)" || { bad "${NEW}: GPU resource not rewritten to nvidia.com/pgpu"; FAILED=1; }; }
jq -e '.metadata.annotations["io.katacontainers.config.hypervisor.cc_init_data"] // "" | length > 0' <<<"${P}" >/dev/null \
  && ok "${NEW}: cc_init_data injected ($(jq -r '.metadata.annotations["coco.io/initdata-configmap"]' <<<"${P}"))" \
  || { bad "${NEW}: cc_init_data annotation missing (initdata ConfigMap in ${NS}?)"; FAILED=1; }

[ "${FAILED}" -eq 0 ] || die "replacement pod was not mutated; it is running on the host runtime"
msg "mutation OK. Watch: ${OC} get pod -n ${NS} -l ${SELECTOR} -w"
