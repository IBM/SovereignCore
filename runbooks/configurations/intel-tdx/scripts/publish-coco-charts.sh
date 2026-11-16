#!/usr/bin/env bash
# Build and publish pinned charts to the hub OCI registry.
# Prerequisites: helm, oras, oc, yq; registry credentials, CA trust and upstream cache or connectivity.
# Effects: Builds/packages; default logs in and pushes; DRY_RUN=true packages only; no APPLY gate.
# Exit: 0 success; nonzero on build failure, lookup error or conflicting immutable tag.
# Tags are immutable; only definitive not-found from both helm and oras permits a push.
# Keep credentials off argv; stream passwords on stdin.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  QUAY_HOST  in-cluster Quay host  (site CHART_REGISTRY)
#  OCI_ORG  repo path prefix under the registry  (sovcloud/coco)
#  OCI_CA_FILE  CA bundle that signs the Quay route (helm/oras --ca-file)  (site HUB_INGRESS_CA_FILE) Must exist when set; empty falls back to the site CA.
#  OCI_INSECURE  explicit opt-in: true skips TLS verification of Quay.  (false) Prefer OCI_CA_FILE; use this only for a throwaway lab registry.
#  REPO_DIR  this repo  (auto: this script's repo root)
#  BUILD_DIR  build output  (${REPO_DIR}/build)
#  SKIP_BUILD  publish the existing build/ as-is  (false)
#  QUAY_USER  push username  (default: from the cluster Secret; required with QUAY_PASS)
#  QUAY_PASS  push password  (default: from cluster secret)
#  CREDS_SECRET / CREDS_NS  where to read creds (quay-oci-repo-creds / openshift-gitops)
#  OC  hub client  (site MIRROR_HOME/bin/oc --kubeconfig=<site HUB_KUBECONFIG>)
#  HELM  helm binary  (site MIRROR_HOME/bin/helm)
#  DRY_RUN  package/pull only; no login/push  (false)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
. "${SCRIPT_DIR}/lib/site.sh"

QUAY_HOST="${QUAY_HOST:-${CHART_REGISTRY}}"
OCI_ORG="${OCI_ORG:-sovcloud/coco}"
OCI_INSECURE="${OCI_INSECURE:-false}"
OCI_CA_FILE="${OCI_CA_FILE:-${HUB_INGRESS_CA_FILE:-}}"

OC="${OC:-${MIRROR_HOME}/bin/oc --kubeconfig=${HUB_KUBECONFIG}}"
HELM="${HELM:-${MIRROR_HOME}/bin/helm}"

CREDS_SECRET="${CREDS_SECRET:-quay-oci-repo-creds}"
CREDS_NS="${CREDS_NS:-openshift-gitops}"

[ "${FORCE:-false}" = "false" ] || { echo "[publish] ERROR: FORCE is unsupported: an existing tag is never overwritten. Bump the chart version." >&2; exit 1; }
DRY_RUN="${DRY_RUN:-false}"

BUILD_DIR="${BUILD_DIR:-${REPO_DIR}/build}"
SKIP_BUILD="${SKIP_BUILD:-false}"

DEST="oci://${QUAY_HOST}/${OCI_ORG}"
WORKDIR="$(mktemp -d /tmp/coco-charts.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

HELM_TLS_FLAG=()
ORAS_TLS_FLAG=()
LOGIN_TLS_FLAG=()
if [ "${OCI_INSECURE}" = "true" ]; then
  HELM_TLS_FLAG=(--insecure-skip-tls-verify)
  ORAS_TLS_FLAG=(--insecure)
  LOGIN_TLS_FLAG=(--insecure)
elif [ -n "${OCI_CA_FILE}" ]; then
  [ -r "${OCI_CA_FILE}" ] || { echo "[publish] ERROR: OCI_CA_FILE=${OCI_CA_FILE} is not a readable file: point it (or the site HUB_INGRESS_CA_FILE) at the Quay route CA bundle, and ensure the file is readable." >&2; exit 1; }
  HELM_TLS_FLAG=(--ca-file "${OCI_CA_FILE}")
  ORAS_TLS_FLAG=(--ca-file "${OCI_CA_FILE}")
  LOGIN_TLS_FLAG=(--ca-file "${OCI_CA_FILE}")
fi

msg()  { printf '\033[1;34m[publish]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[publish] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[publish] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

QUAY_USER="${QUAY_USER:-}"
QUAY_PASS="${QUAY_PASS:-}"

load_creds() {
  if [ -n "${QUAY_PASS}" ]; then
    [ -n "${QUAY_USER}" ] || die "QUAY_PASS is set but QUAY_USER is not; set both."
    msg "Using push credentials from environment (user: ${QUAY_USER})."
    return
  fi
  msg "Reading push credentials from secret ${CREDS_NS}/${CREDS_SECRET} (SovereignCore config)."
  local u p
  u="$(${OC} get secret "${CREDS_SECRET}" -n "${CREDS_NS}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  p="$(${OC} get secret "${CREDS_SECRET}" -n "${CREDS_NS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ -n "${u}" ] || u="${QUAY_USER}"
  [ -n "${u}" ] || die "Could not read the push user from ${CREDS_NS}/${CREDS_SECRET}; set QUAY_USER and QUAY_PASS instead."
  [ -n "${p}" ] || die "Could not read push password from ${CREDS_NS}/${CREDS_SECRET}; set QUAY_PASS instead."
  QUAY_USER="${u}"
  QUAY_PASS="${p}"
}

registry_login() {
  load_creds
  # Password on stdin only; never in argv.
  printf '%s' "${QUAY_PASS}" | "${HELM}" registry login "${QUAY_HOST}" \
    --username "${QUAY_USER}" --password-stdin \
    "${LOGIN_TLS_FLAG[@]}" >/dev/null
  msg "Logged in to ${QUAY_HOST} as ${QUAY_USER}."
}

is_not_found() {
  grep -Eqi ': not found|status code 404|name_unknown|manifest_unknown|name unknown|manifest unknown' <<<"$1" \
    && ! grep -Eqi '401|403|unauthori|denied|forbidden|x509|tls|certificate|timeout|refused|no such host|EOF' <<<"$1"
}

ORAS_AUTH_FLAG=()
helm_registry_config() {
  local f; f="$("${HELM}" env HELM_REGISTRY_CONFIG 2>/dev/null || true)"
  [ -n "${f}" ] && [ -r "${f}" ] && ORAS_AUTH_FLAG=(--registry-config "${f}") || true
}

tag_state() {
  local chart="$1" ver="$2" tags err rc=0
  err="$(mktemp "${WORKDIR}/oras.XXXXXX")"
  tags="$(oras repo tags "${ORAS_TLS_FLAG[@]}" "${ORAS_AUTH_FLAG[@]}" "${QUAY_HOST}/${OCI_ORG}/${chart}" 2>"${err}")" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    is_not_found "$(cat "${err}")" || { echo "oras: $(tail -n1 "${err}")"; return 1; }
    echo absent; return
  fi
  if grep -qx "${ver}" <<<"${tags}"; then echo listed; else echo absent; fi
}

# Hash names and bytes: Helm archive timestamps vary for identical chart content.
content_digest() {
  local d; d="$(mktemp -d "${WORKDIR}/digest.XXXXXX")"
  tar -xzf "$1" -C "${d}"
  (cd "${d}" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum | cut -d' ' -f1
}

push_tgz() {
  local tgz="$1" chart="$2" ver="$3" d have want herr state
  d="$(mktemp -d "${WORKDIR}/remote.XXXXXX")"
  if herr="$("${HELM}" pull "${DEST}/${chart}" --version "${ver}" -d "${d}" "${HELM_TLS_FLAG[@]}" 2>&1 >/dev/null)"; then
    have="$(content_digest "${d}/${chart}-${ver}.tgz")"
    want="$(content_digest "${tgz}")"
    [ "${have}" = "${want}" ] || die "${chart}:${ver} already exists in ${DEST} with DIFFERENT content (${have:0:12} != local ${want:0:12}). Published tags are never overwritten: bump the chart version."
    msg "  skip ${chart}:${ver} (already present, identical content ${want:0:12})"
    return
  fi
  if [ "${DRY_RUN}" = "true" ]; then
    msg "  DRY_RUN: would push ${chart}:${ver} -> ${DEST} if absent (helm pull: $(tail -n1 <<<"${herr}"))"
    return
  fi
  is_not_found "${herr}" || die "${chart}:${ver}: cannot tell whether the tag exists (helm pull: $(tail -n1 <<<"${herr}")); refusing to push. Fix registry access/TLS and re-run."
  state="$(tag_state "${chart}" "${ver}")" || die "${chart}:${ver}: cannot list tags (${state}); refusing to push. Fix registry access/TLS and re-run."
  [ "${state}" = "absent" ] || die "${chart}:${ver} exists in ${DEST} but cannot be pulled to compare; refusing to push over it."
  "${HELM}" push "${HELM_TLS_FLAG[@]}" "${tgz}" "${DEST}" >/dev/null
  msg "  pushed ${chart}:${ver} -> ${DEST}/${chart}:${ver}"
}

publish_built() {
  msg "== Charts from ${BUILD_DIR}/charts =="
  local dir name ver
  for dir in "${BUILD_DIR}"/charts/*/; do
    name="$(awk '/^name:/{print $2; exit}'    "${dir}Chart.yaml")"
    ver="$( awk '/^version:/{print $2; exit}' "${dir}Chart.yaml")"
    "${HELM}" package "${dir}" -d "${WORKDIR}" >/dev/null
    push_tgz "${WORKDIR}/${name}-${ver}.tgz" "${name}" "${ver}"
  done
}

publish_external() {
  msg "== Unmodified upstream charts from ${BUILD_DIR}/external =="
  local tgz n v
  for tgz in "${BUILD_DIR}"/external/*.tgz; do
    # From Chart.yaml: file names cannot be split when the version contains "-" (0.8.1-sovcore.3).
    read -r n v < <("${HELM}" show chart "${tgz}" | yq -r '.name + " " + .version')
    [ -n "${n}" ] && [ -n "${v}" ] || die "cannot read name/version from ${tgz}"
    push_tgz "${tgz}" "${n}" "${v}"
  done
}

main() {
  command -v oras >/dev/null || die "oras not found on PATH"
  [ -x "${HELM}" ] || command -v "${HELM}" >/dev/null || die "helm not found (${HELM})"

  msg "repo:      ${REPO_DIR}"
  msg "registry:  ${DEST}   (insecure-tls=${OCI_INSECURE})"
  [ "${OCI_INSECURE}" != "true" ] || warn "OCI_INSECURE=true: TLS verification of ${QUAY_HOST} is OFF (prefer OCI_CA_FILE)."
  msg "mode:      DRY_RUN=${DRY_RUN}"

  if [ "${DRY_RUN}" != "true" ]; then
    registry_login
    helm_registry_config
  else
    msg "DRY_RUN: skipping registry login."
  fi

  if [ "${SKIP_BUILD}" != "true" ]; then
    BUILD_DIR="${BUILD_DIR}" HELM="${HELM}" "${SCRIPT_DIR}/build-upstream.sh"
  fi
  [ -d "${BUILD_DIR}/charts" ] || die "no ${BUILD_DIR}/charts (run scripts/build-upstream.sh)"

  publish_built
  publish_external

  msg "Done. Published charts live under ${DEST}/<chart>:<version>."
}

main "$@"
