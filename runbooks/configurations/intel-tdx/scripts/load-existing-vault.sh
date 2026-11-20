#!/usr/bin/env bash
# Load secret/hub/* through transient ESO Secrets and PushSecrets.
# Prerequisites: oc, python3, jq; site config, local material, ready ClusterSecretStore and ESO write access.
# Effects: Default previews; APPLY=true writes Vault and cleans transient objects; file-backed paths replace;
#   then waits until ESO has copied the loaded registryConfig/tdxRegistryAuth into their Trustee Secrets.
# Exit: 0 success; nonzero on validation, cluster guard or PushSecret failure.
# Never put secrets (including tdxRegistryAuth) in a ConfigMap or argv; manifests stay 0600.
# Generated paths use IfNotExists; FORCE_REGEN=true replaces them.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; supplies HUB_KUBECONFIG, EXPECT_HUB_API_SERVER)
#  KUBECTL  hub client, may be multi-word  (oc --kubeconfig=<site HUB_KUBECONFIG>)
#  APPLY  true to change the hub (default false: print the plan only)
#  ONLY  comma-separated subset of the paths below  (all paths)
#  NS  namespace of the transient Secrets and PushSecrets  (external-secrets)
#  STORE  ClusterSecretStore  (sovcloud-vault-cluster-secret-store)
#  VAULT_PREFIX  KV prefix under the store's mount  (hub)
#  COCO_SECRETS_DIR  local material  (~/.coco-pattern)
#  TDX_REGISTRY_AUTH_FILE  read-only TDX registry dockerconfigjson (site value; else skip tdxRegistryAuth). Checked by lib/registry-auth.py, pushed byte for byte.
#  FORCE_REGEN  replace generated secrets (false)
#  TIMEOUT  wait for the PushSecrets  (300s)

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/site.sh"
KUBECTL="${KUBECTL:-oc --kubeconfig=${HUB_KUBECONFIG}}"
APPLY="${APPLY:-false}"
ONLY="${ONLY:-}"
NS="${NS:-external-secrets}"
STORE="${STORE:-sovcloud-vault-cluster-secret-store}"
VAULT_PREFIX="${VAULT_PREFIX:-hub}"
COCO_SECRETS_DIR="${COCO_SECRETS_DIR:-${HOME}/.coco-pattern}"
FORCE_REGEN="${FORCE_REGEN:-false}"
TIMEOUT="${TIMEOUT:-300s}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$(date -u +%Y%m%d%H%M%S)-$$"
PATHS="kbsres1 passphrase attestationStatus securityPolicyConfig sealedSecretsSigningKey pcrStash firmwareReferenceValues gpuReferenceValues registryConfig mirrorCA tdxRegistryAuth tdxCollateral"

msg()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v "${KUBECTL%% *}" >/dev/null 2>&1 || die "'${KUBECTL%% *}' not found in PATH"
command -v python3 >/dev/null 2>&1 || die "'python3' not found in PATH"
for p in ${ONLY//,/ }; do
  case " ${PATHS} " in *" ${p} "*) ;; *) die "ONLY: unknown path '${p}' (known: ${PATHS})" ;; esac
done
SELECTED="${ONLY:+${ONLY//,/ }}"; SELECTED="${SELECTED:-${PATHS}}"
. "${SCRIPT_DIR}/lib/cluster-guard.sh"
cluster_guard hub "${KUBECTL}"

W="$(mktemp -d)"
cleanup() {
  rm -rf "${W}"
  [ "${APPLIED:-false}" = true ] || return 0
  # Delete PushSecret first so ESO cannot read a half-deleted source; Vault keeps its data.
  ${KUBECTL} delete pushsecret -n "${NS}" -l "load-existing-vault/run=${RUN}" --ignore-not-found --wait=true >/dev/null 2>&1 \
    || warn "could not delete PushSecrets -l load-existing-vault/run=${RUN} in ${NS}: delete them by hand"
  ${KUBECTL} delete secret -n "${NS}" -l "load-existing-vault/run=${RUN}" --ignore-not-found >/dev/null 2>&1 \
    || warn "could not delete Secrets -l load-existing-vault/run=${RUN} in ${NS}: delete them by hand"
}
trap cleanup EXIT
umask 077

if [ ! -f "${COCO_SECRETS_DIR}/sealed-secrets-signing-pub.jwk" ]; then
  GEN_SECRETS="${GEN_SECRETS:-${SCRIPT_DIR}/../build/pattern/scripts/gen-secrets.sh}"
  if [ "${APPLY}" = true ]; then
    [ -x "${GEN_SECRETS}" ] || die "missing ${GEN_SECRETS} (run scripts/build-upstream.sh)"
    msg "Generating local key/cert material via gen-secrets.sh"
    "${GEN_SECRETS}"
  else
    warn "local key/cert material missing: APPLY=true runs ${GEN_SECRETS} first"
  fi
fi
TDX_AUTH=""
case " ${SELECTED} " in *" tdxRegistryAuth "*)
  if [ -n "${TDX_REGISTRY_AUTH_FILE:-}" ] && [ -f "${TDX_REGISTRY_AUTH_FILE}" ]; then
    python3 -I "${SCRIPT_DIR}/lib/registry-auth.py" check "${TDX_REGISTRY_AUTH_FILE}" \
      || die "refusing ${TDX_REGISTRY_AUTH_FILE} (message above)"
    TDX_AUTH="${TDX_REGISTRY_AUTH_FILE}"
  else
    warn "TDX_REGISTRY_AUTH_FILE (${TDX_REGISTRY_AUTH_FILE:-unset}) missing - skipping tdxRegistryAuth (credential-eso unsynced)."
    warn "  Create it first (docs/manual-install-hub.md step 5b, scripts/create-tdx-registry-credentials.sh)."
  fi ;;
esac

D="${COCO_SECRETS_DIR}" PREFIX="${VAULT_PREFIX}" NS="${NS}" STORE="${STORE}" RUN="${RUN}" \
SELECTED="${SELECTED}" TDX_AUTH="${TDX_AUTH}" FORCE_REGEN="${FORCE_REGEN}" OUT="${W}/manifest.json" \
python3 - > "${W}/plan" <<'PY' || die "could not build the manifest (message above)"
import json, os, re, secrets, sys
e = os.environ
d, sel = e["D"], e["SELECTED"].split()
regen = e["FORCE_REGEN"] == "true"
def warn(s): print("WARN: " + s, file=sys.stderr)
def path(n): return os.path.join(d, n)
def text(n):
    # Preserve newline stripping: mirrorCA bytes affect the measured initdata hash.
    with open(path(n), encoding="utf-8") as f:
        return f.read().rstrip("\n")
def tojson(v): return json.dumps(v, separators=(",", ":"), ensure_ascii=False)
POLICY_INSECURE = '{\n  "default": [{"type": "insecureAcceptAnything"}],\n  "transports": {}\n}'
POLICY_REJECT = '{\n  "default": [{"type": "reject"}],\n  "transports": {}\n}'
POLICY_SIGNED = ('{\n  "default": [{"type": "reject"}],\n  "transports": {\n    "docker": {\n'
                 '      "registry.example.com/my-image": [\n'
                 '        {"type": "sigstoreSigned", "keyPath": "kbs:///default/cosign-keys/key-0"}\n'
                 '      ]\n    }\n  }\n}')
entries = []
def add(p, fields, gen=False):
    if p in sel: entries.append((p, fields, gen))
def need(p, files, hint):
    miss = [f for f in files if not os.path.isfile(path(f))]
    if miss and p in sel: warn("missing %s - skipping %s. %s" % (", ".join(path(f) for f in miss), p, hint))
    return not miss

add("kbsres1", {k: secrets.token_hex(32) for k in ("key1", "key2", "key3")}, True)
add("passphrase", {"passphrase": secrets.token_hex(32)}, True)
add("attestationStatus", {"status": "attested", "random": secrets.token_hex(16)}, True)
add("securityPolicyConfig", {"insecure": POLICY_INSECURE, "reject": POLICY_REJECT, "signed": POLICY_SIGNED})
# KBS serves it as the signing-key resource; a missing Secret stops the whole KbsConfig reconcile.
if need("sealedSecretsSigningKey", ["sealed-secrets-signing-pub.jwk"], "KBS will not reconcile without the signing-key resource."):
    add("sealedSecretsSigningKey", {"public": text("sealed-secrets-signing-pub.jwk")})
# Azure vTPM PCRs only; bare metal stores an empty stash, as upstream does, so pcrs-eso syncs.
add("pcrStash", {"json": "{}"}, True)
if need("firmwareReferenceValues", ["firmware-reference-values.json"],
        "Run collect_firmware_refvals.py first; without it resource release is PolicyDeny (hardware 97)."):
    # The trustee chart reads the collector's whole file from field json (claim -> list of values).
    fw = json.load(open(path("firmware-reference-values.json")))
    add("firmwareReferenceValues", {"json": tojson(fw)})
if os.path.isfile(path("gpu-reference-values.json")):
    add("gpuReferenceValues", {k: tojson(v) for k, v in json.load(open(path("gpu-reference-values.json"))).items()})
else:
    # Real values come with the first GPU tenant (G4, Replace). Until then a placeholder keeps the
    # gpu-refvals ExternalSecret healthy: it sits in an early ArgoCD wave and a Degraded one stops
    # the rest of the trustee sync (KbsConfig, certificates). GPU guests stay denied meanwhile.
    if "gpuReferenceValues" in sel:
        warn("missing %s - writing an empty gpuReferenceValues placeholder (IfNotExists); GPU guests are denied until a GPU tenant loads real values" % path("gpu-reference-values.json"))
    add("gpuReferenceValues", {"none": "[]"}, True)
if need("registryConfig", ["registry-configuration.toml"], "Run ./scripts/collect-registry-config.sh first."):
    add("registryConfig", {"config": text("registry-configuration.toml")})
if need("mirrorCA", ["mirror-ca.pem"], "Run ./scripts/collect-registry-config.sh first."):
    add("mirrorCA", {"ca": text("mirror-ca.pem")})
if e["TDX_AUTH"]:
    # Preserve registry credentials byte-for-byte, including trailing newlines.
    with open(e["TDX_AUTH"], encoding="utf-8") as f:
        add("tdxRegistryAuth", {"regcred": f.read()})
if need("tdxCollateral", ["dcap-offline/platform_collaterals.json"],
        "Run collect-dcap-collateral.sh first; without it KBS cannot verify TDX quotes."):
    # Field name = file name under the KBS mount (trustee kbs.tdx.collateralFileName).
    add("tdxCollateral", {"platform_collaterals.json": text("dcap-offline/platform_collaterals.json")})

items = []
for p, fields, gen in entries:
    for k, v in fields.items():
        if not re.fullmatch(r"[-._a-zA-Z0-9]+", k): sys.exit("%s: field %r is not a valid Secret key" % (p, k))
        if not isinstance(v, str): sys.exit("%s: field %r is not a string" % (p, k))
    name = "vault-load-" + re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", p).lower()
    meta = {"name": name, "namespace": e["NS"],
            "labels": {"app.kubernetes.io/managed-by": "load-existing-vault", "load-existing-vault/run": e["RUN"]}}
    policy = "IfNotExists" if gen and not regen else "Replace"
    items.append({"apiVersion": "v1", "kind": "Secret", "metadata": meta, "type": "Opaque", "stringData": fields})
    items.append({"apiVersion": "external-secrets.io/v1alpha1", "kind": "PushSecret", "metadata": meta, "spec": {
        "updatePolicy": policy, "deletionPolicy": "None", "refreshInterval": "1h",
        "secretStoreRefs": [{"name": e["STORE"], "kind": "ClusterSecretStore"}],
        "selector": {"secret": {"name": name}},
        "data": [{"match": {"remoteRef": {"remoteKey": "%s/%s" % (e["PREFIX"], p)}}}]}})
    print("%-24s %-11s %s" % (e["PREFIX"] + "/" + p, policy, " ".join(fields)))
if not items: sys.exit("nothing to write (all selected paths skipped)")
with open(e["OUT"], "w") as f:
    json.dump({"apiVersion": "v1", "kind": "List", "items": items}, f)
PY

msg "plan (${STORE}, namespace ${NS}): path / updatePolicy / fields"
sed 's/^/    /' "${W}/plan" >&2
if [ "${APPLY}" != true ]; then
  msg "APPLY=false: hub NOT modified. Re-run with APPLY=true."
  exit 0
fi

APPLIED=true
# Server-side: client-side apply copies each object into an annotation (max 256 KiB; the TDX
# collateral alone is ~750 KB) and would duplicate the secret values there.
${KUBECTL} apply --server-side --force-conflicts --field-manager=load-existing-vault -f - < "${W}/manifest.json" >/dev/null || die "apply of the Secrets/PushSecrets failed"
msg "applied; waiting up to ${TIMEOUT} for ESO to push (run ${RUN})"
pushed() { ${KUBECTL} wait pushsecret -n "${NS}" -l "load-existing-vault/run=${RUN}" --for=condition=Ready --timeout="${TIMEOUT}" >&2; }
push_status() { ${KUBECTL} get pushsecret -n "${NS}" -l "load-existing-vault/run=${RUN}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[0].message}{"\n"}{end}'; }

# ESO replaces only entries carrying its custom_metadata managed-by=external-secrets; it refuses entries
# written another way (vault kv put, the Vault UI). A fresh install never has those.
if ! pushed; then
  push_status >&2 || true
  unmanaged="$(push_status 2>/dev/null | awk -F'\t' '/not managed by external-secrets/ {print $1}' | tr '\n' ' ')"
  [ -n "${unmanaged}" ] || die "not every PushSecret is Ready (above); login timeouts = a Vault pod stuck Terminating. The transient objects are deleted on exit."
  paths="$(jq -r --arg n " ${unmanaged}" '.items[] | .metadata.name as $m | select(.kind == "PushSecret" and ($n | contains(" " + $m + " "))) | .spec.data[0].match.remoteRef.remoteKey' "${W}/manifest.json" | tr '\n' ' ')"
  die "Vault entries ${paths}were written outside ESO, so ESO will not replace them. If nothing else
  maintains them, a Vault administrator deletes them or sets their custom_metadata managed-by=external-secrets
  (docs/troubleshooting.md, Vault loader push not ready); then re-run."
fi
msg "PASS: loaded ${VAULT_PREFIX}/{${SELECTED// /,}} (skipped paths warned above). ExternalSecrets sync on their next refresh."
# Wait until ESO has written the loaded KBS inputs into their Trustee Secrets, so a restart right after serves them.
kbs_synced() { # path secret key file strip|exact
  case " ${SELECTED} " in *" $1 "*) ;; *) return 0 ;; esac
  [ "${VAULT_PREFIX}" = hub ] && [ -f "$4" ] || return 0
  ${KUBECTL} get secret -n trustee-operator-system "$2" >/dev/null 2>&1 || return 0
  # Same text-mode read as the loader above.
  python3 -I -c 'import sys; v = open(sys.argv[1], encoding="utf-8").read()
open(sys.argv[3], "w", encoding="utf-8", newline="").write(v.rstrip("\n") if sys.argv[2] == "strip" else v)' "$4" "$5" "${W}/expect"
  msg "waiting up to 2m for ESO to sync $1 into trustee-operator-system/$2"
  for _ in $(seq 24); do
    ${KUBECTL} get secret -n trustee-operator-system "$2" -o json 2>/dev/null \
      | jq -j --arg k "$3" '.data[$k] // "" | @base64d' | cmp -s - "${W}/expect" && return 0
    sleep 5
  done
  die "trustee-operator-system/$2 does not hold the new ${VAULT_PREFIX}/$1 after 2m: check ExternalSecret $2-eso there"
}
kbs_synced registryConfig registry-config config "${COCO_SECRETS_DIR}/registry-configuration.toml" strip
kbs_synced tdxRegistryAuth credential regcred "${TDX_AUTH}" exact
# Trustee's secret-converter init container copies KBS resources and reference values once, at pod start;
# the TDX collateral is mounted directly and reread per attestation.
[ "${SELECTED}" = tdxCollateral ] || msg "Guests see changed values only after a Trustee restart: oc delete pod -n trustee-operator-system -l app=kbs"
