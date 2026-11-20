#!/usr/bin/env bash
# Assemble pinned upstream sources, overlays and patches into build/.
# Prerequisites: git, helm, mikefarah yq v4, tar; warm UPSTREAM_CACHE for OFFLINE=true.
# Effects: Recreates BUILD_DIR: charts/, external/, pattern/ and NOTICE; fills the source cache.
# Exit: 0 success; nonzero on missing sources, pin mismatch, invalid overlay or build failure.
# Overlay lists replace; new templates must not shadow upstream templates.
# ENV (name: meaning; default in parentheses)
#  UPSTREAM_CACHE  source cache  (${XDG_CACHE_HOME:-~/.cache}/intel-tdx-pattern/upstream)
#  BUILD_DIR  output dir  (<repo>/build)
#  OVERLAYS  chart overlays dir  (<repo>/overlays)
#  OFFLINE  use the cache only  (false)
#  HELM  helm binary  (helm)
#  YQ  mikefarah yq v4 binary  (yq)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCK="${REPO_DIR}/upstream/lock"
PATCHES="${REPO_DIR}/patches"
OVERLAYS="${OVERLAYS:-${REPO_DIR}/overlays}"
CACHE="${UPSTREAM_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/intel-tdx-pattern/upstream}"
OUT="${BUILD_DIR:-${REPO_DIR}/build}"
OFFLINE="${OFFLINE:-false}"
HELM="${HELM:-helm}"
YQ="${YQ:-yq}"

msg() { printf '\033[1;34m[build]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[build] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

lock() { awk -v n="$1" '$1 == n { print $2, $3, $4, $5; f = 1 } END { exit !f }' "${LOCK}" || die "${1} not in ${LOCK}"; }

fetch_git() {
  local type url ref sha dir
  read -r type url ref sha < <(lock "$1")
  dir="${CACHE}/git/$1.git"
  [ -d "${dir}" ] || git init -q --bare "${dir}"
  if ! git -C "${dir}" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    [ "${OFFLINE}" != "true" ] || die "OFFLINE: $1 ${ref} not in ${dir}"
    msg "fetch ${url} ${ref}"
    git -C "${dir}" fetch -q --depth 1 "${url}" "+refs/tags/${ref}:refs/tags/${ref}"
  fi
  [ "$(git -C "${dir}" rev-parse "refs/tags/${ref}^{commit}")" = "${sha}" ] \
    || die "$1 ${ref} is not ${sha}"
  echo "${dir}"
}

fetch_helm() {
  local type repo ver sha tgz
  read -r type repo ver sha < <(lock "$1")
  tgz="${CACHE}/helm/$1-${ver}.tgz"
  if [ ! -f "${tgz}" ]; then
    [ "${OFFLINE}" != "true" ] || die "OFFLINE: ${tgz} missing"
    msg "pull $1 ${ver} from ${repo}"
    mkdir -p "${CACHE}/helm"
    "${HELM}" pull "$1" --repo "${repo}" --version "${ver}" -d "${CACHE}/helm" >/dev/null
  fi
  echo "${sha}  ${tgz}" | sha256sum -c --quiet - >/dev/null 2>&1 || die "$1 ${ver}: sha256 mismatch (${tgz})"
  echo "${tgz}"
}

# Fixed tar metadata makes identical source pins produce identical archives.
sample_chart() {
  local base="$1" path="$2" git sha d n v
  git="$(fetch_git "${base}")"; read -r _ _ _ sha < <(lock "${base}")
  d="$(mktemp -d "${WORK}/sample.XXXXXX")"
  git -C "${git}" archive "${sha}:${path}" | tar -x -C "${d}"
  n="$("${YQ}" -r .name "${d}/Chart.yaml")"; v="$("${YQ}" -r .version "${d}/Chart.yaml")"
  [ "${n}" = "$(basename "${path}")" ] || die "${base}:${path} is chart ${n}, not $(basename "${path}")"
  mv "${d}" "${WORK}/${n}"
  tar -C "${WORK}" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - "${n}" \
    | gzip -n > "${OUT}/external/${n}-${v}.tgz"
  rm -rf "${WORK:?}/${n}"
  msg "  sample ${n} ${v} (${base} ${path})"
}

apply_patch() {
  git -C "$1" init -q
  git -C "$1" apply --check --whitespace=nowarn "$2" || die "does not apply: ${2#"${REPO_DIR}/"}"
  git -C "$1" apply --whitespace=nowarn "$2"
  rm -rf "$1/.git"
  msg "  applied ${2#"${REPO_DIR}/"}"
}

apply_patches() {
  local dir="$1" t p; shift
  for t in "$@"; do
    for p in "${PATCHES}/${t}"/*.patch; do apply_patch "${dir}" "${p}"; done
  done
}

overlay_chart() {
  local n="$1" up="$2" o="${OVERLAYS}/$1" dst="${OUT}/charts/$1" f
  [ -d "${o}" ] || die "no overlay ${o#"${REPO_DIR}/"}"
  while IFS= read -r f; do
    case "${f}" in Chart.yaml|values.yaml|upstream.patch|templates/*) ;;
      *) die "overlays/${n}/${f}: an overlay holds only Chart.yaml, values.yaml, upstream.patch, templates/" ;; esac
  done < <(cd "${o}" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
  cp -r "${up}" "${dst}"
  if [ -f "${o}/upstream.patch" ]; then
    ! grep -Eq '^(new|deleted) file mode|^rename (from|to) ' "${o}/upstream.patch" \
      || die "overlays/${n}/upstream.patch creates/deletes/renames files: new files belong in overlays/${n}/templates/"
    ! grep -Eq '^\+\+\+ b/(Chart|values)\.yaml$' "${o}/upstream.patch" \
      || die "overlays/${n}/upstream.patch edits Chart.yaml/values.yaml: use the overlay files"
    apply_patch "${dst}" "${o}/upstream.patch"
  fi
  if [ -d "${o}/templates" ]; then
    while IFS= read -r f; do
      [ ! -e "${up}/${f}" ] || die "overlays/${n}/${f} shadows the upstream ${f}: edit it in upstream.patch instead"
      mkdir -p "$(dirname "${dst}/${f}")"; cp "${o}/${f}" "${dst}/${f}"
    done < <(cd "${o}" && find templates -type f | LC_ALL=C sort)
  fi
  local k
  for k in Chart values; do
    [ ! -f "${o}/${k}.yaml" ] || "${YQ}" -i ". *= load(\"${o}/${k}.yaml\")" "${dst}/${k}.yaml"
  done
  msg "  overlaid overlays/${n}"
}

WORK=""
trap '[ -z "${WORK}" ] || rm -rf "${WORK}"' EXIT

main() {
  local work cp_git cp_sha t
  WORK="$(mktemp -d)"; work="${WORK}"

  msg "coco-pattern"
  cp_git="$(fetch_git coco-pattern)"
  read -r _ _ _ cp_sha < <(lock coco-pattern)
  mkdir "${work}/cp"
  git -C "${cp_git}" archive "${cp_sha}" LICENSE values-secret.yaml.template requirements.txt scripts/gen-secrets.sh \
    scripts/collect_firmware_refvals.py scripts/stage-tdx-measure.sh scripts/dcap-pck.py scripts/collect-dcap-collateral.sh \
    scripts/check-collateral-expiry.sh scripts/check-pck-expiry.sh \
    ansible/init-data-gzipper.yaml ansible/initdata-default.toml.tpl ansible/initdata-debug.toml.tpl \
    charts/all/baremetal charts/all/intel-dcap charts/all/coco-kyverno-policies charts/all/nvidia-gpu \
    | tar -x -C "${work}/cp"
  apply_patches "${work}/cp" ansible

  msg "trustee"
  mkdir "${work}/tr"
  tar -xzf "$(fetch_helm trustee)" -C "${work}/tr"
  rm -rf "${work}/tr/trustee/.git"

  rm -rf "${OUT}"
  mkdir -p "${OUT}/charts" "${OUT}/external" "${OUT}/pattern"
  for t in baremetal intel-dcap coco-kyverno-policies nvidia-gpu; do
    overlay_chart "${t}" "${work}/cp/charts/all/${t}"
  done
  overlay_chart trustee "${work}/tr/trustee"
  cp -rL "${REPO_DIR}"/charts/* "${OUT}/charts/"
  mkdir -p "${OUT}/charts/coco-initdata/files"
  cp "${work}"/cp/ansible/* "${OUT}/charts/coco-initdata/files/"
  (cd "${work}/cp" && cp -r LICENSE values-secret.yaml.template requirements.txt scripts ansible "${OUT}/pattern/")

  msg "external charts"
  for t in clustergroup acm sandboxed-containers sandboxed-policies kyverno; do
    cp "$(fetch_helm "${t}")" "${OUT}/external/"
  done
  sample_chart coco-pattern    charts/hub/storage
  sample_chart coco-pattern    charts/coco-supported/gpu-workload
  sample_chart coco-pattern    charts/coco-supported/hello-openshift
  sample_chart coco-pattern    charts/coco-supported/kbs-access-curl

  {
    echo "build/ contains modified and unmodified upstream works, licensed under the Apache"
    echo "License 2.0 (build/pattern/LICENSE). Files in build/charts/{trustee,baremetal,intel-dcap,"
    echo "coco-kyverno-policies,nvidia-gpu}, build/charts/coco-initdata/files and build/pattern were"
    echo "MODIFIED by IBM Sovereign Core with the overlays and patches below; build/external/*.tgz"
    echo "are unmodified."
    echo
    echo "Upstream bases (upstream/lock):"
    grep -v '^#' "${LOCK}" | awk 'NF { printf "  %-22s %s %s %s\n", $1, $3, $4, $5 }'
    echo
    echo "Overlays and patches:"
    (cd "${REPO_DIR}" && find overlays -type f | LC_ALL=C sort | xargs sha256sum | sed 's/^/  /' \
      && sha256sum patches/*/*.patch | sed 's/^/  /')
  } > "${OUT}/NOTICE"

  msg "done: ${OUT}"
}

main "$@"
