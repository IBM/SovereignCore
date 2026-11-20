#!/usr/bin/env bash
# Mirror pinned catalogs and workload images, then prepare coco-prefixed cluster resources.
# Prerequisites: oc, oc-mirror v2; site config, registry credentials, CA trust and source connectivity.
# Effects: Mirrors unless SKIP_MIRROR=true; APPLY=true applies IDMS/ITMS and catalogs, triggering node reboots.
# Exit: 0 success; nonzero on configuration, mirroring or apply failure.
# ENV (name: meaning; default in parentheses)
#  SITE / SITE_ENV  site config (required; deploy/env/<site>/site.env)
#  MIRROR_HOME  SovereignCore mirror root  (default: site MIRROR_HOME)
#  OC / OC_MIRROR  hub client / oc-mirror binary (default: $MIRROR_HOME/bin/oc --kubeconfig=$HUB_KUBECONFIG, $MIRROR_HOME/bin/oc-mirror)
#  AUTHFILE  containers auth file  (default: $MIRROR_HOME/config/pull-secret.json)
#  QUAY_HOST  mirror registry host  (default: host of site MIRROR_REGISTRY)
#  QUAY_PORT  mirror registry port  (default: port of site MIRROR_REGISTRY)
#  CATALOG_VER  catalog tag  (default: v4.20)
#  WORKDIR  oc-mirror workspace  (default: $MIRROR_HOME/config/coco-pattern-workspace)
#  APPLY  true|false apply cluster-resources (default: false)
#  SKIP_MIRROR  skip mirroring, use generated cluster resources (false)
#  MIRROR_CA_FILE  CA bundle of the mirror registry (oc-mirror --dest-cert-dir) (site MIRROR_CA_FILE)
#  MIRROR_TLS_INSECURE  explicit opt-in: no TLS verification (warns)  (false)

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/site.sh"

OC="${OC:-${MIRROR_HOME}/bin/oc --kubeconfig=${HUB_KUBECONFIG}}"
OC_MIRROR="${OC_MIRROR:-${MIRROR_HOME}/bin/oc-mirror}"
AUTHFILE="${AUTHFILE:-${MIRROR_HOME}/config/pull-secret.json}"
QUAY_HOST="${QUAY_HOST:-${MIRROR_REGISTRY%:*}}"
QUAY_PORT="${QUAY_PORT:-${MIRROR_REGISTRY##*:}}"
CATALOG_VER="${CATALOG_VER:-v4.20}"
LOG_LEVEL="${LOG_LEVEL:-info}"
# Serialize blob uploads because concurrent uploads fail on LocalStorage-backed Quay.
PARALLEL_IMAGES="${PARALLEL_IMAGES:-10}"
PARALLEL_LAYERS="${PARALLEL_LAYERS:-1}"
RETRY_TIMES="${RETRY_TIMES:-10}"
RETRY_DELAY="${RETRY_DELAY:-10s}"
WORKDIR="${WORKDIR:-${MIRROR_HOME}/config/coco-pattern-workspace}"
APPLY="${APPLY:-false}"
SKIP_MIRROR="${SKIP_MIRROR:-false}"

DEST="docker://${QUAY_HOST}:${QUAY_PORT}"
ISC="${WORKDIR}/imagesetconfiguration.yaml"
CR_DIR="${WORKDIR}/working-dir/cluster-resources"

COMMUNITY_CATALOG="registry.redhat.io/redhat/community-operator-index:${CATALOG_VER}"
REDHAT_CATALOG="registry.redhat.io/redhat/redhat-operator-index:${CATALOG_VER}"
CERTIFIED_CATALOG="registry.redhat.io/redhat/certified-operator-index:${CATALOG_VER}"

msg()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for b in "${OC%% *}" "${OC_MIRROR}"; do command -v "${b}" >/dev/null 2>&1 || [ -x "${b}" ] || die "not executable: ${b}"; done
[ -f "${AUTHFILE}" ] || die "auth file not found: ${AUTHFILE} (set AUTHFILE)"

# Pin every package to prevent automatic subscriptions from upgrading on catalog refresh.
mkdir -p "${WORKDIR}"
cat > "${ISC}" <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
    - catalog: ${COMMUNITY_CATALOG}
      targetCatalog: redhat/community-operator-index-coco
      packages:
        - name: patterns-operator
          channels:
            - name: fast
              minVersion: "0.0.80"
              maxVersion: "0.0.80"
    - catalog: ${REDHAT_CATALOG}
      targetCatalog: redhat/redhat-operator-index-coco
      packages:
        - name: sandboxed-containers-operator
          channels:
            - name: stable
              minVersion: "1.13.1"
              maxVersion: "1.13.1"
        - name: trustee-operator
          channels:
            - name: stable
              minVersion: "1.2.1"
              maxVersion: "1.2.1"
        - name: nfd
          channels:
            - name: stable
              minVersion: "4.20.0-202608121308"
              maxVersion: "4.20.0-202608121308"
    - catalog: ${CERTIFIED_CATALOG}
      targetCatalog: redhat/certified-operator-index-coco
      packages:
        - name: intel-device-plugins-operator
          channels:
            - name: stable
              minVersion: "0.36.0"
              maxVersion: "0.36.0"
        # Runs QGS (offline platform registration); its operator and QGS images come with the bundle.
        - name: intel-tdx-dcap-operator
          defaultChannel: alpha
          channels:
            - name: alpha
              minVersion: "0.1.0"
              maxVersion: "0.1.0"
        # NVIDIA GPU Operator for confidential GPUs (H100/H200). Pinned to the
        # same CSV as coco-pattern/values-baremetal-gpu.yaml / deploy/spoke/values-baremetal-spoke-gpu.yaml.
        # Mirroring the operator PACKAGE pulls its bundle's relatedImages
        # (ccManager, vfio-manager, kata sandbox device plugin, gfd,
        # node-status-exporter, validator, cuda-validator) into the mirror -- the
        # host-side NVIDIA driver image is NOT needed because the confidential CC
        # path binds the GPU to vfio-pci and the driver runs INSIDE the kata guest
        # (ClusterPolicy driver.enabled=false).
        - name: gpu-operator-certified
          # upstream default is v26.7; oc-mirror rejects a subset without it
          defaultChannel: v26.3
          channels:
            - name: v26.3
              minVersion: "26.3.0"
              maxVersion: "26.3.0"
  additionalImages:
    # Sample charts (hello-openshift, kbs-access-curl); kbs-access-curl's init image is hardcoded :latest upstream
    - name: registry.redhat.io/ubi9/httpd-24@sha256:68a91ff691092f455fea682330c499588747231c16516cd4f35aff821e6847f2
    - name: registry.access.redhat.com/ubi9/ubi:latest
    - name: registry.redhat.io/openshift4/ose-node-feature-discovery-rhel9:${CATALOG_VER}
    # = INTEL_SGX_PLUGIN_SHA of intel-device-plugins-operator 0.36.0 (the operator rewrites the CR to it)
    - name: registry.connect.redhat.com/intel/intel-sgx-plugin@sha256:dd74e1f7436ca29b88843ecdd385021a5977da22531a5403920a7cc0f09f6cf6
    # ---- Images for the OCI-internalized charts (git-less deploy) ----
    # clusterGroup.imperative.image (imperative jobs runner)
    - name: ghcr.io/butler54/imperative-container@sha256:1885602ea5e2cc0052145ef33451a7003b9b6e523cfbf27bc94556f857682cd2
    # Kyverno chart 3.7.2 (appVersion v1.17.2) component images. reports-controller
    # is disabled via overrides but mirrored for completeness; readiness-checker
    # (test hook), kyverno-cli (crds.migration post-hook) and kubectl
    # (webhooks-cleanup hook) are used by the chart's hooks.
    - name: ghcr.io/kyverno/kyverno:v1.17.2
    - name: ghcr.io/kyverno/kyvernopre:v1.17.2
    - name: ghcr.io/kyverno/background-controller:v1.17.2
    - name: ghcr.io/kyverno/cleanup-controller:v1.17.2
    - name: ghcr.io/kyverno/reports-controller:v1.17.2
    - name: ghcr.io/kyverno/readiness-checker:v0.1.0
    - name: ghcr.io/kyverno/kyverno-cli:v1.17.2
    - name: registry.k8s.io/kubectl:v1.34.3
    # ---- GPU (confidential NVIDIA H100/H200) ----
    # Sample confidential-GPU workload image (coco-pattern/charts/coco-supported/gpu-workload):
    # bundles the CUDA vectorAdd sample + GPU CC verifier, runs in the kata guest.
    - name: quay.io/openshift_sandboxed_containers/gpu-verifier:ubi9
EOF
msg "Rendered ImageSetConfiguration -> ${ISC}"
sed 's/^/    /' "${ISC}"

if [ "${SKIP_MIRROR}" = "true" ]; then
  msg "SKIP_MIRROR=true: not mirroring, will only (re)apply cluster-resources."
else
  LOG="${WORKDIR}/oc-mirror.$(date +%Y%m%d-%H%M%S).log"
  . "$(dirname "${BASH_SOURCE[0]}")/lib/tls.sh"
  tls_ca MIRROR_CA_FILE MIRROR_TLS_INSECURE "the mirror registry ${QUAY_HOST}:${QUAY_PORT}"
  if [ -n "${TLS_CA}" ]; then
    CERT_DIR="$(mktemp -d)"; trap 'rm -rf "${CERT_DIR}"' EXIT
    cp "${TLS_CA}" "${CERT_DIR}/ca.crt"
    TLS_FLAGS=(--dest-cert-dir "${CERT_DIR}")
  else
    TLS_FLAGS=(--src-tls-verify=false --dest-tls-verify=false)   # MIRROR_TLS_INSECURE=true only
  fi
  msg "Mirroring CoCo pattern images -> ${DEST} (this can take a while; log: ${LOG})"
  "${OC_MIRROR}" --v2 \
    --log-level "${LOG_LEVEL}" \
    --authfile "${AUTHFILE}" \
    --ignore-release-signature \
    "${TLS_FLAGS[@]}" \
    --parallel-images "${PARALLEL_IMAGES}" \
    --parallel-layers "${PARALLEL_LAYERS}" \
    --retry-times "${RETRY_TIMES}" \
    --retry-delay "${RETRY_DELAY}" \
    -c "${ISC}" \
    --workspace "file://${WORKDIR}" \
    "${DEST}" 2>&1 | tee "${LOG}"
fi

[ -d "${CR_DIR}" ] || die "no cluster-resources at ${CR_DIR} (mirror may have failed; see log)"

msg "Generated cluster-resources:"
ls -1 "${CR_DIR}" | sed 's/^/    /'

if [ "${APPLY}" != "true" ]; then
  msg "APPLY=false: mirror complete, cluster NOT modified."
  msg "Review ${CR_DIR}/ then re-run with APPLY=true (IDMS/ITMS apply reboots control-plane nodes)."
  exit 0
fi

. "$(dirname "${BASH_SOURCE[0]}")/lib/cluster-guard.sh"
cluster_guard hub "${OC}"
warn "Applying IDMS/ITMS will trigger a ROLLING REBOOT of the control-plane nodes."

# Prefix mirror object names to avoid overwriting mappings owned by other deployments.
apply_renamed_mirrorset() {
  local f="$1"
  sed -E 's/^([[:space:]]{2}name:[[:space:]]*)((idms|itms)-)/\1coco-\2/' "${f}" | ${OC} apply -f -
}

for f in "${CR_DIR}"/idms-*.yaml "${CR_DIR}"/itms-*.yaml; do
  [ -f "${f}" ] || continue
  msg "oc apply (renamed to coco-*) -f ${f}"
  apply_renamed_mirrorset "${f}"
done
for f in "${CR_DIR}"/cs-*.yaml; do
  [ -f "${f}" ] || continue
  msg "oc apply -f ${f}"
  ${OC} apply -f "${f}"
  # The index tag moves on each mirror run but the spec does not change: recreate the pod to re-pull it.
  ${OC} delete pod -n openshift-marketplace -l "olm.catalogSource=$(basename "${f}" .yaml)" --ignore-not-found
done

msg "Applied. Verifying packagemanifests become available (catalog pods must start)..."
WANT="patterns-operator sandboxed-containers-operator trustee-operator nfd intel-device-plugins-operator intel-tdx-dcap-operator gpu-operator-certified"
for i in $(seq 1 30); do
  missing=""
  for p in ${WANT}; do
    ${OC} get packagemanifest "${p}" -n openshift-marketplace >/dev/null 2>&1 || missing="${missing} ${p}"
  done
  if [ -z "${missing}" ]; then
    msg "All expected packagemanifests are available."
    exit 0
  fi
  sleep 10
done
warn "Still missing:${missing}"
warn "Check the new CatalogSource pods: oc get pods -n openshift-marketplace"
