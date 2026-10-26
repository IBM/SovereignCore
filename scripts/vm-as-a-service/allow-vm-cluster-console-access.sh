#!/bin/bash

# Allow (or revoke) VNC/Serial console access from the VM Dashboard to the shared VM cluster by
# registering its API server IP in the EgressFirewall of the sovereign-ui namespace on the hub cluster.
#
# dashboardui proxies VNC/Serial console WebSocket connections directly to the VM cluster API
# server (TCP 6443). The sovereign-ui namespace has a deny-all EgressFirewall, so the VM cluster
# API server IP must be listed as a /32 cidrSelector. The list is rendered from
#   ConfigMap/environment-config (openshift-gitops) -> cluster-config.yaml
#   -> sovereignUi.managedClusterApiCidrs
#
# Allow:  add "<ip>/32" to the list, sync the ArgoCD Application, verify the EgressFirewall.
# Revert: remove "<ip>/32" from the list, sync the ArgoCD Application, verify the EgressFirewall.
#
# Run this script while logged in to the Hub cluster with 'oc'.

set -e

# ---------------------------------------------------------------------------
# Environment settings. Adjust these only if your environment differs.
# ---------------------------------------------------------------------------
CONFIG_NAMESPACE="openshift-gitops"                 # Namespace of the environment-config ConfigMap and ArgoCD Applications
CONFIG_MAP_NAME="environment-config"                # ConfigMap holding the cluster configuration
CONFIG_KEY="cluster-config.yaml"                    # Key in the ConfigMap holding the cluster configuration
CIDR_YQ_PATH=".sovereignUi.managedClusterApiCidrs"  # Path of the allowed CIDR list in CONFIG_KEY
UI_NAMESPACE="sovereign-ui"                         # Namespace that has the EgressFirewall
EGRESS_FIREWALL_NAME="default"                      # Name of the EgressFirewall in UI_NAMESPACE
PARENT_APP_NAME="app-of-apps-parent-app"            # Name of the parent ArgoCD Application (if present)
APP_NAME_PREFIX="sovereign-ui-"                     # Prefix of the ArgoCD Application name (auto-detect)
VM_CLUSTER_LABEL="vm.sovereign.cloud.ibm.com/virtualization-enabled=true" # Label of the VM cluster
API_PORT="6443"                                     # VM cluster API server port (documented in the EgressFirewall rule)
SYNC_TIMEOUT=300                                    # Seconds to wait for the ArgoCD sync

# Default values
CLUSTER=""
IP=""
APPLICATION=""
REVERT=false
DRY_RUN=false
NO_SYNC=false

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Allow the VM Dashboard console proxy to reach the VM cluster API server by registering its IP in the sovereign-ui EgressFirewall."
    echo ""
    echo "Options:"
    echo "  -c, --cluster NAME           ManagedCluster name (e.g., claas-vm-cluster)."
    echo "                               If omitted, the ManagedCluster labeled"
    echo "                               $VM_CLUSTER_LABEL is used (not allowed with --revert)."
    echo "      --ip IP                  Use this IP instead of resolving the API hostname of the cluster."
    echo "                               Useful with --revert when the ManagedCluster no longer exists."
    echo "  -a, --application NAME       ArgoCD Application to sync (e.g., ${APP_NAME_PREFIX}example)."
    echo "                               Default: auto-detect the Application named ${APP_NAME_PREFIX}*."
    echo "      --revert                 Remove the entry instead of adding it, then sync the Application."
    echo "  -d, --dry-run                Show the change to $CONFIG_KEY without applying it"
    echo "      --no-sync                Update the ConfigMap only; do not sync the ArgoCD Application"
    echo "  -h, --help                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Allow console access to the VM cluster"
    echo "  $0 -c claas-vm-cluster"
    echo ""
    echo "  # Show what would change"
    echo "  $0 -c claas-vm-cluster -d"
    echo ""
    echo "  # Same, detecting the VM cluster automatically"
    echo "  $0"
    echo ""
    echo "  # Remove the entry of a deleted VM cluster"
    echo "  $0 --revert -c claas-vm-cluster"
    echo "  $0 --revert --ip 192.0.2.10"
    echo ""
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--cluster)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: Option $1 requires a value"
                usage
            fi
            CLUSTER="$2"
            shift 2
            ;;
        --ip)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: Option $1 requires a value"
                usage
            fi
            IP="$2"
            shift 2
            ;;
        -a|--application)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: Option $1 requires a value"
                usage
            fi
            APPLICATION="$2"
            shift 2
            ;;
        --revert)
            REVERT=true
            shift 1
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift 1
            ;;
        --no-sync)
            NO_SYNC=true
            shift 1
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option: $1"
            usage
            ;;
    esac
done

# Validate parameters
if [ "$REVERT" = true ] && [ -z "$CLUSTER" ] && [ -z "$IP" ]; then
    echo "Error: --revert requires -c/--cluster or --ip"
    usage
fi
IPV4_REGEX='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
if [ -n "$IP" ] && ! [[ "$IP" =~ $IPV4_REGEX ]]; then
    echo "Error: Invalid IP address '$IP'"
    exit 1
fi

echo "Checking prerequisites..."
for cmd in oc yq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: '$cmd' command not found. Please install $cmd (yq must be mikefarah/yq v4)."
        exit 1
    fi
done
if ! yq --version 2>&1 | grep -q "mikefarah"; then
    echo "Error: 'yq' must be mikefarah/yq v4 (https://github.com/mikefarah/yq)."
    exit 1
fi
if ! command -v dig &> /dev/null && ! command -v getent &> /dev/null; then
    echo "Error: neither 'dig' nor 'getent' found. Install one of them to resolve hostnames."
    exit 1
fi
if ! oc whoami &> /dev/null; then
    echo "Error: not logged in to the Hub cluster. Run 'oc login' first."
    exit 1
fi

# Resolve a hostname to an IPv4 address
resolve_ip() {
    local host=$1
    local resolved=""
    if command -v dig &> /dev/null; then
        resolved=$(dig +short A "$host" | grep -E "$IPV4_REGEX" | head -n 1 || true)
    else
        resolved=$(getent ahostsv4 "$host" | awk '{print $1; exit}' || true)
    fi
    echo "$resolved"
}

# Build the list of targets: parallel arrays TARGET_NAMES / TARGET_IPS
TARGET_NAMES=()
TARGET_IPS=()

add_target_from_cluster() {
    local name=$1
    local ip=$IP
    local joined available url host

    if ! oc get managedcluster "$name" &> /dev/null; then
        if [ "$REVERT" = true ] && [ -n "$ip" ]; then
            TARGET_NAMES+=("$name")
            TARGET_IPS+=("$ip")
            return
        fi
        echo "Error: ManagedCluster '$name' not found. For --revert of a deleted cluster, pass --ip."
        exit 1
    fi

    if [ "$REVERT" != true ]; then
        joined=$(oc get managedcluster "$name" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterJoined")].status}')
        available=$(oc get managedcluster "$name" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}')
        if [ "$joined" != "True" ] || [ "$available" != "True" ]; then
            echo "Error: ManagedCluster '$name' is not ready (JOINED=$joined, AVAILABLE=$available)."
            exit 1
        fi
    fi

    if [ -z "$ip" ]; then
        url=$(oc get managedcluster "$name" -o jsonpath='{.spec.managedClusterClientConfigs[0].url}')
        if [ -z "$url" ]; then
            echo "Error: ManagedCluster '$name' has no managedClusterClientConfigs URL."
            exit 1
        fi
        host="${url#*://}"
        host="${host%%[:/]*}"
        ip=$(resolve_ip "$host")
        if [ -z "$ip" ]; then
            echo "Error: could not resolve '$host' (API server of '$name'). Pass --ip to specify the IP."
            exit 1
        fi
        echo "Cluster '$name': API server $host -> $ip"
    fi
    TARGET_NAMES+=("$name")
    TARGET_IPS+=("$ip")
}

if [ -n "$CLUSTER" ]; then
    add_target_from_cluster "$CLUSTER"
elif [ -n "$IP" ]; then
    TARGET_NAMES+=("manual")
    TARGET_IPS+=("$IP")
else
    echo "Looking for the ManagedCluster labeled $VM_CLUSTER_LABEL ..."
    CLUSTERS=$(oc get managedcluster -l "$VM_CLUSTER_LABEL" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    CLUSTER_COUNT=$(printf '%s' "$CLUSTERS" | grep -c . || true)
    if [ "$CLUSTER_COUNT" -eq 0 ]; then
        echo "Error: no ManagedCluster labeled $VM_CLUSTER_LABEL found. Use -c to specify the cluster."
        exit 1
    elif [ "$CLUSTER_COUNT" -gt 1 ]; then
        echo "Error: multiple ManagedClusters labeled $VM_CLUSTER_LABEL found, but only one VM cluster is supported:"
        echo "$CLUSTERS" | sed 's/^/  /'
        echo "Use -c to specify the cluster."
        exit 1
    fi
    add_target_from_cluster "$CLUSTERS"
fi

# Determine the ArgoCD Application to sync
if [ "$NO_SYNC" != true ] && [ "$DRY_RUN" != true ] && [ -z "$APPLICATION" ]; then
    APPS=$(oc get applications.argoproj.io -n "$CONFIG_NAMESPACE" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep "^${APP_NAME_PREFIX}" || true)
    APP_COUNT=$(printf '%s' "$APPS" | grep -c . || true)
    if [ "$APP_COUNT" -eq 1 ]; then
        APPLICATION="$APPS"
    elif [ "$APP_COUNT" -eq 0 ]; then
        echo "Error: no ArgoCD Application named ${APP_NAME_PREFIX}* found in $CONFIG_NAMESPACE. Use -a to specify it."
        exit 1
    else
        echo "Error: multiple ArgoCD Applications found. Use -a to specify one:"
        echo "$APPS" | sed 's/^/  /'
        exit 1
    fi
fi

if [ "$REVERT" = true ]; then
    MODE="revert (remove)"
else
    MODE="register (add)"
fi
echo ""
echo "Configuration:"
echo "  Mode:               $MODE"
echo "  ConfigMap:          $CONFIG_NAMESPACE/$CONFIG_MAP_NAME ($CONFIG_KEY)"
echo "  EgressFirewall:     $UI_NAMESPACE/$EGRESS_FIREWALL_NAME"
echo "  ArgoCD Application: ${APPLICATION:-<not syncing>}"
echo "  Dry Run:            $DRY_RUN"
for i in "${!TARGET_IPS[@]}"; do
    echo "  Target:             ${TARGET_NAMES[$i]} -> ${TARGET_IPS[$i]}/32"
done
echo "--------------------------------------------------------"

# Export the current cluster configuration
ORIGINAL_FILE=$(mktemp)
WORK_FILE=$(mktemp)
trap 'rm -f "$ORIGINAL_FILE" "$WORK_FILE"' EXIT

oc get configmap "$CONFIG_MAP_NAME" -n "$CONFIG_NAMESPACE" \
    -o go-template="{{ index .data \"$CONFIG_KEY\" }}" > "$ORIGINAL_FILE"
if [ ! -s "$ORIGINAL_FILE" ]; then
    echo "Error: key '$CONFIG_KEY' not found or empty in $CONFIG_NAMESPACE/$CONFIG_MAP_NAME."
    exit 1
fi
cp "$ORIGINAL_FILE" "$WORK_FILE"

# Edit the working copy
CHANGED=false
for i in "${!TARGET_IPS[@]}"; do
    export CIDR="${TARGET_IPS[$i]}/32"
    export COMMENT="${TARGET_NAMES[$i]} API VIP"
    EXISTS=$(yq e "($CIDR_YQ_PATH // []) | map(select(. == strenv(CIDR))) | length" "$WORK_FILE")
    if [ "$REVERT" = true ]; then
        if [ "$EXISTS" -eq 0 ]; then
            echo "$CIDR is not listed in $CIDR_YQ_PATH. Skipping."
            continue
        fi
        yq e -i "del($CIDR_YQ_PATH[] | select(. == strenv(CIDR)))" "$WORK_FILE"
    else
        if [ "$EXISTS" -gt 0 ]; then
            echo "$CIDR is already listed in $CIDR_YQ_PATH. Skipping."
            continue
        fi
        yq e -i "$CIDR_YQ_PATH += [strenv(CIDR)] | $CIDR_YQ_PATH[-1] line_comment = strenv(COMMENT)" "$WORK_FILE"
    fi
    CHANGED=true
done

if [ "$CHANGED" != true ]; then
    echo "No change required."
    exit 0
fi

echo "Changes to $CONFIG_KEY:"
diff -u "$ORIGINAL_FILE" "$WORK_FILE" || true
echo "--------------------------------------------------------"

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] No changes were applied."
    exit 0
fi

# Keep a backup of the previous content for manual restore
BACKUP_FILE="${TMPDIR:-/tmp}/${CONFIG_KEY%.yaml}.backup.$(date +%Y%m%d%H%M%S).yaml"
cp "$ORIGINAL_FILE" "$BACKUP_FILE"
echo "Backup of the previous $CONFIG_KEY: $BACKUP_FILE"

oc set data configmap/"$CONFIG_MAP_NAME" -n "$CONFIG_NAMESPACE" \
    --from-file="$CONFIG_KEY=$WORK_FILE"
echo "✓ Updated $CONFIG_NAMESPACE/$CONFIG_MAP_NAME"

# Sync the ArgoCD Applications
if [ "$NO_SYNC" = true ]; then
    echo "Skipping ArgoCD sync (--no-sync). Sync '${APPLICATION:-${APP_NAME_PREFIX}<cluster-id>}' manually to apply the change."
else
    sync_app() {
        local app=$1
        local prev_finished
        prev_finished=$(oc get applications.argoproj.io "$app" -n "$CONFIG_NAMESPACE" \
            -o jsonpath='{.status.operationState.finishedAt}' 2>/dev/null || true)
        echo "Syncing ArgoCD Application $app ..."
        oc patch applications.argoproj.io "$app" -n "$CONFIG_NAMESPACE" --type merge \
            -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}},"operation":{"initiatedBy":{"username":"admin"},"sync":{"syncStrategy":{"hook":{}}}}}'

        local elapsed=0
        while true; do
            local finished phase sync_status health
            finished=$(oc get applications.argoproj.io "$app" -n "$CONFIG_NAMESPACE" \
                -o jsonpath='{.status.operationState.finishedAt}' 2>/dev/null || true)
            phase=$(oc get applications.argoproj.io "$app" -n "$CONFIG_NAMESPACE" \
                -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)
            sync_status=$(oc get applications.argoproj.io "$app" -n "$CONFIG_NAMESPACE" \
                -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
            health=$(oc get applications.argoproj.io "$app" -n "$CONFIG_NAMESPACE" \
                -o jsonpath='{.status.health.status}' 2>/dev/null || true)
            if [ -n "$finished" ] && [ "$finished" != "$prev_finished" ]; then
                if [ "$phase" = "Failed" ] || [ "$phase" = "Error" ]; then
                    echo "Error: ArgoCD sync $phase. Check the Application $app."
                    exit 1
                fi
                if [ "$phase" = "Succeeded" ] && [ "$sync_status" = "Synced" ] && [ "$health" = "Healthy" ]; then
                    break
                fi
            fi
            if [ "$elapsed" -ge "$SYNC_TIMEOUT" ]; then
                echo "Error: timed out after ${SYNC_TIMEOUT}s (phase=$phase, sync=$sync_status, health=$health)."
                exit 1
            fi
            sleep 5
            elapsed=$((elapsed + 5))
        done
        echo "✓ $app: $sync_status / $health"
    }

    # Reload repo-server so it picks up the ConfigMap changes immediately
    if oc get deployment/openshift-gitops-repo-server -n "$CONFIG_NAMESPACE" &>/dev/null; then
        echo "Reloading $CONFIG_NAMESPACE/openshift-gitops-repo-server ..."
        oc rollout restart deployment/openshift-gitops-repo-server -n "$CONFIG_NAMESPACE" >/dev/null
        oc rollout status deployment/openshift-gitops-repo-server -n "$CONFIG_NAMESPACE" --timeout=60s >/dev/null
    fi

    if [ -n "$PARENT_APP_NAME" ] && oc get applications.argoproj.io "$PARENT_APP_NAME" -n "$CONFIG_NAMESPACE" &>/dev/null; then
        sync_app "$PARENT_APP_NAME"
    fi
    sync_app "$APPLICATION"

    # Verify the EgressFirewall
    CIDRS=$(oc get egressfirewall "$EGRESS_FIREWALL_NAME" -n "$UI_NAMESPACE" \
        -o jsonpath='{range .spec.egress[*]}{.to.cidrSelector}{"\n"}{end}')
    for i in "${!TARGET_IPS[@]}"; do
        CIDR="${TARGET_IPS[$i]}/32"
        if printf '%s\n' "$CIDRS" | grep -qx "$CIDR"; then
            FOUND=true
        else
            FOUND=false
        fi
        if [ "$REVERT" = true ] && [ "$FOUND" = true ]; then
            echo "Error: $CIDR is still present in EgressFirewall $UI_NAMESPACE/$EGRESS_FIREWALL_NAME."
            exit 1
        elif [ "$REVERT" != true ] && [ "$FOUND" != true ]; then
            echo "Error: $CIDR is not present in EgressFirewall $UI_NAMESPACE/$EGRESS_FIREWALL_NAME (port $API_PORT)."
            exit 1
        fi
        echo "✓ EgressFirewall $UI_NAMESPACE/$EGRESS_FIREWALL_NAME: $CIDR $([ "$REVERT" = true ] && echo "removed" || echo "allowed")"
    done
fi

echo ""
echo "--------------------------------------------------------"
echo "Completed. Remaining manual steps:"
if [ "$REVERT" != true ]; then
    echo "  Smoke test: open the VNC/Serial console of a VM on the VM cluster in the VM Dashboard UI."
else
    echo "  None."
fi
echo "--------------------------------------------------------"
