#!/usr/bin/env bash

set -e

INSTALL_FOLDER=$1
MANIFEST=$2
export WORKSPACE_DIR="./v100-patch1-mirror-workspace"
export VALUES_FILE_DYNAMIC="${INSTALL_FOLDER}/partner-install/mcsp/resources/charts/bootstrap-cd-pipeline/values-dynamic.yaml"
export SECRETS_FILE="${INSTALL_FOLDER}/partner-install/mcsp/resources/charts/bootstrap-cd-pipeline/secrets.yaml"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function main() {

# need to validate parameters
    if [ -z "$INSTALL_FOLDER" ]; then
        log_error "Install folder not specified. Please rerun script in format: ./apply-v100-patch1.sh <path to install-folder> <path to manifest-file>"
        exit 1
    fi
    if [ ! -d "$INSTALL_FOLDER" ]; then
        log_error "Error: Install folder $INSTALL_FOLDER does not exist."
        exit 1
    fi
    
    if [ -z "$MANIFEST" ]; then
        log_error "Manifest file not specified. Please rerun script in format: ./apply-v100-patch1.sh <path to install-folder> <path to manifest-file>"
        exit 1
    fi
    if [ ! -f "$MANIFEST" ]; then
        log_error "Error: Manifest file $MANIFEST does not exist."
        exit 1
    fi
    if [ ! -f "$INSTALL_FOLDER/partner-install/mcsp/resources/charts/bootstrap-cd-pipeline/mirror/scripts/mirror.sh" ]; then
        log_error "Make sure the install folder path points to the SovereignCore directory and re-run"
        exit 1
    fi
    log_info "Validations passed"

    #source necessary template.env values
    source ${INSTALL_FOLDER}/partner-install/mcsp/resources/charts/bootstrap-cd-pipeline/template.env

    # extract variables from values.yaml and secrets.yaml
    QUAY_REGISTRY=$(yq -r '.registry.domain // ""' "$VALUES_FILE_DYNAMIC")
    QUAY_USERNAME=$(yq -r '.registry.username // ""' "$SECRETS_FILE")
    QUAY_PASSWORD=$(yq -r '.registry.password // ""' "$SECRETS_FILE")
    QUAY_ORGANIZATION="sovcloud"

    ROOT_DIR=$(yq '.workingDir' "${INSTALL_FOLDER}/config/global.yaml")
    export KUBECONFIG="${ROOT_DIR}/ocp-cluster/auth/kubeconfig"

# need to mirror images based on image manifest file
    # call the mirror.sh mirror_images function, directly point it to the manifest file  
    if mirror_images "$MANIFEST"; then
        log_info "Successfully mirrored images from $MANIFEST"
    else
        log_error "Failed to mirror images from $MANIFEST"
        exit 1
    fi
    log_info "done mirroring images"

# run cuga argo refresh commands
    refresh_cuga_argo

#run concert command
}

refresh_cuga_argo() {
    APPS=(
        acm-cuga-system-core
        acm-vault-aas-core
        agent-service-broker-core
        acm-service-broker-core
        catalog-as-a-service-broker-core
        common-service-broker-core
        postgres-service-broker-core
        service-broker-parent-app
        sovereign-ui-core
    )

    NS="openshift-gitops"

    for app in "${APPS[@]}"; do
    log_info "Refreshing $app"
    oc patch application.argoproj.io "$app" -n "$NS" \
        --type merge \
        -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
    oc annotate application.argoproj.io "$app" -n "$NS" \
        cache-buster="$(date +%s)" --overwrite
    done
}

mirror_images() {
    local manifest_file=$1
    local manifest_name=$(basename "$manifest_file" .yaml)
    
    log_info "=========================================="
    log_info "Mirroring images from: $manifest_file"
    log_info "=========================================="
    
    if [ ! -f "$manifest_file" ]; then
        log_error "Manifest file not found: $manifest_file"
        return 1
    fi
    
    # Set workspace directory
    local workspace_dir="${WORKSPACE_DIR:-./mirror-workspace}"
    mkdir -p "$workspace_dir"

    # Get oc-mirror auth file directory
    local auth_file_dir="${AUTH_FILE_DIR}"
    
    # Build the oc-mirror command
    local target_registry="docker://${QUAY_REGISTRY}/${QUAY_ORGANIZATION}"
    local workspace_path="file://$(realpath $workspace_dir)"
    
    log_info "Target registry: $target_registry"
    log_info "Workspace: $workspace_path"
    log_info ""
    log_info "Running oc-mirror..."
    
    # Run oc-mirror
    if oc-mirror --v2 --dest-tls-verify=false \
        --authfile "$auth_file_dir" \
        --config "$manifest_file" \
        --retry-times 5 \
        --retry-delay 10s \
        --workspace "$workspace_path" \
        "$target_registry"; then
        log_info "✓ Successfully mirrored images from $manifest_name"

        return 0
    else
        log_error "✗ Failed to mirror images from $manifest_name"
        return 1
    fi
}

# Function to print colored messages
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

main "$@"
