#!/usr/bin/env bash
# setup-metallb-pool-vmaas.sh
#
# Creates the MetalLB IPAddressPool and L2Advertisement on a VMaaS spoke cluster.
# This is the MSP-side setup step for VMaaS Clear Edition (externalIPMode=metallb-pool).
# Run once per VM cluster before provisioning VMs.
#
# Before applying anything, the script probes every address in POOL_RANGE from the
# machine it runs on and stops if any address shows signs of use on the network.
# MetalLB itself does not detect duplicate addresses.
#
# Design split:
#   MSP (this script):      IPAddressPool, L2Advertisement
#   vmaas-service-broker:   per-VM LoadBalancer Service with metallb.io/address-pool
#
# The vmaas-metallb-init ManifestWork that the hub deploys also creates a
# L2Advertisement (vmaas-l2-advertisement) using an ipAddressPoolSelectors label
# rule. This script creates a separate L2Advertisement that references the pool by
# name. Both can coexist; this script's advertisement is the operative one before
# the init ManifestWork is applied.
#
# Usage:
#   KUBECONFIG=/path/to/spoke.yaml ./setup-metallb-pool-vmaas.sh
#   KUBECONFIG=... POOL_RANGE="192.0.2.10-192.0.2.13" ./setup-metallb-pool-vmaas.sh
#   KUBECONFIG=... DRY_RUN=true ./setup-metallb-pool-vmaas.sh
#   POOL_RANGE=... CHECK_ONLY=true ./setup-metallb-pool-vmaas.sh   # probe only, no cluster access
#
# Prerequisites:
#   - kubectl in PATH (not needed with CHECK_ONLY=true)
#   - KUBECONFIG pointing directly to the spoke cluster (not the hub)
#   - MetalLB installed (script exits if CRDs are absent)
#   - Run the script from a host in the same L2 segment as the worker nodes, so that the
#     probes see the same neighbours that MetalLB would announce to.
#     Verify L2 route: `ip route get <worker-node-ip>` (should be direct, no "via <gw>").

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration -- override via env vars
# ---------------------------------------------------------------------------
POOL_NAME="${POOL_NAME:-vmaas}"
POOL_RANGE="${POOL_RANGE:-}"
METALLB_NAMESPACE="${METALLB_NAMESPACE:-metallb-system}"
# MANAGED_LABEL is required for vmaas-l2-advertisement (ipAddressPoolSelectors)
# deployed by the hub's vmaas-metallb-init ManifestWork.
MANAGED_LABEL="vmaas.sovereign-core.ibm.com/managed"
# EXTERNAL_ACCESS_LABEL is set on every per-VM LoadBalancer Service by vmaas-service-broker.
# serviceAllocation.serviceSelectors uses this to restrict the pool to VMaaS Services only.
EXTERNAL_ACCESS_LABEL="vmaas.sovereign.cloud.ibm.com/external-access"
DRY_RUN="${DRY_RUN:-false}"
# Address-in-use check
SKIP_ADDRESS_CHECK="${SKIP_ADDRESS_CHECK:-false}"   # true: do not probe at all
FORCE="${FORCE:-false}"                             # true: continue even if addresses answer
CHECK_ONLY="${CHECK_ONLY:-false}"                   # true: probe, print the result, exit
PROBE_TCP_PORTS="${PROBE_TCP_PORTS:-22 80 443}"     # TCP ports tried on each address
PROBE_TIMEOUT="${PROBE_TIMEOUT:-1}"                 # seconds per probe
PROBE_IFACE="${PROBE_IFACE:-}"                      # interface for arping (optional)
# Addresses that this cluster's MetalLB already hands out are not a conflict. They are
# read from the Services of the spoke cluster when a kubeconfig is available.
KNOWN_OWN_ADDRESSES="${KNOWN_OWN_ADDRESSES:-}"      # space separated, optional

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info() { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn() { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*"; }
die()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

apply_manifest() {
  local desc="$1"; shift
  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY RUN -- would apply: $desc"
    printf -- '---\n'
    cat
    printf -- '---\n'
  else
    info "Applying: $desc"
    kubectl apply -f -
  fi
}

# --- IPv4 helpers ----------------------------------------------------------
ip_to_int() {
  local IFS=.
  # shellcheck disable=SC2086
  set -- $1
  echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 ))
}

int_to_ip() {
  local n="$1"
  echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

valid_ip() {
  local ip="$1" o
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.
  for o in $ip; do (( o <= 255 )) || return 1; done
}

# Prints every address of POOL_RANGE, one per line. Accepts a.b.c.d-a.b.c.e or a.b.c.d/n.
expand_range() {
  local spec="$1" first last base bits mask
  if [[ "$spec" == */* ]]; then
    base="${spec%/*}"; bits="${spec#*/}"
    valid_ip "$base" && (( bits >= 0 && bits <= 32 )) || return 1
    mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    first=$(( $(ip_to_int "$base") & mask ))
    last=$(( first | (~mask & 0xFFFFFFFF) ))
  else
    valid_ip "${spec%-*}" && valid_ip "${spec#*-}" || return 1
    first=$(ip_to_int "${spec%-*}"); last=$(ip_to_int "${spec#*-}")
  fi
  (( first <= last )) || return 1
  (( last - first < 1024 )) || return 2   # refuse very large ranges
  local n
  for (( n = first; n <= last; n++ )); do int_to_ip "$n"; done
}

# --- address probes --------------------------------------------------------
# Each probe prints a short reason and returns 0 when the address answered.
probe_ping() {
  local ip="$1"
  if [[ "$(uname)" == "Darwin" ]]; then
    ping -c 1 -t "$PROBE_TIMEOUT" "$ip" > /dev/null 2>&1
  else
    ping -c 1 -W "$PROBE_TIMEOUT" "$ip" > /dev/null 2>&1
  fi
}

probe_tcp() {
  local ip="$1" port
  command -v nc > /dev/null 2>&1 || return 1
  for port in $PROBE_TCP_PORTS; do
    if nc -z -w "$PROBE_TIMEOUT" "$ip" "$port" > /dev/null 2>&1; then
      echo "$port"
      return 0
    fi
  done
  return 1
}

probe_arp() {
  local ip="$1"
  command -v arping > /dev/null 2>&1 || return 1
  local iface_opt=()
  [[ -n "$PROBE_IFACE" ]] && iface_opt=(-I "$PROBE_IFACE")
  # Sends two ARP requests and captures stdout+stderr.
  # Reply detection is done by text pattern because exit-code semantics differ between
  # arping implementations (iputils vs Thomas Habets). This script is tested with
  # iputils arping; Thomas Habets arping should also work via the 'reply from' pattern.
  local out
  out=$(arping -c 2 -w 3 "${iface_opt[@]}" "$ip" 2>&1 || true)
  grep -qiE 'Received [1-9][0-9]* response|reply from|bytes from' <<< "$out"
}

probe_rdns() {
  local ip="$1" name=""
  if command -v getent > /dev/null 2>&1; then
    name=$(getent hosts "$ip" 2>/dev/null | awk '{print $2}' | head -1)
  elif command -v dig > /dev/null 2>&1; then
    name=$(dig +short +time=2 +tries=1 -x "$ip" 2>/dev/null | head -1)
  elif command -v host > /dev/null 2>&1; then
    name=$(host -W 2 "$ip" 2>/dev/null | awk '/pointer/ {print $NF}' | head -1)
  fi
  name="${name%.}"
  [[ -n "$name" ]] || return 1
  echo "$name"
}

# Checks one address. Prints "ADDRESS<TAB>STATUS<TAB>EVIDENCE". STATUS is IN_USE,
# DNS_ONLY or NO_SIGN. Always returns 0 so that it is safe under set -e.
check_address() {
  local ip="$1" evidence=() port name
  if probe_ping "$ip"; then evidence+=("ping"); fi
  if port=$(probe_tcp "$ip"); then evidence+=("tcp/${port}"); fi
  if probe_arp "$ip"; then evidence+=("arp"); fi
  name=$(probe_rdns "$ip" || true)
  if (( ${#evidence[@]} > 0 )); then
    [[ -n "$name" ]] && evidence+=("rdns=${name}")
    printf '%s\tIN_USE\t%s\n' "$ip" "${evidence[*]}"
  elif [[ -n "$name" ]]; then
    printf '%s\tDNS_ONLY\trdns=%s\n' "$ip" "$name"
  else
    printf '%s\tNO_SIGN\t-\n' "$ip"
  fi
}

is_own_address() {
  local ip="$1" a
  for a in $KNOWN_OWN_ADDRESSES; do [[ "$a" == "$ip" ]] && return 0; done
  return 1
}

# Probes all addresses and prints a table. Returns 1 when any address is IN_USE or DNS_ONLY
# (and not one of this cluster's own addresses).
LAST_CHECK_IN_USE=0
LAST_CHECK_DNS_ONLY=0

run_address_check() {
  local range="$1" ip line status in_use=0 dns_only=0 total=0 no_sign=0 rc
  local addrs
  addrs=$(expand_range "$range") && rc=0 || rc=$?
  (( rc == 0 )) || die "Cannot expand POOL_RANGE '${range}' (rc=${rc}; ranges larger than 1024 addresses are refused)."

  echo ""
  info "Checking whether addresses in ${range} are already in use on the network ..."
  info "Probes: ping, TCP ports [${PROBE_TCP_PORTS}], ARP (if arping exists), reverse DNS."
  info "Run from a host in the same L2 segment as the worker nodes for a meaningful result."
  printf '  %-16s %-9s %s\n' "ADDRESS" "RESULT" "EVIDENCE"
  while read -r ip; do
    [[ -n "$ip" ]] || continue
    total=$(( total + 1 ))
    line=$(check_address "$ip")
    status=$(cut -f2 <<< "$line")
    if is_own_address "$ip"; then
      printf '  %-16s %-9s %s\n' "$ip" "OWN" "assigned to a Service of this cluster (skipped)"
      continue
    fi
    printf '  %-16s %-9s %s\n' "$ip" "$status" "$(cut -f3 <<< "$line")"
    case "$status" in
      IN_USE)   in_use=$(( in_use + 1 )) ;;
      DNS_ONLY) dns_only=$(( dns_only + 1 )) ;;
      *)        no_sign=$(( no_sign + 1 )) ;;
    esac
  done <<< "$addrs"
  echo ""
  info "Summary: ${total} address(es): ${in_use} IN_USE, ${dns_only} DNS_ONLY, ${no_sign} NO_SIGN."
  info "NO_SIGN means no probe was answered. It does not prove that the address is free:"
  info "a host may block ICMP and the probed TCP ports, or be on another segment."
  info "Confirm the range with the network owner before use."
  LAST_CHECK_IN_USE="$in_use"
  LAST_CHECK_DNS_ONLY="$dns_only"
  (( in_use + dns_only == 0 ))
}

# ---------------------------------------------------------------------------
# Step 0: Validate flags and POOL_RANGE format (before any cluster access)
# ---------------------------------------------------------------------------
if [[ "$CHECK_ONLY" == "true" && "$SKIP_ADDRESS_CHECK" == "true" ]]; then
  die "CHECK_ONLY=true and SKIP_ADDRESS_CHECK=true are mutually exclusive: no probes would run."
fi

if [[ -z "$POOL_RANGE" && "$CHECK_ONLY" == "true" ]]; then
  die "CHECK_ONLY=true needs POOL_RANGE."
fi

# Validate POOL_RANGE format and range sanity up front, even when SKIP_ADDRESS_CHECK=true,
# so that a bad range is caught before any cluster access or manifest generation.
if [[ -n "$POOL_RANGE" ]]; then
  OCTET_EARLY='[0-9]{1,3}'
  IP_PAT_EARLY="${OCTET_EARLY}\.${OCTET_EARLY}\.${OCTET_EARLY}\.${OCTET_EARLY}"
  if ! echo "$POOL_RANGE" | grep -qE "^${IP_PAT_EARLY}-${IP_PAT_EARLY}$|^${IP_PAT_EARLY}/[0-9]{1,2}$"; then
    die "POOL_RANGE '${POOL_RANGE}' is not valid. Use a.b.c.d-a.b.c.e or a.b.c.d/n"
  fi
  # Full octet and range-order validation via expand_range (also catches ranges >1024).
  _expand_rc=0
  expand_range "$POOL_RANGE" > /dev/null || _expand_rc=$?
  if (( _expand_rc != 0 )); then
    die "POOL_RANGE '${POOL_RANGE}' failed validation (rc=${_expand_rc}; check octet values, range order, and that range is <= 1024 addresses)."
  fi
fi

# ---------------------------------------------------------------------------
# Step 1: Validate KUBECONFIG
# ---------------------------------------------------------------------------
if [[ "$CHECK_ONLY" != "true" ]]; then
  [[ -n "${KUBECONFIG:-}" ]] || die "KUBECONFIG is not set. Point it to the spoke cluster kubeconfig."
  [[ -f "$KUBECONFIG" ]]     || die "KUBECONFIG file not found: $KUBECONFIG"
  info "Using kubeconfig: $KUBECONFIG"

  # -------------------------------------------------------------------------
  # Step 2: Verify spoke cluster connectivity
  # -------------------------------------------------------------------------
  info "Verifying spoke cluster connectivity ..."
  kubectl cluster-info --request-timeout=15s > /dev/null \
    || die "Cannot reach the spoke cluster. Check KUBECONFIG and network."
  info "Context: $(kubectl config current-context 2>/dev/null || echo '(no context name)')"

  # -------------------------------------------------------------------------
  # Step 3: Show node IPs to help choose the pool range
  # -------------------------------------------------------------------------
  echo ""
  info "Worker node IPs on the spoke cluster:"
  kubectl get nodes -o wide --no-headers \
    | awk '{printf "  %-55s  INTERNAL=%-16s  EXTERNAL=%s\n", $1, $6, $7}'
  echo ""

  # -------------------------------------------------------------------------
  # Step 4: Check MetalLB installation
  # -------------------------------------------------------------------------
  kubectl get crd ipaddresspools.metallb.io > /dev/null 2>&1 \
    || die "CRD ipaddresspools.metallb.io not found. Install MetalLB before running this script."

  kubectl get crd l2advertisements.metallb.io > /dev/null 2>&1 \
    || die "CRD l2advertisements.metallb.io not found. MetalLB installation may be incomplete."

  # The controller pod label depends on how MetalLB was installed:
  # "app.kubernetes.io/component=controller" (Helm chart) or "component=controller" (operator).
  count_running_pods() {
    kubectl get pods -n "${METALLB_NAMESPACE}" -l "$1" \
      --field-selector=status.phase=Running \
      -o name 2>/dev/null | wc -l | tr -d ' '
  }
  RUNNING_CONTROLLER=$(( $(count_running_pods "app.kubernetes.io/component=controller") \
    + $(count_running_pods "component=controller") ))

  if [[ "$RUNNING_CONTROLLER" -eq 0 ]]; then
    warn "No running MetalLB controller pod found in '${METALLB_NAMESPACE}'."
    warn "Resources will be created but MetalLB may not act on them until it is running."
  else
    info "MetalLB controller: ${RUNNING_CONTROLLER} pod(s) running in '${METALLB_NAMESPACE}'."
  fi
fi

# ---------------------------------------------------------------------------
# Step 5: Determine pool range
# ---------------------------------------------------------------------------
if [[ -z "$POOL_RANGE" ]]; then
  warn "POOL_RANGE is not set."
  warn "Choose addresses in the same L2 segment as the node IPs shown above."
  warn "Avoid node IPs, the cluster VIP, and any address used by another cluster or host"
  warn "on the same network. The address check below probes the range, but the network"
  warn "owner must confirm the range."
  warn "Accepted formats:"
  warn "  range: 192.0.2.10-192.0.2.13"
  warn "  CIDR:  192.0.2.8/30"
  echo ""
  read -rp "Enter POOL_RANGE: " POOL_RANGE
  [[ -n "$POOL_RANGE" ]] || die "POOL_RANGE cannot be empty."
fi

# POOL_RANGE was already validated in Step 0 when it was provided up front.
# If the user entered it interactively above, validate it now.
OCTET='[0-9]{1,3}'
IP_PAT="${OCTET}\.${OCTET}\.${OCTET}\.${OCTET}"
if ! echo "$POOL_RANGE" | grep -qE "^${IP_PAT}-${IP_PAT}$|^${IP_PAT}/[0-9]{1,2}$"; then
  die "POOL_RANGE '${POOL_RANGE}' is not valid. Use a.b.c.d-a.b.c.e or a.b.c.d/n"
fi
_expand_rc=0
expand_range "$POOL_RANGE" > /dev/null || _expand_rc=$?
if (( _expand_rc != 0 )); then
  die "POOL_RANGE '${POOL_RANGE}' failed validation (rc=${_expand_rc}; check octet values, range order, and that range is <= 1024 addresses)."
fi
info "Pool range: ${POOL_RANGE}"

# ---------------------------------------------------------------------------
# Step 5b: Check that the addresses are not already in use
# ---------------------------------------------------------------------------
if [[ "$SKIP_ADDRESS_CHECK" == "true" ]]; then
  warn "SKIP_ADDRESS_CHECK=true: addresses in ${POOL_RANGE} were NOT probed."
else
  # Addresses that this cluster's MetalLB already uses are not a conflict.
  if [[ "$CHECK_ONLY" != "true" ]] && [[ -z "$KNOWN_OWN_ADDRESSES" ]]; then
    KNOWN_OWN_ADDRESSES=$(kubectl get svc -A \
      -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' \
      2>/dev/null | sort -u | tr '\n' ' ' || true)
  fi
  if run_address_check "$POOL_RANGE"; then
    info "No address showed signs of use."
  else
    if [[ "$CHECK_ONLY" == "true" ]]; then
      warn "Some addresses show signs of use. See the table above."
      exit 2
    fi
    if [[ "$FORCE" == "true" ]]; then
      if (( LAST_CHECK_IN_USE > 0 )); then
        warn "DANGER: FORCE=true used while ${LAST_CHECK_IN_USE} active host(s) (IN_USE) were detected."
        warn "This will cause ARP conflicts and route SSH traffic to the wrong host."
      else
        warn "FORCE=true: continuing despite ${LAST_CHECK_DNS_ONLY} DNS-only record(s)."
      fi
    else
      if (( LAST_CHECK_IN_USE > 0 )); then
        die "Active host(s) detected in ${POOL_RANGE} (IN_USE). Choose a different range to prevent address conflicts."
      else
        die "DNS record(s) detected for ${POOL_RANGE} (DNS_ONLY). Confirm decommissioning with network owner, or re-run with FORCE=true (break-glass)."
      fi
    fi
  fi
fi
if [[ "$CHECK_ONLY" == "true" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 6: Show existing pools and warn about overlap
# ---------------------------------------------------------------------------
echo ""
info "Existing IPAddressPools in '${METALLB_NAMESPACE}':"
kubectl get ipaddresspool -n "${METALLB_NAMESPACE}" \
  -o custom-columns="NAME:.metadata.name,ADDRESSES:.spec.addresses,AUTO:.spec.autoAssign,ASSIGNED:.status.assignedIPv4,AVAILABLE:.status.availableIPv4" \
  2>/dev/null || echo "  (none)"
echo ""

if kubectl get ipaddresspool "${POOL_NAME}" -n "${METALLB_NAMESPACE}" > /dev/null 2>&1; then
  EXISTING=$(kubectl get ipaddresspool "${POOL_NAME}" \
    -n "${METALLB_NAMESPACE}" -o jsonpath='{.spec.addresses}' 2>/dev/null)
  warn "IPAddressPool '${POOL_NAME}' already exists (current: ${EXISTING})."
  warn "kubectl apply will update it to: ${POOL_RANGE}"
  warn "Services that already hold an address outside the new range keep it until they are recreated."
fi

# ---------------------------------------------------------------------------
# Step 7: Apply IPAddressPool
# ---------------------------------------------------------------------------
# Labels:
#   managed=true         -- picked up by vmaas-l2-advertisement (ipAddressPoolSelectors)
#                           that the hub's vmaas-metallb-init ManifestWork deploys.
#
# spec.autoAssign: false -- prevents MetalLB from assigning IPs to unrelated Services
#                           that don't carry the address-pool annotation.
#
# serviceAllocation.serviceSelectors:
#   Restricts this pool to Services with the external-access label.
#   vmaas-service-broker sets this label on every per-VM Service in pool mode.
#   Requires MetalLB v0.13.2 or later.
apply_manifest "IPAddressPool '${POOL_NAME}' (${POOL_RANGE})" <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${POOL_NAME}
  namespace: ${METALLB_NAMESPACE}
  labels:
    ${MANAGED_LABEL}: "true"
spec:
  addresses:
    - ${POOL_RANGE}
  autoAssign: false
  serviceAllocation:
    serviceSelectors:
      - matchLabels:
          ${EXTERNAL_ACCESS_LABEL}: "true"
EOF

# ---------------------------------------------------------------------------
# Step 8: Apply L2Advertisement
# ---------------------------------------------------------------------------
# Creates an L2Advertisement that references the pool by name.
#
# Note: the hub's vmaas-metallb-init ManifestWork also deploys a L2Advertisement
# (vmaas-l2-advertisement) that uses ipAddressPoolSelectors (label-based).
# This script creates a separate advertisement named after the pool. Both refer
# to the same pool and coexist safely; L2 can be announced by multiple advertisements.
# If this cluster runs without the init ManifestWork (standalone MSP setup),
# this advertisement alone is sufficient.
apply_manifest "L2Advertisement '${POOL_NAME}'" <<EOF
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${POOL_NAME}
  namespace: ${METALLB_NAMESPACE}
  labels:
    ${MANAGED_LABEL}: "true"
spec:
  ipAddressPools:
    - ${POOL_NAME}
EOF

# ---------------------------------------------------------------------------
# Step 9: Verify
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" != "true" ]]; then
  echo ""
  info "IPAddressPool status:"
  kubectl get ipaddresspool "${POOL_NAME}" -n "${METALLB_NAMESPACE}" \
    -o custom-columns="NAME:.metadata.name,ADDRESSES:.spec.addresses,AUTO:.spec.autoAssign,ASSIGNED:.status.assignedIPv4,AVAILABLE:.status.availableIPv4"

  echo ""
  info "L2Advertisement status:"
  kubectl get l2advertisement -n "${METALLB_NAMESPACE}" \
    -o custom-columns="NAME:.metadata.name,POOLS:.spec.ipAddressPools,SELECTORS:.spec.ipAddressPoolSelectors"

  echo ""
  info "Done. Checklist before provisioning VMs:"
  printf '  1. The MetalLB controller runs with the load balancer class "metallb"\n'
  printf '     (argument --lb-class=metallb). Per-VM Services use loadBalancerClass: metallb.\n'
  printf '  2. VMServiceBrokerConfig CR on the hub:\n'
  printf '       spec.metallb.externalIPMode: metallb-pool\n'
  printf '       spec.metallb.addressPoolName: %s\n' "${POOL_NAME}"
  printf '     (metallb-pool is the default on Clear Edition)\n'
  printf '  3. The pool range was confirmed with the network owner\n'
  printf '     (see setting-up-metallb-pool-for-clear-edition.md: Choosing an IP range)\n'
  echo ""
fi
