#!/usr/bin/env bash

set -e

INSTALL_FOLDER=$1
MANIFEST=$2
export WORKSPACE_DIR="./v100-patch1-mirror-workspace"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function main() {

# need to validate parameters
#TODO validate install folder
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

    #source necessary mirror.sh functions
    source ${INSTALL_FOLDER}/partner-install/mcsp/resources/charts/bootstrap-cd-pipeline/mirror/scripts/mirror.sh
    source ${INSTALL_FOLDER}/partner-install/mcsp/resources/charts/bootstrap-cd-pipeline/template.env

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
