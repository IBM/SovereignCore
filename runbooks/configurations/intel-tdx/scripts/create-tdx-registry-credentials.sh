#!/usr/bin/env bash
# Create or rotate dedicated read-only TDX Quay robots for one host.
# Prerequisites: curl, jq, python3; site config, trusted CA and Quay org:admin/repo:admin token.
# Effects: Default reads and previews; APPLY=true grants read, creates/rotates robots and writes OUT (0600).
# Exit: 0 success; nonzero on invalid credentials, API or file errors.
# Keep tokens off argv and out of logs; rotate only when consumers can adopt the replacement.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required)
#  QUAY_HOST  Quay host  (site CHART_REGISTRY)
#  ORGS  organizations to read: the example guests' orgs by default (sovcloud aiiaas-models rhaiis on
#        CHART_REGISTRY, ubi9 hashicorp on MIRROR_REGISTRY; required on any other host). Add the orgs
#        of your own guest images (docs/install.md#tdx-registry-credentials).
#  ROBOT  robot short name  (tdx_pull)
#  QUAY_TOKEN_FILE  file holding the Quay token  (unset: read stdin)
#  QUAY_CA_FILE  CA bundle for QUAY_HOST (site HUB_INGRESS_CA_FILE, MIRROR_CA_FILE on MIRROR_REGISTRY)
#  OUT  dockerconfigjson to write  (site TDX_REGISTRY_AUTH_FILE)
#  ROTATE  regenerate existing robot tokens, invalidating them (false)
#  APPLY  create/rotate robots, grant read and write OUT (false)

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/site.sh"
# The orgs the example guests pull from: samples (ubi9), Vault in TDX (hashicorp), the
# confidential LLM (rhaiis runtime, aiiaas-models model) and the CUGA agent (sovcloud).
TDX_EXAMPLE_ORGS_CHART="sovcloud aiiaas-models rhaiis"
TDX_EXAMPLE_ORGS_MIRROR="ubi9 hashicorp"
QUAY_HOST="${QUAY_HOST:-${CHART_REGISTRY}}"
if [ "${QUAY_HOST}" = "${CHART_REGISTRY}" ]; then
  ORGS="${ORGS:-${TDX_EXAMPLE_ORGS_CHART}}"; QUAY_CA_FILE="${QUAY_CA_FILE-${HUB_INGRESS_CA_FILE:-}}"
else
  ORGS="${ORGS:-}"
  if [ "${QUAY_HOST}" = "${MIRROR_REGISTRY}" ]; then
    ORGS="${ORGS:-${TDX_EXAMPLE_ORGS_MIRROR}}"; QUAY_CA_FILE="${QUAY_CA_FILE-${MIRROR_CA_FILE:-}}"
  fi
fi
ROBOT="${ROBOT:-tdx_pull}"
OUT="${OUT:-${TDX_REGISTRY_AUTH_FILE:-}}"
ROTATE="${ROTATE:-false}"; APPLY="${APPLY:-false}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"

msg() { printf '\033[1;34m[tdx-robots]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[tdx-robots] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "${ORGS}" ] || die "ORGS is required for ${QUAY_HOST} (the organizations the TDX stack pulls from)"
[[ "${ROBOT}" =~ ^[a-z][a-z0-9_]{1,63}$ ]] || die "ROBOT must match [a-z][a-z0-9_]+"
[ -n "${OUT}" ] || die "OUT / site TDX_REGISTRY_AUTH_FILE is not set"
[ -z "${QUAY_CA_FILE:-}" ] || [ -r "${QUAY_CA_FILE}" ] || die "QUAY_CA_FILE ${QUAY_CA_FILE} is not readable"
command -v curl >/dev/null && command -v python3 >/dev/null || die "needs curl and python3"
API="https://${QUAY_HOST}/api/v1"

T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
umask 077
if [ -n "${QUAY_TOKEN_FILE:-}" ]; then tok="$(cat "${QUAY_TOKEN_FILE}")"
elif [ ! -t 0 ]; then read -r tok
else die "no Quay token: set QUAY_TOKEN_FILE or pipe it on stdin"; fi
[ -n "${tok}" ] || die "empty Quay token"
printf 'Authorization: Bearer %s\n' "${tok}" > "${T}/hdr"; unset tok

api() {
  curl -sS ${QUAY_CA_FILE:+--cacert "${QUAY_CA_FILE}"} -o "${T}/body" -w '%{http_code}' \
    -H @"${T}/hdr" -H 'Content-Type: application/json' -X "$1" ${3:+--data-binary @"$3"} "${API}$2"
}
py() { python3 -I -c "$1" "${T}/body" "${@:2}"; }

declare -A ACTION
for org in ${ORGS}; do
  [[ "${org}" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || die "bad organization name '${org}'"
  code="$(api GET "/organization/${org}")"
  [ "${code}" = 200 ] || die "organization ${org}: HTTP ${code} (missing, or the token lacks org:admin)"
  : > "${T}/repos-${org}"; page=""
  while :; do
    code="$(api GET "/repository?namespace=${org}${page:+&next_page=${page}}")"
    [ "${code}" = 200 ] || die "list repositories of ${org}: HTTP ${code}"
    py 'import json,sys; [print(r["name"]) for r in json.load(open(sys.argv[1])).get("repositories", [])]' >> "${T}/repos-${org}"
    page="$(py 'import json,sys; print(json.load(open(sys.argv[1])).get("next_page") or "")')"
    [ -n "${page}" ] || break
  done
  code="$(api GET "/organization/${org}/robots/${ROBOT}")"
  case "${code}" in
    200) if [ "${ROTATE}" = true ]; then ACTION[${org}]=rotate; else ACTION[${org}]=keep; fi ;;
    400|404) ACTION[${org}]=create ;;
    *) die "robot lookup ${org}+${ROBOT}: HTTP ${code}" ;;
  esac
  msg "${QUAY_HOST}/${org}: robot ${org}+${ROBOT} ${ACTION[${org}]}, read on $(wc -l < "${T}/repos-${org}") repositories + new ones"
done
msg "output ${OUT} (entries ${QUAY_HOST}/<org>; other entries kept)"
if [ "${APPLY}" != true ]; then msg "APPLY=false: Quay and ${OUT} unchanged."; exit 0; fi

printf '{"role":"read"}' > "${T}/role"
mkdir -p "$(dirname "${OUT}")"
[ -s "${OUT}" ] && cp "${OUT}" "${T}/out.json" || echo '{"auths":{}}' > "${T}/out.json"
for org in ${ORGS}; do
  full="${org}+${ROBOT}"
  case "${ACTION[${org}]}" in
    create) printf '{"description":"TDX read-only pull (guests, tenant nodes, tenant ArgoCD)"}' > "${T}/req"
            code="$(api PUT "/organization/${org}/robots/${ROBOT}" "${T}/req")"
            case "${code}" in 200|201) ;; *) die "create robot ${full}: HTTP ${code}" ;; esac ;;
    rotate) code="$(api POST "/organization/${org}/robots/${ROBOT}/regenerate")"
            [ "${code}" = 200 ] || die "regenerate ${full}: HTTP ${code}" ;;
  esac
  while read -r repo; do
    code="$(api PUT "/repository/${org}/${repo}/permissions/user/${full}" "${T}/role")"
    [ "${code}" = 200 ] || die "grant read on ${org}/${repo} to ${full}: HTTP ${code}"
  done < "${T}/repos-${org}"
  code="$(api GET "/organization/${org}/prototypes")"
  [ "${code}" = 200 ] || die "list default permissions of ${org}: HTTP ${code}"
  if ! py 'import json,sys; sys.exit(0 if any(p.get("delegate",{}).get("name")==sys.argv[2] for p in json.load(open(sys.argv[1])).get("prototypes",[])) else 1)' "${full}"; then
    printf '{"delegate":{"kind":"user","name":"%s"},"role":"read"}' "${full}" > "${T}/proto"
    code="$(api POST "/organization/${org}/prototypes" "${T}/proto")"
    case "${code}" in 200|201) ;; *) die "default permission for ${full} on ${org}: HTTP ${code}" ;; esac
  fi
  code="$(api GET "/organization/${org}/robots/${ROBOT}")"
  [ "${code}" = 200 ] || die "read back ${full}: HTTP ${code}"
  python3 -I - "${T}/body" "${T}/out.json" "${QUAY_HOST}/${org}" <<'PY'
import base64, json, sys
robot, out, key = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
if not robot.get("token"):
    sys.exit("Quay returned no robot token")
cfg = json.load(open(out))
cfg.setdefault("auths", {})[key] = {"auth": base64.b64encode(f'{robot["name"]}:{robot["token"]}'.encode()).decode()}
json.dump(cfg, open(out, "w"), sort_keys=True, indent=1)
PY
  msg "${ACTION[${org}]}: ${full} reads ${org}"
done
python3 -I "${LIB}/registry-auth.py" check "${T}/out.json" || die "the result failed the read-only check; ${OUT} unchanged"
install -m 0600 "${T}/out.json" "${OUT}"
msg "wrote ${OUT}. Next: load it into the hub Vault and restart Trustee (docs/install.md, TDX registry credentials)."
