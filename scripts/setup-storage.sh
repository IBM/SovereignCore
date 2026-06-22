#!/bin/bash

################################################################################
# setup-storage.sh
#
# Storage Admin Script — Works with Native Ceph or ODF
# BLOCK AND OBJECT STORAGE WITH HTTPS/TLS SUPPORT
#
# Purpose:
#   Provisions isolated Ceph storage for multi-tenant/control plane:
#   - Block storage (RBD) for PVCs
#   - Object storage (RGW) for S3-compatible storage via NooBaa
#   - HTTPS/TLS support with CA certificate validation and auto-extraction
#
# What this script does (8 phases):
#   1. Pre-flight checks     — verify Ceph access, health, tools
#   2. Ceph health check     — ceph status must be HEALTH_OK or HEALTH_WARN
#   3. Create RBD pool       — <tenant>-rbd-pool with PG count and quota
#   4. Create Ceph users     — client.<tenant> + CSI users for RBD
#   5. Create RGW user       — RGW user in main RGW for object storage (optional)
#                            — CA certificate handling (validation, auto-extraction)
#   6. Create backing bucket — S3 bucket for NooBaa BackingStore (optional)
#   7. Generate config       — run create-external-cluster-resources.py or manual config
#   8. Save artifacts        — write JSON to output dir
#
# Usage:
#   ./setup-storage.sh --tenant TENANT_NAME --rbd-quota SIZE [OPTIONS]
#
# Examples:
#   # Block storage only
#   ./setup-storage.sh --tenant customer-a --rbd-quota 1T --mode odf --output-dir ~/ceph-configs
#
#   # Block + Object storage (HTTP)
#   ./setup-storage.sh --tenant dev-team --rbd-quota 500G --rgw-user-quota 1T --mode odf --output-dir ~/odf-configs
#
#   # Block + Object storage with HTTPS and custom CA bundle
#   ./setup-storage.sh --tenant prod-app --rbd-quota 2T --rgw-user-quota 5T \
#     --ca-bundle-path /path/to/ca-bundle.crt --mode odf --output-dir ~/prod-configs
#
#   # Block + Object storage with HTTPS auto-extraction
#   ./setup-storage.sh --tenant staging --rbd-quota 1T --rgw-user-quota 2T \
#     --rgw-region us-east-1 --mode odf --output-dir ~/staging-configs
#
#   # Block + Object storage with custom region and CA bundle
#   ./setup-storage.sh --tenant prod-eu --rbd-quota 2T --rgw-user-quota 5T \
#     --rgw-region eu-west-1 --ca-bundle-path /etc/ssl/certs/company-ca.crt \
#     --mode odf --output-dir ~/prod-configs
#
# HTTPS/TLS Features:
#   - Custom CA bundle support via --ca-bundle-path
#   - Automatic CA certificate extraction from HTTPS endpoints
#   - Certificate validation (structure, expiry, endpoint verification)
#   - Support for self-signed, enterprise CA, and public CA certificates
#   - Certificate chain handling
#   - 30-day expiry warnings
#
# Prerequisites:
#   Native Ceph Mode:
#     - Direct access to Ceph cluster (ceph command available)
#     - Ceph admin credentials configured
#
#   ODF Mode:
#     - oc CLI installed and logged into the ODF provider cluster
#     - ODF StorageCluster in Ready phase
#     - Rook toolbox pod running
#
#   HTTPS/TLS (Optional):
#     - openssl command (for certificate validation and extraction)
#     - Network access to RGW endpoint (for auto-extraction)
#     - CA certificate bundle in PEM format (if using --ca-bundle-path)
################################################################################

set -euo pipefail

###############################################################################
# DEFAULTS
###############################################################################
TENANT_NAME=""
RBD_QUOTA=""
RGW_USER_QUOTA=""
POOL_PGS=128
AUTO_CALCULATE_PG=false
INTERACTIVE_PG=false
USE_AUTOSCALING=false
POOL_TARGET_RATIO=""
TARGET_PGS_PER_OSD=128  # Ceph recommendation: 100-200 PGs per OSD
OUTPUT_DIR=""
MODE="native"  # native or odf
NAMESPACE=""  # Will be auto-detected for ODF mode
STORAGECLUSTER_NAME=""  # Will be auto-detected
TOOLBOX_POD=""
STATE_FILE=""
LOG_FILE=""
START_PHASE=1
RESUME_MODE=false
UPDATE_MODE=false
DELETE_MODE=false
LOG_LEVEL="INFO"
CEPH_MON_HOST=""
CEPH_FSID=""
RGW_REGION=""  # Will be set based on deployment or default to "default"
RGW_PROTOCOL="http"
MAIN_RGW_ENDPOINT=""
ENABLE_OBJECT_STORAGE=false
CUSTOM_CA_BUNDLE_PATH=""  # Path to custom CA certificate bundle
CA_BUNDLE_TYPE=""  # Type of CA bundle: custom, extracted-chain, extracted-self-signed, manual-placeholder, http-placeholder
CERT_EXPIRY_WARNING_DAYS=30  # Warn if certificate expires within this many days

###############################################################################
# COLOR AND FORMATTING
###############################################################################
# Modern color palette for terminal automation scripts
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
  readonly COLOR_RESET="$(tput sgr0)"
  
  # Errors / Critical
  readonly COLOR_RED="$(tput setaf 196 2>/dev/null || tput setaf 1)"
  
  # Success
  readonly COLOR_GREEN="$(tput setaf 46 2>/dev/null || tput setaf 2)"
  
  # Warnings
  readonly COLOR_YELLOW="$(tput setaf 220 2>/dev/null || tput setaf 3)"
  
  # Highlights / Important Information
  readonly COLOR_ORANGE="$(tput setaf 214 2>/dev/null || tput setaf 3)"
  
  # Main headers / banners
  readonly COLOR_BLUE="$(tput setaf 39 2>/dev/null || tput setaf 4)"
  
  # Phase titles / section separators
  readonly COLOR_CYAN="$(tput setaf 51 2>/dev/null || tput setaf 6)"
  
  # User prompts / interactive questions
  readonly COLOR_MAGENTA="$(tput setaf 213 2>/dev/null || tput setaf 5)"
  
  # Secondary information
  readonly COLOR_GRAY="$(tput setaf 245 2>/dev/null || echo "")"
  
  # Info messages / general text
  readonly COLOR_WHITE="$(tput setaf 15 2>/dev/null || tput setaf 7)"
  
  readonly COLOR_BOLD="$(tput bold)"
  readonly COLOR_DIM="$(tput dim 2>/dev/null || echo "")"
else
  readonly COLOR_RESET=""
  readonly COLOR_RED=""
  readonly COLOR_GREEN=""
  readonly COLOR_YELLOW=""
  readonly COLOR_ORANGE=""
  readonly COLOR_BLUE=""
  readonly COLOR_CYAN=""
  readonly COLOR_MAGENTA=""
  readonly COLOR_GRAY=""
  readonly COLOR_WHITE=""
  readonly COLOR_BOLD=""
  readonly COLOR_DIM=""
fi

# Legacy color codes for backward compatibility
RED="${COLOR_RED}"
GREEN="${COLOR_GREEN}"
YELLOW="${COLOR_YELLOW}"
BLUE="${COLOR_BLUE}"
CYAN="${COLOR_CYAN}"
BOLD="${COLOR_BOLD}"
NC="${COLOR_RESET}"

###############################################################################
# LOGGING FUNCTIONS
###############################################################################
get_log_level_value() {
    case "$1" in
        DEBUG)   echo 0 ;;
        INFO)    echo 1 ;;
        WARNING) echo 2 ;;
        ERROR)   echo 3 ;;
        *)       echo 1 ;;
    esac
}

require_cmd() {
    local cmd="$1"
    local install_hint="${2:-}"
    if ! command -v "$cmd" &>/dev/null; then
        print_error "Required command not found: ${cmd}"
        if [ -n "$install_hint" ]; then
            print_error "$install_hint"
        fi
        exit 1
    fi
}

log_to_file() {
    [[ -n "${LOG_FILE:-}" ]] || return 0
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" >> "$LOG_FILE"
}

should_log() {
    local current_level
    current_level=$(get_log_level_value "$LOG_LEVEL")
    local message_level
    message_level=$(get_log_level_value "$1")
    [ "$message_level" -ge "$current_level" ]
}

_log_raw() {
  local level="$1"
  local color="$2"
  local symbol="$3"
  shift 3
  local msg="$*"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  # Console output
  if should_log "$level"; then
    printf "${color}${COLOR_BOLD}[%s]${COLOR_RESET} ${color}%s %s${COLOR_RESET}\n" \
      "${timestamp}" "${symbol}" "${msg}"
  fi
  
  # File output (no colors)
  log_to_file "${level}: ${msg}"
}

print_debug()   { if should_log "DEBUG";   then _log_raw "DEBUG" "${COLOR_DIM}" "·" "$@"; else log_to_file "DEBUG: $*"; fi; }
print_info()    { if should_log "INFO";    then _log_raw "INFO" "${COLOR_WHITE}" "ℹ" "$@"; else log_to_file "INFO: $*"; fi; }
print_success() { if should_log "INFO";    then _log_raw "OK" "${COLOR_GREEN}" "✅" "$@"; else log_to_file "SUCCESS: $*"; fi; }
print_warning() { if should_log "WARNING"; then _log_raw "WARN" "${COLOR_YELLOW}" "⚠" "$@" >&2; else log_to_file "WARNING: $*"; fi; }
print_error()   { if should_log "ERROR";   then _log_raw "ERROR" "${COLOR_RED}" "✘" "$@" >&2; else log_to_file "ERROR: $*"; fi; }
print_header()  { if should_log "INFO"; then echo "${COLOR_BOLD}${COLOR_BLUE}$*${COLOR_RESET}"; fi; log_to_file "HEADER: $*"; }

###############################################################################
# PROGRESS BAR HELPER
###############################################################################
show_progress_bar() {
    local description="$1"
    local timeout="$2"
    local elapsed=0
    
    while [ "$elapsed" -lt "$timeout" ]; do
        if [ -t 1 ]; then
            local progress=$((elapsed * 100 / timeout))
            local bar_width=30
            local filled=$((progress * bar_width / 100))
            local empty=$((bar_width - filled))
            
            printf "\r${COLOR_CYAN}  %s [" "${description}"
            printf "%${filled}s" | tr ' ' '█'
            printf "%${empty}s" | tr ' ' '░'
            printf "] %d%% (%ds/%ds)${COLOR_RESET}" "$progress" "$elapsed" "$timeout"
        fi
        
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    # Clear progress bar line
    if [ -t 1 ]; then
        printf "\r%*s\r" 100 ""
    fi
}

###############################################################################
# STATE MANAGEMENT
###############################################################################
save_phase() {
    cat > "$STATE_FILE" <<STATE
$1
${TENANT_NAME}
${RBD_QUOTA}
${RGW_USER_QUOTA}
${POOL_PGS}
${OUTPUT_DIR}
${MODE}
${NAMESPACE}
${STORAGECLUSTER_NAME}
${RGW_REGION}
${ENABLE_OBJECT_STORAGE}
${ENABLE_BLOCK_STORAGE}
${CUSTOM_CA_BUNDLE_PATH}
STATE
    print_debug "State saved: phase=$1 tenant=${TENANT_NAME} mode=${MODE}"
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        START_PHASE=$(sed -n '1p' "$STATE_FILE")
        TENANT_NAME=$(sed -n '2p' "$STATE_FILE")
        RBD_QUOTA=$(sed -n '3p' "$STATE_FILE")
        RGW_USER_QUOTA=$(sed -n '4p' "$STATE_FILE")
        POOL_PGS=$(sed -n '5p' "$STATE_FILE")
        OUTPUT_DIR=$(sed -n '6p' "$STATE_FILE")
        MODE=$(sed -n '7p' "$STATE_FILE")
        NAMESPACE=$(sed -n '8p' "$STATE_FILE")
        STORAGECLUSTER_NAME=$(sed -n '9p' "$STATE_FILE")
        RGW_REGION=$(sed -n '10p' "$STATE_FILE")
        ENABLE_OBJECT_STORAGE=$(sed -n '11p' "$STATE_FILE")
        ENABLE_BLOCK_STORAGE=$(sed -n '12p' "$STATE_FILE")
        CUSTOM_CA_BUNDLE_PATH=$(sed -n '13p' "$STATE_FILE")
        [ -z "$LOG_LEVEL" ] && LOG_LEVEL="INFO"
        [ -z "$RGW_REGION" ] && RGW_REGION="default"
        [ -z "$ENABLE_OBJECT_STORAGE" ] && ENABLE_OBJECT_STORAGE=false
        [ -z "$ENABLE_BLOCK_STORAGE" ] && ENABLE_BLOCK_STORAGE=false
        return 0
    fi
    return 1
}

should_skip_phase() { [ "$1" -lt "$START_PHASE" ]; }

###############################################################################
# ARGUMENT PARSING
###############################################################################
while [[ $# -gt 0 ]]; do
    case $1 in
        --tenant)
            TENANT_NAME="$2"; shift 2 ;;
        --rbd-quota)
            RBD_QUOTA="$2"; shift 2 ;;
        --rgw-user-quota)
            RGW_USER_QUOTA="$2"
            ENABLE_OBJECT_STORAGE=true
            shift 2 ;;
        --pool-pgs)
            POOL_PGS="$2"; shift 2 ;;
        --auto-calculate-pgs)
            AUTO_CALCULATE_PG=true; shift ;;
        --interactive-pgs)
            INTERACTIVE_PG=true; shift ;;
        --enable-autoscaling)
            USE_AUTOSCALING=true; shift ;;
        --pool-target-ratio)
            POOL_TARGET_RATIO="$2"; shift 2 ;;
        --target-pgs-per-osd)
            TARGET_PGS_PER_OSD="$2"; shift 2 ;;
        --output-dir)
            OUTPUT_DIR="$2"; shift 2 ;;
        --mode)
            MODE="$2"
            if ! [[ "$MODE" =~ ^(native|odf)$ ]]; then
                echo "ERROR: Invalid mode: $2. Must be 'native' or 'odf'" >&2
                exit 1
            fi
            shift 2 ;;
        --namespace)
            NAMESPACE="$2"; shift 2 ;;
        --storagecluster)
            STORAGECLUSTER_NAME="$2"; shift 2 ;;
        --region|--rgw-region)
            RGW_REGION="$2"; shift 2 ;;
        --ca-bundle-path)
            CUSTOM_CA_BUNDLE_PATH="$2"; shift 2 ;;
        --resume)
            RESUME_MODE=true; shift ;;
        --phase)
            START_PHASE="$2"; shift 2 ;;
        --log-level)
            LOG_LEVEL=$(echo "$2" | tr '[:lower:]' '[:upper:]')
            if ! [[ "$LOG_LEVEL" =~ ^(DEBUG|INFO|WARNING|ERROR)$ ]]; then
                echo "ERROR: Invalid log level: $2" >&2
                exit 1
            fi
            shift 2 ;;
        --update)
            UPDATE_MODE=true; shift ;;
        --delete)
            DELETE_MODE=true; shift ;;
        --help|-h)
            echo -e "
${COLOR_BOLD}setup-storage.sh${COLOR_RESET} — Native Ceph / ODF Provisioning (Block and Object Storage)

${COLOR_BOLD}USAGE${COLOR_RESET}
  $0 --tenant TENANT_NAME --rbd-quota SIZE --output-dir PATH --mode MODE [OPTIONS]
  $0 --resume --output-dir PATH

${COLOR_BOLD}REQUIRED${COLOR_RESET}
  --tenant NAME           Tenant identifier (lowercase, alphanumeric, hyphens)
  --rbd-quota SIZE        RBD pool quota (e.g., 1T, 500G, 2048M)
                          Required for block storage and NooBaa PostgreSQL PVC
  --output-dir PATH       Secure directory for output files (REQUIRED for security)
                          Example: ~/ceph-configs or /secure/storage-configs
                          Never use /tmp or other world-accessible directories
  --mode MODE             Deployment mode: 'native' or 'odf' (default: native)
                          native: Direct Ceph cluster access
                          odf: OpenShift Data Foundation / Rook

${COLOR_BOLD}OBJECT STORAGE (OPTIONAL)${COLOR_RESET}
  --rgw-user-quota SIZE   Enable object storage and set RGW user quota
                          Example: --rgw-user-quota 1T
                          Creates RGW user in main RGW for NooBaa backend
                          Note: Requires --rbd-quota for NooBaa PostgreSQL PVC
  --region REGION         S3 region for RGW (default: us-east-1)
  --rgw-region REGION     Alias for --region

${COLOR_BOLD}HTTPS/TLS OPTIONS${COLOR_RESET}
  --ca-bundle-path PATH   Path to custom CA certificate bundle for HTTPS endpoints
                          Supports PEM format with single or multiple certificates
                          If not provided, will attempt auto-extraction from endpoint

${BOLD}PG COUNT OPTIONS${NC}
  --pool-pgs NUM          Manual PG count (default: 128)
                          Specify exact number of Placement Groups for the pool
  --auto-calculate-pgs    Automatically calculate optimal PG count
                          Analyzes cluster size and recommends appropriate value
  --interactive-pgs       Interactive PG count selection with guidance
                          Shows recommendations and lets you choose
  --enable-autoscaling    Enable Ceph PG autoscaling (recommended)
                          Lets Ceph automatically manage PG count based on data usage
  --pool-target-ratio NUM Target size ratio for autoscaler (0.0-1.0)
                          Percentage of cluster capacity this pool should use
  --target-pgs-per-osd NUM Target PGs per OSD (default: 128)
                          Used in automatic PG calculation (range: 100-200)

${BOLD}PG COUNT GUIDANCE${NC}
  The script can help you choose the right PG count for your cluster:
  
  ${GREEN}Recommended approaches:${NC}
    • Use ${CYAN}--auto-calculate-pgs${NC} for automatic calculation based on cluster size
    • Use ${CYAN}--interactive-pgs${NC} for guided selection with detailed recommendations
    • Use ${CYAN}--enable-autoscaling${NC} to let Ceph manage PG count automatically (best for production)
  
  ${YELLOW}Manual configuration:${NC}
    • Use ${CYAN}--pool-pgs${NC} only if you have specific requirements or expertise
    • PG count must be a power of 2 (8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096)
    • Target: 100-200 PGs per OSD across all pools in the cluster
  
  ${BOLD}Why PG count matters:${NC}
    Too few PGs  → Poor data distribution, performance bottlenecks
    Too many PGs → Increased overhead, slower recovery operations

${BOLD}OTHER OPTIONS${NC}
  --namespace NS          ODF namespace (auto-detected for ODF mode, ODF mode only)
                          Override auto-detection if multiple namespaces exist
  --storagecluster NAME   StorageCluster name (auto-detected, can be overridden)
                          Specify if auto-detection fails or to use a different cluster
  --resume                Resume from last failed phase
  --phase NUM             Start from specific phase (1-8)
  --log-level LEVEL       DEBUG | INFO | WARNING | ERROR (default: INFO)
  --update                Update tenant storage configuration (quotas, regenerate config)
                          Preserves existing data, updates quotas if specified
                          Requires: --tenant, --output-dir, --mode
                          Optional: --rbd-quota, --rgw-user-quota (to update quotas)
  --delete                Delete tenant storage (requires --tenant, --output-dir, --mode)
                          ⚠️  WARNING: This permanently deletes ALL tenant data
                          Includes customer notification prompts and confirmations
  --help                  Show this help

${COLOR_BOLD}EXAMPLES${COLOR_RESET}
  # Block storage only (auto-detects namespace and storage cluster)
  $0 --tenant customer-a --rbd-quota 1T --output-dir ~/ceph-configs --mode odf
  
  # Block + Object storage (auto-detects namespace and storage cluster)
  $0 --tenant dev-team --rbd-quota 500G --rgw-user-quota 1T --output-dir ~/odf-configs --mode odf
  
  # Update tenant quotas
  $0 --tenant customer-a --rbd-quota 2T --rgw-user-quota 2T --output-dir ~/ceph-configs --mode odf --update
  
  # Block storage with manual namespace/cluster override
  $0 --tenant prod-app --rbd-quota 2T --output-dir ~/prod-configs --mode odf \
     --namespace custom-storage --storagecluster my-cluster

  
  # Resume from failure
  $0 --resume --output-dir ~/odf-configs
  
  # Delete tenant storage (with customer warning prompts)
  $0 --tenant customer-a --output-dir ~/ceph-configs --mode odf --delete

${COLOR_BOLD}SECURITY${COLOR_RESET}
  - Always set umask 077 before running this script
  - Use a secure, non-shared directory for --output-dir
  - The <tenant>-external-config.json file should be handed over to the control plane or LOB Admin UI

${COLOR_BOLD}ARCHITECTURE${COLOR_RESET}
  Storage Cluster:
    - RBD Pool: <tenant>-rbd-pool (tenant-specific, with quota)
    - Ceph Users: client.<tenant> + CSI users for RBD
    - RGW User: <tenant>-noobaa-user (if object storage enabled)
    - Backing Bucket: <tenant>-backing-bucket (if object storage enabled)

  Tenant Cluster (configured via LOB Admin UI):
    - Ceph CSI drivers for block storage
    - StorageClass → uses RBD CSI provisioner
    - NooBaa → BackingStore pointing to main RGW (if object storage enabled)
"
            exit 0 ;;
        *)
            echo "ERROR: Unknown option: $1. Use --help for usage." >&2
            exit 1 ;;
    esac
done
###############################################################################
# PG COUNT HELPER FUNCTIONS
###############################################################################

# Validate if a number is a power of 2
is_power_of_two() {
    local n=$1
    [ "$n" -gt 0 ] 2>/dev/null && [ $((n & (n - 1))) -eq 0 ]
}

# Calculate optimal PG count based on cluster configuration
calculate_pg_count() {
    print_debug "Calculating optimal PG count..."
    
    # Get total number of OSDs
    local total_osds
    total_osds=$(ceph_exec ceph osd stat -f json 2>/dev/null | jq -r '.num_osds' 2>/dev/null || echo "0")
    
    if [ "$total_osds" -eq 0 ] || [ -z "$total_osds" ]; then
        print_warning "Unable to determine OSD count, using default PG count"
        echo "128"
        return
    fi
    
    print_debug "Total OSDs in cluster: ${total_osds}"
    
    # Get replication size (default 3 for most pools)
    local replica_size=3
    
    # Get number of existing pools (to distribute PGs across)
    local num_pools
    num_pools=$(ceph_exec ceph osd pool ls 2>/dev/null | wc -l)
    num_pools=$((num_pools + 1))  # +1 for the pool we're creating
    
    print_debug "Number of pools (including new): ${num_pools}"
    
    # Formula: (Total OSDs × Target PGs per OSD) / Replica Size / Number of Pools
    local calculated_pgs=$(( (total_osds * TARGET_PGS_PER_OSD) / replica_size / num_pools ))
    
    print_debug "Calculated PGs (before rounding): ${calculated_pgs}"
    
    # Round to nearest power of 2 (Ceph requirement)
    local pg_count=8
    while [ $pg_count -lt $calculated_pgs ]; do
        pg_count=$((pg_count * 2))
    done
    
    # Cap at reasonable maximum (4096)
    if [ $pg_count -gt 4096 ]; then
        pg_count=4096
    fi
    
    # Ensure minimum of 8
    if [ $pg_count -lt 8 ]; then
        pg_count=8
    fi
    
    print_debug "Final calculated PG count: ${pg_count}"
    echo "$pg_count"
}

# Enable PG autoscaling for a pool
enable_pg_autoscaling() {
    local pool_name="$1"
    
    print_info "Enabling PG autoscaling for pool: ${pool_name}"
    
    # Enable autoscaler module (if not already enabled)
    if ceph_exec ceph mgr module enable pg_autoscaler 2>/dev/null; then
        print_debug "PG autoscaler module enabled"
    else
        print_debug "PG autoscaler module already enabled or failed to enable"
    fi
    
    # Set autoscale mode to 'on' for the pool
    if ceph_exec ceph osd pool set "$pool_name" pg_autoscale_mode on 2>/dev/null; then
        print_success "PG autoscaling enabled for ${pool_name}"
    else
        print_warning "Failed to enable PG autoscaling for ${pool_name}"
        return 1
    fi
    
    # Set target size ratio if provided
    if [ -n "$POOL_TARGET_RATIO" ]; then
        print_info "Setting target size ratio: ${POOL_TARGET_RATIO}"
        if ceph_exec ceph osd pool set "$pool_name" target_size_ratio "$POOL_TARGET_RATIO" 2>/dev/null; then
            print_debug "Target size ratio set successfully"
        else
            print_warning "Failed to set target size ratio"
        fi
    fi
    
    return 0
}

# Display PG count guidance to user
display_pg_guidance() {
    local calculated_pg="$1"
    local current_pg="$2"
    
    echo ""
    print_header "============================================================"
    print_header "PG Count Configuration Guidance"
    print_header "============================================================"
    
    # Get cluster info
    local total_osds
    total_osds=$(ceph_exec ceph osd stat -f json 2>/dev/null | jq -r '.num_osds' 2>/dev/null || echo "unknown")
    
    cat << EOF

${BOLD}Understanding Placement Groups (PGs):${NC}
  PGs distribute data across OSDs for balanced storage and performance.
  
  ${YELLOW}Too few PGs:${NC}  Poor data distribution, performance bottlenecks
  ${YELLOW}Too many PGs:${NC} Increased CPU/memory overhead, slower recovery

${BOLD}Current Configuration:${NC}
  Configured PG count:  ${CYAN}${current_pg}${NC}
  Recommended PG count: ${GREEN}${calculated_pg}${NC}
  Total OSDs in cluster: ${total_osds}
  Target PGs per OSD:   ${TARGET_PGS_PER_OSD}

${BOLD}Ceph Best Practices:${NC}
  • Target: 100-200 PGs per OSD across all pools
  • PG count must be a power of 2 (8, 16, 32, 64, 128, 256, 512, 1024, etc.)
  • Consider enabling PG autoscaling for automatic management
  • Autoscaling adjusts PG count based on actual data usage

EOF

    # Provide specific recommendations
    if [ "$current_pg" -lt "$calculated_pg" ]; then
        print_warning "Your configured PG count (${current_pg}) is lower than recommended (${calculated_pg})"
        print_info "This may lead to poor data distribution and performance issues"
        echo ""
    elif [ "$current_pg" -gt $((calculated_pg * 2)) ]; then
        print_warning "Your configured PG count (${current_pg}) is higher than recommended (${calculated_pg})"
        print_info "This may cause unnecessary overhead and slower operations"
        echo ""
    else
        print_success "Your PG count is within acceptable range"
        echo ""
    fi
}

# Interactive PG count selection
select_pg_count_interactive() {
    local calculated_pg
    calculated_pg=$(calculate_pg_count)
    
    display_pg_guidance "$calculated_pg" "$POOL_PGS"
    
    echo "${BOLD}PG Count Options:${NC}"
    echo "  ${GREEN}1)${NC} Use recommended value: ${GREEN}${calculated_pg}${NC} (calculated based on cluster)"
    echo "  ${CYAN}2)${NC} Use current value: ${CYAN}${POOL_PGS}${NC} (from command line or default)"
    echo "  ${BLUE}3)${NC} Enable autoscaling (let Ceph manage PG count automatically)"
    echo "  ${YELLOW}4)${NC} Enter custom value"
    echo ""
    
    local choice
    read -p "Select option [1-4]: " choice
    
    case $choice in
        1)
            POOL_PGS="$calculated_pg"
            USE_AUTOSCALING=false
            print_success "Using recommended PG count: ${POOL_PGS}"
            ;;
        2)
            USE_AUTOSCALING=false
            print_info "Using configured PG count: ${POOL_PGS}"
            ;;
        3)
            USE_AUTOSCALING=true
            POOL_PGS="$calculated_pg"  # Start with recommended, autoscaler will adjust
            print_success "PG autoscaling will be enabled (starting with ${POOL_PGS} PGs)"
            ;;
        4)
            local custom_pg
            read -p "Enter custom PG count (must be power of 2): " custom_pg
            if is_power_of_two "$custom_pg"; then
                POOL_PGS="$custom_pg"
                USE_AUTOSCALING=false
                print_success "Using custom PG count: ${POOL_PGS}"
            else
                print_error "Invalid PG count. Must be a power of 2 (8, 16, 32, 64, 128, 256, 512, 1024, etc.)"
                print_info "Falling back to recommended value: ${calculated_pg}"
                POOL_PGS="$calculated_pg"
                USE_AUTOSCALING=false
            fi
            ;;
        *)
            print_warning "Invalid option. Using recommended value: ${calculated_pg}"
            POOL_PGS="$calculated_pg"
            USE_AUTOSCALING=false
            ;;
    esac
    
    echo ""
}

# Check and display autoscaler recommendations
check_autoscaler_recommendations() {
    print_info "Checking PG autoscaler status and recommendations..."
    echo ""
    
    if ceph_exec ceph osd pool autoscale-status 2>/dev/null; then
        echo ""
        print_info "The autoscaler will adjust PG counts based on actual data usage"
    else
        print_warning "Unable to retrieve autoscaler status"
    fi
}


###############################################################################
# CA BUNDLE VALIDATION HELPER FUNCTION
###############################################################################
validate_ca_bundle() {
    local ca_file="$1"
    local test_endpoint="${2:-}"
    local test_port="${3:-443}"
    
    print_info "Validating CA certificate bundle: ${ca_file}"
    
    # Check file exists and is readable
    if [ ! -f "$ca_file" ]; then
        print_error "CA bundle file not found: ${ca_file}"
        return 1
    fi
    
    if [ ! -r "$ca_file" ]; then
        print_error "CA bundle file not readable: ${ca_file}"
        return 1
    fi
    
    # Check file is not empty
    if [ ! -s "$ca_file" ]; then
        print_error "CA bundle file is empty: ${ca_file}"
        return 1
    fi
    
    # Check for PEM format
    if ! grep -q "BEGIN CERTIFICATE" "$ca_file"; then
        print_error "CA bundle does not contain PEM-formatted certificates"
        print_error "Expected '-----BEGIN CERTIFICATE-----' marker"
        return 1
    fi
    
    # Count certificates in bundle
    local cert_count
    cert_count=$(grep -c "BEGIN CERTIFICATE" "$ca_file" || echo "0")
    print_info "CA bundle contains ${cert_count} certificate(s)"
    
    # Validate each certificate in the bundle
    print_info "Validating certificate structure and expiry..."
    local temp_cert_dir
    temp_cert_dir=$(mktemp -d)
    
    # Split certificates - use a more reliable method
    # Extract each certificate block separately
    local cert_num=0
    while IFS= read -r line; do
        if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
            cert_num=$((cert_num + 1))
            echo "$line" > "${temp_cert_dir}/cert-${cert_num}.pem"
        elif [[ -n "${cert_num}" ]] && [[ "${cert_num}" -gt 0 ]]; then
            echo "$line" >> "${temp_cert_dir}/cert-${cert_num}.pem"
        fi
    done < "$ca_file"
    
    local valid_certs=0
    local invalid_certs=0
    local expired_certs=0
    local expiring_soon=0
    local expiry_warning_seconds=$((CERT_EXPIRY_WARNING_DAYS * 86400))
    
    for cert_file in "${temp_cert_dir}"/cert-*; do
        [ -f "$cert_file" ] || continue
        
        # Skip empty files
        if [ ! -s "$cert_file" ]; then
            continue
        fi
        
        # Skip files without certificate content
        if ! grep -q "BEGIN CERTIFICATE" "$cert_file" 2>/dev/null; then
            continue
        fi
        
        if openssl x509 -in "$cert_file" -noout 2>/dev/null; then
            ((++valid_certs))
            
            # Extract certificate details for logging
            local cert_subject cert_issuer cert_expiry
            cert_subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/subject=//' | cut -c1-60)
            cert_issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null | sed 's/issuer=//' | cut -c1-60)
            cert_expiry=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
            
            print_debug "  Certificate ${valid_certs}:"
            print_debug "    Subject: ${cert_subject}..."
            print_debug "    Issuer:  ${cert_issuer}..."
            print_debug "    Expires: ${cert_expiry}"
            
            # Check if certificate is expired
            if ! openssl x509 -in "$cert_file" -noout -checkend 0 2>/dev/null; then
                print_error "EXPIRED certificate detected!"
                print_error "Subject: ${cert_subject}"
                print_error "Expiry date: ${cert_expiry}"
                ((++expired_certs))
            fi
            
            # Warn before certificates get close to expiry.
            if ! openssl x509 -in "$cert_file" -noout -checkend "$expiry_warning_seconds" 2>/dev/null; then
                if [ "$expired_certs" -eq 0 ]; then
                    print_warning "Certificate expires within ${CERT_EXPIRY_WARNING_DAYS} days: ${cert_subject}"
                    print_warning "Expiry date: ${cert_expiry}"
                    ((++expiring_soon))
                fi
            fi
        else
            ((++invalid_certs))
        fi
    done
    
    rm -rf "$temp_cert_dir"
    
    # Report validation results
    if [ "$invalid_certs" -gt 0 ]; then
        print_error "CA bundle contains ${invalid_certs} invalid certificate(s)"
        return 1
    fi
    
    if [ "$expired_certs" -gt 0 ]; then
        print_error "CA bundle contains ${expired_certs} EXPIRED certificate(s)"
        print_error "Please provide a valid, non-expired CA certificate"
        return 1
    fi
    
    if [ "$valid_certs" -eq 0 ]; then
        print_error "No valid certificates found in CA bundle"
        return 1
    fi
    
    print_success "All ${valid_certs} certificate(s) are valid and not expired"
    
    if [ "$expiring_soon" -gt 0 ]; then
        print_warning "${expiring_soon} certificate(s) expire within ${CERT_EXPIRY_WARNING_DAYS} days - consider renewal"
    fi
    
    # Test against endpoint if provided
    if [ -n "$test_endpoint" ] && [ "$RGW_PROTOCOL" = "https" ]; then
        local endpoint_host endpoint_port connect_target
        endpoint_host=$(echo "$test_endpoint" | sed -E 's|^https?://||' | cut -d':' -f1)
        endpoint_port=$(echo "$test_endpoint" | sed -E 's|^https?://||' | cut -s -d':' -f2)
        [ -z "$endpoint_port" ] && endpoint_port="$test_port"
        connect_target="${endpoint_host}:${endpoint_port}"

        print_info "Testing CA bundle against endpoint: ${connect_target}"
        
        # Start progress bar in background
        show_progress_bar "Verifying endpoint" 10 &
        local progress_pid=$!
        
        local verify_result
        local timeout_cmd=""
        if command -v timeout &>/dev/null; then
            timeout_cmd="timeout"
        elif command -v gtimeout &>/dev/null; then
            timeout_cmd="gtimeout"
        fi

        if [ -n "$timeout_cmd" ]; then
            verify_result=$(echo | "$timeout_cmd" 10 openssl s_client \
                -connect "$connect_target" \
                -CAfile "$ca_file" \
                -servername "$endpoint_host" \
                2>&1 || echo "CONNECTION_FAILED")
        else
            verify_result=$(echo | openssl s_client \
                -connect "$connect_target" \
                -CAfile "$ca_file" \
                -servername "$endpoint_host" \
                2>&1 || echo "CONNECTION_FAILED")
        fi
        
        # Stop progress bar
        kill "$progress_pid" 2>/dev/null || true
        wait "$progress_pid" 2>/dev/null || true
        
        # Clear progress bar line
        if [ -t 1 ]; then
            printf "\r%*s\r" 100 ""
        fi
        
        if echo "$verify_result" | grep -q "Verify return code: 0"; then
            print_success "✓ CA bundle successfully verifies endpoint"
        elif echo "$verify_result" | grep -q "CONNECTION_FAILED"; then
            print_warning "Could not connect to endpoint for verification"
            print_warning "CA bundle will be used, but verification skipped"
        else
            local verify_error
            verify_error=$(echo "$verify_result" | grep "Verify return code:" | head -1)
            print_warning "CA bundle verification warning: ${verify_error}"
            print_warning "This may cause NooBaa BackingStore connection issues"
            print_warning "Ensure the CA bundle contains the correct root/intermediate CA"
        fi
    fi
    
    return 0
}
###############################################################################
# CA BUNDLE EXTRACTION HELPER FUNCTION
###############################################################################
extract_ca_from_endpoint() {
    local endpoint="$1"
    local output_file="$2"

    print_info "Extracting CA certificate chain from endpoint: ${endpoint}"

    # Parse hostname and port
    local hostname port
    hostname=$(echo "$endpoint" | cut -d':' -f1)

    if echo "$endpoint" | grep -q ':'; then
        port=$(echo "$endpoint" | cut -d':' -f2)
    else
        port="443"
    fi

    print_info "Connecting to ${hostname}:${port}..."

    # Remove old file first
    rm -f "$output_file"

    local temp_output
    temp_output=$(mktemp)

    # Extract complete certificate chain
    # Always run locally - OpenShift routes are only accessible from outside the cluster
    if ! command -v openssl &>/dev/null; then
        print_error "openssl command not found - cannot extract certificates"
        rm -f "$temp_output"
        return 1
    fi

    # Use timeout if available (gtimeout on macOS, timeout on Linux)
    local timeout_cmd=""
    if command -v timeout &>/dev/null; then
        timeout_cmd="timeout 20"
    elif command -v gtimeout &>/dev/null; then
        timeout_cmd="gtimeout 20"
    fi

    # Run openssl with or without timeout
    if [ -n "$timeout_cmd" ]; then
        if $timeout_cmd openssl s_client \
            -connect "${hostname}:${port}" \
            -showcerts \
            -servername "${hostname}" \
            </dev/null > "$temp_output" 2>&1; then
            print_info "Connection successful"
        else
            print_warning "Connection may have issues, attempting to extract certificates anyway..."
        fi
    else
        # No timeout command available - run without timeout (use echo to auto-close connection)
        if echo | openssl s_client \
            -connect "${hostname}:${port}" \
            -showcerts \
            -servername "${hostname}" \
            > "$temp_output" 2>&1; then
            print_info "Connection successful"
        else
            print_warning "Connection may have issues, attempting to extract certificates anyway..."
        fi
    fi

    # Extract ALL certificates (full chain: server + intermediates + root)
    # This is required for proper TLS validation in NooBaa
    awk '
    /-----BEGIN CERTIFICATE-----/ {
        capture=1
    }

    capture {
        print
    }

    /-----END CERTIFICATE-----/ {
        capture=0
    }
    ' "$temp_output" > "$output_file"

    rm -f "$temp_output"

    # Validate extraction
    if [ ! -s "$output_file" ]; then
        print_error "Certificate extraction failed - output file is empty"
        return 1
    fi

    if ! grep -q "BEGIN CERTIFICATE" "$output_file"; then
        print_error "No valid certificates found in extracted output"
        return 1
    fi

    local cert_count
    cert_count=$(grep -c "BEGIN CERTIFICATE" "$output_file")

    print_success "Successfully extracted ${cert_count} certificate(s)"
    print_info "Certificate bundle saved to: ${output_file}"

    # Validate the first certificate in the bundle
    if ! openssl x509 -in "$output_file" -noout >/dev/null 2>&1; then
        print_error "Generated CA bundle is invalid"
        return 1
    fi

    # Determine certificate type
    if [ "$cert_count" -eq 1 ]; then
        # Single cert - check if self-signed
        local cert_subject cert_issuer
        cert_subject=$(openssl x509 -in "$output_file" -noout -subject 2>/dev/null | sed 's/subject=//')
        cert_issuer=$(openssl x509 -in "$output_file" -noout -issuer 2>/dev/null | sed 's/issuer=//')
        
        if [ "$cert_subject" = "$cert_issuer" ]; then
            print_success "✓ Extracted self-signed certificate"
            CA_BUNDLE_TYPE="extracted-self-signed"
        else
            print_warning "Single certificate extracted but Subject ≠ Issuer"
            print_warning "This may be missing intermediate/root CA"
            CA_BUNDLE_TYPE="extracted-incomplete"
        fi
    else
        print_success "✓ Extracted certificate chain (${cert_count} certificates)"
        CA_BUNDLE_TYPE="extracted-chain"
    fi

    return 0
}

###############################################################################
# HELPER FUNCTIONS
###############################################################################
# Execute Ceph commands (native or via ODF toolbox)
ceph_exec() {
    if [ "$MODE" = "native" ]; then
        # Direct Ceph command execution
        # Handle both 'ceph' and 'radosgw-admin' commands
        if [ "$1" = "ceph" ]; then
            # For ceph commands, remove 'ceph' and execute with ceph
            shift
            ceph "$@"
        elif [ "$1" = "radosgw-admin" ]; then
            # For radosgw-admin commands, execute directly
            "$@"
        else
            # For other commands, execute directly
            "$@"
        fi
    else
        # ODF mode: execute via toolbox pod
        oc exec -n "$NAMESPACE" "$TOOLBOX_POD" -- "$@"
    fi
}

# Convert size string to bytes (e.g., "1T" -> bytes)
convert_to_bytes() {
    local size="$1"
    local num="${size//[^0-9]/}"
    local unit="${size//[0-9]/}"
    unit=$(echo "$unit" | tr '[:lower:]' '[:upper:]')
    
    case "$unit" in
        K|KB) echo $((num * 1024)) ;;
        M|MB) echo $((num * 1024 * 1024)) ;;
        G|GB) echo $((num * 1024 * 1024 * 1024)) ;;
        T|TB) echo $((num * 1024 * 1024 * 1024 * 1024)) ;;
        P|PB) echo $((num * 1024 * 1024 * 1024 * 1024 * 1024)) ;;
        *) echo "$num" ;;
    esac
}

# Convert size with unit to bytes (e.g., "311 GiB" -> bytes)
# This is the reverse of convert_from_bytes and works on all platforms
convert_to_bytes_from_unit() {
    local size_str="$1"
    
    # Extract number and unit
    local num=$(echo "$size_str" | awk '{print $1}')
    local unit=$(echo "$size_str" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')
    
    # Handle empty or invalid input
    if [ -z "$num" ]; then
        echo "0"
        return
    fi
    
    # Convert based on unit
    case "$unit" in
        KIB|K) echo $((num * 1024)) ;;
        MIB|M) echo $((num * 1024 * 1024)) ;;
        GIB|G) echo $((num * 1024 * 1024 * 1024)) ;;
        TIB|T) echo $((num * 1024 * 1024 * 1024 * 1024)) ;;
        PIB|P) echo $((num * 1024 * 1024 * 1024 * 1024 * 1024)) ;;
        BYTES|B|"") echo "$num" ;;
        *) echo "$num" ;;
    esac
}

# Convert bytes to human-readable format (e.g., 1073741824 -> "1 GiB")
convert_from_bytes() {
    local bytes="$1"
    local units=("bytes" "KiB" "MiB" "GiB" "TiB" "PiB")
    local unit_index=0
    local size=$bytes
    
    # Handle zero or invalid input
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ] 2>/dev/null; then
        echo "0"
        return
    fi
    
    # Convert to float and divide by 1024 until we get a reasonable number
    while [ "$size" -ge 1024 ] 2>/dev/null && [ "$unit_index" -lt 5 ]; do
        size=$((size / 1024))
        unit_index=$((unit_index + 1))
    done
    
    echo "${size} ${units[$unit_index]}"
}

# Detect the correct RGW zone for user creation
detect_rgw_zone() {
    local zone_list
    local default_zone
    
    print_debug "Detecting RGW zone..."
    
    # Get list of zones
    zone_list=$(ceph_exec radosgw-admin zone list 2>&1 || echo "")
    
    if [ -z "$zone_list" ]; then
        print_warning "Could not detect RGW zones, using default"
        echo "default"
        return
    fi
    
    # Check if storage cluster CephObjectStore zone exists
    local rgw_zone_name="${STORAGECLUSTER_NAME}-cephobjectstore"
    if echo "$zone_list" | grep -q "$rgw_zone_name"; then
        print_debug "Found ODF zone: ${rgw_zone_name}"
        echo "${rgw_zone_name}"
        return
    fi
    
    # Get default zone
    default_zone=$(echo "$zone_list" | sed -n 's/.*"default_info":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    
    if [ -n "$default_zone" ]; then
        print_debug "Using default zone from zone list"
        echo "default"
    else
        print_debug "No specific zone detected, using 'default'"
        echo "default"
    fi
}

###############################################################################
# UPDATE FUNCTIONS
###############################################################################

# Update tenant storage configuration
update_tenant_storage() {
    print_header "UPDATE TENANT STORAGE: ${TENANT_NAME}"
    
    local pool_name="${TENANT_NAME}-rbd-pool"
    local rgw_user="${TENANT_NAME}-noobaa-user"
    local updated=false
    
    # Validate tenant exists
    print_info "Checking if tenant '${TENANT_NAME}' exists..."
    
    # Check if pool exists (completely avoid pipes to prevent subshell issues)
    local pool_list
    pool_list=$(ceph_exec ceph osd pool ls)
    
    # Use grep separately and capture result
    local pool_exists
    pool_exists=$(echo "$pool_list" | grep "^${pool_name}$" || true)
    
    if [ -z "$pool_exists" ]; then
        print_warning "Tenant '${TENANT_NAME}' does not exist."
        echo ""
        read -rp "Do you want to create this tenant instead? (yes/no): " response
        if [ "$response" = "yes" ]; then
            # Check if quotas are provided
            if [ -z "$RBD_QUOTA" ]; then
                print_error "To create tenant, you need to provide --rbd-quota"
                print_info "Example: --rbd-quota 1T --rgw-user-quota 2T"
                exit 1
            fi
            print_info "Switching to PROVISION mode..."
            return 2  # Signal mode switch
        else
            print_info "Operation cancelled"
            exit 0
        fi
    fi
    print_success "Tenant '${TENANT_NAME}' found"
    
    # Simple confirmation prompt
    echo ""
    read -rp "Proceed with updating tenant '${TENANT_NAME}' quotas? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Update cancelled"
        exit 0
    fi
    echo ""
    
    # Update RBD pool quota if specified
    if [ -n "$RBD_QUOTA" ]; then
        print_header "Updating RBD Pool Quota"
        
        # Get current quota
        print_info "Analyzing current quota and usage..."
        local quota_output
        quota_output=$(ceph_exec ceph osd pool get-quota "${pool_name}" 2>/dev/null || echo "")
        
        local current_quota_bytes=0
        local current_quota_display="unlimited"
        if echo "$quota_output" | grep -q "max bytes"; then
            # Extract the quota value - format: "max bytes  : 100 GiB"
            local quota_line
            quota_line=$(echo "$quota_output" | grep "max bytes")
            
            # Check if it shows a size (not N/A)
            if echo "$quota_line" | grep -qv "N/A"; then
                # Extract the size with unit (e.g., "100 GiB")
                local quota_with_unit
                quota_with_unit=$(echo "$quota_line" | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//' | awk '{print $1, $2}')
                
                if [ -n "$quota_with_unit" ]; then
                    current_quota_display="$quota_with_unit"
                    # Convert to bytes for comparison (macOS compatible)
                    current_quota_bytes=$(convert_to_bytes_from_unit "$quota_with_unit")
                fi
            fi
        fi
        
        # Get current usage
        local pool_stats
        pool_stats=$(ceph_exec ceph df detail 2>/dev/null | grep " ${pool_name} " || echo "")
        
        local current_usage_bytes=0
        local current_usage_str="0"
        if [ -n "$pool_stats" ]; then
            # Extract STORED column (actual data stored)
            current_usage_str=$(echo "$pool_stats" | awk '{print $3}')
            if [ -n "$current_usage_str" ]; then
                # Convert to bytes (handles K, M, G, T suffixes) - macOS compatible
                current_usage_bytes=$(convert_to_bytes_from_unit "$current_usage_str")
            fi
        fi
        
        # Convert new quota to bytes
        local new_quota_bytes
        new_quota_bytes=$(convert_to_bytes "$RBD_QUOTA")
        
        # Display current state
        print_info "Currently allocated quota: ${current_quota_display}"
        print_info "Current usage: ${current_usage_str}"
        print_info "Requested quota: ${RBD_QUOTA}"
        echo ""
        
        # Validation 1: Check if quota is already set to requested value
        if [ "$current_quota_bytes" -gt 0 ] 2>/dev/null && [ "$new_quota_bytes" -eq "$current_quota_bytes" ] 2>/dev/null; then
            print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            print_info "ℹ️  NO ACTION REQUIRED"
            print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            print_info "RBD quota is already set to ${RBD_QUOTA}"
            print_info "Tenant already has this allocation - no changes needed"
            if [ "$current_usage_bytes" -gt 0 ] 2>/dev/null; then
                local usage_percent
                usage_percent=$(echo "scale=1; $current_usage_bytes * 100 / $current_quota_bytes" | bc 2>/dev/null || echo "0")
                print_info "Current usage: ${current_usage_str} (${usage_percent}% of quota)"
            fi
            # Don't exit here, continue to check RGW quota
        else
        
        # Validation 2: Prevent dangerous reduction (new quota < current usage)
        if [ "$current_usage_bytes" -gt 0 ] && [ "$new_quota_bytes" -lt "$current_usage_bytes" ]; then
            print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            print_error "❌ CANNOT REDUCE QUOTA BELOW CURRENT USAGE"
            print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            print_error ""
            print_error "Current quota: $(convert_from_bytes "$current_quota_bytes")"
            print_error "Current usage: ${current_usage_str}"
            if [ "$current_quota_bytes" -gt 0 ]; then
                local usage_percent
                usage_percent=$(echo "scale=1; $current_usage_bytes * 100 / $current_quota_bytes" | bc 2>/dev/null || echo "0")
                print_error "Usage percentage: ${usage_percent}%"
            fi
            print_error "Requested quota: ${RBD_QUOTA}"
            print_error ""
            print_error "⚠️  CRITICAL: The tenant is currently using MORE space than the requested quota."
            print_error "Reducing the quota below current usage would cause:"
            print_error "  • Immediate data loss risk"
            print_error "  • Service disruption for tenant workloads"
            print_error "  • Failed write operations"
            print_error "  • Potential data corruption"
            print_error ""
            print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            print_info "📋 AVAILABLE OPTIONS"
            print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            print_info "Option 1: Ask tenant to delete data"
            print_info "  • Tenant must reduce usage below ${RBD_QUOTA}"
            print_info "  • Then retry this quota update"
            print_info "Option 2: Set a higher quota"
            local recommended_quota
            recommended_quota=$(echo "$current_usage_bytes * 1.2" | bc | cut -d. -f1)
            print_info "  • Recommended minimum: $(convert_from_bytes "$recommended_quota") (current usage + 20%)"
            print_info "  • Command: ./setup-storage.sh --tenant ${TENANT_NAME} --rbd-quota $(convert_from_bytes "$recommended_quota") --update"
            print_info "Option 3: Delete the entire tenant (⚠️  ALL DATA WILL BE PERMANENTLY LOST)"
            print_info "  • Command: ./setup-storage.sh --tenant ${TENANT_NAME} --delete"
            exit 1
        fi
        
        # Validation 3: Warn on safe reduction (new quota > usage but < current quota)
        if [ "$current_quota_bytes" -gt 0 ] && [ "$new_quota_bytes" -lt "$current_quota_bytes" ]; then
            print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            print_warning "⚠️  QUOTA REDUCTION DETECTED"
            print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            print_warning ""
            print_warning "Current quota: $(convert_from_bytes "$current_quota_bytes")"
            print_warning "Current usage: ${current_usage_str}"
            if [ "$current_quota_bytes" -gt 0 ]; then
                local usage_percent
                usage_percent=$(echo "scale=1; $current_usage_bytes * 100 / $current_quota_bytes" | bc 2>/dev/null || echo "0")
                print_warning "Usage percentage: ${usage_percent}%"
            fi
            print_warning "New quota: ${RBD_QUOTA}"
            local available_after
            available_after=$(echo "$new_quota_bytes - $current_usage_bytes" | bc)
            print_warning "Available space after reduction: $(convert_from_bytes "$available_after")"
            print_warning ""
            print_warning "⚠️  IMPACT:"
            print_warning "  • Tenant's storage capacity will be reduced"
            print_warning "  • May limit tenant's ability to store new data"
            print_warning "  • Existing data will NOT be affected"
            print_warning "  • Tenant operations will continue normally"
            print_warning ""
            echo ""
            read -rp "Type 'CONFIRM-REDUCTION' to proceed with quota reduction: " confirm
            if [ "$confirm" != "CONFIRM-REDUCTION" ]; then
                print_info "Quota reduction cancelled by operator"
                exit 0
            fi
            print_success "✓ Quota reduction confirmed"
            echo ""
        fi
        
        # Validation 4: Inform about expansion
        if [ "$current_quota_bytes" -gt 0 ] && [ "$new_quota_bytes" -gt "$current_quota_bytes" ]; then
            print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            print_info "📈 RBD QUOTA EXPANSION"
            print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            print_info ""
            print_info "Current quota: $(convert_from_bytes "$current_quota_bytes")"
            print_info "New quota: ${RBD_QUOTA}"
            local additional_space
            additional_space=$(echo "$new_quota_bytes - $current_quota_bytes" | bc)
            print_info "Additional space: $(convert_from_bytes "$additional_space")"
            print_success "✓ Expanding tenant storage capacity"
        fi
        
            # Perform the quota update
            print_info "Applying new quota: ${RBD_QUOTA}"
            if ceph_exec ceph osd pool set-quota "${pool_name}" max_bytes "$new_quota_bytes"; then
                print_success "RBD pool quota updated to ${RBD_QUOTA}"
                updated=true
            else
                print_error "Failed to update RBD pool quota"
            fi
            
            print_info "Verifying new quota:"
            ceph_exec ceph osd pool get-quota "${pool_name}"
        fi
    else
        print_info "No RBD quota update requested (use --rbd-quota to update)"
    fi
    
    # Update RGW user quota if specified
    if [ -n "$RGW_USER_QUOTA" ]; then
        print_header "Updating RGW User Quota"
        
        # Detect RGW zone (same as provision mode)
        local rgw_zone
        rgw_zone=$(detect_rgw_zone)
        print_info "Detected RGW zone: ${rgw_zone}"
        
        # Check if RGW user exists (with zone parameter)
        if ceph_exec radosgw-admin user info --uid="${rgw_user}" --rgw-zone="${rgw_zone}" &>/dev/null; then
            # Get current quota and usage
            print_info "Analyzing current quota and usage..."
            local user_info
            user_info=$(ceph_exec radosgw-admin user info --uid="${rgw_user}" --rgw-zone="${rgw_zone}" 2>/dev/null || echo "")
            
            local current_quota_bytes=0
            local current_quota_display="unlimited"
            if [ -n "$user_info" ]; then
                # Extract max_size from user_quota section (in bytes)
                local max_size_line
                max_size_line=$(echo "$user_info" | grep -A 10 '"user_quota"' | grep '"max_size"' | head -1)
                
                if [ -n "$max_size_line" ]; then
                    # Extract the number (format: "max_size": 107374182400,)
                    # Use awk instead of grep -P for macOS compatibility
                    current_quota_bytes=$(echo "$max_size_line" | awk -F': ' '{print $2}' | tr -d ',' | tr -d ' ' || echo "0")
                    
                    # Check if quota is set (not -1 or 0)
                    if [ "$current_quota_bytes" -gt 0 ] 2>/dev/null && [ "$current_quota_bytes" != "-1" ]; then
                        current_quota_display=$(convert_from_bytes "$current_quota_bytes")
                    fi
                fi
            fi
            
            # Get current usage from stats
            local stats_output
            stats_output=$(ceph_exec radosgw-admin user stats --uid="${rgw_user}" --rgw-zone="${rgw_zone}" 2>/dev/null || echo "")
            
            local current_usage_bytes=0
            local current_usage_str="0"
            if [ -n "$stats_output" ]; then
                # Extract size_actual from stats (total bytes used)
                local size_line
                size_line=$(echo "$stats_output" | grep '"size_actual"' | head -1)
                if [ -n "$size_line" ]; then
                    # Use awk instead of grep -P for macOS compatibility
                    current_usage_bytes=$(echo "$size_line" | awk -F': ' '{print $2}' | tr -d ',' | tr -d ' ' || echo "0")
                    if [ "$current_usage_bytes" -gt 0 ] 2>/dev/null; then
                        current_usage_str=$(convert_from_bytes "$current_usage_bytes")
                    fi
                fi
            fi
            
            # Convert new quota to bytes
            local new_quota_bytes
            new_quota_bytes=$(convert_to_bytes "$RGW_USER_QUOTA")
            
            # Display current state
            print_info "Currently allocated quota: ${current_quota_display}"
            print_info "Current usage: ${current_usage_str}"
            print_info "Requested quota: ${RGW_USER_QUOTA}"
            echo ""
            
            # Validation 1: Check if quota is already set to requested value
            if [ "$current_quota_bytes" -gt 0 ] && [ "$new_quota_bytes" -eq "$current_quota_bytes" ]; then
                print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                print_info "ℹ️  NO ACTION REQUIRED"
                print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                print_info ""
                print_info "RGW quota is already set to ${RGW_USER_QUOTA}"
                print_info "Tenant already has this allocation - no changes needed"
                if [ "$current_usage_bytes" -gt 0 ]; then
                    local usage_percent
                    usage_percent=$(echo "scale=1; $current_usage_bytes * 100 / $current_quota_bytes" | bc 2>/dev/null || echo "0")
                    print_info "Current usage: ${current_usage_str} (${usage_percent}% of quota)"
                fi
                # Don't exit here, continue to check if RBD was updated
            elif [ "$current_usage_bytes" -gt 0 ] && [ "$new_quota_bytes" -lt "$current_usage_bytes" ]; then
                # Validation 2: Prevent dangerous reduction
                print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                print_error "❌ CANNOT REDUCE RGW QUOTA BELOW CURRENT USAGE"
                print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                print_error ""
                print_error "Current quota: $(convert_from_bytes "$current_quota_bytes")"
                print_error "Current usage: ${current_usage_str}"
                print_error "Requested quota: ${RGW_USER_QUOTA}"
                print_error ""
                print_error "⚠️  CRITICAL: The tenant is currently using MORE object storage than the requested quota."
                print_error ""
                print_info "📋 AVAILABLE OPTIONS"
                print_info "Option 1: Ask tenant to delete objects/buckets"
                print_info "Option 2: Set a higher quota"
                local recommended_quota
                recommended_quota=$(echo "$current_usage_bytes * 1.2" | bc | cut -d. -f1)
                print_info "  • Recommended minimum: $(convert_from_bytes "$recommended_quota") (current usage + 20%)"
                print_info ""
                exit 1
            elif [ "$current_quota_bytes" -gt 0 ] && [ "$new_quota_bytes" -lt "$current_quota_bytes" ]; then
                # Validation 3: Warn on safe reduction
                print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                print_warning "⚠️  RGW QUOTA REDUCTION DETECTED"
                print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                print_warning ""
                print_warning "Current quota: $(convert_from_bytes "$current_quota_bytes")"
                print_warning "Current usage: ${current_usage_str}"
                print_warning "New quota: ${RGW_USER_QUOTA}"
                local available_after
                available_after=$(echo "$new_quota_bytes - $current_usage_bytes" | bc)
                print_warning "Available space after reduction: $(convert_from_bytes "$available_after")"
                print_warning ""
                echo ""
                read -rp "Type 'CONFIRM-REDUCTION' to proceed with RGW quota reduction: " confirm
                if [ "$confirm" != "CONFIRM-REDUCTION" ]; then
                    print_info "RGW quota reduction cancelled by operator"
                    exit 0
                fi
                print_success "✓ RGW quota reduction confirmed"
                echo ""
            elif [ "$current_quota_bytes" -gt 0 ] && [ "$new_quota_bytes" -gt "$current_quota_bytes" ]; then
                # Validation 4: Inform about expansion
                print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                print_info "📈 RGW QUOTA EXPANSION"
                print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                print_info "Current quota: $(convert_from_bytes "$current_quota_bytes")"
                print_info "New quota: ${RGW_USER_QUOTA}"
                local additional_space
                additional_space=$(echo "$new_quota_bytes - $current_quota_bytes" | bc)
                print_info "Additional space: $(convert_from_bytes "$additional_space")"
                print_success "✓ Expanding tenant object storage capacity"
            fi
            
            # Perform the quota update (skip if already at requested value)
            if [ "$current_quota_bytes" -eq 0 ] || [ "$new_quota_bytes" -ne "$current_quota_bytes" ]; then
                print_info "Setting new RGW user quota: ${RGW_USER_QUOTA}"
                local quota_bytes
                quota_bytes=$(convert_to_bytes "$RGW_USER_QUOTA")
                if ceph_exec radosgw-admin quota set --uid="${rgw_user}" --quota-scope=user --max-size="${quota_bytes}" --rgw-zone="${rgw_zone}"; then
                    if ceph_exec radosgw-admin quota enable --uid="${rgw_user}" --quota-scope=user --rgw-zone="${rgw_zone}"; then
                        print_success "RGW user quota updated to ${RGW_USER_QUOTA}"
                        updated=true
                    else
                        print_warning "Quota set but failed to enable"
                    fi
                else
                    print_error "Failed to update RGW user quota"
                fi
                
                # Display the new quota in user-friendly format
                print_success "New RGW quota: ${RGW_USER_QUOTA}"
            fi
        else
            print_warning "RGW user '${rgw_user}' not found in zone '${rgw_zone}'"
            print_info "Object storage may not be enabled for this tenant"
            print_info "To enable object storage, use provision mode with --rgw-user-quota"
        fi
    else
        print_info "No RGW quota update requested (use --rgw-user-quota to update)"
    fi
    
    # Regenerate configuration files
    if [ "$updated" = true ]; then
        print_header "Regenerating Configuration Files"
        print_info "Configuration files will be regenerated with updated quotas..."
        print_info "Output directory: ${OUTPUT_DIR}"
        
        # Set variables needed for Phase 7
        POOL_NAME="${TENANT_NAME}-rbd-pool"
        OUTPUT_JSON="${OUTPUT_DIR}/${TENANT_NAME}-external-config.json"
        
        # Execute Phase 7 logic to regenerate config
        if [ "$MODE" = "odf" ]; then
            # ODF mode: use create-external-cluster-resources.py
            print_info "Running create-external-cluster-resources.py in toolbox..."
            print_info "This generates the external-cluster-details JSON with updated quotas"
            
            # Auto-detect the Python script location
            print_info "Detecting create-external-cluster-resources.py location..."
            
            COMMON_PATHS=(
                "/etc/rook-external/create-external-cluster-resources.py"
                "/usr/share/ceph/create-external-cluster-resources.py"
                "/opt/ceph/create-external-cluster-resources.py"
                "/usr/local/bin/create-external-cluster-resources.py"
            )
            
            SCRIPT_PATH=""
            for path in "${COMMON_PATHS[@]}"; do
                if ceph_exec test -f "$path" 2>/dev/null; then
                    SCRIPT_PATH="$path"
                    print_success "Found script at: ${SCRIPT_PATH}"
                    break
                fi
            done
            
            if [ -z "$SCRIPT_PATH" ]; then
                print_error "Script not found in any common location"
                print_error "Checked locations:"
                for path in "${COMMON_PATHS[@]}"; do
                    print_error "  - ${path}"
                done
                print_error ""
                print_error "To find the script manually:"
                print_error "  oc rsh -n ${NAMESPACE} ${TOOLBOX_POD}"
                print_error "  find / -name 'create-external-cluster-resources.py' 2>/dev/null"
                print_warning "Configuration regeneration failed - you can manually run phase 7:"
                print_info "  ./setup-storage.sh --tenant ${TENANT_NAME} --rbd-quota ${RBD_QUOTA} \\"
                print_info "    --output-dir ${OUTPUT_DIR} --mode ${MODE} --phase 7"
                return 1
            fi
            
            # Run the Python script
            SCRIPT_OUTPUT=$(ceph_exec python3 \
                "$SCRIPT_PATH" \
                --rbd-data-pool-name "$POOL_NAME" \
                --k8s-cluster-name "$TENANT_NAME" \
                --restricted-auth-permission true \
                --format json \
                --output /tmp/external-config.json 2>&1)
            
            if echo "$SCRIPT_OUTPUT" | grep -qi "error\|failed"; then
                print_error "Failed to generate external config"
                print_error "$SCRIPT_OUTPUT"
                print_warning "Configuration regeneration failed - you can manually run phase 7:"
                print_info "  ./setup-storage.sh --tenant ${TENANT_NAME} --rbd-quota ${RBD_QUOTA} \\"
                print_info "    --output-dir ${OUTPUT_DIR} --mode ${MODE} --phase 7"
                return 1
            fi
            
            print_success "External config generated in toolbox"
            
            # Copy JSON from toolbox to local
            print_info "Copying JSON from toolbox..."
            oc cp "${NAMESPACE}/${TOOLBOX_POD}:/tmp/external-config.json" "$OUTPUT_JSON"
            
            if [ ! -f "$OUTPUT_JSON" ]; then
                print_error "Failed to copy JSON from toolbox"
                print_warning "Configuration regeneration failed - you can manually run phase 7:"
                print_info "  ./setup-storage.sh --tenant ${TENANT_NAME} --rbd-quota ${RBD_QUOTA} \\"
                print_info "    --output-dir ${OUTPUT_DIR} --mode ${MODE} --phase 7"
                return 1
            fi
            
            print_success "External config saved to: ${OUTPUT_JSON}"
            
        else
            # Native Ceph mode: use ceph-external-cluster-details-exporter.py
            print_info "Generating external config for native Ceph..."
            
            # Check for Python 3
            if ! command -v python3 &>/dev/null; then
                print_error "python3 is required but not found"
                print_warning "Configuration regeneration failed - you can manually run phase 7:"
                print_info "  ./setup-storage.sh --tenant ${TENANT_NAME} --rbd-quota ${RBD_QUOTA} \\"
                print_info "    --output-dir ${OUTPUT_DIR} --mode ${MODE} --phase 7"
                return 1
            fi
            
            # Find the exporter script
            EXPORTER_SCRIPT=""
            COMMON_PATHS=(
                "/root/ceph-external-cluster-details-exporter.py"
                "/usr/share/ceph/ceph-external-cluster-details-exporter.py"
                "/usr/local/share/ceph/ceph-external-cluster-details-exporter.py"
                "/opt/ceph/ceph-external-cluster-details-exporter.py"
                "/usr/share/ceph-common/ceph-external-cluster-details-exporter.py"
            )
            
            for path in "${COMMON_PATHS[@]}"; do
                if [ -f "$path" ]; then
                    EXPORTER_SCRIPT="$path"
                    print_success "Found exporter script at: ${EXPORTER_SCRIPT}"
                    break
                fi
            done
            
            if [ -z "$EXPORTER_SCRIPT" ]; then
                EXPORTER_SCRIPT=$(find /usr -name "ceph-external-cluster-details-exporter.py" 2>/dev/null | head -1)
            fi
            
            if [ -z "$EXPORTER_SCRIPT" ]; then
                print_error "ceph-external-cluster-details-exporter.py not found"
                print_warning "Configuration regeneration failed - you can manually run phase 7:"
                print_info "  ./setup-storage.sh --tenant ${TENANT_NAME} --rbd-quota ${RBD_QUOTA} \\"
                print_info "    --output-dir ${OUTPUT_DIR} --mode ${MODE} --phase 7"
                return 1
            fi
            
            # Run the exporter script
            SCRIPT_OUTPUT=$(python3 "$EXPORTER_SCRIPT" \
                --rbd-data-pool-name "$POOL_NAME" \
                --k8s-cluster-name "$TENANT_NAME" \
                --restricted-auth-permission true \
                --format json 2>&1)
            
            SCRIPT_EXIT_CODE=$?
            
            if [ $SCRIPT_EXIT_CODE -ne 0 ]; then
                print_error "Failed to run ceph-external-cluster-details-exporter.py"
                print_error "Exit code: ${SCRIPT_EXIT_CODE}"
                print_warning "Configuration regeneration failed - you can manually run phase 7:"
                print_info "  ./setup-storage.sh --tenant ${TENANT_NAME} --rbd-quota ${RBD_QUOTA} \\"
                print_info "    --output-dir ${OUTPUT_DIR} --mode ${MODE} --phase 7"
                return 1
            fi
            
            # Save the output to the JSON file
            echo "$SCRIPT_OUTPUT" > "$OUTPUT_JSON"
            
            if [ ! -s "$OUTPUT_JSON" ]; then
                print_error "Generated JSON file is empty"
                print_warning "Configuration regeneration failed - you can manually run phase 7:"
                print_info "  ./setup-storage.sh --tenant ${TENANT_NAME} --rbd-quota ${RBD_QUOTA} \\"
                print_info "    --output-dir ${OUTPUT_DIR} --mode ${MODE} --phase 7"
                return 1
            fi
            
            print_success "External config generated: ${OUTPUT_JSON}"
        fi
        
        # Validate JSON
        if ! jq empty "$OUTPUT_JSON" 2>/dev/null; then
            print_error "Generated JSON is invalid"
            print_warning "Configuration regeneration failed - you can manually run phase 7:"
            print_info "  ./setup-storage.sh --tenant ${TENANT_NAME} --rbd-quota ${RBD_QUOTA} \\"
            print_info "    --output-dir ${OUTPUT_DIR} --mode ${MODE} --phase 7"
            return 1
        fi
        
        print_success "JSON validation passed"
        print_success "Configuration files regenerated successfully with updated quotas"
    fi
    
    print_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$updated" = true ]; then
        print_success "Tenant '${TENANT_NAME}' configuration updated successfully"
    else
        print_info "No updates were performed (specify --rbd-quota or --rgw-user-quota to update)"
    fi
    print_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_info "Update operation logged to: ${LOG_FILE}"
    return 0  # Explicit return for successful update
}

###############################################################################
# DELETE FUNCTIONS
###############################################################################

# Validate tenant exists before delete
validate_tenant_exists() {
    local tenant="$1"
    local pool_name="${tenant}-rbd-pool"
    local rgw_user="${tenant}-noobaa-user"
    
    print_info "Checking if tenant '${tenant}' exists..."
    
    if ! ceph_exec ceph osd pool ls | grep -q "^${pool_name}$"; then
        print_warning "Tenant '${tenant}' does not exist or was already deleted"
        
        # Check for any remaining artifacts
        local has_artifacts=false
        
        if ceph_exec radosgw-admin user info --uid="${rgw_user}" &>/dev/null || \
           ceph_exec ceph auth get "client.${tenant}" &>/dev/null || \
           [ -f "${OUTPUT_DIR}/${tenant}-external-config.json" ]; then
            has_artifacts=true
        fi
        
        if [ "$has_artifacts" = true ]; then
            print_info "Found remaining artifacts. Cleaning up..."
            return 0  # Proceed with cleanup
        else
            print_info "No artifacts found - tenant is completely clean"
            echo ""
            print_info "To create this tenant, re-run the command WITHOUT --delete flag:"
            print_info "Examples:"
            # Resolve OUTPUT_DIR to absolute path for display
            local abs_output_dir
            if [[ "$OUTPUT_DIR" = /* ]]; then
                abs_output_dir="$OUTPUT_DIR"
            else
                abs_output_dir="$(cd "$OUTPUT_DIR" 2>/dev/null && pwd || echo "$OUTPUT_DIR")"
            fi
            
            print_info ""
            print_info "  # Block storage only:"
            print_info "  ./setup-storage.sh --tenant ${tenant} --rbd-quota 500G --output-dir ${abs_output_dir} --mode ${MODE}"
            print_info ""
            print_info "  # Block + Object storage:"
            print_info "  ./setup-storage.sh --tenant ${tenant} --rbd-quota 500G --rgw-user-quota 1T --output-dir ${abs_output_dir} --mode ${MODE}"
            return 1
        fi
    fi
    
    print_success "Tenant '${tenant}' found"
    return 0
}

# Check for active resources
check_active_resources() {
    local tenant="$1"
    local pool_name="${tenant}-rbd-pool"
    
    print_header "Checking Active Resources"
    
    # Check pool usage
    local pool_stats
    pool_stats=$(ceph_exec ceph df detail 2>/dev/null | grep "${pool_name}" || echo "")
    
    if [ -n "$pool_stats" ]; then
        print_warning "Pool '${pool_name}' contains data:"
        echo "$pool_stats"
    fi
    
    # Check RBD images
    local images
    images=$(ceph_exec rbd ls "${pool_name}" 2>/dev/null || echo "")
    if [ -n "$images" ]; then
        print_warning "Found RBD images:"
        echo "$images" | while read -r img; do
            print_warning "  • ${img}"
        done
    fi
}

# Multi-level confirmation with enhanced customer warnings
confirm_delete() {
    local tenant="$1"
    
    echo ""
    echo ""
    print_header "╔═══════════════════════════════════════════════════════════════════════════════╗"
    print_header "║                                                                               ║"
    print_header "║                    🚨 CRITICAL CUSTOMER WARNING 🚨                            ║"
    print_header "║                                                                               ║"
    print_header "║              YOU ARE ABOUT TO DELETE TENANT STORAGE                           ║"
    print_header "║                                                                               ║"
    print_header "╚═══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_warning "                         TENANT INFORMATION"
    print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_warning "  Tenant Name:        ${tenant}"
    print_warning "  RBD Pool:           ${tenant}-rbd-pool"
    print_warning "  RGW User:           ${tenant}-noobaa-user (if exists)"
    print_warning "  Backing Bucket:     ${tenant}-backing-bucket (if exists)"
    echo ""
    print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_warning "⚠️  CUSTOMER IMPACT WARNING ⚠️"
    print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_warning ""
    print_warning "THIS OPERATION WILL CAUSE IMMEDIATE CUSTOMER SERVICE DISRUPTION:"
    print_warning ""
    print_warning "  ❌ ALL customer applications using this storage will FAIL"
    print_warning "  ❌ ALL customer data in this tenant will be PERMANENTLY DELETED"
    print_warning "  ❌ ALL customer PVCs (Persistent Volume Claims) will become UNUSABLE"
    print_warning "  ❌ ALL customer workloads depending on this storage will CRASH"
    print_warning ""
    print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_warning "⚠️  TECHNICAL IMPACT ⚠️"
    print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_warning ""
    print_warning "The following resources will be PERMANENTLY DELETED:"
    print_warning ""
    print_warning "  🗑️  RBD Pool: All block storage data (IRREVERSIBLE)"
    print_warning "  🗑️  Object Storage: All objects in backing bucket (IRREVERSIBLE)"
    print_warning "  🗑️  Ceph Users: All authentication credentials"
    print_warning "  🗑️  Configuration Files: All tenant config files"
    print_warning ""
    print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_warning "⚠️  CRITICAL REMINDERS ⚠️"
    print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_warning ""
    print_warning "  ⛔ This action CANNOT be undone"
    print_warning "  ⛔ NO automatic backups will be created"
    print_warning "  ⛔ Customer must be notified BEFORE proceeding"
    print_warning "  ⛔ Ensure customer has backed up all critical data"
    print_warning "  ⛔ Verify customer approval and change ticket number"
    print_warning ""
    echo ""
    
    # First confirmation - Customer notification and backup check
    print_header "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_header "                    STEP 1: CUSTOMER NOTIFICATION & BACKUP"
    print_header "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_warning "1. Have you notified the customer about this deletion?"
    print_warning "2. Has the customer confirmed they have backed up all critical data?"
    print_warning ""
    read -rp "Confirm customer notification and backup completion (y/n): " response1
    if [ "$response1" != "y" ] && [ "$response1" != "Y" ]; then
        print_error "Customer notification and backup not confirmed!"
        print_info "❌ Delete operation cancelled - Please notify customer and ensure backups first"
        exit 0
    fi
    print_success "✓ Customer notification and backup confirmed"
    echo ""
    
    # Second confirmation - Understanding impact
    print_header "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_header "                    STEP 2: IMPACT ACKNOWLEDGMENT"
    print_header "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_warning "Do you understand that:"
    print_warning "  • This will cause immediate service disruption"
    print_warning "  • ALL data will be permanently lost"
    print_warning "  • This action CANNOT be undone"
    print_warning ""
    print_warning "Type 'I UNDERSTAND THE IMPACT' to proceed:"
    read -r response2
    # Convert to lowercase for case-insensitive comparison
    response2_lower=$(echo "$response2" | tr '[:upper:]' '[:lower:]')
    if [ "$response2_lower" != "i understand the impact" ]; then
        print_error "Impact not acknowledged!"
        print_info "❌ Delete operation cancelled"
        exit 0
    fi
    print_success "✓ Impact acknowledged"
    echo ""
    
    # Third confirmation - Final tenant name verification
    print_header "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_header "                    STEP 3: FINAL CONFIRMATION"
    print_header "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_warning "⚠️  LAST CHANCE TO CANCEL ⚠️"
    print_warning ""
    print_warning "To proceed with PERMANENT deletion of tenant '${tenant}',"
    print_warning "type exactly: DELETE-${tenant}"
    print_warning ""
    print_warning "Confirmation string:"
    read -r response3
    if [ "$response3" != "DELETE-${tenant}" ]; then
        print_error "Confirmation failed!"
        print_error "Expected: 'DELETE-${tenant}'"
        print_error "Received: '${response3}'"
        print_info "❌ Delete operation cancelled"
        exit 1
    fi
    
    echo ""
    print_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "✓ All confirmations received. Proceeding with deletion..."
    print_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    sleep 2  # Give operator a moment to reconsider
}

# Delete RGW resources
delete_rgw_resources() {
    local tenant="$1"
    local rgw_user="${tenant}-noobaa-user"
    local backing_bucket="${tenant}-backing-bucket"
    
    print_header "Deleting RGW Resources"
    
    # Check if RGW user exists
    if ceph_exec radosgw-admin user info --uid="${rgw_user}" &>/dev/null; then
        # Delete backing bucket first
        print_info "Deleting backing bucket: ${backing_bucket}"
        ceph_exec radosgw-admin bucket rm --bucket="${backing_bucket}" --purge-objects 2>/dev/null || print_warning "Bucket not found or already deleted"
        
        # Delete RGW user
        print_info "Deleting RGW user: ${rgw_user}"
        if ceph_exec radosgw-admin user rm --uid="${rgw_user}" --purge-data; then
            print_success "RGW user deleted"
        else
            print_warning "Failed to delete RGW user"
        fi
    else
        print_info "RGW user not found (object storage may not have been enabled)"
    fi
}

# Delete Ceph users
delete_ceph_users() {
    local tenant="$1"
    local pool_name="${tenant}-rbd-pool"
    
    print_header "Deleting Ceph Users"
    
    # Delete main client
    print_info "Deleting client.${tenant}"
    ceph_exec ceph auth del "client.${tenant}" 2>/dev/null || print_warning "User not found"
    
    # Delete CSI users
    local csi_node="csi-rbd-node-${tenant}-${pool_name}"
    local csi_prov="csi-rbd-provisioner-${tenant}-${pool_name}"
    
    print_info "Deleting CSI users"
    ceph_exec ceph auth del "client.${csi_node}" 2>/dev/null || print_warning "CSI node user not found"
    ceph_exec ceph auth del "client.${csi_prov}" 2>/dev/null || print_warning "CSI provisioner user not found"
    
    print_success "Ceph users deleted"
}

# Delete RBD pool
delete_rbd_pool() {
    local tenant="$1"
    local pool_name="${tenant}-rbd-pool"
    
    print_header "Deleting RBD Pool"
    
    # Check if pool exists
    if ! ceph_exec ceph osd pool ls | grep -q "^${pool_name}$"; then
        print_warning "Pool '${pool_name}' not found"
        return 0
    fi
    
    print_info "Deleting pool: ${pool_name}"
    if ceph_exec ceph osd pool delete "${pool_name}" "${pool_name}" --yes-i-really-really-mean-it; then
        print_success "Pool deleted successfully"
    else
        print_error "Failed to delete pool"
        return 1
    fi
}

# Cleanup artifacts
cleanup_artifacts() {
    local tenant="$1"
    
    print_header "Cleaning Up Artifacts"
    
    local config_file="${OUTPUT_DIR}/${tenant}-external-config.json"
    if [ -f "$config_file" ]; then
        print_info "Removing config file: ${config_file}"
        rm -f "$config_file"
    fi
    
    print_success "Artifacts cleaned up"
}

# Main delete function
delete_tenant_storage() {
    local tenant="$1"
    print_header "DELETE TENANT STORAGE: ${tenant}"
    
    # Validate tenant exists (or handle mode switch)
    validate_tenant_exists "$tenant"
    local validation_result=$?
    
    if [ $validation_result -eq 1 ]; then
        return 1
    elif [ $validation_result -eq 2 ]; then
        # Mode switch requested
        return 2
    fi
    
    # Check if pool exists to determine if we need full delete or just cleanup
    local pool_name="${tenant}-rbd-pool"
    local pool_exists=false
    if ceph_exec ceph osd pool ls | grep -q "^${pool_name}$"; then
        pool_exists=true
        # Get simple confirmation
        confirm_delete "$tenant"
    fi
    
    # Delete resources
    delete_rgw_resources "$tenant"
    delete_ceph_users "$tenant"
    if [ "$pool_exists" = true ]; then
        delete_rbd_pool "$tenant"
    fi
    cleanup_artifacts "$tenant"
    
    print_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "Tenant '${TENANT_NAME}' cleanup completed successfully"
    print_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_info "Delete operation logged to: ${LOG_FILE}"
}

###############################################################################
# DELETE MODE HANDLING
###############################################################################
if [ "$DELETE_MODE" = true ]; then
    if [ -z "$TENANT_NAME" ]; then
        echo "ERROR: --tenant is required for delete mode" >&2
        exit 1
    fi
    
    if [ -z "$OUTPUT_DIR" ]; then
        echo "ERROR: --output-dir is required for delete mode" >&2
        exit 1
    fi
    
    # Initialize log file for delete operation
    LOG_FILE="${OUTPUT_DIR}/msp-delete-$(date +%Y%m%d-%H%M%S).log"
    
    # Initialize ODF context and toolbox pod if in ODF mode
    if [ "$MODE" = "odf" ]; then
        # Verify OCP login
        if ! oc whoami &>/dev/null; then
            echo "ERROR: Not logged into an OpenShift cluster. Run: oc login <api-url>" >&2
            exit 1
        fi

        # Auto-detect namespace for delete/update paths, since Phase 1 is skipped
        if [ -z "$NAMESPACE" ]; then
            common_namespaces=("openshift-storage" "odf" "red-hat-odf")
            for ns in "${common_namespaces[@]}"; do
                if oc get namespace "$ns" &>/dev/null 2>&1; then
                    sc_count=$(oc get storagecluster -n "$ns" -o jsonpath='{.items | length}' 2>/dev/null || echo "0")
                    if [ "$sc_count" -gt 0 ]; then
                        NAMESPACE="$ns"
                        break
                    fi
                fi
            done

            if [ -z "$NAMESPACE" ]; then
                namespaces_with_sc=$(oc get storagecluster --all-namespaces -o jsonpath='{.items[*].metadata.namespace}' 2>/dev/null | tr ' ' '\n' | sort -u)
                if [ -n "$namespaces_with_sc" ]; then
                    NAMESPACE=$(echo "$namespaces_with_sc" | head -1)
                fi
            fi

            if [ -n "$NAMESPACE" ]; then
                print_info "Auto-detected namespace: ${NAMESPACE}"
            else
                echo "ERROR: Failed to auto-detect ODF namespace. Specify --namespace <namespace>." >&2
                exit 1
            fi
        fi

        # Auto-detect storage cluster for delete/update paths if not provided
        if [ -z "$STORAGECLUSTER_NAME" ]; then
            sc_list=$(oc get storagecluster -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$sc_list" ]; then
                STORAGECLUSTER_NAME=$(echo "$sc_list" | awk '{print $1}')
            fi
            if [ -n "$STORAGECLUSTER_NAME" ]; then
                print_info "Auto-detected storage cluster: ${STORAGECLUSTER_NAME}"
            fi
        fi
        
        # Find toolbox pod
        TOOLBOX_POD=$(oc get pods -n "$NAMESPACE" -l app=rook-ceph-tools \
                      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -z "$TOOLBOX_POD" ]; then
            echo "ERROR: Rook toolbox pod not found in namespace: ${NAMESPACE}" >&2
            echo "       Ensure the toolbox is deployed before running delete operations." >&2
            exit 1
        fi
        print_info "Using toolbox pod: ${TOOLBOX_POD}"
    fi
    
    # Run delete operation
    delete_tenant_storage "$TENANT_NAME"
    delete_result=$?
    
    if [ $delete_result -eq 0 ]; then
        print_success "Tenant storage deleted successfully!"
        exit 0
    else
        print_error "Failed to delete or cleanup tenant storage"
        exit 1
    fi
fi

###############################################################################
# UPDATE MODE HANDLING
###############################################################################
if [ "$UPDATE_MODE" = true ]; then
    if [ -z "$TENANT_NAME" ]; then
        echo "ERROR: --tenant is required for update mode" >&2
        exit 1
    fi
    
    if [ -z "$OUTPUT_DIR" ]; then
        echo "ERROR: --output-dir is required for update mode" >&2
        exit 1
    fi
    
    # Initialize log file for update operation
    LOG_FILE="${OUTPUT_DIR}/msp-update-$(date +%Y%m%d-%H%M%S).log"
    
    # Initialize ODF context and toolbox pod if in ODF mode
    if [ "$MODE" = "odf" ]; then
        # Verify OCP login
        if ! oc whoami &>/dev/null; then
            echo "ERROR: Not logged into an OpenShift cluster. Run: oc login <api-url>" >&2
            exit 1
        fi

        # Auto-detect namespace for delete/update paths, since Phase 1 is skipped
        if [ -z "$NAMESPACE" ]; then
            common_namespaces=("openshift-storage" "odf" "red-hat-odf")
            for ns in "${common_namespaces[@]}"; do
                if oc get namespace "$ns" &>/dev/null 2>&1; then
                    sc_count=$(oc get storagecluster -n "$ns" -o jsonpath='{.items | length}' 2>/dev/null || echo "0")
                    if [ "$sc_count" -gt 0 ]; then
                        NAMESPACE="$ns"
                        break
                    fi
                fi
            done

            if [ -z "$NAMESPACE" ]; then
                namespaces_with_sc=$(oc get storagecluster --all-namespaces -o jsonpath='{.items[*].metadata.namespace}' 2>/dev/null | tr ' ' '\n' | sort -u)
                if [ -n "$namespaces_with_sc" ]; then
                    NAMESPACE=$(echo "$namespaces_with_sc" | head -1)
                fi
            fi

            if [ -n "$NAMESPACE" ]; then
                print_info "Auto-detected namespace: ${NAMESPACE}"
            else
                echo "ERROR: Failed to auto-detect ODF namespace. Specify --namespace <namespace>." >&2
                exit 1
            fi
        fi

        # Auto-detect storage cluster for delete/update paths if not provided
        if [ -z "$STORAGECLUSTER_NAME" ]; then
            sc_list=$(oc get storagecluster -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$sc_list" ]; then
                STORAGECLUSTER_NAME=$(echo "$sc_list" | awk '{print $1}')
            fi
            if [ -n "$STORAGECLUSTER_NAME" ]; then
                print_info "Auto-detected storage cluster: ${STORAGECLUSTER_NAME}"
            fi
        fi
        
        # Find toolbox pod
        TOOLBOX_POD=$(oc get pods -n "$NAMESPACE" -l app=rook-ceph-tools \
                      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -z "$TOOLBOX_POD" ]; then
            echo "ERROR: Rook toolbox pod not found in namespace: ${NAMESPACE}" >&2
            echo "       Ensure the toolbox is deployed before running update operations." >&2
            exit 1
        fi
        print_info "Using toolbox pod: ${TOOLBOX_POD}"
    fi
    
    # Run update operation
    # Temporarily disable 'set -e' to allow return 2 without exiting the script
    set +e
    update_tenant_storage
    update_result=$?
    set -e

    if [ $update_result -eq 2 ]; then
        # Mode switch to provision - continue with provision flow
        print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_info "Switching to PROVISION mode..."
        print_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        UPDATE_MODE=false  # Disable update mode
        # Re-initialize log file for provision operation
        LOG_FILE="${OUTPUT_DIR}/msp-provision-$(date +%Y%m%d-%H%M%S).log"
        # Continue to provision flow below (don't exit)
    elif [ $update_result -eq 0 ]; then
        print_success "Tenant storage updated successfully!"
        exit 0
    else
        print_error "Failed to update tenant storage"
        exit 1
    fi
fi

###############################################################################
# RESUME / VALIDATE
###############################################################################

# --resume requires output-dir so state file can be located
if [ "$RESUME_MODE" = true ] && [ -z "$OUTPUT_DIR" ]; then
    echo "ERROR: --resume requires --output-dir to locate the state file." >&2
    exit 1
fi

if [ -z "$OUTPUT_DIR" ]; then
    echo "ERROR: --output-dir is required for security reasons." >&2
    echo "       Specify a secure directory (e.g., ~/odf-configs)" >&2
    echo "       Never use /tmp or other world-accessible directories." >&2
    echo "       Use --help for more information." >&2
    exit 1
fi

# Initialize state and log file paths based on OUTPUT_DIR
STATE_FILE="${OUTPUT_DIR}/msp-provision-state.txt"
LOG_FILE="${OUTPUT_DIR}/msp-provision-$(date +%Y%m%d-%H%M%S).log"

if [ "$RESUME_MODE" = false ] && [ "$START_PHASE" -eq 1 ] && [ -f "$STATE_FILE" ]; then
    SAVED_PHASE=$(sed -n '1p' "$STATE_FILE" 2>/dev/null || echo "")
    if [[ "$SAVED_PHASE" =~ ^[0-9]+$ ]] && [ "$SAVED_PHASE" -gt 1 ]; then
        START_PHASE="$SAVED_PHASE"
        print_info "Auto-resuming from saved setup-storage phase ${START_PHASE}"
    fi
fi

###############################################################################
# PROVISION MODE VALIDATION
###############################################################################

if [ "$RESUME_MODE" = true ]; then
    if load_state; then
        print_info "Resuming from Phase ${START_PHASE} for tenant: ${TENANT_NAME}"
    else
        echo "ERROR: No state file found at ${STATE_FILE}. Cannot resume." >&2
        exit 1
    fi
fi

if [ -z "$TENANT_NAME" ]; then
    echo "ERROR: --tenant is required. Use --help for usage." >&2
    exit 1
fi

if [ -z "$RBD_QUOTA" ]; then
    echo "ERROR: --rbd-quota is required. Use --help for usage." >&2
    echo "       Block storage is required for NooBaa PostgreSQL PVC." >&2
    exit 1
fi

# Block storage is always enabled (required for NooBaa)
ENABLE_BLOCK_STORAGE=true

if [ -z "$OUTPUT_DIR" ]; then
    echo "ERROR: --output-dir is required for security reasons." >&2
    echo "       Specify a secure directory (e.g., ~/odf-configs)" >&2
    echo "       Never use /tmp or other world-accessible directories." >&2
    echo "       Use --help for more information." >&2
    exit 1
fi

if ! [[ "$TENANT_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "ERROR: Invalid tenant name '${TENANT_NAME}'. Use lowercase letters, numbers, and hyphens only." >&2
    exit 1
fi

# Create output directory if it doesn't exist
if [ ! -d "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR" || {
        echo "ERROR: Failed to create output directory: ${OUTPUT_DIR}" >&2
        exit 1
    }
fi

# Initialize state and log file paths based on OUTPUT_DIR
STATE_FILE="${OUTPUT_DIR}/msp-provision-state.txt"
LOG_FILE="${OUTPUT_DIR}/msp-provision-$(date +%Y%m%d-%H%M%S).log"

print_debug "After UPDATE mode block, UPDATE_MODE=$UPDATE_MODE"
print_debug "Entering PROVISION MODE VALIDATION"

# Derived names
POOL_NAME="${TENANT_NAME}-rbd-pool"
USER_NAME="client.${TENANT_NAME}"
RGW_USER_NAME="${TENANT_NAME}-noobaa-user"
BACKING_BUCKET="${TENANT_NAME}-backing-bucket"
CA_BUNDLE_FILE="${OUTPUT_DIR}/${TENANT_NAME}-ca-bundle.crt"

# CSI user names
CSI_RBD_NODE_USER="csi-rbd-node-${TENANT_NAME}-${POOL_NAME}"
CSI_RBD_PROV_USER="csi-rbd-provisioner-${TENANT_NAME}-${POOL_NAME}"

###############################################################################
# BANNER
###############################################################################
if [ "$ENABLE_OBJECT_STORAGE" = true ]; then
    echo ""
    print_header "============================================================"
    print_header "  Ceph Provisioning — Block and Object Storage"
    print_header "============================================================"
    print_info "Mode:             ${MODE}"
    print_info "Tenant:           ${TENANT_NAME}"
    print_info "RBD Pool:         ${POOL_NAME}"
    print_info "RBD Quota:        ${RBD_QUOTA}"
    print_info "RGW User:         ${RGW_USER_NAME}"
    print_info "RGW User Quota:   ${RGW_USER_QUOTA}"
    print_info "Backing Bucket:   ${BACKING_BUCKET}"
    print_info "RGW Region:       ${RGW_REGION}"
    print_info "Pool PGs:         ${POOL_PGS}"
    print_info "Output Dir:       ${OUTPUT_DIR}"
    print_info "Log File:         ${LOG_FILE}"
    print_info "Start Phase:      ${START_PHASE}"
    print_header "============================================================"
else
    echo ""
    print_header "========================================================"
    print_header "  Ceph Provisioning — Block Storage Only"
    print_header "========================================================"
    print_info "Mode:             ${MODE}"
    print_info "Tenant:           ${TENANT_NAME}"
    print_info "RBD Pool:         ${POOL_NAME}"
    print_info "RBD Quota:        ${RBD_QUOTA}"
    print_info "Pool PGs:         ${POOL_PGS}"
    print_info "Output Dir:       ${OUTPUT_DIR}"
    print_info "Log File:         ${LOG_FILE}"
    print_info "Start Phase:      ${START_PHASE}"
    print_header "========================================================"
fi
echo ""

###############################################################################
# HELPER FUNCTIONS
###############################################################################
# Detect the correct RGW zone for user creation
detect_rgw_zone() {
    local zone_list
    local default_zone
    
    print_debug "Detecting RGW zone..."
    
    # Get list of zones
    zone_list=$(ceph_exec radosgw-admin zone list 2>&1 || echo "")
    
    if [ -z "$zone_list" ]; then
        print_warning "Could not detect RGW zones, using default"
        echo "default"
        return
    fi
    
    # Check if storage cluster CephObjectStore zone exists
    local rgw_zone_name="${STORAGECLUSTER_NAME}-cephobjectstore"
    if echo "$zone_list" | grep -q "$rgw_zone_name"; then
        print_debug "Found ODF zone: $rgw_zone_name"
        echo "$rgw_zone_name"
        return
    fi
    
    # Get default zone
    default_zone=$(echo "$zone_list" | sed -n 's/.*"default_info":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    
    if [ -n "$default_zone" ]; then
        print_debug "Using default zone from zone list"
        echo "default"
    else
        print_debug "No specific zone detected, using 'default'"
        echo "default"
    fi
}

extract_json_string_field() {
    local input="$1"
    local field="$2"
    echo "$input" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1
}

convert_to_bytes() {
    local size="$1"
    local num="${size//[^0-9]/}"
    local unit="${size//[0-9]/}"
    unit=$(echo "$unit" | tr '[:lower:]' '[:upper:]')
    
    case "$unit" in
        K|KB) echo $((num * 1024)) ;;
        M|MB) echo $((num * 1024 * 1024)) ;;
        G|GB) echo $((num * 1024 * 1024 * 1024)) ;;
        T|TB) echo $((num * 1024 * 1024 * 1024 * 1024)) ;;
        P|PB) echo $((num * 1024 * 1024 * 1024 * 1024 * 1024)) ;;
        *) echo "$num" ;;
    esac
}

ceph_exec() {
    if [ "$MODE" = "native" ]; then
        if [ "$1" = "ceph" ]; then
            shift
            ceph "$@"
        elif [ "$1" = "radosgw-admin" ]; then
            "$@"
        else
            "$@"
        fi
    else
        oc exec -n "$NAMESPACE" "$TOOLBOX_POD" -- "$@"
    fi
}

###############################################################################
# AUTO-DETECT NAMESPACE FOR ODF MODE
###############################################################################
auto_detect_namespace() {
    print_debug "Auto-detecting ODF namespace..."
    
    if ! command -v oc &>/dev/null; then
        print_debug "oc command not available, cannot auto-detect namespace"
        return 1
    fi
    
    if ! oc whoami &>/dev/null 2>&1; then
        print_debug "Not logged into OpenShift cluster, cannot auto-detect namespace"
        return 1
    fi
    
    local common_namespaces=("openshift-storage" "odf" "red-hat-odf")
    
    for ns in "${common_namespaces[@]}"; do
        if oc get namespace "$ns" &>/dev/null 2>&1; then
            local sc_count
            sc_count=$(oc get storagecluster -n "$ns" -o jsonpath='{.items | length}' 2>/dev/null || echo "0")
            
            if [ "$sc_count" -gt 0 ]; then
                print_debug "Found ODF namespace with StorageClusters: $ns"
                NAMESPACE="$ns"
                return 0
            fi
        fi
    done
    
    print_debug "Common namespaces not found, searching all namespaces..."
    local namespaces_with_sc
    namespaces_with_sc=$(oc get storagecluster --all-namespaces -o jsonpath='{.items[*].metadata.namespace}' 2>/dev/null | tr ' ' '\n' | sort -u)
    
    if [ -n "$namespaces_with_sc" ]; then
        NAMESPACE=$(echo "$namespaces_with_sc" | head -1)
        local ns_count
        ns_count=$(echo "$namespaces_with_sc" | wc -l)
        
        if [ "$ns_count" -gt 1 ]; then
            print_warning "Multiple namespaces with StorageClusters found: $(echo "$namespaces_with_sc" | tr '\n' ', ')"
            print_warning "Using first namespace: $NAMESPACE"
            print_info "To use a different namespace, specify with: --namespace <namespace>"
        fi
        
        print_debug "Auto-detected ODF namespace: $NAMESPACE"
        return 0
    fi
    
    print_debug "No ODF namespace with StorageClusters found"
    return 1
}

auto_detect_storagecluster() {
    print_debug "Auto-detecting storage cluster (mode: ${MODE}, namespace: ${NAMESPACE})..."
    
    if command -v oc &>/dev/null && oc whoami &>/dev/null 2>&1; then
        print_debug "OpenShift/OCP detected, scanning for StorageCluster resources..."
        
        local sc_list
        sc_list=$(oc get storagecluster -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        
        if [ -n "$sc_list" ]; then
            local sc_count
            sc_count=$(echo "$sc_list" | wc -w)
            
            if [ "$sc_count" -eq 1 ]; then
                STORAGECLUSTER_NAME=$(echo "$sc_list" | awk '{print $1}')
                print_success "✓ Auto-detected StorageCluster: ${STORAGECLUSTER_NAME}"
                return 0
            else
                print_debug "Multiple StorageClusters detected (${sc_count}): ${sc_list}"
                
                local ready_sc
                ready_sc=$(oc get storagecluster -n "$NAMESPACE" -o jsonpath='{.items[?(@.status.phase=="Ready")].metadata.name}' 2>/dev/null | awk '{print $1}')
                
                if [ -n "$ready_sc" ]; then
                    STORAGECLUSTER_NAME="$ready_sc"
                    print_success "✓ Auto-detected ready StorageCluster: ${STORAGECLUSTER_NAME}"
                    return 0
                else
                    STORAGECLUSTER_NAME=$(echo "$sc_list" | awk '{print $1}')
                    print_warning "No StorageCluster in Ready phase. Using first available: ${STORAGECLUSTER_NAME}"
                    return 0
                fi
            fi
        else
            print_debug "No StorageCluster resources found in namespace '${NAMESPACE}'"
        fi
    fi
    
    if [ "$MODE" = "native" ] && command -v ceph &>/dev/null; then
        print_debug "Native Ceph mode detected, attempting to detect Ceph cluster identity..."
        
        local ceph_fsid
        ceph_fsid=$(ceph fsid 2>/dev/null || echo "")
        
        if [ -n "$ceph_fsid" ]; then
            STORAGECLUSTER_NAME="ceph-${ceph_fsid:0:8}"
            print_success "✓ Auto-detected native Ceph cluster: ${STORAGECLUSTER_NAME} (FSID: ${ceph_fsid})"
            CEPH_FSID="$ceph_fsid"
            return 0
        fi
    fi
    
    print_error "Could not auto-detect storage cluster"
    print_error ""
    print_error "Please ensure one of the following:"
    print_error "  1. For ODF/Fusion-on-OCP: oc CLI is installed and logged in"
    print_error "  2. For native Ceph: ceph CLI is installed and configured"
    print_error "  3. Or manually specify with: --storagecluster <name>"
    exit 1
}

# Ensure all runtime dependencies are initialized
# This is called before phases that were skipped to ensure required variables are set
ensure_runtime_dependencies() {
    local phase=$1
    
    # TOOLBOX_POD is needed for phases 2, 3, 4, 5 in ODF mode (any phase using ceph_exec)
    if [ "$MODE" = "odf" ] && [ "$phase" -ge 2 ] && [ -z "$TOOLBOX_POD" ]; then
        print_debug "Initializing TOOLBOX_POD for phase ${phase}..."
        TOOLBOX_POD=$(oc get pods -n "$NAMESPACE" -l app=rook-ceph-tools \
                      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -z "$TOOLBOX_POD" ]; then
            print_error "Rook toolbox pod not found in namespace: ${NAMESPACE}"
            print_error "Required for phases 2-5. Ensure toolbox is deployed."
            exit 1
        fi
        print_debug "Toolbox pod: ${TOOLBOX_POD}"
    fi
    
    # For native mode, verify ceph command is available
    if [ "$MODE" = "native" ] && [ "$phase" -ge 2 ]; then
        if ! command -v ceph &>/dev/null; then
            print_error "ceph command not found. Ensure Ceph client tools are installed."
            print_error "Install with: apt-get install ceph-common (Debian/Ubuntu)"
            print_error "           or: yum install ceph-common (RHEL/CentOS)"
            exit 1
        fi
        print_debug "Ceph command available"
    fi
}

###############################################################################
# PHASE 1: PRE-FLIGHT CHECKS
###############################################################################
if should_skip_phase 1; then
    print_info "Skipping Phase 1 (already completed)"
else
    ensure_runtime_dependencies 1
    save_phase 1
    echo ""
    print_header "============================================================"
    print_header "PHASE 1: Pre-flight Checks"
    print_header "============================================================"
    echo ""
    # Core tool dependencies
    require_cmd jq "Install jq to process generated JSON artifacts."
    require_cmd curl "Install curl for endpoint reachability and S3 API checks."
    if [ "$ENABLE_OBJECT_STORAGE" = true ]; then
        require_cmd openssl "Install openssl for certificate validation and RGW signature generation."
        require_cmd base64 "Install base64 utility for S3 request signing."
    fi
    
    # Auto-detect namespace for ODF mode
    if [ "$MODE" = "odf" ] && [ -z "$NAMESPACE" ]; then
        print_info "Auto-detecting ODF namespace..."
        common_namespaces=("openshift-storage" "odf" "red-hat-odf")
        for ns in "${common_namespaces[@]}"; do
            if oc get namespace "$ns" &>/dev/null 2>&1; then
                sc_count=$(oc get storagecluster -n "$ns" -o jsonpath='{.items | length}' 2>/dev/null || echo "0")
                if [ "$sc_count" -gt 0 ]; then
                    NAMESPACE="$ns"
                    break
                fi
            fi
        done

        if [ -z "$NAMESPACE" ]; then
            namespaces_with_sc=$(oc get storagecluster --all-namespaces -o jsonpath='{.items[*].metadata.namespace}' 2>/dev/null | tr ' ' '\n' | sort -u)
            if [ -n "$namespaces_with_sc" ]; then
                NAMESPACE=$(echo "$namespaces_with_sc" | head -1)
            fi
        fi

        if [ -n "$NAMESPACE" ]; then
            print_success "✓ Auto-detected namespace: ${NAMESPACE}"
        else
            print_error "Failed to auto-detect ODF namespace"
            print_error "Please ensure you are logged into OpenShift and ODF is installed"
            print_error "Or manually specify with: --namespace <namespace>"
            exit 1
        fi
    fi
    
    # Auto-detect StorageCluster for ODF mode
    if [ "$MODE" = "odf" ] && [ -z "$STORAGECLUSTER_NAME" ]; then
        print_info "Auto-detecting storage cluster..."
        sc_list=$(oc get storagecluster -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$sc_list" ]; then
            ready_sc=$(oc get storagecluster -n "$NAMESPACE" -o jsonpath='{.items[?(@.status.phase=="Ready")].metadata.name}' 2>/dev/null | awk '{print $1}')
            if [ -n "$ready_sc" ]; then
                STORAGECLUSTER_NAME="$ready_sc"
            else
                STORAGECLUSTER_NAME=$(echo "$sc_list" | awk '{print $1}')
            fi
        fi

        if [ -n "$STORAGECLUSTER_NAME" ]; then
            print_success "✓ Auto-detected storage cluster: ${STORAGECLUSTER_NAME}"
        else
            print_error "Failed to auto-detect storage cluster"
            exit 1
        fi
    fi
    
    if [ "$MODE" = "odf" ]; then
        # ODF mode checks
        # OCP login
        if ! oc whoami &>/dev/null; then
            print_error "Not logged into an OpenShift cluster. Run: oc login <api-url>"
            exit 1
        fi
        CLUSTER_URL=$(oc whoami --show-server)
        print_success "Logged into cluster: ${CLUSTER_URL}"
        
        # Verify namespace exists
        if ! oc get namespace "$NAMESPACE" &>/dev/null; then
            print_error "Namespace '${NAMESPACE}' not found"
            exit 1
        fi
        print_success "Namespace exists: ${NAMESPACE}"
        
        # Verify StorageCluster exists and is Ready (if auto-detection found one)
        if [ -n "$STORAGECLUSTER_NAME" ] && ! [[ "$STORAGECLUSTER_NAME" =~ ^ceph- ]]; then
            # ODF StorageCluster (not native Ceph)
            if ! oc get storagecluster "$STORAGECLUSTER_NAME" -n "$NAMESPACE" &>/dev/null; then
                print_error "StorageCluster '${STORAGECLUSTER_NAME}' not found in namespace '${NAMESPACE}'"
                exit 1
            fi
            SC_PHASE=$(oc get storagecluster "$STORAGECLUSTER_NAME" -n "$NAMESPACE" \
                       -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            if [ "$SC_PHASE" != "Ready" ]; then
                print_error "StorageCluster phase is '${SC_PHASE}' (expected: Ready)"
                exit 1
            fi
            print_success "StorageCluster is Ready: ${STORAGECLUSTER_NAME}"
        fi
        
        # Find toolbox pod
        TOOLBOX_POD=$(oc get pods -n "$NAMESPACE" -l app=rook-ceph-tools \
                      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -z "$TOOLBOX_POD" ]; then
            print_error "Rook toolbox pod not found. Deploy it first."
            exit 1
        fi
        print_success "Toolbox pod found: ${TOOLBOX_POD}"
        
        # Verify main RGW exists if object storage is enabled
        if [ "$ENABLE_OBJECT_STORAGE" = true ]; then
            ceph_objectstore_name="${STORAGECLUSTER_NAME}-cephobjectstore"
            if ! oc get cephobjectstore "$ceph_objectstore_name" -n "$NAMESPACE" &>/dev/null; then
                print_error "Main CephObjectStore '$ceph_objectstore_name' not found"
                print_error "Object storage requires a main RGW to be deployed"
                exit 1
            fi
            print_success "Main CephObjectStore exists: $ceph_objectstore_name"
            
            # Discover both HTTP and HTTPS routes
            print_info "Discovering RGW endpoints..."
            http_route_name="$ceph_objectstore_name"
            https_route_name="${STORAGECLUSTER_NAME}-cephobjectstore-secure"
            RGW_HTTP_ENDPOINT=$(oc get route "$http_route_name" \
                                -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
            RGW_HTTPS_ENDPOINT=$(oc get route "$https_route_name" \
                                 -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
            
            # Prefer HTTPS if available, otherwise use HTTP
            if [ -n "$RGW_HTTPS_ENDPOINT" ]; then
                MAIN_RGW_ENDPOINT="$RGW_HTTPS_ENDPOINT"
                RGW_PROTOCOL="https"
                print_info "Using HTTPS endpoint (secure)"
            elif [ -n "$RGW_HTTP_ENDPOINT" ]; then
                MAIN_RGW_ENDPOINT="$RGW_HTTP_ENDPOINT"
                RGW_PROTOCOL="http"
                print_warning "HTTPS endpoint not found, falling back to HTTP"
            fi
            
            # Fallback to service endpoint if no routes exist
            if [ -z "$MAIN_RGW_ENDPOINT" ]; then
                print_warning "No external routes found, using internal service endpoint"
                MAIN_RGW_ENDPOINT=$(oc get cephobjectstore "$ceph_objectstore_name" \
                                    -n "$NAMESPACE" -o jsonpath='{.status.info.endpoint}' 2>/dev/null || echo "")
                
                # Strip protocol if present
                if [[ "$MAIN_RGW_ENDPOINT" =~ ^https?:// ]]; then
                    RGW_PROTOCOL=$(echo "$MAIN_RGW_ENDPOINT" | grep -oP '^https?')
                    MAIN_RGW_ENDPOINT=$(echo "$MAIN_RGW_ENDPOINT" | sed 's|^https\?://||')
                fi
                
                # Remove port if present (we'll use standard ports)
                MAIN_RGW_ENDPOINT=$(echo "$MAIN_RGW_ENDPOINT" | sed 's|:[0-9]*$||')
            fi
            
            if [ -z "$MAIN_RGW_ENDPOINT" ]; then
                print_error "Could not find main RGW endpoint (tried routes and service)"
                exit 1
            fi
            
            print_info "RGW endpoint found: ${RGW_PROTOCOL}://${MAIN_RGW_ENDPOINT}"
            if [ -n "$RGW_HTTP_ENDPOINT" ]; then
                print_info "  HTTP endpoint:  http://${RGW_HTTP_ENDPOINT}"
            fi
            if [ -n "$RGW_HTTPS_ENDPOINT" ]; then
                print_info "  HTTPS endpoint: https://${RGW_HTTPS_ENDPOINT}"
            fi
        fi
    else
        # Native Ceph mode checks
        # Verify ceph command is available
        if ! command -v ceph &>/dev/null; then
            print_error "ceph command not found. Ensure Ceph client tools are installed."
            print_error "Install with: apt-get install ceph-common (Debian/Ubuntu)"
            print_error "           or: yum install ceph-common (RHEL/CentOS)"
            exit 1
        fi
        print_success "Ceph command available"
        
        # Verify Ceph configuration
        if [ ! -f /etc/ceph/ceph.conf ]; then
            print_error "Ceph configuration not found at /etc/ceph/ceph.conf"
            print_error "Ensure Ceph client is properly configured"
            exit 1
        fi
        print_success "Ceph configuration found"
        
        # Verify Ceph keyring
        if [ ! -f /etc/ceph/ceph.client.admin.keyring ]; then
            print_error "Ceph admin keyring not found at /etc/ceph/ceph.client.admin.keyring"
            print_error "Ensure you have admin credentials"
            exit 1
        fi
        print_success "Ceph admin keyring found"
        
        # Test Ceph connectivity
        if ! ceph status &>/dev/null; then
            print_error "Cannot connect to Ceph cluster. Check configuration and credentials."
            exit 1
        fi
        print_success "Connected to Ceph cluster"
        
        # Detect RGW endpoint if object storage is enabled
        if [ "$ENABLE_OBJECT_STORAGE" = true ]; then
            print_info "Detecting RGW endpoint for native Ceph mode..."
            
            # Strategy:
            # 1. Try ceph orch ps (cephadm/orchestrator) - most accurate for managed clusters
            # 2. Fallback to ceph config dump - works for all deployments
            # 3. Extract hostname from ceph.conf or mon_host
            
            RGW_HOST=""
            RGW_PORT=""
            RGW_SSL_PORT=""
            RGW_PROTOCOL="http"
            
            # Method 1: Try to get RGW service info from ceph orchestrator
            if ceph orch ps --daemon-type rgw &>/dev/null; then
                print_debug "Using ceph orchestrator to detect RGW services..."
                
                # Get all RGW services
                RGW_SERVICES=$(ceph orch ps --daemon-type rgw 2>/dev/null | grep -v "NAME" || echo "")
                RGW_COUNT=$(echo "$RGW_SERVICES" | grep -c "rgw\." || echo "0")
                
                if [ "$RGW_COUNT" -gt 1 ]; then
                    print_warning "Multiple RGW services detected (${RGW_COUNT}). Using the first one."
                    print_warning "To specify a different RGW, set MAIN_RGW_ENDPOINT manually."
                    print_warning "Note: Ensure the selected RGW is network-accessible from the tenant plane."
                    print_warning "You may need to verify network connectivity and firewall rules."
                fi
                
                # Extract hostname and port from first RGW service
                # Format: rgw.ocmirror.sc5-ceph01.deuuvy  sc5-ceph01  *:8000  running...
                RGW_SERVICE_INFO=$(echo "$RGW_SERVICES" | head -1)
                
                if [ -n "$RGW_SERVICE_INFO" ]; then
                    RGW_HOST=$(echo "$RGW_SERVICE_INFO" | awk '{print $2}')
                    RGW_PORT_INFO=$(echo "$RGW_SERVICE_INFO" | awk '{print $3}')
                    
                    # Extract port from *:PORT or IP:PORT format (handles IPv4 and IPv6)
                    # For IPv6, format is [addr]:port, for IPv4 it's addr:port or *:port
                    if [[ "$RGW_PORT_INFO" =~ \]:([0-9]+)$ ]]; then
                        # IPv6 format: [addr]:port
                        RGW_PORT="${BASH_REMATCH[1]}"
                    elif [[ "$RGW_PORT_INFO" =~ :([0-9]+)$ ]]; then
                        # IPv4 format: addr:port or *:port
                        RGW_PORT="${BASH_REMATCH[1]}"
                    fi
                    
                    print_debug "RGW service found via orchestrator - host: ${RGW_HOST}, port: ${RGW_PORT}"
                fi
            else
                print_debug "Ceph orchestrator not available, using config-based detection..."
            fi
            
            # Method 2: Fallback to config-based detection if orchestrator didn't work
            if [ -z "$RGW_HOST" ] || [ -z "$RGW_PORT" ]; then
                print_debug "Parsing RGW configuration from ceph config..."
                
                # Get rgw_frontends configuration
                RGW_ENDPOINT_RAW=$(ceph config dump | grep "rgw_frontends" | head -1 | awk '{print $NF}' || echo "")
                
                if [ -n "$RGW_ENDPOINT_RAW" ]; then
                    print_debug "Found rgw_frontends config: ${RGW_ENDPOINT_RAW}"
                    
                    # Parse the endpoint (format: "beast port=8080" or "beast ssl_port=8443 ssl_certificate=...")
                    # Extract both HTTP and SSL ports if available
                    # Note: rgw_frontends can have formats like 'beast port=8080' or 'beast port="8080"'
                    if [[ "$RGW_ENDPOINT_RAW" =~ port=\"?([0-9]+)\"? ]]; then
                        RGW_PORT="${BASH_REMATCH[1]}"
                    fi
                    
                    if [[ "$RGW_ENDPOINT_RAW" =~ ssl_port=\"?([0-9]+)\"? ]]; then
                        RGW_SSL_PORT="${BASH_REMATCH[1]}"
                    fi
                    
                    # Determine current protocol
                    if [[ "$RGW_ENDPOINT_RAW" =~ ssl_port ]] || [[ "$RGW_ENDPOINT_RAW" =~ ssl_certificate ]]; then
                        if [ -n "$RGW_SSL_PORT" ]; then
                            RGW_PROTOCOL="https"
                            RGW_PORT="$RGW_SSL_PORT"
                        else
                            RGW_PROTOCOL="https"
                            RGW_PORT="443"
                        fi
                    else
                        RGW_PROTOCOL="http"
                    fi
                fi
                
                # Set default port if still not found
                if [ -z "$RGW_PORT" ]; then
                    RGW_PORT="80"
                    RGW_PROTOCOL="http"
                fi
                
                # Get hostname from ceph.conf
                if grep -q "^rgw_host" /etc/ceph/ceph.conf 2>/dev/null; then
                    RGW_HOST=$(grep "^rgw_host" /etc/ceph/ceph.conf | head -1 | awk '{print $3}')
                    print_debug "Found rgw_host in ceph.conf: ${RGW_HOST}"
                else
                    # Extract first monitor IP from mon_host as fallback
                    # mon_host format: [v2:192.168.2.41:3300/0,v1:192.168.2.41:6789/0] [v2:192.168.2.42:3300/0,...]
                    # Extract: 192.168.2.41
                    MON_HOST_LINE=$(grep "^mon_host" /etc/ceph/ceph.conf | head -1 || echo "")
                    if [ -n "$MON_HOST_LINE" ]; then
                        # Remove protocol prefix (v2:, v1:), extract IP, remove port and brackets
                        RGW_HOST=$(echo "$MON_HOST_LINE" | sed 's/.*v[12]://;s/:[0-9]*.*//;s/\[//;s/\]//' | cut -d',' -f1)
                        print_debug "Using first monitor IP as RGW host: ${RGW_HOST}"
                    else
                        print_error "Could not determine RGW hostname from ceph.conf"
                        print_error "RGW endpoint must be accessible from external clusters (ODF client)"
                        print_error "Please ensure 'rgw_host' or 'mon_host' is configured in /etc/ceph/ceph.conf"
                        print_error "Or manually set MAIN_RGW_ENDPOINT environment variable before running this script"
                        exit 1
                    fi
                fi
            fi
            
            # Final validation
            if [ -z "$RGW_HOST" ] || [ "$RGW_HOST" = "localhost" ] || [ "$RGW_HOST" = "127.0.0.1" ]; then
                print_error "Invalid RGW hostname detected: '${RGW_HOST}'"
                print_error "RGW must be accessible from external clusters (ODF client), not localhost"
                print_error "Please configure a proper hostname/IP in ceph.conf or set MAIN_RGW_ENDPOINT manually"
                exit 1
            fi
            
            if [ -z "$RGW_PORT" ]; then
                print_error "Failed to detect RGW port"
                exit 1
            fi
            
            # Construct endpoint
            MAIN_RGW_ENDPOINT="${RGW_HOST}:${RGW_PORT}"
            
            print_info "RGW endpoint detected: ${RGW_PROTOCOL}://${MAIN_RGW_ENDPOINT}"
            
            # Verify radosgw-admin is available
            if ! command -v radosgw-admin &>/dev/null; then
                print_warning "radosgw-admin command not found. Install ceph-radosgw package if needed."
            fi
            
            # Verify endpoint is reachable
            print_info "Verifying RGW endpoint is reachable..."
            
            # Start progress bar in background
            show_progress_bar "Checking endpoint" 5 &
            progress_pid=$!
            
            http_code=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "${RGW_PROTOCOL}://${MAIN_RGW_ENDPOINT}/" 2>/dev/null)
            
            # Stop progress bar
            kill "$progress_pid" 2>/dev/null || true
            wait "$progress_pid" 2>/dev/null || true
            
            # Clear progress bar line
            if [ -t 1 ]; then
                printf "\r%*s\r" 100 ""
            fi
            
            if echo "$http_code" | grep -q "^[23]"; then
                print_success "RGW endpoint is reachable: ${RGW_PROTOCOL}://${MAIN_RGW_ENDPOINT}"
            else
                print_warning "RGW endpoint may not be reachable from this host: ${RGW_PROTOCOL}://${MAIN_RGW_ENDPOINT}"
                print_warning "This is OK if RGW is not accessible from the Ceph admin node"
                print_warning "NooBaa will access it from within the tenant cluster"
            fi
        fi
    fi
    
    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    print_success "Output directory ready: ${OUTPUT_DIR}"
    
    print_success "Phase 1 Complete: Pre-flight checks passed"
    echo ""
fi

###############################################################################
# PHASE 2: CEPH HEALTH CHECK
###############################################################################
if should_skip_phase 2; then
    print_info "Skipping Phase 2 (already completed)"
else
    ensure_runtime_dependencies 2
    save_phase 2
    echo ""
    print_header "============================================================"
    print_header "PHASE 2: Ceph Health Check"
    print_header "============================================================"
    echo ""
    CEPH_STATUS=$(ceph_exec ceph status 2>&1 || echo "ERROR")
    if echo "$CEPH_STATUS" | grep -q "ERROR"; then
        print_error "Failed to get Ceph status"
        print_error "$CEPH_STATUS"
        exit 1
    fi
    
    CEPH_HEALTH=$(echo "$CEPH_STATUS" | grep "health:" | awk '{print $2}')
    print_info "Ceph health: ${CEPH_HEALTH}"
    
    if [ "$CEPH_HEALTH" != "HEALTH_OK" ] && [ "$CEPH_HEALTH" != "HEALTH_WARN" ]; then
        print_error "Ceph cluster is not healthy: ${CEPH_HEALTH}"
        print_error "Fix Ceph health issues before provisioning tenants"
        exit 1
    fi
    
    if [ "$CEPH_HEALTH" = "HEALTH_WARN" ]; then
        print_warning "Ceph cluster has warnings — proceeding anyway"
    fi
    
    print_success "Phase 2 Complete: Ceph health check passed"
    echo ""
fi

###############################################################################
# PHASE 3: CREATE RBD POOL
###############################################################################
if should_skip_phase 3; then
    print_info "Skipping Phase 3 (already completed)"
else
    ensure_runtime_dependencies 3
    save_phase 3
    echo ""
    print_header "============================================================"
    print_header "PHASE 3: Create RBD Pool"
    print_header "============================================================"
    # Determine PG count using new logic
    recommended_pg=$(calculate_pg_count)
    
    # Handle different PG selection modes
    if [ "$INTERACTIVE_PG" = true ]; then
        print_info "Interactive PG selection mode enabled"
        select_pg_count_interactive
    elif [ "$AUTO_CALCULATE_PG" = true ]; then
        print_info "Auto-calculating optimal PG count..."
        POOL_PGS="$recommended_pg"
        print_success "Calculated PG count: ${POOL_PGS}"
        display_pg_guidance "$recommended_pg" "$POOL_PGS"
    else
        # Non-interactive: show guidance but use configured value
        display_pg_guidance "$recommended_pg" "$POOL_PGS"
        
        # Warn if significantly different from recommended
        if [ "$POOL_PGS" -lt $((recommended_pg / 2)) ] || [ "$POOL_PGS" -gt $((recommended_pg * 2)) ]; then
            print_warning "Proceeding with configured PG count: ${POOL_PGS}"
            print_info "Consider using --auto-calculate-pgs or --interactive-pgs for optimal values"
            print_info "Or use --enable-autoscaling to let Ceph manage PG count automatically"
            sleep 3
        fi
    fi
    
    # Validate PG count is power of 2
    if ! is_power_of_two "$POOL_PGS"; then
        print_error "PG count must be a power of 2 (8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096)"
        print_info "Recommended value: ${recommended_pg}"
        exit 1
    fi
    
    # Validate minimum PG count
    if [ "$POOL_PGS" -lt 8 ]; then
        print_error "PG count must be at least 8 (current: ${POOL_PGS})"
        print_info "Minimum PG count: 8"
        print_info "Recommended value: ${recommended_pg}"
        exit 1
    fi
    
    # Validate maximum PG count
    if [ "$POOL_PGS" -gt 4096 ]; then
        print_error "PG count must not exceed 4096 (current: ${POOL_PGS})"
        print_info "Maximum PG count: 4096"
        print_info "Recommended value: ${recommended_pg}"
        exit 1
    fi
    
    print_header "============================================================"
    echo ""
    # Create RBD pool (idempotent)
    if ceph_exec ceph osd pool ls 2>/dev/null | grep -q "^${POOL_NAME}$"; then
        print_warning "RBD pool '${POOL_NAME}' already exists — skipping creation"
        
        # If autoscaling requested and pool exists, still enable it
        if [ "$USE_AUTOSCALING" = true ]; then
            print_info "Enabling autoscaling on existing pool..."
            enable_pg_autoscaling "$POOL_NAME"
        fi
    else
        print_info "Creating RBD pool: ${POOL_NAME} (${POOL_PGS} PGs)"
        ceph_exec ceph osd pool create "$POOL_NAME" "$POOL_PGS"
        print_success "RBD pool created: ${POOL_NAME}"
        
        print_info "Enabling RBD application on pool..."
        ceph_exec ceph osd pool application enable "$POOL_NAME" rbd
        print_success "RBD application enabled"
        
        # Enable autoscaling if requested
        if [ "$USE_AUTOSCALING" = true ]; then
            enable_pg_autoscaling "$POOL_NAME"
            check_autoscaler_recommendations
        fi
    fi
    
    # Set RBD quota (always apply — idempotent)
    RBD_QUOTA_BYTES=$(convert_to_bytes "$RBD_QUOTA")
    print_info "Setting RBD quota: ${RBD_QUOTA} (${RBD_QUOTA_BYTES} bytes)"
    if ceph_exec ceph osd pool set-quota "$POOL_NAME" max_bytes "$RBD_QUOTA_BYTES" 2>&1; then
        CURRENT_QUOTA=$(ceph_exec ceph osd pool get-quota "$POOL_NAME" 2>/dev/null || echo "")
        print_info "RBD pool quota: ${CURRENT_QUOTA}"
    else
        print_warning "Failed to set RBD pool quota, but continuing..."
    fi
    
    print_success "Phase 3 Complete: RBD pool '${POOL_NAME}' ready"
    echo ""
fi

###############################################################################
# PHASE 4: CREATE CEPH USERS
###############################################################################
if should_skip_phase 4; then
    print_info "Skipping Phase 4 (already completed)"
else
    ensure_runtime_dependencies 4
    save_phase 4
    echo ""
    print_header "============================================================"
    print_header "PHASE 4: Create Ceph Users"
    print_header "============================================================"
    echo ""
    # Main tenant user
    print_info "Creating Ceph user: ${USER_NAME}"
    if ceph_exec ceph auth get "$USER_NAME" &>/dev/null; then
        print_warning "User '${USER_NAME}' already exists — skipping creation"
    else
        ceph_exec ceph auth get-or-create "$USER_NAME" \
            mon 'profile rbd' \
            osd "profile rbd pool=${POOL_NAME}" \
            mgr 'profile rbd'
        print_success "User created: ${USER_NAME}"
    fi
    
    # CSI RBD node user
    print_info "Creating CSI RBD node user: ${CSI_RBD_NODE_USER}"
    if ceph_exec ceph auth get "client.${CSI_RBD_NODE_USER}" &>/dev/null; then
        print_warning "User 'client.${CSI_RBD_NODE_USER}' already exists"
    else
        ceph_exec ceph auth get-or-create "client.${CSI_RBD_NODE_USER}" \
            mon 'profile rbd, allow command "osd blocklist"' \
            osd "profile rbd pool=${POOL_NAME}" \
            mgr 'profile rbd'
        print_success "CSI RBD node user created"
    fi
    
    # CSI RBD provisioner user
    print_info "Creating CSI RBD provisioner user: ${CSI_RBD_PROV_USER}"
    if ceph_exec ceph auth get "client.${CSI_RBD_PROV_USER}" &>/dev/null; then
        print_warning "User 'client.${CSI_RBD_PROV_USER}' already exists"
    else
        ceph_exec ceph auth get-or-create "client.${CSI_RBD_PROV_USER}" \
            mon 'profile rbd, allow command "osd blocklist"' \
            osd "profile rbd pool=${POOL_NAME}" \
            mgr 'allow rw'
        print_success "CSI RBD provisioner user created"
    fi
    
    print_success "Phase 4 Complete: Ceph users created"
    echo ""
fi

###############################################################################
# PHASE 5: CREATE RGW USER IN MAIN RGW (OPTIONAL)
###############################################################################
if should_skip_phase 5; then
    print_info "Skipping Phase 5 (already completed)"
else
    if [ "$ENABLE_OBJECT_STORAGE" = true ]; then
        ensure_runtime_dependencies 5
        save_phase 5
        echo ""
        print_header "============================================================"
        print_header "PHASE 5: Create RGW User in Main RGW"
        print_header "============================================================"
        echo ""
        # Detect the correct RGW zone
        RGW_ZONE=$(detect_rgw_zone)
        print_info "Detected RGW zone: ${RGW_ZONE}"
        
        print_info "Creating RGW user: ${RGW_USER_NAME} (in main RGW zone: ${RGW_ZONE})"
        
        # Check if user already exists first (check in the correct zone)
        if ceph_exec radosgw-admin user info --uid="${RGW_USER_NAME}" --rgw-zone="${RGW_ZONE}" &>/dev/null; then
            print_warning "RGW user '${RGW_USER_NAME}' already exists in zone '${RGW_ZONE}' — fetching credentials"
            RGW_USER_INFO=$(ceph_exec radosgw-admin user info --uid="${RGW_USER_NAME}" --rgw-zone="${RGW_ZONE}" 2>&1)
            RGW_ACCESS_KEY=$(echo "$RGW_USER_INFO" | jq -r '.keys[0].access_key' 2>/dev/null || echo "")
            RGW_SECRET_KEY=$(echo "$RGW_USER_INFO" | jq -r '.keys[0].secret_key' 2>/dev/null || echo "")
            
            # Fallback to portable field extraction if jq fails
            if [ -z "$RGW_ACCESS_KEY" ] || [ -z "$RGW_SECRET_KEY" ]; then
                RGW_ACCESS_KEY=$(extract_json_string_field "$RGW_USER_INFO" "access_key")
                RGW_SECRET_KEY=$(extract_json_string_field "$RGW_USER_INFO" "secret_key")
            fi
        else
            # Create new RGW user in the correct zone with full capabilities
            print_info "User does not exist, creating in zone '${RGW_ZONE}' with full capabilities..."
            RGW_USER_OUTPUT=$(ceph_exec radosgw-admin user create \
                --uid="${RGW_USER_NAME}" \
                --display-name="${TENANT_NAME} NooBaa User" \
                --max-buckets=1000 \
                --rgw-zone="${RGW_ZONE}" \
                --caps="buckets=*;users=*;usage=*;metadata=*" 2>&1 || echo "COMMAND_FAILED")
            
            if echo "$RGW_USER_OUTPUT" | grep -q "COMMAND_FAILED"; then
                print_error "radosgw-admin command failed or timed out"
                print_error "Output: $RGW_USER_OUTPUT"
                exit 1
            fi
            
            if echo "$RGW_USER_OUTPUT" | grep -qi "error" && ! echo "$RGW_USER_OUTPUT" | grep -qi "already exists"; then
                print_error "Failed to create RGW user ${RGW_USER_NAME}"
                print_error "Output: $RGW_USER_OUTPUT"
                exit 1
            fi
            
            # Extract access key and secret key using jq first.
            RGW_ACCESS_KEY=$(echo "$RGW_USER_OUTPUT" | jq -r '.keys[0].access_key' 2>/dev/null || echo "")
            RGW_SECRET_KEY=$(echo "$RGW_USER_OUTPUT" | jq -r '.keys[0].secret_key' 2>/dev/null || echo "")
            
            # Fallback to portable field extraction if jq fails
            if [ -z "$RGW_ACCESS_KEY" ] || [ -z "$RGW_SECRET_KEY" ]; then
                RGW_ACCESS_KEY=$(extract_json_string_field "$RGW_USER_OUTPUT" "access_key")
                RGW_SECRET_KEY=$(extract_json_string_field "$RGW_USER_OUTPUT" "secret_key")
            fi
            
            if [ -z "$RGW_ACCESS_KEY" ] || [ -z "$RGW_SECRET_KEY" ]; then
                # Try to get existing keys if creation reported "already exists"
                print_warning "Could not extract keys from creation output, fetching user info"
                RGW_USER_INFO=$(ceph_exec radosgw-admin user info --uid="${RGW_USER_NAME}" --rgw-zone="${RGW_ZONE}" 2>&1)
                RGW_ACCESS_KEY=$(echo "$RGW_USER_INFO" | jq -r '.keys[0].access_key' 2>/dev/null || echo "")
                RGW_SECRET_KEY=$(echo "$RGW_USER_INFO" | jq -r '.keys[0].secret_key' 2>/dev/null || echo "")
                
                # Final fallback to portable field extraction
                if [ -z "$RGW_ACCESS_KEY" ] || [ -z "$RGW_SECRET_KEY" ]; then
                    RGW_ACCESS_KEY=$(extract_json_string_field "$RGW_USER_INFO" "access_key")
                    RGW_SECRET_KEY=$(extract_json_string_field "$RGW_USER_INFO" "secret_key")
                fi
            fi
        fi
        
        if [ -z "$RGW_ACCESS_KEY" ] || [ -z "$RGW_SECRET_KEY" ]; then
            print_error "Failed to get RGW credentials for user ${RGW_USER_NAME}"
            exit 1
        fi
        
        # Ensure user has proper capabilities (in case it already existed without them)
        print_info "Ensuring user has full management capabilities..."
        ceph_exec radosgw-admin caps add \
            --uid="${RGW_USER_NAME}" \
            --caps="buckets=*;users=*;usage=*;metadata=*" \
            --rgw-zone="${RGW_ZONE}" &>/dev/null || {
            print_warning "Could not add capabilities (user may already have them)"
        }
        
        print_success "RGW user created: ${RGW_USER_NAME}"
        print_info "  Access Key: ${RGW_ACCESS_KEY}"
        print_info "  Secret Key: [REDACTED]"
        
        # Set quota on RGW user
        print_info "Setting RGW user quota: ${RGW_USER_QUOTA}"
        RGW_QUOTA_BYTES=$(convert_to_bytes "$RGW_USER_QUOTA")
        
        ceph_exec radosgw-admin quota set \
            --quota-scope=user \
            --uid="${RGW_USER_NAME}" \
            --rgw-zone="${RGW_ZONE}" \
            --max-size="${RGW_QUOTA_BYTES}" 2>&1 || {
            print_error "Failed to set quota for RGW user ${RGW_USER_NAME}"
            exit 1
        }
        
        # Enable quota enforcement
        print_info "Enabling RGW quota enforcement"
        ceph_exec radosgw-admin quota enable \
            --quota-scope=user \
            --uid="${RGW_USER_NAME}" \
            --rgw-zone="${RGW_ZONE}" 2>&1 || {
            print_error "Failed to enable quota for RGW user ${RGW_USER_NAME}"
            exit 1
        }
        
        print_success "RGW quota set and enabled: ${RGW_USER_QUOTA}"
        
        # Save RGW credentials
        RGW_CREDS_FILE="${OUTPUT_DIR}/${TENANT_NAME}-rgw-credentials.txt"
        cat > "$RGW_CREDS_FILE" <<RGWCREDS
# RGW Credentials for Tenant: ${TENANT_NAME}
# Generated: $(date)
# User: ${RGW_USER_NAME} (in RGW zone: ${RGW_ZONE})

RGW_USER_NAME=${RGW_USER_NAME}
RGW_ACCESS_KEY=${RGW_ACCESS_KEY}
RGW_SECRET_KEY=${RGW_SECRET_KEY}
RGW_ENDPOINT=${RGW_PROTOCOL}://${MAIN_RGW_ENDPOINT}
RGW_REGION=${RGW_REGION}
RGW_QUOTA=${RGW_USER_QUOTA}
RGW_QUOTA_BYTES=${RGW_QUOTA_BYTES}
BACKING_BUCKET=${BACKING_BUCKET}

# For ACM Policy (BackingStore secret):
AWS_ACCESS_KEY_ID=${RGW_ACCESS_KEY}
AWS_SECRET_ACCESS_KEY=${RGW_SECRET_KEY}

# For NooBaa BackingStore (current configuration - ${RGW_PROTOCOL}):
# endpoint: ${RGW_PROTOCOL}://${MAIN_RGW_ENDPOINT}
# targetBucket: ${BACKING_BUCKET}
# secret: <tenant>-rgw-credentials  # pragma: allowlist secret
RGWCREDS
        
        # Add HTTPS alternative if SSL port is detected or if currently using HTTP
        # Extract hostname from MAIN_RGW_ENDPOINT for use in comments
        RGW_ENDPOINT_HOST=$(echo "$MAIN_RGW_ENDPOINT" | cut -d':' -f1)
        
        if [ -n "${RGW_SSL_PORT:-}" ] && [ "$RGW_PROTOCOL" = "http" ]; then
            # SSL is configured but not currently used
            cat >> "$RGW_CREDS_FILE" <<RGWCREDS_HTTPS
#
# Alternative: For secure HTTPS endpoint (SSL is configured on port ${RGW_SSL_PORT}):
# endpoint: https://${RGW_ENDPOINT_HOST}:${RGW_SSL_PORT}
# targetBucket: ${BACKING_BUCKET}
# secret: <tenant>-rgw-credentials  # pragma: allowlist secret
RGWCREDS_HTTPS
        elif [ "$RGW_PROTOCOL" = "http" ]; then
            # No SSL detected, show common SSL ports as placeholder
            cat >> "$RGW_CREDS_FILE" <<RGWCREDS_HTTPS
#
# Alternative: For secure HTTPS endpoint (configure RGW SSL first):
# endpoint: https://${RGW_ENDPOINT_HOST}:443
# targetBucket: ${BACKING_BUCKET}
# secret: <tenant>-rgw-credentials  # pragma: allowlist secret
# Note: Common SSL ports are 443 (standard) or 8443 (alternative)
RGWCREDS_HTTPS
        fi
        
        print_success "RGW credentials saved to: ${RGW_CREDS_FILE}"
        
        # Handle CA certificate bundle
        print_info "Preparing CA certificate bundle..."
        
        # Check if custom CA bundle was provided
        if [ -n "$CUSTOM_CA_BUNDLE_PATH" ]; then
            print_info "Using custom CA bundle: ${CUSTOM_CA_BUNDLE_PATH}"
            
            # Validate the custom CA bundle
            if validate_ca_bundle "$CUSTOM_CA_BUNDLE_PATH" "$MAIN_RGW_ENDPOINT"; then
                cp "$CUSTOM_CA_BUNDLE_PATH" "$CA_BUNDLE_FILE"
                CA_BUNDLE_TYPE="custom"
                print_success "Custom CA bundle validated and copied"
            else
                print_error "Custom CA bundle validation failed"
                exit 1
            fi
        elif [ "$RGW_PROTOCOL" = "https" ]; then
            # HTTPS endpoint - attempt auto-extraction
            print_info "HTTPS endpoint detected - attempting CA certificate extraction..."
            
            if extract_ca_from_endpoint "$MAIN_RGW_ENDPOINT" "$CA_BUNDLE_FILE"; then
                print_success "CA certificate extracted successfully"
                
                # Validate the extracted certificate
                if validate_ca_bundle "$CA_BUNDLE_FILE" "$MAIN_RGW_ENDPOINT"; then
                    print_success "Extracted CA bundle validated"
                else
                    print_warning "Extracted CA bundle validation had warnings"
                    print_warning "Review the certificate if NooBaa BackingStore connection fails"
                fi
            else
                print_warning "Automatic CA extraction failed"
                print_info "Creating placeholder CA bundle for manual configuration"
                cat > "$CA_BUNDLE_FILE" <<'PLACEHOLDER_CA'
# CA Certificate Bundle Placeholder
#
# Automatic extraction failed. Please provide the CA certificate(s) manually.
# This file should contain the CA certificate(s) needed to verify the RGW HTTPS endpoint.
#
# To extract the certificate from your RGW endpoint, run:
#   openssl s_client -connect <rgw-host>:<rgw-port> -showcerts </dev/null 2>/dev/null | \
#   awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' > ca-bundle.crt

# Or copy your organization CA certificate here in PEM format.
PLACEHOLDER_CA
                CA_BUNDLE_TYPE="manual-placeholder"
                print_warning "Manual CA certificate configuration required"
                print_warning "Edit: ${CA_BUNDLE_FILE}"
            fi
        else
            # HTTP endpoint - create placeholder for future HTTPS migration
            print_info "HTTP endpoint - creating CA bundle placeholder..."
            cat > "$CA_BUNDLE_FILE" <<'PLACEHOLDER_CA'
# CA Certificate Bundle Placeholder
#
# This file is a placeholder for future HTTPS migration.
# Currently using HTTP endpoint - no CA certificate required.
#
# When migrating to HTTPS, replace this content with your CA certificate(s) in PEM format.
#
# To extract the certificate from your RGW endpoint, run:
#   openssl s_client -connect <rgw-host>:<rgw-port> -showcerts </dev/null 2>/dev/null | \
#   awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' > ca-bundle.crt
#
# Or copy your organization CA certificate here.
PLACEHOLDER_CA
            CA_BUNDLE_TYPE="http-placeholder"
        fi
        
        # Final validation
        if [ ! -f "$CA_BUNDLE_FILE" ]; then
            print_error "Failed to create CA bundle file"
            exit 1
        fi
        
        print_success "CA bundle file ready: ${CA_BUNDLE_FILE}"
        print_info "CA bundle type: ${CA_BUNDLE_TYPE}"
        
        print_success "Phase 5 Complete: RGW user created in main RGW"
        echo ""
    else
        print_info "Skipping Phase 5: Object storage not enabled"
        save_phase 5
    fi
fi

###############################################################################
# PHASE 6: CREATE BACKING BUCKET (OPTIONAL)
###############################################################################
if should_skip_phase 6; then
    print_info "Skipping Phase 6 (already completed)"
else
    if [ "$ENABLE_OBJECT_STORAGE" = true ]; then
        ensure_runtime_dependencies 6
        save_phase 6
        echo ""
        print_header "============================================================"
        print_header "PHASE 6: Create Backing Bucket in Main RGW"
        print_header "============================================================"
        echo ""
        print_info "Creating backing bucket: ${BACKING_BUCKET}"
        print_info "Note: Bucket will be created using S3 API"
        
        # Try to create bucket using curl with AWS signature
        print_info "Attempting to create bucket via S3 API..."
        
        DATE=$(date -u +"%a, %d %b %Y %H:%M:%S GMT")
        STRING_TO_SIGN="PUT\n\n\n${DATE}\n/${BACKING_BUCKET}"
        SIGNATURE=$(echo -en "${STRING_TO_SIGN}" | openssl sha1 -hmac "${RGW_SECRET_KEY}" -binary | base64)
        
        BUCKET_CREATE_RESULT=$(curl -k -s -w "\n%{http_code}" -X PUT "${RGW_PROTOCOL}://${MAIN_RGW_ENDPOINT}/${BACKING_BUCKET}" \
            -H "Host: ${MAIN_RGW_ENDPOINT}" \
            -H "Date: ${DATE}" \
            -H "Authorization: AWS ${RGW_ACCESS_KEY}:${SIGNATURE}")
        
        HTTP_CODE=$(echo "$BUCKET_CREATE_RESULT" | tail -1)
        RESPONSE_BODY=$(echo "$BUCKET_CREATE_RESULT" | sed '$d')
        
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "409" ]; then
            if [ "$HTTP_CODE" = "409" ]; then
                print_warning "Bucket '${BACKING_BUCKET}' already exists"
            else
                print_success "Bucket created: ${BACKING_BUCKET}"
            fi
        else
            print_warning "Could not create bucket via S3 API (HTTP ${HTTP_CODE})"
            print_warning "Response: ${RESPONSE_BODY}"
            print_warning "NooBaa will attempt to create the bucket when BackingStore is configured"
            print_info "If bucket creation fails, create it manually:"
            print_info "  export AWS_ACCESS_KEY_ID='${RGW_ACCESS_KEY}'"
            print_info "  export AWS_SECRET_ACCESS_KEY='${RGW_SECRET_KEY}'"
            print_info "  aws s3 mb s3://${BACKING_BUCKET} \\"
            print_info "    --endpoint-url ${RGW_PROTOCOL}://${MAIN_RGW_ENDPOINT} \\"
            print_info "    --region ${RGW_REGION} --no-verify-ssl"
        fi
        
        print_success "Phase 6 Complete: Backing bucket configuration ready"
        echo ""
    else
        print_info "Skipping Phase 6: Object storage not enabled"
        save_phase 6
    fi
fi

###############################################################################
# PHASE 7: GENERATE EXTERNAL CONFIG JSON
###############################################################################
if should_skip_phase 7; then
    print_info "Skipping Phase 7 (already completed)"
else
    ensure_runtime_dependencies 7
    save_phase 7
    echo ""
    print_header "============================================================"
    print_header "PHASE 7: Generate External Config JSON"
    print_header "============================================================"
    echo ""
    OUTPUT_JSON="${OUTPUT_DIR}/${TENANT_NAME}-external-config.json"
    
    if [ "$MODE" = "odf" ]; then
        # ODF mode: use create-external-cluster-resources.py
        print_info "Running create-external-cluster-resources.py in toolbox..."
        print_info "This generates the external-cluster-details JSON for control plane or LOB Admin UI deployment"
        
        # Auto-detect the Python script location (varies by ODF version)
        print_info "Detecting create-external-cluster-resources.py location..."
        
        # Check only predefined common locations
        COMMON_PATHS=(
            "/etc/rook-external/create-external-cluster-resources.py"
            "/usr/share/ceph/create-external-cluster-resources.py"
            "/opt/ceph/create-external-cluster-resources.py"
            "/usr/local/bin/create-external-cluster-resources.py"
        )
        
        SCRIPT_PATH=""
        print_info "Checking common locations..."
        for path in "${COMMON_PATHS[@]}"; do
            print_debug "Checking: ${path}"
            if ceph_exec test -f "$path" 2>/dev/null; then
                SCRIPT_PATH="$path"
                print_success "Found script at: ${SCRIPT_PATH}"
                break
            fi
        done
        
        # If not found in any common location, provide error with instructions
        if [ -z "$SCRIPT_PATH" ]; then
            print_error "Script not found in any common location"
            print_error ""
            print_error "Checked locations:"
            for path in "${COMMON_PATHS[@]}"; do
                print_error "  - ${path}"
            done
            print_error ""
            print_error "To find the script manually:"
            print_error "  oc rsh -n ${NAMESPACE} ${TOOLBOX_POD}"
            print_error "  find / -name 'create-external-cluster-resources.py' 2>/dev/null"
            exit 1
        fi
        
        # Run the Python script from detected location
        SCRIPT_OUTPUT=$(ceph_exec python3 \
            "$SCRIPT_PATH" \
            --rbd-data-pool-name "$POOL_NAME" \
            --k8s-cluster-name "$TENANT_NAME" \
            --restricted-auth-permission true \
            --format json \
            --output /tmp/external-config.json 2>&1)
        
        if echo "$SCRIPT_OUTPUT" | grep -qi "error\|failed"; then
            print_error "Failed to generate external config"
            print_error "$SCRIPT_OUTPUT"
            exit 1
        fi
        
        print_success "External config generated in toolbox"
        
        # Copy JSON from toolbox to local
        print_info "Copying JSON from toolbox..."
        oc cp "${NAMESPACE}/${TOOLBOX_POD}:/tmp/external-config.json" "$OUTPUT_JSON"
        
        if [ ! -f "$OUTPUT_JSON" ]; then
            print_error "Failed to copy JSON from toolbox"
            exit 1
        fi
        
        print_success "External config saved to: ${OUTPUT_JSON}"
    else
        # Native Ceph mode: use ceph-external-cluster-details-exporter.py
        print_info "Generating external config for native Ceph using ceph-external-cluster-details-exporter.py..."
        
        # Check for Python 3
        if ! command -v python3 &>/dev/null; then
            print_error "python3 is required but not found"
            exit 1
        fi
        
        # Find the exporter script
        print_info "Locating ceph-external-cluster-details-exporter.py..."
        EXPORTER_SCRIPT=""
        
        # Common locations for the script
        COMMON_PATHS=(
            "/root/ceph-external-cluster-details-exporter.py"
            "/usr/share/ceph/ceph-external-cluster-details-exporter.py"
            "/usr/local/share/ceph/ceph-external-cluster-details-exporter.py"
            "/opt/ceph/ceph-external-cluster-details-exporter.py"
            "/usr/share/ceph-common/ceph-external-cluster-details-exporter.py"
        )
        
        for path in "${COMMON_PATHS[@]}"; do
            if [ -f "$path" ]; then
                EXPORTER_SCRIPT="$path"
                print_success "Found exporter script at: ${EXPORTER_SCRIPT}"
                break
            fi
        done
        
        # If not found in common locations, try to find it
        if [ -z "$EXPORTER_SCRIPT" ]; then
            print_info "Script not found in common locations, searching..."
            EXPORTER_SCRIPT=$(find /usr -name "ceph-external-cluster-details-exporter.py" 2>/dev/null | head -1)
            
            if [ -n "$EXPORTER_SCRIPT" ]; then
                print_success "Found exporter script at: ${EXPORTER_SCRIPT}"
            else
                print_error "ceph-external-cluster-details-exporter.py not found"
                print_error ""
                print_error "This script is required for native Ceph external cluster configuration."
                print_error "It should be included with ceph-common package."
                print_error ""
                print_error "Checked locations:"
                for path in "${COMMON_PATHS[@]}"; do
                    print_error "  - ${path}"
                done
                print_error ""
                print_error "To install:"
                print_error "  RHEL/CentOS: yum install ceph-common"
                print_error "  Ubuntu/Debian: apt-get install ceph-common"
                print_error ""
                print_error "Or download from: https://github.com/rook/rook/tree/master/deploy/examples"
                exit 1
            fi
        fi
        
        # Run the exporter script
        print_info "Running ceph-external-cluster-details-exporter.py..."
        print_info "This will generate all necessary ConfigMaps and Secrets for ODF"
        
        # The script needs these parameters:
        # --rbd-data-pool-name: The RBD pool name
        # --k8s-cluster-name: Cluster identifier (tenant name)
        # --restricted-auth-permission: Use restricted permissions
        # --format: Output format (json)
        
        SCRIPT_OUTPUT=$(python3 "$EXPORTER_SCRIPT" \
            --rbd-data-pool-name "$POOL_NAME" \
            --k8s-cluster-name "$TENANT_NAME" \
            --restricted-auth-permission true \
            --format json 2>&1)
        
        SCRIPT_EXIT_CODE=$?
        
        if [ $SCRIPT_EXIT_CODE -ne 0 ]; then
            print_error "Failed to run ceph-external-cluster-details-exporter.py"
            print_error "Exit code: ${SCRIPT_EXIT_CODE}"
            print_error "Output:"
            print_error "$SCRIPT_OUTPUT"
            exit 1
        fi
        
        # Save the output to the JSON file
        echo "$SCRIPT_OUTPUT" > "$OUTPUT_JSON"
        
        if [ ! -s "$OUTPUT_JSON" ]; then
            print_error "Generated JSON file is empty"
            print_error "Script output:"
            print_error "$SCRIPT_OUTPUT"
            exit 1
        fi
        
        print_success "External config generated: ${OUTPUT_JSON}"
        print_info "The configuration includes:"
        print_info "  - rook-ceph-mon-endpoints ConfigMap"
        print_info "  - rook-ceph-mon Secret"
        print_info "  - rook-ceph-operator-creds Secret"
        print_info "  - rook-config-override ConfigMap (with ceph.conf)"
        print_info "  - CSI RBD secrets"
        print_info "  - Monitoring endpoint"
    fi
    
    # Validate JSON
    if ! jq empty "$OUTPUT_JSON" 2>/dev/null; then
        print_error "Generated JSON is invalid"
        exit 1
    fi
    
    print_success "JSON validation passed"
    
    # For native Ceph mode, normalize placeholder secret keys for consistency
    if [ "$MODE" = "native" ]; then
        print_info "Normalizing placeholder secret fields in external config JSON..."
        
        # Replace placeholders in the JSON with literal string values
        # The exporter script generates "admin-secret" and "mon-secret" as placeholders
        jq '
          map(
            if .name == "rook-ceph-mon" and .kind == "Secret" then
              .data["admin-secret"] = "admin-secret" |  # pragma: allowlist secret
              .data["mon-secret"] = "mon-secret"  # pragma: allowlist secret
            else
              .
            end
          )
        ' "$OUTPUT_JSON" > "${OUTPUT_JSON}.tmp" && mv "${OUTPUT_JSON}.tmp" "$OUTPUT_JSON"
        
        if ! jq empty "$OUTPUT_JSON" 2>/dev/null; then
            print_error "Failed to replace placeholder secrets"
            exit 1
        fi
        
        print_success "Placeholder secret fields normalized"
    fi
    
    # Post-process JSON (both ODF and native modes)
    print_info "Post-processing external config JSON..."
    
    # Get FSID from rook-ceph-mon secret for clusterID
    CEPH_FSID=$(jq -r '.[] | select(.name == "rook-ceph-mon" and .kind == "Secret") | .data.fsid' "$OUTPUT_JSON")
    
    # 1. Add controller-publish-secret parameter (required for volume attachment)
    # 2. Remove all CephFS resources (we only expose RBD block storage, not file storage)
    # Note: Use the auto-detected namespace for ceph-csi-config
    jq '
      map(
        if .name == "ceph-rbd" and .kind == "StorageClass" then
          .data["csi.storage.k8s.io/controller-publish-secret-name"] = .data["csi.storage.k8s.io/node-stage-secret-name"] |
          .data["csi.storage.k8s.io/controller-publish-secret-namespace"] = "'"$NAMESPACE"'"
        else
          .
        end
      ) |
      # Remove CephFS StorageClass
      map(select(.name != "cephfs" or .kind != "StorageClass")) |
      # Remove CephFS secrets
      map(select(.name | test("cephfs") | not))
    ' "$OUTPUT_JSON" > "${OUTPUT_JSON}.tmp" && mv "${OUTPUT_JSON}.tmp" "$OUTPUT_JSON"
    
    if ! jq empty "$OUTPUT_JSON" 2>/dev/null; then
        print_error "JSON post-processing failed"
        exit 1
    fi
    
    print_success "StorageClass controller-publish-secret parameter added"
    print_success "CephFS resources removed (block storage only)"
    
    ###########################################################################
    # FIX MON ENDPOINTS - Include ALL monitors (not just one)
    ###########################################################################
    print_info "Fixing rook-ceph-mon-endpoints to include all monitors..."
    
    # Get all mon endpoints from Ceph cluster
    if [ "$MODE" = "odf" ]; then
        # ODF mode: get from ceph mon dump
        print_info "Retrieving all monitor endpoints from Ceph cluster..."
        MON_DUMP=$(ceph_exec ceph mon dump -f json 2>/dev/null || echo "")
        
        if [ -n "$MON_DUMP" ]; then
            # Parse mon dump JSON to get all monitor endpoints
            # Format: a=IP1:PORT,b=IP2:PORT,c=IP3:PORT
            ALL_MON_ENDPOINTS=$(echo "$MON_DUMP" | jq -r '.mons[] | "\(.name)=\(.public_addrs.addrvec[0].addr)"' | paste -sd ',' -)
            
            if [ -n "$ALL_MON_ENDPOINTS" ]; then
                print_success "Found monitor endpoints: ${ALL_MON_ENDPOINTS}"
                
                # Get maxMonId (number of monitors - 1)
                MAX_MON_ID=$(echo "$MON_DUMP" | jq -r '.mons | length - 1')
                
                # Update the rook-ceph-mon-endpoints ConfigMap in JSON
                jq --arg endpoints "$ALL_MON_ENDPOINTS" --arg maxid "$MAX_MON_ID" '
                  map(
                    if .name == "rook-ceph-mon-endpoints" and .kind == "ConfigMap" then
                      .data.data = $endpoints |
                      .data.maxMonId = $maxid |
                      .data.mapping = "{}"
                    else
                      .
                    end
                  )
                ' "$OUTPUT_JSON" > "${OUTPUT_JSON}.tmp" && mv "${OUTPUT_JSON}.tmp" "$OUTPUT_JSON"
                
                if ! jq empty "$OUTPUT_JSON" 2>/dev/null; then
                    print_error "Failed to update mon endpoints in JSON"
                    exit 1
                fi
                
                print_success "rook-ceph-mon-endpoints ConfigMap updated with all monitors"
                print_info "  - data: ${ALL_MON_ENDPOINTS}"
                print_info "  - maxMonId: ${MAX_MON_ID}"
            else
                print_warning "Could not parse monitor endpoints from ceph mon dump"
                print_warning "Using default single monitor endpoint from Python script"
            fi
        else
            print_warning "Could not retrieve ceph mon dump"
            print_warning "Using default single monitor endpoint from Python script"
        fi
    else
        # Native Ceph mode: get from ceph mon dump
        print_info "Retrieving all monitor endpoints from native Ceph cluster..."
        MON_DUMP=$(ceph mon dump -f json 2>/dev/null || echo "")
        
        if [ -n "$MON_DUMP" ]; then
            ALL_MON_ENDPOINTS=$(echo "$MON_DUMP" | jq -r '.mons[] | "\(.name)=\(.public_addrs.addrvec[0].addr)"' | paste -sd ',' -)
            
            if [ -n "$ALL_MON_ENDPOINTS" ]; then
                print_success "Found monitor endpoints: ${ALL_MON_ENDPOINTS}"
                MAX_MON_ID=$(echo "$MON_DUMP" | jq -r '.mons | length - 1')
                
                jq --arg endpoints "$ALL_MON_ENDPOINTS" --arg maxid "$MAX_MON_ID" '
                  map(
                    if .name == "rook-ceph-mon-endpoints" and .kind == "ConfigMap" then
                      .data.data = $endpoints |
                      .data.maxMonId = $maxid |
                      .data.mapping = "{}"
                    else
                      .
                    end
                  )
                ' "$OUTPUT_JSON" > "${OUTPUT_JSON}.tmp" && mv "${OUTPUT_JSON}.tmp" "$OUTPUT_JSON"
                
                print_success "rook-ceph-mon-endpoints ConfigMap updated with all monitors"
            else
                print_warning "Could not parse monitor endpoints"
            fi
        else
            print_warning "Could not retrieve ceph mon dump in native mode"
        fi
    fi
    
    # Add RGW credentials to JSON if object storage is enabled
    if [ "$ENABLE_OBJECT_STORAGE" = true ]; then
        print_info "Adding RGW object storage resources to external config JSON..."
        
        # Prepare CA bundle content (always include, even if placeholder)
        CA_BUNDLE_CONTENT=""
        if [ -f "$CA_BUNDLE_FILE" ]; then
            # Always read the file content (certificate or placeholder)
            CA_BUNDLE_CONTENT=$(cat "$CA_BUNDLE_FILE")
            if grep -q "BEGIN CERTIFICATE" "$CA_BUNDLE_FILE"; then
                print_debug "CA bundle loaded for ConfigMap (valid certificate)"
            else
                print_debug "CA bundle loaded for ConfigMap (placeholder)"
            fi
        fi
        
        # Create RGW resources as separate objects
        # 1. Secret for RGW credentials (plain text, not base64 encoded)
        RGW_SECRET_JSON=$(jq -n \
            --arg access_key "$RGW_ACCESS_KEY" \
            --arg secret_key "$RGW_SECRET_KEY" \
            '{
                name: "rgw-credentials",
                kind: "Secret",
                data: {
                    "AWS_ACCESS_KEY_ID": $access_key,
                    "AWS_SECRET_ACCESS_KEY": $secret_key
                }
            }')
        
        # 2. ConfigMap for CA bundle (only if CA bundle exists)
        if [ -n "$CA_BUNDLE_CONTENT" ]; then
            RGW_CA_CONFIGMAP_JSON=$(jq -n \
                --arg ca_cert "$CA_BUNDLE_CONTENT" \
                '{
                    name: "rgw-ca-bundle",
                    kind: "ConfigMap",
                    data: {
                        "ca-bundle.crt": $ca_cert
                    }
                }')
        fi
        
        # 3. BackingStore configuration
        RGW_BACKINGSTORE_JSON=$(jq -n \
            --arg bucket "$BACKING_BUCKET" \
            --arg endpoint "${RGW_PROTOCOL}://${MAIN_RGW_ENDPOINT}" \
            '{
                name: "rgw-backing-store",
                kind: "BackingStore",
                data: {
                    targetBucket: $bucket,
                    endpoint: $endpoint
                }
            }')
        
        # Add all RGW resources to the JSON array
        print_debug "Adding RGW Secret to JSON..."
        jq --argjson rgw_secret "$RGW_SECRET_JSON" '. += [$rgw_secret]' "$OUTPUT_JSON" > "${OUTPUT_JSON}.tmp" && \
            mv "${OUTPUT_JSON}.tmp" "$OUTPUT_JSON"
        
        if [ -n "$CA_BUNDLE_CONTENT" ]; then
            print_debug "Adding RGW CA ConfigMap to JSON..."
            jq --argjson rgw_ca "$RGW_CA_CONFIGMAP_JSON" '. += [$rgw_ca]' "$OUTPUT_JSON" > "${OUTPUT_JSON}.tmp" && \
                mv "${OUTPUT_JSON}.tmp" "$OUTPUT_JSON"
        fi
        
        print_debug "Adding RGW BackingStore to JSON..."
        jq --argjson rgw_bs "$RGW_BACKINGSTORE_JSON" '. += [$rgw_bs]' "$OUTPUT_JSON" > "${OUTPUT_JSON}.tmp" && \
            mv "${OUTPUT_JSON}.tmp" "$OUTPUT_JSON"
        
        if ! jq empty "$OUTPUT_JSON" 2>/dev/null; then
            print_error "Failed to add RGW resources to JSON"
            exit 1
        fi
        
        print_success "RGW object storage resources added to external config JSON:"
        print_success "  - rgw-credentials Secret (AWS keys)"
        if [ -n "$CA_BUNDLE_CONTENT" ]; then
            print_success "  - rgw-ca-bundle ConfigMap (CA certificate)"
        fi
        print_success "  - rgw-backing-store BackingStore (endpoint and bucket)"
    fi
    
    print_success "Phase 7 Complete: External config JSON generated"
    echo ""
fi

###############################################################################
# PHASE 8: SAVE ARTIFACTS & SUMMARY
###############################################################################
if should_skip_phase 8; then
    print_info "Skipping Phase 8 (already completed)"
else
    ensure_runtime_dependencies 8
    save_phase 8
    echo ""
    print_header "============================================================"
    print_header "PHASE 8: Save Artifacts & Summary"
    print_header "============================================================"
    echo ""
    # Create summary file
    SUMMARY_FILE="${OUTPUT_DIR}/${TENANT_NAME}-summary.txt"
    
    if [ "$MODE" = "odf" ]; then
        CLUSTER_INFO=$(oc whoami --show-server)
    else
        CLUSTER_INFO=$(ceph fsid 2>/dev/null || echo "Native Ceph Cluster")
    fi
    
    if [ "$ENABLE_OBJECT_STORAGE" = true ]; then
        cat > "$SUMMARY_FILE" <<SUMMARY
================================================================================
Ceph Provisioning Summary — Block and Object Storage
================================================================================
Mode:              ${MODE}
Tenant:            ${TENANT_NAME}
Generated:         $(date)
Storage Cluster:   ${CLUSTER_INFO}

BLOCK STORAGE (RBD)
-------------------
Pool:              ${POOL_NAME}
Quota:             ${RBD_QUOTA}
Main User:         ${USER_NAME}
CSI Node User:     client.${CSI_RBD_NODE_USER}
CSI Prov User:     client.${CSI_RBD_PROV_USER}

OBJECT STORAGE (RGW)
--------------------
RGW User:          ${RGW_USER_NAME}
RGW Quota:         ${RGW_USER_QUOTA}
Backing Bucket:    ${BACKING_BUCKET}
RGW Endpoint:      ${RGW_PROTOCOL}://${MAIN_RGW_ENDPOINT}
RGW Region:        ${RGW_REGION}

GENERATED FILES
---------------
External Config:   ${OUTPUT_JSON}  (HAND OVER THIS FILE)
RGW Credentials:   ${RGW_CREDS_FILE}  (FOR ACM POLICY)
Summary:           ${SUMMARY_FILE}
Log File:          ${LOG_FILE}

NEXT STEPS
----------
1. Hand over these files to the control plane or LOB Admin UI:
   - ${OUTPUT_JSON}
   - ${RGW_CREDS_FILE}

2. LOB Admin UI will deploy ODF client on tenant cluster with:
   - Block storage (RBD)
   - Object storage (NooBaa with RGW backend)

3. Verify on tenant cluster (after deployment):
   - ODF StorageCluster is Ready
   - StorageClass exists: ${TENANT_NAME}-rbd-storage
   - NooBaa BackingStore connected to main RGW
   - Test PVC and OBC creation

ARCHITECTURE
------------
Storage Cluster:
  ├── RBD Pool: ${POOL_NAME} (${RBD_QUOTA} quota)
  │   ├── User: ${USER_NAME}
  │   ├── CSI Node User: client.${CSI_RBD_NODE_USER}
  │   └── CSI Provisioner User: client.${CSI_RBD_PROV_USER}
  └── Main RGW: ${STORAGECLUSTER_NAME}-cephobjectstore
      ├── RGW User: ${RGW_USER_NAME} (${RGW_USER_QUOTA} quota)
      └── Backing Bucket: ${BACKING_BUCKET}

Tenant Cluster (configured by LOB Admin UI):
  ├── Ceph CSI drivers for block storage
  ├── StorageClass → RBD CSI provisioner
  └── NooBaa → BackingStore pointing to main RGW

================================================================================
SUMMARY
    else
        cat > "$SUMMARY_FILE" <<SUMMARY
================================================================================
Ceph Provisioning Summary — Block Storage Only
================================================================================
Mode:              ${MODE}
Tenant:            ${TENANT_NAME}
Generated:         $(date)
Storage Cluster:   ${CLUSTER_INFO}

BLOCK STORAGE (RBD)
-------------------
Pool:              ${POOL_NAME}
Quota:             ${RBD_QUOTA}
Main User:         ${USER_NAME}
CSI Node User:     client.${CSI_RBD_NODE_USER}
CSI Prov User:     client.${CSI_RBD_PROV_USER}

GENERATED FILES
---------------
External Config:   ${OUTPUT_JSON}  (HAND OVER THIS FILE)
Summary:           ${SUMMARY_FILE}
Log File:          ${LOG_FILE}

NEXT STEPS
----------
1. Hand over the external-config.json file to the control plane or LOB Admin UI:
   ${OUTPUT_JSON}

2. LOB Admin UI will deploy ODF client on tenant cluster during
   cluster-as-a-service creation workflow

3. Verify on tenant cluster (after deployment):
   - ODF StorageCluster is Ready
   - StorageClass exists: ${TENANT_NAME}-rbd-storage
   - Test PVC creation and pod attachment

ARCHITECTURE
------------
Storage Cluster:
  └── RBD Pool: ${POOL_NAME} (${RBD_QUOTA} quota)
      ├── User: ${USER_NAME}
      ├── CSI Node User: client.${CSI_RBD_NODE_USER}
      └── CSI Provisioner User: client.${CSI_RBD_PROV_USER}

Tenant Cluster (configured by LOB Admin UI):
  ├── Ceph CSI drivers
  ├── StorageClass → RBD CSI provisioner
  └── Block storage only (no object/file storage)

================================================================================
SUMMARY
    fi
    
    print_success "Summary saved to: ${SUMMARY_FILE}"
    
    print_success "Phase 8 Complete: All artifacts saved"
    echo ""
fi

###############################################################################
# FINAL SUMMARY
###############################################################################
if [ "$ENABLE_OBJECT_STORAGE" = true ]; then
    echo ""
    print_header "============================================================"
    print_header "  PROVISIONING COMPLETE — BLOCK AND OBJECT STORAGE"
    print_header "============================================================"
    echo ""
    print_success "Tenant:            ${TENANT_NAME}"
    print_success "RBD Pool:          ${POOL_NAME} (${RBD_QUOTA})"
    print_success "RGW User:          ${RGW_USER_NAME} (${RGW_USER_QUOTA})"
    print_success "Backing Bucket:    ${BACKING_BUCKET}"
    echo ""
    print_info "Generated Files:"
    print_info "  External Config: ${OUTPUT_DIR}/${TENANT_NAME}-external-config.json  ${COLOR_GREEN}(HAND OVER)${COLOR_RESET}"
    print_info "  RGW Credentials: ${OUTPUT_DIR}/${TENANT_NAME}-rgw-credentials.txt  ${COLOR_GREEN}(HAND OVER)${COLOR_RESET}"
    if [ "$RGW_PROTOCOL" = "https" ] && [ -f "${OUTPUT_DIR}/${TENANT_NAME}-ca-bundle.crt" ]; then
        print_info "  CA Bundle:       ${OUTPUT_DIR}/${TENANT_NAME}-ca-bundle.crt  ${COLOR_GREEN}(HAND OVER)${COLOR_RESET}"
    fi
    print_info "  Summary:         ${OUTPUT_DIR}/${TENANT_NAME}-summary.txt"
    echo ""
    print_header "Next Steps:"
    print_info "  1. Hand over these files to the control plane or LOB Admin UI:"
    print_info "     - ${OUTPUT_DIR}/${TENANT_NAME}-external-config.json (includes RGW credentials)"
    if [ "$RGW_PROTOCOL" = "https" ] && [ -f "${OUTPUT_DIR}/${TENANT_NAME}-ca-bundle.crt" ]; then
        print_info "     - ${OUTPUT_DIR}/${TENANT_NAME}-ca-bundle.crt (for HTTPS verification)"
    fi
    print_info "     - ${OUTPUT_DIR}/${TENANT_NAME}-rgw-credentials.txt (reference/backup)"
    print_info ""
    print_info "  2. LOB Admin UI will deploy ODF client on tenant cluster with:"
    print_info "     - Block storage (RBD)"
    print_info "     - Object storage (NooBaa with RGW backend)"
    print_header "============================================================"
    echo ""
    
    log_to_file "COMPLETE: Tenant ${TENANT_NAME} provisioned successfully (Block + Object Storage)"
else
    echo ""
    print_header "========================================================"
    print_header "  PROVISIONING COMPLETE — BLOCK STORAGE ONLY"
    print_header "========================================================"
    echo ""
    print_success "Tenant:            ${TENANT_NAME}"
    print_success "RBD Pool:          ${POOL_NAME} (${RBD_QUOTA})"
    print_success "Main User:         ${USER_NAME}"
    echo ""
    print_info "Generated Files:"
    print_info "  External Config: ${OUTPUT_DIR}/${TENANT_NAME}-external-config.json  ${COLOR_GREEN}(HAND OVER THIS FILE)${COLOR_RESET}"
    print_info "  Summary:         ${OUTPUT_DIR}/${TENANT_NAME}-summary.txt"
    echo ""
    print_header "Next Steps:"
    print_info "  1. Hand over the external-config.json file to the control plane or LOB Admin UI:"
    print_info "     ${OUTPUT_DIR}/${TENANT_NAME}-external-config.json"
    print_info ""
    print_info "  2. LOB Admin UI will deploy ODF client on tenant cluster"
    print_info "     during cluster-as-a-service creation workflow"
    print_header "========================================================"
    echo ""
    
    log_to_file "COMPLETE: Tenant ${TENANT_NAME} provisioned successfully (Block Storage Only)"
fi

# Clean up state file on successful completion
rm -f "$STATE_FILE"
print_debug "State file removed: ${STATE_FILE}"

print_info "Full log: ${LOG_FILE}"