#!/usr/bin/env bash
# Merge dedicated read-only TDX credentials into the tenant pull secret.
# Prerequisites: oc, python3; site config, TDX_REGISTRY_AUTH_FILE and tenant access.
# Effects: Default previews; APPLY=true writes the merged secret and rolls kubelet configuration through the MCP.
# Exit: 0 success; nonzero on validation, guard or write failure.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  OC  oc targeting the TENANT  (oc --kubeconfig=$TENANT_KUBECONFIG)
#  TDX_REGISTRY_AUTH_FILE  dockerconfigjson with the TDX robots  (site value)
#  APPLY  true to write the merged secret (default false = preview only)

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/site.sh"
OC="${OC:-oc --kubeconfig=${TENANT_KUBECONFIG}}"
APPLY="${APPLY:-false}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"

msg()  { printf '\033[1;34m[00-pull-creds]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[00-pull-creds] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[00-pull-creds] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "${TDX_REGISTRY_AUTH_FILE:-}" ] && [ -r "${TDX_REGISTRY_AUTH_FILE}" ] \
  || die "TDX_REGISTRY_AUTH_FILE (${TDX_REGISTRY_AUTH_FILE:-unset}) is not readable: create it (docs/manual-install-hub.md, TDX registry credentials)"
command -v jq >/dev/null 2>&1 || die "'jq' not found in PATH"
python3 -I "${LIB}/registry-auth.py" check "${TDX_REGISTRY_AUTH_FILE}" || die "refusing ${TDX_REGISTRY_AUTH_FILE}"

. "${LIB}/cluster-guard.sh"
cluster_guard tenant "${OC}"

T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
umask 077
msg "reading tenant openshift-config/pull-secret"
${OC} get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d > "${T}/current.json" || die "could not read the tenant pull-secret (is OC pointed at the tenant?)"
jq -e '.auths | type == "object"' "${T}/current.json" >/dev/null 2>&1 || die "the tenant pull-secret has no auths object"
python3 -I "${LIB}/registry-auth.py" merge "${T}/current.json" "${TDX_REGISTRY_AUTH_FILE}" > "${T}/merged.json"

python3 -I "${LIB}/registry-auth.py" check "${T}/current.json" 2>/dev/null \
  || warn "the tenant pull secret already holds an admin-looking or user-less entry; this script leaves it alone"

keys() { jq -r '.auths|keys[]' "$1" | sort; }
added="$(comm -13 <(keys "${T}/current.json") <(keys "${T}/merged.json"))"
updated="$(jq -rn --slurpfile c "${T}/current.json" --slurpfile m "${T}/merged.json" \
  '$c[0].auths as $a | $m[0].auths | to_entries[] | select($a[.key] != null and $a[.key] != .value) | .key')"
kept="$(jq -rn --slurpfile t "${TDX_REGISTRY_AUTH_FILE}" --slurpfile m "${T}/merged.json" \
  '$m[0].auths as $a | $t[0].auths | to_entries[] | select($a[.key] != .value) | .key')"
[ -z "${kept}" ] || { msg "kept (the tenant holds that key for a different user):"; printf '    = %s\n' ${kept} >&2; }
if [ -z "${added}${updated}" ]; then
  msg "nothing to change; tenant pull-secret unchanged."
  exit 0
fi
[ -z "${added}" ] || { msg "entries to add:"; printf '    + %s\n' ${added} >&2; }
[ -z "${updated}" ] || { msg "entries to update (same robot, new token):"; printf '    ~ %s\n' ${updated} >&2; }

if [ "${APPLY}" != "true" ]; then
  msg "APPLY=false: preview only, tenant NOT modified. Re-run with APPLY=true."
  exit 0
fi
warn "Writing the global pull secret rolls the kubelet config on every node."
${OC} set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="${T}/merged.json"
msg "tenant pull-secret updated. Watch the rollout: ${OC} get mcp"
