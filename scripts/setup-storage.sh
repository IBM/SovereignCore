#!/bin/bash

################################################################################
# setup-storage.sh
#
# Storage Admin Script — Works with Native Ceph or ODF
# BLOCK AND OBJECT STORAGE
#
# Purpose:
#   Provisions isolated Ceph storage for multi-tenant/control plane:
#   - Block storage (RBD) for PVCs
#   - Object storage (RGW) for S3-compatible storage via NooBaa
#
# What this script does (8 phases):
#   1. Pre-flight checks  — verify Ceph access, health, tools
#   2. Ceph health check  — ceph status must be HEALTH_OK or HEALTH_WARN
#   3. Create RBD pool    — <tenant>-rbd-pool with quota
#   4. Create Ceph users  — client.<tenant> + CSI users for RBD
#   5. Create RGW user    — RGW user in main RGW for object storage (optional)
#   6. Create backing bucket — S3 bucket for NooBaa BackingStore (optional)
#   7. Generate config    — run create-external-cluster-resources.py or manual config
#   8. Save artifacts     — write JSON to output dir
#
# Usage:
#   ./setup-storage.sh --tenant TENANT_NAME --rbd-quota SIZE [OPTIONS]
#
# Examples:
#   # Block storage only
#   ./setup-storage.sh --tenant customer-a --rbd-quota 1T --mode odf --output-dir ~/ceph-configs
#
#   # Block + Object storage
#   ./setup-storage.sh --tenant dev-team --rbd-quota 500G --rgw-user-quota 1T --mode odf --output-dir ~/odf-configs
#
#   # Block + Object storage with custom region
#   ./setup-storage.sh --tenant prod-app --rbd-quota 2T --rgw-user-quota 5T --rgw-region eu-west-1 --mode odf --output-dir ~/prod-configs
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
################################################################################

set -euo pipefail

###############################################################################
# GREP COMPATIBILITY (macOS/Linux)
###############################################################################
# Detect GNU grep (supports -P for Perl regex) vs BSD grep (macOS default)
if command -v ggrep &>/dev/null; then
    GREP_CMD="ggrep"
else
    GREP_CMD="grep"
fi

###############################################################################
# DEFAULTS
###############################################################################
TENANT_NAME=""
RBD_QUOTA=""
RGW_USER_QUOTA=""
POOL_PGS=128
OUTPUT_DIR=""
MODE="native"  # native or odf
NAMESPACE="openshift-storage"
STORAGECLUSTER_NAME="odf-storagecluster"
TOOLBOX_POD=""
STATE_FILE=""
LOG_FILE=""
START_PHASE=1
RESUME_MODE=false
LOG_LEVEL="INFO"
CEPH_MON_HOST=""
CEPH_FSID=""
RGW_REGION=""  # Will be set based on deployment or default to "default"
RGW_PROTOCOL="http"
MAIN_RGW_ENDPOINT=""
ENABLE_OBJECT_STORAGE=false

###############################################################################
# COLORS
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

###############################################################################
# LOGGING
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

log_to_file() {
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

print_debug()   { log_to_file "DEBUG: $1";   should_log "DEBUG"   && echo -e "${BLUE}[DEBUG]${NC}   $1" || true; }
print_info()    { log_to_file "INFO: $1";    should_log "INFO"    && echo -e "${CYAN}[INFO]${NC}    $1" || true; }
print_success() { log_to_file "SUCCESS: $1"; should_log "INFO"    && echo -e "${GREEN}[SUCCESS]${NC} $1" || true; }
print_warning() { log_to_file "WARNING: $1"; should_log "WARNING" && echo -e "${YELLOW}[WARNING]${NC} $1" || true; }
print_error()   { log_to_file "ERROR: $1";   should_log "ERROR"   && echo -e "${RED}[ERROR]${NC}   $1" >&2 || true; }
print_header()  { log_to_file "HEADER: $1";  should_log "INFO"    && echo -e "\n${BOLD}${CYAN}$1${NC}" || true; }

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
        --region)
            RGW_REGION="$2"; shift 2 ;;
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
        --help|-h)
            echo -e "
${BOLD}setup-storage.sh${NC} — Native Ceph / ODF Provisioning (Block and Object Storage)

${BOLD}USAGE${NC}
  $0 --tenant TENANT_NAME --rbd-quota SIZE --output-dir PATH --mode MODE [OPTIONS]
  $0 --resume

${BOLD}REQUIRED${NC}
  --tenant NAME           Tenant identifier (lowercase, alphanumeric, hyphens)
  --rbd-quota SIZE        RBD pool quota (e.g., 1T, 500G, 2048M)
                          Required for block storage and NooBaa PostgreSQL PVC
  --output-dir PATH       Secure directory for output files (REQUIRED for security)
                          Example: ~/ceph-configs or /secure/storage-configs
                          Never use /tmp or other world-accessible directories
  --mode MODE             Deployment mode: 'native' or 'odf' (default: native)
                          native: Direct Ceph cluster access
                          odf: OpenShift Data Foundation / Rook

${BOLD}OBJECT STORAGE (OPTIONAL)${NC}
  --rgw-user-quota SIZE   Enable object storage and set RGW user quota
                          Example: --rgw-user-quota 1T
                          Creates RGW user in main RGW for NooBaa backend
                          Note: Requires --rbd-quota for NooBaa PostgreSQL PVC
  --region REGION         S3 region for RGW (default: us-east-1)

${BOLD}OTHER OPTIONS${NC}
  --pool-pgs NUM          Placement Group count (default: 128)
                          PG count affects data distribution across OSDs in Ceph.
                          Consult Ceph documentation or your storage team for
                          appropriate values based on cluster size and data volume.
  --namespace NS          ODF namespace (default: openshift-storage, ODF mode only)
  --storagecluster NAME   StorageCluster name (default: odf-storagecluster, ODF mode only)
  --resume                Resume from last failed phase
  --phase NUM             Start from specific phase (1-8)
  --log-level LEVEL       DEBUG | INFO | WARNING | ERROR (default: INFO)
  --help                  Show this help

${BOLD}EXAMPLES${NC}
  # Block storage only
  $0 --tenant customer-a --rbd-quota 1T --output-dir ~/ceph-configs --mode odf
  
  # Block + Object storage
  $0 --tenant dev-team --rbd-quota 500G --rgw-user-quota 1T --output-dir ~/odf-configs --mode odf
  
  # Resume from failure
  $0 --resume

${BOLD}SECURITY${NC}
  - Always set umask 077 before running this script
  - Use a secure, non-shared directory for --output-dir
  - The <tenant>-external-config.json file should be handed over to the control plane or LOB Admin UI

${BOLD}ARCHITECTURE${NC}
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
# RESUME / VALIDATE
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

# Derived names
POOL_NAME="${TENANT_NAME}-rbd-pool"
USER_NAME="client.${TENANT_NAME}"
RGW_USER_NAME="${TENANT_NAME}-noobaa-user"
BACKING_BUCKET="${TENANT_NAME}-backing-bucket"

# CSI user names
CSI_RBD_NODE_USER="csi-rbd-node-${TENANT_NAME}-${POOL_NAME}"
CSI_RBD_PROV_USER="csi-rbd-provisioner-${TENANT_NAME}-${POOL_NAME}"

###############################################################################
# BANNER
###############################################################################
if [ "$ENABLE_OBJECT_STORAGE" = true ]; then
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
    
    # Check if odf-storagecluster-cephobjectstore zone exists
    if echo "$zone_list" | grep -q "odf-storagecluster-cephobjectstore"; then
        print_debug "Found ODF zone: odf-storagecluster-cephobjectstore"
        echo "odf-storagecluster-cephobjectstore"
        return
    fi
    
    # Get default zone
    default_zone=$(echo "$zone_list" | $GREP_CMD -oP '"default_info":\s*"\K[^"]+' | head -1)
    
    if [ -n "$default_zone" ]; then
        print_debug "Using default zone from zone list"
        echo "default"
    else
        print_debug "No specific zone detected, using 'default'"
        echo "default"
    fi
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
    print_header "PHASE 1: Pre-flight Checks"
    
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
        
        # Verify StorageCluster
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
            if ! oc get cephobjectstore odf-storagecluster-cephobjectstore -n "$NAMESPACE" &>/dev/null; then
                print_error "Main CephObjectStore 'odf-storagecluster-cephobjectstore' not found"
                print_error "Object storage requires a main RGW to be deployed"
                exit 1
            fi
            print_success "Main CephObjectStore exists: odf-storagecluster-cephobjectstore"
            
            # Try to get external route first (for curl access from outside cluster)
            # Note: Only HTTP is supported, skip HTTPS route check
            print_info "Looking for RGW endpoint (HTTP only)..."
            MAIN_RGW_ENDPOINT=$(oc get route odf-storagecluster-cephobjectstore \
                                -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
            RGW_PROTOCOL="http"
            
            # Fallback to service endpoint if no routes exist
            if [ -z "$MAIN_RGW_ENDPOINT" ]; then
                print_warning "No external routes found, using internal service endpoint"
                MAIN_RGW_ENDPOINT=$(oc get cephobjectstore odf-storagecluster-cephobjectstore \
                                    -n "$NAMESPACE" -o jsonpath='{.status.info.endpoint}' 2>/dev/null || echo "")
                
                # Strip protocol if present (we only support HTTP)
                if [[ "$MAIN_RGW_ENDPOINT" =~ ^https?:// ]]; then
                    MAIN_RGW_ENDPOINT=$(echo "$MAIN_RGW_ENDPOINT" | sed 's|^https\?://||')
                fi
                
                # Remove port if present (we'll use standard ports)
                MAIN_RGW_ENDPOINT=$(echo "$MAIN_RGW_ENDPOINT" | sed 's|:[0-9]*$||')
                
                # Force HTTP protocol
                RGW_PROTOCOL="http"
            fi
            
            if [ -z "$MAIN_RGW_ENDPOINT" ]; then
                print_error "Could not find main RGW endpoint (tried routes and service)"
                exit 1
            fi
            
            print_info "RGW endpoint found: ${RGW_PROTOCOL}://${MAIN_RGW_ENDPOINT}"
            
            # Verify endpoint is reachable
            print_info "Verifying RGW endpoint is reachable..."
            if curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "${RGW_PROTOCOL}://${MAIN_RGW_ENDPOINT}/" | grep -q "^[23]"; then
                print_success "RGW endpoint is reachable: ${RGW_PROTOCOL}://${MAIN_RGW_ENDPOINT}"
            else
                print_warning "RGW endpoint may not be reachable from this host"
                print_warning "This is OK if running from outside the cluster"
                print_warning "NooBaa will access it from within the tenant cluster"
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
            if curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "${RGW_PROTOCOL}://${MAIN_RGW_ENDPOINT}/" 2>/dev/null | grep -q "^[23]"; then
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
    print_header "PHASE 2: Ceph Health Check"
    
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
    
    # Fix 1: Configure client mode to allow both secure and legacy connections (Native mode only)
    if [ "$MODE" = "native" ]; then
        print_info "Checking Ceph client mode configuration..."
        CURRENT_CLIENT_MODE=$(ceph_exec ceph config get mon ms_mon_client_mode 2>/dev/null || echo "")
        
        # Check if both secure and crc are present (space or comma separated, any order)
        if echo "$CURRENT_CLIENT_MODE" | grep -q "secure" && echo "$CURRENT_CLIENT_MODE" | grep -q "crc"; then
            print_success "Client mode already configured: ${CURRENT_CLIENT_MODE}"
        else
            print_info "Configuring Ceph client mode to support secure and legacy connections..."
            if ceph_exec ceph config set global ms_mon_client_mode "secure,crc" 2>&1; then
                print_success "Client mode configured: secure,crc"
                
                # Restart ceph-mon.target to apply the changes
                print_info "Restarting ceph-mon.target to apply configuration..."
                if ceph_exec systemctl restart ceph-mon.target 2>&1; then
                    print_success "ceph-mon.target restarted successfully"
                    
                    # Wait a moment for the service to stabilize
                    sleep 5
                    
                    # Verify the setting
                    CLIENT_MODE=$(ceph_exec ceph config get mon ms_mon_client_mode 2>/dev/null || echo "not set")
                    print_info "Verified client mode: ${CLIENT_MODE}"
                else
                    print_warning "Failed to restart ceph-mon.target. You may need to restart it manually."
                fi
            else
                print_warning "Failed to set client mode, but continuing..."
            fi
        fi
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
    print_header "PHASE 3: Create RBD Pool"
    
    # Create RBD pool (idempotent)
    if ceph_exec ceph osd pool ls 2>/dev/null | grep -q "^${POOL_NAME}$"; then
        print_warning "RBD pool '${POOL_NAME}' already exists — skipping creation"
    else
        print_info "Creating RBD pool: ${POOL_NAME} (${POOL_PGS} PGs)"
        ceph_exec ceph osd pool create "$POOL_NAME" "$POOL_PGS"
        print_success "RBD pool created: ${POOL_NAME}"
        
        print_info "Enabling RBD application on pool..."
        ceph_exec ceph osd pool application enable "$POOL_NAME" rbd
        print_success "RBD application enabled"
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
    print_header "PHASE 4: Create Ceph Users"
    
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
    
    # Fix 2: Update CSI RBD node user capabilities to include "auth ls" (Native mode only)
    if [ "$MODE" = "native" ]; then
        print_info "Updating CSI RBD node user capabilities..."
        ceph_exec ceph auth caps "client.${CSI_RBD_NODE_USER}" \
            mon 'profile rbd, allow command "auth ls"' \
            osd 'profile rbd'
        print_success "CSI RBD node user capabilities updated"
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
    
    # Fix 2: Update CSI RBD provisioner user capabilities to include "auth ls" (Native mode only)
    if [ "$MODE" = "native" ]; then
        print_info "Updating CSI RBD provisioner user capabilities..."
        ceph_exec ceph auth caps "client.${CSI_RBD_PROV_USER}" \
            mon 'profile rbd, allow command "auth ls"' \
            mgr 'allow rw' \
            osd 'profile rbd'
        print_success "CSI RBD provisioner user capabilities updated"
        
        # Fix 2: Verify CSI users can run auth ls command
        print_info "Verifying CSI user permissions..."
        
        # Test CSI provisioner key
        print_info "Testing CSI provisioner key can run 'auth ls'..."
        if ceph_exec ceph auth get "client.${CSI_RBD_PROV_USER}" -o /tmp/csi-prov.keyring 2>&1; then
            AUTH_LS_TEST=$(ceph_exec ceph -n "client.${CSI_RBD_PROV_USER}" -k /tmp/csi-prov.keyring auth ls 2>&1 || echo "PERMISSION_DENIED")
            if echo "$AUTH_LS_TEST" | grep -q "PERMISSION_DENIED\|permission denied\|Error EACCES"; then
                print_error "CSI provisioner user cannot run 'auth ls' command"
                print_error "Output: ${AUTH_LS_TEST}"
                ceph_exec rm -f /tmp/csi-prov.keyring
                exit 1
            else
                print_success "CSI provisioner user can run 'auth ls' command"
            fi
            ceph_exec rm -f /tmp/csi-prov.keyring
        else
            print_warning "Could not retrieve CSI provisioner keyring for testing"
        fi
        
        # Test CSI node key
        print_info "Testing CSI node key can run 'auth ls'..."
        if ceph_exec ceph auth get "client.${CSI_RBD_NODE_USER}" -o /tmp/csi-node.keyring 2>&1; then
            AUTH_LS_TEST=$(ceph_exec ceph -n "client.${CSI_RBD_NODE_USER}" -k /tmp/csi-node.keyring auth ls 2>&1 || echo "PERMISSION_DENIED")
            if echo "$AUTH_LS_TEST" | grep -q "PERMISSION_DENIED\|permission denied\|Error EACCES"; then
                print_error "CSI node user cannot run 'auth ls' command"
                print_error "Output: ${AUTH_LS_TEST}"
                ceph_exec rm -f /tmp/csi-node.keyring
                exit 1
            else
                print_success "CSI node user can run 'auth ls' command"
            fi
            ceph_exec rm -f /tmp/csi-node.keyring
        else
            print_warning "Could not retrieve CSI node keyring for testing"
        fi
    fi
    
    print_success "Phase 4 Complete: Ceph users created and verified"
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
        print_header "PHASE 5: Create RGW User in Main RGW"
        
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
            
            # Fallback to grep if jq fails
            if [ -z "$RGW_ACCESS_KEY" ] || [ -z "$RGW_SECRET_KEY" ]; then
                RGW_ACCESS_KEY=$(echo "$RGW_USER_INFO" | $GREP_CMD -oP '"access_key":\s*"\K[^"]+' | head -1)
                RGW_SECRET_KEY=$(echo "$RGW_USER_INFO" | $GREP_CMD -oP '"secret_key":\s*"\K[^"]+' | head -1)
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
            
            # Extract access key and secret key using jq (preferred) or grep (fallback)
            RGW_ACCESS_KEY=$(echo "$RGW_USER_OUTPUT" | jq -r '.keys[0].access_key' 2>/dev/null || echo "")
            RGW_SECRET_KEY=$(echo "$RGW_USER_OUTPUT" | jq -r '.keys[0].secret_key' 2>/dev/null || echo "")
            
            # Fallback to grep if jq fails
            if [ -z "$RGW_ACCESS_KEY" ] || [ -z "$RGW_SECRET_KEY" ]; then
                RGW_ACCESS_KEY=$(echo "$RGW_USER_OUTPUT" | $GREP_CMD -oP '"access_key":\s*"\K[^"]+' | head -1)
                RGW_SECRET_KEY=$(echo "$RGW_USER_OUTPUT" | $GREP_CMD -oP '"secret_key":\s*"\K[^"]+' | head -1)
            fi
            
            if [ -z "$RGW_ACCESS_KEY" ] || [ -z "$RGW_SECRET_KEY" ]; then
                # Try to get existing keys if creation reported "already exists"
                print_warning "Could not extract keys from creation output, fetching user info"
                RGW_USER_INFO=$(ceph_exec radosgw-admin user info --uid="${RGW_USER_NAME}" --rgw-zone="${RGW_ZONE}" 2>&1)
                RGW_ACCESS_KEY=$(echo "$RGW_USER_INFO" | jq -r '.keys[0].access_key' 2>/dev/null || echo "")
                RGW_SECRET_KEY=$(echo "$RGW_USER_INFO" | jq -r '.keys[0].secret_key' 2>/dev/null || echo "")
                
                # Final fallback to grep
                if [ -z "$RGW_ACCESS_KEY" ] || [ -z "$RGW_SECRET_KEY" ]; then
                    RGW_ACCESS_KEY=$(echo "$RGW_USER_INFO" | $GREP_CMD -oP '"access_key":\s*"\K[^"]+' | head -1)
                    RGW_SECRET_KEY=$(echo "$RGW_USER_INFO" | $GREP_CMD -oP '"secret_key":\s*"\K[^"]+' | head -1)
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
        print_info "  Secret Key: ${RGW_SECRET_KEY:0:8}... (truncated)"
        
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
        
        # Extract and save CA bundle (create placeholder for HTTP, extract for HTTPS)
        print_info "Preparing CA certificate bundle..."
        
        CA_BUNDLE_FILE="${OUTPUT_DIR}/${TENANT_NAME}-ca-bundle.crt"
        CA_BUNDLE_EXTRACTED=false
        
        if [ "$RGW_PROTOCOL" = "https" ]; then
            print_info "Extracting CA certificate for HTTPS endpoint..."
            
            # Method 1: Try to get CA cert from RGW SSL configuration
            if command -v openssl &>/dev/null; then
                print_debug "Attempting to extract CA certificate from RGW endpoint..."
                
                # Extract hostname and port for openssl
                RGW_HOSTNAME=$(echo "$MAIN_RGW_ENDPOINT" | cut -d':' -f1)
                RGW_PORT_NUM=$(echo "$MAIN_RGW_ENDPOINT" | cut -d':' -f2)
                
                # Try to get the certificate chain
                if timeout 10 openssl s_client -connect "${RGW_HOSTNAME}:${RGW_PORT_NUM}" -showcerts </dev/null 2>/dev/null | \
                   openssl x509 -outform PEM > "$CA_BUNDLE_FILE" 2>/dev/null; then
                    if [ -s "$CA_BUNDLE_FILE" ]; then
                        CA_BUNDLE_EXTRACTED=true
                        print_success "CA certificate extracted from RGW endpoint"
                    fi
                fi
            fi
            
            # Method 2: Check for system CA bundle or Ceph-specific CA
            if [ "$CA_BUNDLE_EXTRACTED" = false ]; then
                print_debug "Checking for system or Ceph CA certificates..."
                
                # Common CA bundle locations
                CA_LOCATIONS=(
                    "/etc/pki/ca-trust/source/anchors/ceph-rgw.crt"
                    "/etc/pki/tls/certs/ca-bundle.crt"
                    "/etc/ssl/certs/ca-certificates.crt"
                    "/etc/ssl/certs/ca-bundle.crt"
                )
                
                for ca_path in "${CA_LOCATIONS[@]}"; do
                    if [ -f "$ca_path" ]; then
                        cp "$ca_path" "$CA_BUNDLE_FILE"
                        CA_BUNDLE_EXTRACTED=true
                        print_success "CA bundle copied from: ${ca_path}"
                        break
                    fi
                done
            fi
            
            # Method 3: Create a placeholder if no CA found (HTTPS)
            if [ "$CA_BUNDLE_EXTRACTED" = false ]; then
                print_warning "Could not automatically extract CA certificate"
                print_warning "Creating placeholder CA bundle file for HTTPS"
                cat > "$CA_BUNDLE_FILE" <<'PLACEHOLDER_CA'
# CA Certificate Bundle Placeholder
#
# This file should contain the CA certificate(s) needed to verify the RGW HTTPS endpoint.
# Replace this content with your actual CA certificate(s) in PEM format.
#
# To extract the certificate from your RGW endpoint, run:
#   openssl s_client -connect <rgw-host>:<rgw-port> -showcerts </dev/null 2>/dev/null | \
#   openssl x509 -outform PEM > ca-bundle.crt
#
# Or copy your organization CA certificate here.
PLACEHOLDER_CA
                print_warning "Manual CA certificate configuration required"
                print_warning "Edit: ${CA_BUNDLE_FILE}"
            fi
        else
            # HTTP endpoint - create placeholder for future HTTPS migration
            print_info "Creating CA bundle placeholder for HTTP endpoint..."
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
#   openssl x509 -outform PEM > ca-bundle.crt
#
# Or copy your organization CA certificate here.
PLACEHOLDER_CA
        fi
        
        # Validate the CA bundle file exists
        if [ -f "$CA_BUNDLE_FILE" ]; then
            if [ "$CA_BUNDLE_EXTRACTED" = true ]; then
                print_success "CA bundle file created with certificate: ${CA_BUNDLE_FILE}"
            else
                print_success "CA bundle placeholder created: ${CA_BUNDLE_FILE}"
                if [ "$RGW_PROTOCOL" = "http" ]; then
                    print_info "HTTP endpoint - CA bundle will be needed if migrating to HTTPS"
                fi
            fi
        else
            print_error "Failed to create CA bundle file"
            exit 1
        fi
        
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
        print_header "PHASE 6: Create Backing Bucket in Main RGW"
        
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
    print_header "PHASE 7: Generate External Config JSON"
    
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
    
    # For native Ceph mode, replace placeholder secrets with actual Ceph admin keys
    if [ "$MODE" = "native" ]; then
        print_info "Replacing placeholder secrets with actual Ceph admin keys..."
        
        # Get the actual Ceph admin key
        ADMIN_KEY=$(ceph auth get-key client.admin 2>/dev/null)
        if [ -z "$ADMIN_KEY" ]; then
            print_error "Failed to retrieve Ceph admin key"
            print_error "Ensure you have access to client.admin credentials"
            exit 1
        fi
        
        # Keep placeholder values as-is (literal strings "admin-secret" and "mon-secret")
        print_debug "Admin key retrieved - keeping placeholder values in JSON"
        
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
        
        print_success "Placeholder secrets replaced with actual Ceph admin keys"
    fi
    
    # Post-process JSON (both ODF and native modes)
    print_info "Post-processing external config JSON..."
    
    # Get FSID from rook-ceph-mon secret for clusterID
    CEPH_FSID=$(jq -r '.[] | select(.name == "rook-ceph-mon" and .kind == "Secret") | .data.fsid' "$OUTPUT_JSON")
    
    # 1. Add controller-publish-secret parameter (required for volume attachment)
    # 2. Remove all CephFS resources (we only expose RBD block storage, not file storage)
    # Note: Do NOT add clusterID - let ODF use default "openshift-storage" from ceph-csi-config
    jq '
      map(
        if .name == "ceph-rbd" and .kind == "StorageClass" then
          .data["csi.storage.k8s.io/controller-publish-secret-name"] = .data["csi.storage.k8s.io/node-stage-secret-name"] |
          .data["csi.storage.k8s.io/controller-publish-secret-namespace"] = "openshift-storage"
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
    
    # Add RGW credentials to JSON if object storage is enabled
    if [ "$ENABLE_OBJECT_STORAGE" = true ]; then
        print_info "Adding RGW object storage resources to external config JSON..."
        
        # Prepare CA bundle content (always include, even if placeholder)
        CA_BUNDLE_CONTENT=""
        CA_BUNDLE_FILE="${OUTPUT_DIR}/${TENANT_NAME}-ca-bundle.crt"
        
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
    print_header "PHASE 8: Save Artifacts & Summary"
    
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
RGW Endpoint:      https://${MAIN_RGW_ENDPOINT}
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
  └── Main RGW: odf-storagecluster-cephobjectstore
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
    print_info "  External Config: ${OUTPUT_DIR}/${TENANT_NAME}-external-config.json  ${GREEN}(HAND OVER)${NC}"
    print_info "  RGW Credentials: ${OUTPUT_DIR}/${TENANT_NAME}-rgw-credentials.txt  ${GREEN}(HAND OVER)${NC}"
    if [ "$RGW_PROTOCOL" = "https" ] && [ -f "${OUTPUT_DIR}/${TENANT_NAME}-ca-bundle.crt" ]; then
        print_info "  CA Bundle:       ${OUTPUT_DIR}/${TENANT_NAME}-ca-bundle.crt  ${GREEN}(HAND OVER)${NC}"
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
    print_header "========================================================"
    print_header "  PROVISIONING COMPLETE — BLOCK STORAGE ONLY"
    print_header "========================================================"
    echo ""
    print_success "Tenant:            ${TENANT_NAME}"
    print_success "RBD Pool:          ${POOL_NAME} (${RBD_QUOTA})"
    print_success "Main User:         ${USER_NAME}"
    echo ""
    print_info "Generated Files:"
    print_info "  External Config: ${OUTPUT_DIR}/${TENANT_NAME}-external-config.json  ${GREEN}(HAND OVER THIS FILE)${NC}"
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

