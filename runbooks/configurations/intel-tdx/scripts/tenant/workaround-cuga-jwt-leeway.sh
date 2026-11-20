#!/usr/bin/env bash
# Build a JWT-leeway ConfigMap from the exact configured CUGA agent image.
# Prerequisites: oc, python3; site config, registry pull access, trusted CA and matching image digest.
# Effects: Default extracts/patches/checks locally; APPLY=true writes the ConfigMap; recreate the agent pod afterwards.
# Exit: 0 success; nonzero on digest, call-count, syntax, guard or apply failure.
# WORKAROUND ONLY; remove script, chart and ConfigMap when IBM ships JWT leeway.
# IBM code is never committed; extract it from the registry into temporary files.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  OC  oc targeting the TENANT (oc --kubeconfig=$TENANT_KUBECONFIG)
#  NS  agent namespace  ($TENANT_AGENT_NAMESPACE)
#  IMAGE  agent image (must match the chart's images[0]) (${CHART_REGISTRY}/sovcloud/cp/sovereign-cloud-platform/automation-saas-platform-dev/cuga:0.2.27)
#  EXPECT_DIGEST  required image digest (sha256:c9635fed...; cuga 0.2.27)
#  EXPECT_CALLS  jwt.decode calls expected in the file, including the unverified one  (3)
#  REGISTRY_AUTH  pull credential file for oc image  ($TDX_REGISTRY_AUTH_FILE)
#  HUB_INGRESS_CA_FILE  registry TLS CA (site value)
#  APPLY  true to write the ConfigMap  (false)
#  HUB_INGRESS_TLS_INSECURE  disable registry TLS verification (false)

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../lib/site.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/tls.sh"
OC="${OC:-oc --kubeconfig=${TENANT_KUBECONFIG}}"
NS="${NS:-${TENANT_AGENT_NAMESPACE}}"
IMAGE="${IMAGE:-${CHART_REGISTRY}/sovcloud/cp/sovereign-cloud-platform/automation-saas-platform-dev/cuga:0.2.27}"
EXPECT_DIGEST="${EXPECT_DIGEST:-sha256:c9635fed873e059e3e6acc66cd631957388b05626e60dc12e54191e6cf0ec870}"
EXPECT_CALLS="${EXPECT_CALLS:-3}"
REGISTRY_AUTH="${REGISTRY_AUTH:-${TDX_REGISTRY_AUTH_FILE}}"
APPLY="${APPLY:-false}"
SRC_PATH="/app/src/cuga/backend/server/auth/jwt_validator.py"
CM="cuga-jwt-leeway"

msg()  { printf '\033[1;34m[jwt-leeway]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[jwt-leeway] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[jwt-leeway] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cluster-guard.sh"

warn "WORKAROUND ONLY: remove once the agent image validates JWTs with a leeway"
[ -n "${NS}" ] || die "NS / TENANT_AGENT_NAMESPACE is empty"
[ -r "${REGISTRY_AUTH}" ] || die "registry credential not readable: ${REGISTRY_AUTH} (TDX_REGISTRY_AUTH_FILE)"
tls_ca HUB_INGRESS_CA_FILE HUB_INGRESS_TLS_INSECURE "the registry ${IMAGE%%/*}"
IMGTLS=()
if [ -n "${TLS_CA}" ]; then export SSL_CERT_FILE="${TLS_CA}"; else IMGTLS=(--insecure=true); fi

T="$(mktemp -d)"; chmod 700 "${T}"; trap 'rm -rf "${T}"' EXIT

digest="$(oc image info "${IMGTLS[@]}" -a "${REGISTRY_AUTH}" --filter-by-os=linux/amd64 -o json "${IMAGE}" | jq -r '.digest')"
[ "${digest}" = "${EXPECT_DIGEST}" ] \
  || die "image ${IMAGE} is ${digest:-<unknown>}, expected ${EXPECT_DIGEST}: a different agent build; re-check whether it still needs this workaround"
msg "image ${IMAGE}@${digest}"

oc image extract "${IMGTLS[@]}" -a "${REGISTRY_AUTH}" --filter-by-os=linux/amd64 --confirm \
  "${IMAGE}@${digest}" --path "${SRC_PATH}:${T}/" >/dev/null
[ -s "${T}/jwt_validator.py" ] || die "${SRC_PATH} not found in the image"

python3 -I - "${T}/jwt_validator.py" "${EXPECT_CALLS}" <<'PY'
import ast, re, sys
path, expect = sys.argv[1], int(sys.argv[2])
src = open(path, encoding="utf-8").read()

def calls(tree):
    return [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
            and n.func.attr == "decode" and isinstance(n.func.value, ast.Name) and n.func.value.id == "jwt"]

found = calls(ast.parse(src))
if len(found) != expect:
    sys.exit(f"expected {expect} jwt.decode calls, found {len(found)}: not the validator this workaround was written for")
if any(k.arg == "leeway" for c in found for k in c.keywords):
    sys.exit("a jwt.decode call already has a leeway: the workaround is not needed for this image")

lines = src.splitlines(keepends=True)
offs = [0]
for l in lines:
    offs.append(offs[-1] + len(l))
for c in sorted(found, key=lambda c: (c.end_lineno, c.end_col_offset), reverse=True):
    end = offs[c.end_lineno - 1] + c.end_col_offset - 1
    assert src[end] == ")"
    before = src[:end].rstrip()
    sep = "" if before.endswith(",") else ","
    src = src[:len(before)] + sep + " leeway=30" + src[len(before):end] + src[end:]

patched = calls(ast.parse(src))
ok = len(patched) == expect and all(
    any(k.arg == "leeway" and isinstance(k.value, ast.Constant) and k.value.value == 30 for k in c.keywords)
    for c in patched)
if not ok:
    sys.exit("patched file failed verification")
open(path, "w", encoding="utf-8").write(src)
print(f"patched {expect} jwt.decode calls")
PY

if [ "${APPLY}" != "true" ]; then
  msg "APPLY=false: patched copy verified locally; nothing written. Re-run with APPLY=true."
  exit 0
fi

cluster_guard tenant "${OC}"
${OC} create configmap "${CM}" -n "${NS}" --from-file=jwt_validator.py="${T}/jwt_validator.py" \
  --dry-run=client -o yaml \
  | ${OC} label --local -f - -o yaml coco.io/workaround=cuga-jwt-leeway \
  | ${OC} apply -f - >/dev/null
msg "ConfigMap ${NS}/${CM} written (workaround). Recreate the agent pod so the policy mounts it."
