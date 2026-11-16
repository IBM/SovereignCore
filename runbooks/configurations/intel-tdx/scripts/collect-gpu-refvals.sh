#!/usr/bin/env bash
# Fetch and verify NVIDIA RIMs for RVPS; accepts RIM IDs as positional arguments.
# Prerequisites: curl, jq, python3 with lxml, openssl, xmlsec1; NVIDIA RIM and OCSP connectivity.
# Effects: Writes OUTPUT.
# Exit: 0 success; 1 verification failure.
# RIM signatures, pinned root, SHA256 and signer OCSP must verify before writing refvals.
# Refresh when guest driver, VBIOS or signer changes; the offline verifier cannot check revocation.
# ENV (name: meaning; default in parentheses)
#  DRIVER_VERSION  guest driver version (required unless RIM IDs are arguments)
#  VBIOS_VERSION  GPU VBIOS version (required unless RIM IDs are arguments)
#  INDEX_OFFSET  trustee measurement key = RIM index + INDEX_OFFSET  (1)
#  OUTPUT  output file  (~/.coco-pattern/gpu-reference-values.json)

set -euo pipefail

RIM_URL="${RIM_URL:-https://rim.attestation.nvidia.com/v1/rim}"
OCSP_URL="${OCSP_URL:-http://ocsp.ndis.nvidia.com}"
# NVIDIA CoRIM signing root: NVIDIA/nvtrust verifier_RIM_root.pem.
ROOT_SHA256="12:97:7B:51:15:AC:B0:38:11:79:27:9F:FF:EB:5A:8C:4D:26:49:71:EB:B3:22:98:02:3A:46:5F:A4:1D:F5:D1"
INDEX_OFFSET="${INDEX_OFFSET:-1}"
OUTPUT="${OUTPUT:-${HOME}/.coco-pattern/gpu-reference-values.json}"

msg() { printf '\033[1;34m[gpu-refvals]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[gpu-refvals] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for t in curl jq xmlsec1 openssl python3; do command -v "$t" >/dev/null || die "$t not found"; done
python3 -c 'import lxml' 2>/dev/null || die "python3 lxml not found"

W="$(mktemp -d /tmp/gpu-refvals.XXXXXX)"
trap 'rm -rf "$W"' EXIT

IDS=("$@")
if [ ${#IDS[@]} -eq 0 ]; then
  [ -n "${DRIVER_VERSION:-}" ] && [ -n "${VBIOS_VERSION:-}" ] || die "pass RIM IDs, or set DRIVER_VERSION and VBIOS_VERSION"
  IDS+=("NV_GPU_DRIVER_GH100_${DRIVER_VERSION}")
  vb="$(tr -d . <<<"${VBIOS_VERSION}" | tr '[:lower:]' '[:upper:]')"
  curl -fsS -m 60 "${RIM_URL}/ids" -o "$W/ids.json" || die "cannot list ${RIM_URL}/ids"
  mapfile -t m < <(jq -r --arg s "_${vb}" '.ids[] | select(startswith("NV_GPU_VBIOS_") and endswith($s))' "$W/ids.json")
  [ ${#m[@]} -eq 1 ] || die "VBIOS ${VBIOS_VERSION}: expected 1 RIM ID, found ${#m[@]} (${m[*]:-none}); pass the IDs explicitly"
  IDS+=("${m[0]}")
fi

echo '{}' > "$W/out.json"
for id in "${IDS[@]}"; do
  msg "== ${id}"
  d="$W/${id}"; mkdir -p "$d"
  curl -fsS -m 60 "${RIM_URL}/${id}" -o "$d/rim.json" || die "cannot fetch RIM ${id}"
  jq -r .rim "$d/rim.json" | base64 -d > "$d/rim.xml"
  [ "$(sha256sum < "$d/rim.xml" | cut -d' ' -f1)" = "$(jq -r .sha256 "$d/rim.json")" ] || die "${id}: sha256 mismatch"

  python3 - "$d" <<'EOF'
import sys
from lxml import etree
d = sys.argv[1]
certs = [e.text.strip() for e in etree.parse(d + "/rim.xml").getroot().iter()
         if etree.QName(e).localname == "X509Certificate"]
for i, c in enumerate(certs):
    open("%s/c%d.pem" % (d, i), "w").write("-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----\n" % c)
EOF
  n="$(ls "$d"/c*.pem | wc -l)"; root="$d/c$((n - 1)).pem"
  [ "$(openssl x509 -in "$root" -noout -fingerprint -sha256 | cut -d= -f2)" = "${ROOT_SHA256}" ] \
    || die "${id}: chain does not end at the pinned NVIDIA CoRIM root"

  xmlsec1 --verify --enabled-key-data x509 --trusted-pem "$root" "$d/rim.xml" >/dev/null 2>&1 \
    || die "${id}: RIM signature verification FAILED"
  msg "  signature OK (chain to pinned NVIDIA CoRIM root)"

  cat "$d"/c*.pem > "$d/chain.pem"
  for ((i = 0; i < n - 1; i++)); do
    out="$(openssl ocsp -issuer "$d/c$((i + 1)).pem" -cert "$d/c$i.pem" -url "${OCSP_URL}" \
           -CAfile "$root" -verify_other "$d/chain.pem" -no_nonce 2>&1)" || die "${id}: OCSP c$i failed: ${out}"
    grep -q "^$d/c$i.pem: good" <<<"$out" || die "${id}: OCSP c$i not good: ${out}"
    grep -q '^Response verify OK' <<<"$out" || die "${id}: OCSP c$i response not verified"
  done
  msg "  OCSP good for $((n - 1)) certs"

  python3 - "$d/rim.xml" "$id" "$INDEX_OFFSET" "$W/out.json" <<'EOF'
import json, re, sys
from lxml import etree
rim, rid, off, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
vals = json.load(open(out))
idx = []
for e in etree.parse(rim).getroot().iter():
    if etree.QName(e).localname != "Resource" or e.get("active") != "True":
        continue
    i = str(int(e.get("index")) + off)
    hashes = [v.lower() for k, v in e.attrib.items() if re.fullmatch(r"(\{.*\})?Hash\d+", k)]
    assert hashes, "no hashes for index %s" % i
    idx.append(i)
    vals["%s_m%s" % (rid, i)] = hashes
assert idx, "no active measurements in " + rid
vals[rid + "_indices"] = idx
json.dump(vals, open(out, "w"), indent=1, sort_keys=True)
print("  %d active measurements" % len(idx), file=sys.stderr)
EOF
done

mkdir -p "$(dirname "${OUTPUT}")"
install -m 600 "$W/out.json" "${OUTPUT}"
msg "wrote ${OUTPUT} ($(jq length "${OUTPUT}") reference values). Next: ONLY=gpuReferenceValues APPLY=true ./scripts/load-existing-vault.sh"

