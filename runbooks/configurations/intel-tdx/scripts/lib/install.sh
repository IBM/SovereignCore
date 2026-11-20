# shellcheck shell=bash
# Step runner and waits for scripts/install-hub.sh and scripts/install-tenant.sh.
# Prerequisites: oc, jq; caller sets INSTALL_TAG, STATE and STATE_ID (which cluster/site/profile the state belongs to),
#   defines one function per step, then calls run_stages "$@".
# Options: --resume continue after the last finished step; --from <step> rerun that step and every later one;
#          --only <step> run that one step again, other steps untouched; --restart forget finished steps and
#          start over; -h/--help print the plan.
# ENV: APPLY true to run (default: print the plan);
#      MCP_TIMEOUT minutes per MachineConfigPool wait (120); APP_TIMEOUT minutes for ArgoCD sync (60).
# Effects: appends finished step names to STATE; a step returning 3 pauses the run for outside input.
# Exit: run_stages exits 0 when all steps are done, 3 when paused, 1 on failure, 2 on bad options.

msg()  { printf '\033[1;34m[%s]\033[0m %s\n' "${INSTALL_TAG}" "$*" >&2; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "${INSTALL_TAG}" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "${INSTALL_TAG}" "$*" >&2; exit 1; }
pause() { printf '\033[1;33m[%s] PAUSED:\033[0m %s\n' "${INSTALL_TAG}" "$*" >&2; return 3; }

# STAGES entries: "<name>|<description>|<disruption or empty>"; the function is stage_<name with - as _>.
# Each step wraps one step script (or one wait), so a failed step is where --resume starts.
run_stages() {
  local e name desc disr fn done_ mode=new from="" only="" rc keep=() hit=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --resume) mode=resume ;;
      --restart) mode=restart ;;
      --from) [ -n "${2:-}" ] || { echo "--from needs a step name" >&2; exit 2; }; mode=resume; from="$2"; shift ;;
      --only) [ -n "${2:-}" ] || { echo "--only needs a step name" >&2; exit 2; }; mode=resume; only="$2"; shift ;;
      -h|--help) APPLY=false ;;
      *) echo "unknown option '$1' (want --resume, --from <step>, --only <step>, --restart, --help)" >&2; exit 2 ;;
    esac
    shift
  done
  mkdir -p "$(dirname "${STATE}")"; touch "${STATE}"
  local id; id="$(sed -n '1s/^#id //p' "${STATE}")"
  [ -z "${from}" ] || printf '%s\n' "${STAGES[@]}" | grep -q "^${from}|" || die "--from ${from}: no such step"
  [ -z "${only}" ] || printf '%s\n' "${STAGES[@]}" | grep -q "^${only}|" || die "--only ${only}: no such step"
  if [ "${APPLY:-false}" != true ]; then
    msg "plan (state ${STATE}):"
    for e in "${STAGES[@]}"; do
      IFS='|' read -r name desc disr <<<"${e}"
      grep -qx "${name}" "${STATE}" && done_="done" || done_="todo"
      printf '  %-5s %-20s %s%s\n' "${done_}" "${name}" "${desc}" "${disr:+   ! ${disr}}" >&2
    done
    [ -z "${id}" ] || [ "${id}" = "${STATE_ID}" ] || warn "state belongs to ${id}, not ${STATE_ID}"
    msg "APPLY=false: nothing changed. Run with APPLY=true; after a failure or pause continue with --resume."
    exit 0
  fi
  case "${mode}" in
    restart) : > "${STATE}" ;;
    new) ! grep -qv '^#' "${STATE}" || die "a previous run finished steps ($(grep -v '^#' "${STATE}" | tail -n 1) last; ${STATE}): continue with --resume, or start over with --restart" ;;
    resume) [ -z "${id}" ] || [ "${id}" = "${STATE_ID}" ] || [ -n "${from}${only}" ] \
      || die "${STATE} belongs to ${id}, not ${STATE_ID}: use --restart, --from <step>, or another STATE" ;;
  esac
  if [ -n "${from}" ]; then
    for e in "${STAGES[@]}"; do name="${e%%|*}"; [ "${name}" = "${from}" ] && hit=1
      [ "${hit}" = 1 ] || ! grep -qx "${name}" "${STATE}" || keep+=("${name}"); done
    printf '%s\n' ${keep[@]+"${keep[@]}"} > "${STATE}"
  fi
  # The first line records which cluster, site and profile the finished steps belong to.
  { echo "#id ${STATE_ID}"; grep -v '^#' "${STATE}" || true; } > "${STATE}.tmp" && mv "${STATE}.tmp" "${STATE}"
  local again="--resume"; [ -z "${only}" ] || again="--only ${only}"
  for e in "${STAGES[@]}"; do
    IFS='|' read -r name desc disr <<<"${e}"
    if [ -n "${only}" ]; then [ "${name}" = "${only}" ] || continue
    else grep -qx "${name}" "${STATE}" && { msg "skip ${name} (done)"; continue; }; fi
    msg "=== ${name}: ${desc}${disr:+ (${disr})}"
    fn="stage_${name//-/_}"
    # A function called in an `||` list runs with set -e ignored; a plain subshell keeps it.
    set +e; ( set -e; "${fn}" ); rc=$?; set -e
    case "${rc}" in
      0) grep -qx "${name}" "${STATE}" || echo "${name}" >> "${STATE}" ;;
      3) msg "when done, continue with: $0 ${again}"; exit 3 ;;
      *) die "step ${name} failed (rc ${rc}); fix it, then continue from this step with: $0 ${again}" ;;
    esac
  done
  [ -z "${only}" ] || { msg "PASS: step ${only} done (${STATE})"; return 0; }
  msg "PASS: all steps done (${STATE})"
}

# Poll a command until it succeeds; failures (API down during a reboot) count as "not yet".
wait_for() {
  local what="$1" mins="$2" end; shift 2
  end=$(( $(date +%s) + mins * 60 ))
  until "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "${end}" ] || { warn "timeout after ${mins} min: ${what}"; return 1; }
    sleep 30
  done
  msg "ready: ${what}"
}

_mcp_settled() {
  ${1} get mcp -o json | jq -e '.items | length > 0 and all(
    .metadata.generation == .status.observedGeneration and
    (.spec.paused // false) == false and
    .spec.configuration.name == .status.configuration.name and
    .status.machineCount == .status.updatedMachineCount and
    .status.machineCount == .status.readyMachineCount and
    .status.unavailableMachineCount == 0 and
    any(.status.conditions[]; .type == "Updated" and .status == "True") and
    all(.status.conditions[]; ((.type == "Degraded" or .type == "Updating") | not) or .status == "False"))'
}
# Nodes the MCO reports as failing to drain (it does after 1 hour; it keeps retrying, but a pod its
# PodDisruptionBudget never lets go, e.g. the last replica of a broken workload, blocks the pool forever).
_drain_failed() {
  ${1} get mcp -o json | jq -r '.items[].status.conditions[]? | select(.type == "NodeDegraded" and .status == "True") | .message' \
    | grep -o -E 'Node [^ ]+ is reporting: "failed to drain node' | awk '{print $2}' | sort -u
}
# Fixed grace period for the MCO to pick up a new MachineConfig; poll the rendered config if it ever races.
wait_mcp() {
  local end nodes pods p
  sleep "${MCP_GRACE:-120}"
  end=$(( $(date +%s) + ${MCP_TIMEOUT:-120} * 60 ))
  until _mcp_settled "$1" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "${end}" ] || { warn "timeout after ${MCP_TIMEOUT:-120} min: MachineConfigPools settled"; return 1; }
    nodes="$(_drain_failed "$1" 2>/dev/null | tr '\n' ' ' || true)"
    if [ -n "${nodes}" ]; then
      pods=""
      # Only pods still on a draining node count: the condition and the log lag behind a deleted pod.
      for p in $(${1} logs -n openshift-machine-config-operator deploy/machine-config-controller -c machine-config-controller --since=15m 2>/dev/null \
          | grep -o -E 'error when evicting pods/"[^"]+" -n "[^"]+"' | sed -E 's#.*pods/"([^"]+)" -n "([^"]+)"#\2/\1#' | sort -u); do
        case " ${nodes}" in *" $(${1} get pod -n "${p%%/*}" "${p#*/}" -o jsonpath='{.spec.nodeName}' 2>/dev/null) "*) pods+="${p} " ;; esac
      done
      [ -n "${pods}" ] || { sleep 30; continue; }
      pause "the MCO cannot drain ${nodes}: evictions refused for ${pods}(PodDisruptionBudget). It keeps retrying; let those pods move (delete one that is already unhealthy), then resume"
      return
    fi
    sleep 30
  done
  msg "ready: MachineConfigPools settled"
}

# The root Application and every enabled child in the profile values file exist and are Synced;
# other Applications in the namespace (Sovereign Core's own) are ignored.
_apps_synced() {
  ${1} get applications.argoproj.io -n "${ARGO_NS:-openshift-gitops}" -o json \
    | jq -e --argjson want "$2" '[.items[] | select(.status.sync.status == "Synced") | .metadata.name] as $ok
        | all($want[]; . as $n | $ok | index($n))'
}
# wait_apps <client> <root app name> <profile values file>
# A sync that used up its retries (e.g. webhooks down during a rolling reboot) is not retried by
# automated sync for the same revision; start a new one, as `argocd app sync` does.
_apps_kick_failed() {
  local n phase
  # Once per app per wait: a sync that fails again on content shows its error instead of looping.
  # Also an app whose last sync succeeded but that drifted since: auto-sync does not repeat a
  # revision it already synced (e.g. fields a CRD dropped until its operator upgraded).
  for n in $(${1} get applications.argoproj.io -n "${ARGO_NS:-openshift-gitops}" -o json \
      | jq -r --argjson want "$2" '.items[] | select(.metadata.name as $n | $want | index($n))
          | select(.operation == null and ((.status.operationState.phase == "Failed" and .status.sync.status != "Synced")
              or (.status.operationState.phase == "Succeeded" and .status.sync.status == "OutOfSync")))
          | "\(.metadata.name):\(.status.operationState.phase)"'); do
    phase="${n#*:}"; n="${n%%:*}"
    case " ${APPS_KICKED:-} " in *" ${n} "*) continue ;; esac
    APPS_KICKED="${APPS_KICKED:-} ${n}"
    if [ "${phase}" = Failed ]; then
      warn "Application ${n}: last sync failed with its retries used up; starting a new sync" 2>&3
    else
      warn "Application ${n}: OutOfSync after a successful sync of the same revision; starting a new sync" 2>&3
    fi
    ${1} patch applications.argoproj.io -n "${ARGO_NS:-openshift-gitops}" "${n}" --type merge \
      -p '{"operation":{"initiatedBy":{"username":"install-runner"},"sync":{"syncStrategy":{"hook":{}}},"retry":{"limit":5}}}' >/dev/null || true
  done
}
# The root Application creates its children and their AppProjects in one sync; a child created a
# moment before its project gets InvalidSpecError and Argo CD does not re-check it when the project
# appears. Refresh such an Application once its project exists (once per app per run).
_apps_refresh_invalid() {
  local n proj
  while read -r n proj; do
    [ -n "${n}" ] || continue
    case " ${APPS_REFRESHED:-} " in *" ${n} "*) continue ;; esac
    ${1} get appprojects.argoproj.io -n "${ARGO_NS:-openshift-gitops}" "${proj}" >/dev/null 2>&1 || continue
    APPS_REFRESHED="${APPS_REFRESHED:-} ${n}"
    warn "Application ${n}: was created before AppProject ${proj}; refreshing it" 2>&3
    ${1} annotate applications.argoproj.io -n "${ARGO_NS:-openshift-gitops}" "${n}" \
      argocd.argoproj.io/refresh=normal --overwrite >/dev/null || true
  done < <(${1} get applications.argoproj.io -n "${ARGO_NS:-openshift-gitops}" -o json | jq -r '.items[]
      | (.status.conditions // [])[] as $c | select($c.type == "InvalidSpecError")
      | ([$c.message | capture("referencing project (?<p>[^ ]+) which does not exist")?][0].p) as $p
      | select($p != null) | "\(.metadata.name) \($p)"')
}
_apps_synced_or_kick() { _apps_refresh_invalid "$1"; _apps_kick_failed "$1" "$2"; _apps_synced "$1" "$2"; }
_kata_or_refresh()     { _apps_refresh_invalid "$1"; ${1} get runtimeclass kata-cc; }
wait_apps() {
  local want; APPS_KICKED=""
  want="$(yq -o=json -I=0 "[\"$2\"] + [.clusterGroup.applications | to_entries[] | select(.value.disabled != true) | .value.name]" "$3")"
  # fd 3: the re-sync notice reaches the log although wait_for silences its check.
  wait_for "ArgoCD Applications Synced: $(jq -r 'join(" ")' <<<"${want}")" "${APP_TIMEOUT:-60}" _apps_synced_or_kick "$1" "${want}" 3>&2 || {
    ${1} get applications.argoproj.io -n "${ARGO_NS:-openshift-gitops}" -o json \
      | jq -r --argjson want "${want}" '.items[] | select(.metadata.name as $n | $want | index($n)) | "\(.metadata.name) \(.status.sync.status)"' >&2 || true
    return 1; }
}

# After a deploy: kata-cc exists, nodes settled, NFD found TDX and the DCAP operator registered every
# TDX platform (one platform-data Secret each); QGS serves quotes once its PCK certificates are imported.
wait_tdx_runtime() {
  # kata-cc comes from the sandbox Application, which may be one of those waiting for its project.
  wait_for "RuntimeClass kata-cc" "${MCP_TIMEOUT:-120}" _kata_or_refresh "$1" 3>&2 || return 1
  wait_mcp "$1" || return 1
  wait_for "a node labelled TDX by NFD" 30 _tdx_nodes "$1" || return 1
  wait_for "platform-data Secrets for all TDX nodes" 30 _platforms_registered "$1"
}
_tdx_nodes() { [ -n "$(tdx_nodes "$1")" ]; }
tdx_nodes() { ${1} get nodes -l intel.feature.node.kubernetes.io/tdx=true -o jsonpath='{.items[*].metadata.name}'; }
_platforms_registered() {
  local want; want="$(tdx_nodes "$1" | wc -w)"
  [ "${want}" -gt 0 ] && [ "$(${1} get secrets -n intel-dcap-operator-system -l type=platform-data -o name | wc -l)" -ge "${want}" ]
}

DCAP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/build/pattern/scripts"
export DCAP_PCSCLIENT_DIR="${DCAP_PCSCLIENT_DIR:-${HOME}/.coco-pattern/intel-dcap/tools/PcsClientTool}"

# pck_provision <kubeconfig> <bundle dir>: export platform data, fetch PCK certificates from Intel PCS,
# import them as Secrets and restart QGS (upstream dcap-pck.py). The API key stays in the environment.
pck_provision() {
  local key="${INTEL_PCS_API_KEY:-}" f="${HOME}/.coco-pattern/pccs_api_key" consent="${HOME}/.coco-pattern/intel-pcs-consent"
  if [ ! -e "${consent}" ]; then
    cat >&2 <<EOF
Before the PCK certificates are fetched, confirm the data sent to Intel PCS.
Collected by the DCAP operator per TDX platform, in the platform-data Secrets of namespace
intel-dcap-operator-system on the cluster: encrypted PPID, PCE ID, CPU SVN, PCE SVN, QE ID and
platform manifest.
Sent from this host to https://api.trustedservices.intel.com/sgx/certification/v4/pckcerts, with
your API key: the PCE ID and the platform manifest of each platform (indirect registration).
Stored on this host: the exported platform data in $2/request and the PCK certificates in
$2/response. Stored on the cluster: the PCK certificates as <qe_id>-pck Secrets in
intel-dcap-operator-system.
Details: https://cc-enabling.trustedservices.intel.com/intel-tdx-enabling-guide/02/infrastructure_setup/#platform-registration
EOF
    pause "to confirm, create ${consent} (touch ${consent}), then rerun with --resume"
    return
  fi
  if [ -z "${key}" ]; then
    [ -s "${f}" ] || { pause "write your Intel PCS API key to ${f} (mode 0600; docs/install.md#intel-pcs-api-key)"; return; }
    key="$(tr -d '\r\n' < "${f}")"
  fi
  mkdir -p "$2"
  INTEL_PCS_API_KEY="${key}" KUBECONFIG="$1" DCAP_REQUEST_BUNDLE="$2/request" DCAP_RESPONSE_BUNDLE="$2/response" \
    python3 "${DCAP}/dcap-pck.py" provision
}

# A new KBS pod reruns secret-converter, which copies the KBS resources and reference values. `rollout
# restart` does not: the Trustee operator rewrites the Deployment template and scales the new ReplicaSet away.
trustee_restart() {
  ${1} delete pod -n trustee-operator-system -l app=kbs --wait=true
  ${1} rollout status deploy/trustee-deployment -n trustee-operator-system --timeout=300s
}

# RVPS reference values as {name: [values]}; Trustee 1.2 stores base64url JSON entries under reference_value.
rvps_values() {
  ${1} get cm rvps-reference-values -n trustee-operator-system -o jsonpath='{.data.reference_value}' \
    | jq 'map_values(gsub("-"; "+") | gsub("_"; "/") | . + ("=" * ((4 - length % 4) % 4)) | @base64d | fromjson | .value)'
}

# The trustee chart loads only these TDX firmware keys into RVPS (rvps-values-policies.yaml); the
# collector also writes tdvfkernel*, which RVPS never holds.
RVPS_TDX_KEYS='["mr_td","rtmr_1","rtmr_2","xfam"]'
# rvps_has_fw <client> [refvals file]: every loaded key is in RVPS, with all of the file's values for it.
rvps_has_fw() {
  rvps_values "$1" | jq -e --argjson k "${RVPS_TDX_KEYS}" --slurpfile t "${2:-/dev/null}" \
    '. as $r | all($k[]; . as $n | $r | has($n) and all(($t[0][$n] // [])[]; . as $x | $r[$n] | index($x)))'
}

# Union of two firmware refvals files (arrays per key); never drops a value of the first.
merge_refvals() {
  jq -S -s '.[0] as $h | .[1] as $t
    | $h + ($t | with_entries(select(.value | type == "array") | .value = ((($h[.key] // []) + .value) | unique)))' "$1" "$2"
}

