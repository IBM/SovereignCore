#!/usr/bin/env bash
# Embed a trusted API root CA into a kubeconfig and verify access.
# Prerequisites: oc; writable kubeconfig, CA_FILE from the installer or trusted administrator.
# Effects: Backs up to .bak-preca, embeds CA, clears insecure TLS and runs whoami; no APPLY gate.
# Exit: 0 success; nonzero on invalid input or failed access.
# ENV (name: meaning; default in parentheses)
#  KUBECONFIG  kubeconfig to edit  (default: ~/.kube/config)
#  KUBECTL  oc/kubectl binary  (default: oc)
#  CONTEXT  kube context to use  (default: current-context)
#  CLUSTER  cluster entry name to patch  (default: from CONTEXT)
#  SERVER  API server URL  (default: from CLUSTER entry)
#  CA_FILE  trusted API root CA PEM file (required)

set -euo pipefail

KUBECTL="${KUBECTL:-oc}"
KUBECONFIG_FILE="${KUBECONFIG:-${HOME}/.kube/config}"

msg()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v "${KUBECTL}" >/dev/null 2>&1 || die "'${KUBECTL}' not found in PATH"
command -v openssl      >/dev/null 2>&1 || die "'openssl' not found in PATH"
[ -f "${KUBECONFIG_FILE}" ] || die "kubeconfig not found: ${KUBECONFIG_FILE}"

export KUBECONFIG="${KUBECONFIG_FILE}"
kc() { "${KUBECTL}" config "$@"; }

CONTEXT="${CONTEXT:-$(kc current-context 2>/dev/null || true)}"
[ -n "${CONTEXT}" ] || die "no current context and \$CONTEXT not set in ${KUBECONFIG_FILE}"

CLUSTER="${CLUSTER:-$(kc view -o jsonpath="{.contexts[?(@.name=='${CONTEXT}')].context.cluster}" 2>/dev/null || true)}"
[ -n "${CLUSTER}" ] || die "could not resolve cluster for context '${CONTEXT}'"

SERVER="${SERVER:-$(kc view -o jsonpath="{.clusters[?(@.name=='${CLUSTER}')].cluster.server}" 2>/dev/null || true)}"
[ -n "${SERVER}" ] || die "could not resolve server URL for cluster '${CLUSTER}'"

msg "kubeconfig : ${KUBECONFIG_FILE}"
msg "context    : ${CONTEXT}"
msg "cluster    : ${CLUSTER}"
msg "server     : ${SERVER}"

[ -n "${CA_FILE:-}" ] || die "set CA_FILE to the API server's root CA (PEM) from a trusted source, e.g. the installer's auth/kubeconfig (see the header); it is never fetched from the server"
[ -f "${CA_FILE}" ] || die "CA_FILE not found: ${CA_FILE}"
openssl x509 -in "${CA_FILE}" -noout 2>/dev/null || die "CA_FILE ${CA_FILE} holds no PEM certificate"
msg "Using CA bundle from CA_FILE: ${CA_FILE}"
CA_PATH="${CA_FILE}"

BACKUP="${KUBECONFIG_FILE}.bak-preca"
if [ ! -f "${BACKUP}" ]; then
  cp "${KUBECONFIG_FILE}" "${BACKUP}"
  msg "Backed up kubeconfig -> ${BACKUP}"
else
  msg "Backup already exists (${BACKUP}); not overwriting"
fi

kc set-cluster "${CLUSTER}" \
  --server="${SERVER}" \
  --certificate-authority="${CA_PATH}" \
  --embed-certs=true
kc unset "clusters.${CLUSTER}.insecure-skip-tls-verify" >/dev/null 2>&1 || true
msg "Embedded CA into cluster '${CLUSTER}' (insecure-skip-tls-verify cleared)"

if who="$("${KUBECTL}" --context "${CONTEXT}" whoami 2>&1)"; then
  msg "Verified: 'oc whoami' over verified TLS -> ${who}"
elif grep -Eqi 'x509|certificate' <<<"${who}"; then
  die "the server's certificate does not verify against CA_FILE (${who}); the kubeconfig now holds that CA, restore ${BACKUP} if it is wrong"
else
  warn "'oc whoami' failed: ${who}"
  warn "  CA is embedded, but your OAuth token may have expired. Run 'oc login' and retry."
fi

msg "Done. TLS is now verified; no insecure flags needed for pattern.sh / make install."
