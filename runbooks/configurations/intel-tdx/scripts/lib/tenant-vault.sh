# shellcheck shell=bash
# Copy a hub Secret field byte-for-byte into tenant Vault through ESO.
# Prerequisites: OC (tenant), OC_HUB (hub), msg/die; call tv_init then tv_push <hubNs> <hubSecret> <hubKey> <key> <leaf>.
# ENV (defaults): CSS_NAME store (sovcloud-vault-cluster-secret-store); CLUSTER_NAME (tenant baseDomain first label).
#  TV_NS transient namespace (tdx-tenant-delivery); TIMEOUT PushSecret wait (300s); APPLY write gate (false).
# Effects: default previews; APPLY=true creates Secret/PushSecret, writes Vault, then cleans both on exit.
# Preserve certificate bytes and trailing newlines: they affect the initdata measurement.
# Keep secrets off argv and stdout; delete PushSecret before its source Secret.
# Exit: returns 0 on success; exits 1 on guard, source, store or push failure.

CSS_NAME="${CSS_NAME:-sovcloud-vault-cluster-secret-store}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
TV_NS="${TV_NS:-tdx-tenant-delivery}"
TIMEOUT="${TIMEOUT:-300s}"
TV_RUN="$(date -u +%Y%m%d%H%M%S)-$$"
TV_APPLIED=false

tv_cleanup() {
  [ "${TV_APPLIED}" = true ] || return 0
  ${OC} delete pushsecret -n "${TV_NS}" -l "tenant-vault/run=${TV_RUN}" --ignore-not-found --wait=true >/dev/null 2>&1 \
    || warn "could not delete PushSecrets -l tenant-vault/run=${TV_RUN} in ${TV_NS}: delete them by hand"
  ${OC} delete secret -n "${TV_NS}" -l "tenant-vault/run=${TV_RUN}" --ignore-not-found >/dev/null 2>&1 \
    || warn "could not delete Secrets -l tenant-vault/run=${TV_RUN} in ${TV_NS}: delete them by hand"
}

tv_init() {
  ${OC} get clustersecretstore "${CSS_NAME}" >/dev/null 2>&1 \
    || die "tenant ClusterSecretStore ${CSS_NAME} not found (is ${OC} the tenant? set CSS_NAME=...)"
  if [ -z "${CLUSTER_NAME}" ]; then
    local bd
    bd="$(${OC} get dns.config cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null || true)"
    [ -n "${bd}" ] || die "could not read the tenant base domain (set CLUSTER_NAME=... explicitly)"
    CLUSTER_NAME="${bd%%.*}"
  fi
  [[ "${CLUSTER_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "bad CLUSTER_NAME '${CLUSTER_NAME}'"
  trap tv_cleanup EXIT
  msg "tenant store:  ${CSS_NAME}   cluster name: ${CLUSTER_NAME}"
}

tv_b64() {
  local b64
  b64="$(${OC_HUB} get secret "$2" -n "$1" -o jsonpath="{.data.${3//./\\.}}" 2>/dev/null || true)"
  [ -n "${b64}" ] || die "hub Secret $1/$2 has no field '$3' (is ${OC_HUB} the hub?)"
  [[ "${b64}" =~ ^[A-Za-z0-9+/]+=*$ ]] || die "hub Secret $1/$2 field '$3' is not base64"
  printf %s "${b64}"
}

tv_push() {
  local b64 name
  b64="$(tv_b64 "$1" "$2" "$3")" || exit 1
  name="tenant-vault-$(printf %s "$5" | sed -E 's/([a-z0-9])([A-Z])/\1-\2/g' | tr A-Z a-z)"
  msg "hub $1/$2[$3] -> ${CLUSTER_NAME}/$5 (property $4), $(printf %s "${b64}" | base64 -d | wc -c) bytes"
  if [ "${APPLY}" != true ]; then
    msg "APPLY=false: tenant Vault NOT written. Re-run with APPLY=true."
    return 0
  fi
  TV_APPLIED=true
  local m
  m="$(printf '{"apiVersion":"v1","kind":"List","items":[
{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"%s"}},
{"apiVersion":"v1","kind":"Secret","type":"Opaque","metadata":{"name":"%s","namespace":"%s","labels":{"app.kubernetes.io/managed-by":"tenant-vault","tenant-vault/run":"%s"}},"data":{"%s":"%s"}},
{"apiVersion":"external-secrets.io/v1alpha1","kind":"PushSecret","metadata":{"name":"%s","namespace":"%s","labels":{"app.kubernetes.io/managed-by":"tenant-vault","tenant-vault/run":"%s"}},
 "spec":{"updatePolicy":"Replace","deletionPolicy":"None","refreshInterval":"1h",
  "secretStoreRefs":[{"name":"%s","kind":"ClusterSecretStore"}],"selector":{"secret":{"name":"%s"}},
  "data":[{"match":{"secretKey":"%s","remoteRef":{"remoteKey":"%s/%s","property":"%s"}}}]}}]}\n' \
    "${TV_NS}" "${name}" "${TV_NS}" "${TV_RUN}" "$4" "${b64}" \
    "${name}" "${TV_NS}" "${TV_RUN}" "${CSS_NAME}" "${name}" "$4" "${CLUSTER_NAME}" "$5" "$4")"
  ${OC} apply --server-side --force-conflicts --field-manager=tenant-vault -f - <<<"${m}" >/dev/null \
    || die "apply of the Secret/PushSecret ${TV_NS}/${name} failed"
  if ! ${OC} wait pushsecret "${name}" -n "${TV_NS}" --for=condition=Ready --timeout="${TIMEOUT}" >/dev/null; then
    ${OC} get pushsecret "${name}" -n "${TV_NS}" -o jsonpath='{.status.conditions[0].message}{"\n"}' >&2 || true
    die "PushSecret ${TV_NS}/${name} not Ready (above). 'secret not managed by external-secrets' = the entry was
  written outside ESO: a Vault administrator deletes it or sets its custom_metadata managed-by=external-secrets;
  403 = the tenant Vault policy does not grant ${CLUSTER_NAME}/*. The transient objects are deleted on exit."
  fi
  msg "PASS: ${CLUSTER_NAME}/$5 (property $4) written through ${CSS_NAME}"
}
