#!/usr/bin/env bash
# Issue a Quay OAuth token from a user login, for a Quay that has none (e.g. the oc-mirror mirror-registry).
# Prerequisites: curl, python3; site config; a Quay user with direct (database) login and its CA bundle.
# Effects: Default signs in and reads only; APPLY=true creates ORG and its OAuth application APP if missing,
#  authorizes APP for the user and writes the token to OUT (0600).
# Exit: 0 success; nonzero on login, API or file errors.
# Optional: only for create-tdx-registry-credentials.sh on a Quay without an OAuth token. The token acts as
# the user, limited to SCOPES. The login comes from AUTHFILE and never reaches argv or logs.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  QUAY_HOST  Quay host[:port]  (site MIRROR_REGISTRY)
#  AUTHFILE  dockerconfigjson holding the user's login for QUAY_HOST  (site MIRROR_HOME/config/pull-secret.json)
#  QUAY_CA_FILE  CA bundle for QUAY_HOST  (site MIRROR_CA_FILE)
#  ORG  organization that holds the OAuth application  (tdxpattern)
#  ORG_EMAIL  e-mail Quay requires for a new organization  (tdxpattern@invalid.example)
#  APP  OAuth application name  (tdx-robots)
#  SCOPES  token scopes  (org:admin repo:admin)
#  OUT  token file  (~/.coco-pattern/quay-mirror-token)
#  APPLY  true to create missing ORG/APP and write OUT  (false)

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/site.sh"
QUAY_HOST="${QUAY_HOST:-${MIRROR_REGISTRY}}"
AUTHFILE="${AUTHFILE:-${MIRROR_HOME}/config/pull-secret.json}"
QUAY_CA_FILE="${QUAY_CA_FILE-${MIRROR_CA_FILE:-}}"
ORG="${ORG:-tdxpattern}"; ORG_EMAIL="${ORG_EMAIL:-tdxpattern@invalid.example}"
APP="${APP:-tdx-robots}"; SCOPES="${SCOPES:-org:admin repo:admin}"
OUT="${OUT:-${HOME}/.coco-pattern/quay-mirror-token}"
APPLY="${APPLY:-false}"

msg() { printf '\033[1;34m[quay-oauth]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[quay-oauth] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "${ORG}" =~ ^[a-z0-9][a-z0-9_]{1,254}$ ]] || die "ORG must match [a-z0-9][a-z0-9_]+"
[ -r "${AUTHFILE}" ] || die "AUTHFILE ${AUTHFILE} is not readable"
[ -n "${QUAY_CA_FILE}" ] && [ -r "${QUAY_CA_FILE}" ] || die "QUAY_CA_FILE (${QUAY_CA_FILE:-unset}) is not readable"
command -v curl >/dev/null && command -v python3 >/dev/null || die "needs curl and python3"
BASE="https://${QUAY_HOST}"

T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
umask 077
# Login -> a JSON sign-in body file; it never goes on argv.
python3 -I - "${AUTHFILE}" "${QUAY_HOST}" "${T}" <<'PY' || die "no login for ${QUAY_HOST} in ${AUTHFILE}"
import base64, json, sys
auths, host, t = json.load(open(sys.argv[1])).get("auths", {}), sys.argv[2], sys.argv[3]
e = auths.get(host) or sys.exit(1)
u, _, p = (base64.b64decode(e["auth"]).decode() if e.get("auth") else e["username"] + ":" + e["password"]).partition(":")
u and p or sys.exit(1)
json.dump({"username": u, "password": p}, open(t + "/signin.json", "w"))
open(t + "/user", "w").write(u)
PY
USER_NAME="$(cat "${T}/user")"

# req METHOD PATH [JSON-FILE]: session call with cookie jar and CSRF header; body in T/body, prints the HTTP code.
req() {
  curl -sS --cacert "${QUAY_CA_FILE}" -b "${T}/jar" -c "${T}/jar" -o "${T}/body" -w '%{http_code}' \
    -H @"${T}/csrf" -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
    -X "$1" ${3:+--data-binary @"$3"} "${BASE}$2"
}
py() { python3 -I -c "$1" "${T}/body" "${@:2}"; }
csrf() {
  : > "${T}/csrf"
  [ "$(req GET /csrf_token)" = 200 ] || die "GET /csrf_token failed"
  py 'import json,sys; print("X-CSRF-Token: " + json.load(open(sys.argv[1]))["csrf_token"])' > "${T}/csrf.new"
  mv "${T}/csrf.new" "${T}/csrf"
}

csrf
code="$(req POST /api/v1/signin "${T}/signin.json")"
[ "${code}" = 200 ] && py 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("success") else 1)' \
  || die "sign-in as ${USER_NAME} failed (HTTP ${code}): direct login off, or wrong password"
csrf
msg "${QUAY_HOST}: signed in as ${USER_NAME}"

code="$(req GET "/api/v1/organization/${ORG}")"
case "${code}" in 200) org=exists ;; 403|404) org=missing ;; *) die "organization ${ORG}: HTTP ${code}" ;; esac
client=""
if [ "${org}" = exists ]; then
  [ "$(req GET "/api/v1/organization/${ORG}/applications")" = 200 ] || die "list applications of ${ORG} failed"
  client="$(py 'import json,sys; print(next((a["client_id"] for a in json.load(open(sys.argv[1])).get("applications", []) if a["name"] == sys.argv[2]), ""))' "${APP}")"
fi
msg "organization ${ORG}: ${org}; application ${APP}: $([ -n "${client}" ] && echo exists || echo missing); scopes: ${SCOPES}; output ${OUT}"
if [ "${APPLY}" != true ]; then msg "APPLY=false: Quay and ${OUT} unchanged."; exit 0; fi

if [ "${org}" = missing ]; then
  python3 -I -c 'import json,sys; json.dump({"name": sys.argv[1], "email": sys.argv[2]}, open(sys.argv[3], "w"))' \
    "${ORG}" "${ORG_EMAIL}" "${T}/org.json"
  code="$(req POST /api/v1/organization/ "${T}/org.json")"
  [ "${code}" = 201 ] || [ "${code}" = 200 ] || die "create organization ${ORG}: HTTP ${code}"
  msg "created organization ${ORG}"
fi
if [ -z "${client}" ]; then
  python3 -I -c 'import json,sys; u="https://"+sys.argv[2]+"/"; json.dump({"name": sys.argv[1], "redirect_uri": u, "application_uri": u, "description": "Issues the token for create-tdx-registry-credentials.sh"}, open(sys.argv[3], "w"))' \
    "${APP}" "${QUAY_HOST}" "${T}/app.json"
  code="$(req POST "/api/v1/organization/${ORG}/applications" "${T}/app.json")"
  [ "${code}" = 200 ] || [ "${code}" = 201 ] || die "create application ${APP}: HTTP ${code}"
  client="$(py 'import json,sys; print(json.load(open(sys.argv[1]))["client_id"])')"
  msg "created OAuth application ${APP} in ${ORG}"
fi

# Quay's OAuth implicit grant, with the web session: mirror-registry
# Quay answers basic auth here with "CSRF token was invalid or missing". The token is in the redirect fragment.
curl -sS --cacert "${QUAY_CA_FILE}" -b "${T}/jar" -c "${T}/jar" -H @"${T}/csrf" -D "${T}/hdr" -o /dev/null -X POST "${BASE}/oauth/authorizeapp" \
  --data-urlencode response_type=token --data-urlencode "client_id=${client}" \
  --data-urlencode "redirect_uri=https://${QUAY_HOST}/" --data-urlencode "scope=${SCOPES}" \
  || die "POST /oauth/authorizeapp failed"
python3 -I - "${T}/hdr" "${T}/token" <<'PY' || die "no access_token in the authorizeapp redirect"
import re, sys
m = re.search(r"(?im)^location:.*[#&]access_token=([^&\s]+)", open(sys.argv[1]).read())
m or sys.exit(1)
open(sys.argv[2], "w").write(m.group(1))
PY
printf 'Authorization: Bearer %s\n' "$(cat "${T}/token")" > "${T}/bearer"
# Check with an org:admin call (/api/v1/user/ would need user:read).
code="$(curl -sS --cacert "${QUAY_CA_FILE}" -o "${T}/body" -w '%{http_code}' -H @"${T}/bearer" "${BASE}/api/v1/organization/${ORG}/applications")"
[ "${code}" = 200 ] || die "the new token cannot read organization ${ORG} (HTTP ${code})"
mkdir -p "$(dirname "${OUT}")"
install -m 600 "${T}/token" "${OUT}"
msg "wrote ${OUT} (token for ${USER_NAME}, scopes ${SCOPES}). Next: QUAY_HOST=${QUAY_HOST} ORGS=\"<orgs>\" QUAY_TOKEN_FILE=${OUT} APPLY=true ./scripts/create-tdx-registry-credentials.sh"
