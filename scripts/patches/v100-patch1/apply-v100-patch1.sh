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
    if [ ! -f "$INSTALL_FOLDER/partner-install/mcsp/resources/charts/bootstrap-cd-pipeline/template.env" ]; then
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
    CLUSTER_NAME=$(yq -r '.clusterName // ""' "${INSTALL_FOLDER}/config/global.yaml")

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

    sync_cuga_argo ${CLUSTER_NAME}

# run cuga argo refresh commands
    refresh_cuga_argo ${CLUSTER_NAME}

# apply IBM Concert v2.4.0 patch
    apply_concert_patch

# apply machine config patch for CVE-2026-31431
    update_machine_config
}

apply_concert_patch() {
    log_info "=========================================="
    log_info "Applying IBM Concert v2.4.0.prerelease01.patch01"
    log_info "=========================================="
    
    # Concert namespace is fixed
    local concert_namespace="concert"
    
    log_info "Concert namespace: $concert_namespace"
    
    # Check if rojacore deployment exists
    if ! oc get deploy rojacore -n "$concert_namespace" &>/dev/null; then
        log_warning "rojacore deployment not found in namespace $concert_namespace"
        log_warning "Skipping Concert patch application"
        return 0
    fi
    
    # Extract Concert image from manifest file and construct mirrored location
    local source_image=$(yq -r '.mirror.additionalImages[] | select(.name | contains("concert/rojacore")) | .name' "$MANIFEST")
    
    if [ -z "$source_image" ]; then
        log_error "Concert rojacore image not found in manifest file: $MANIFEST"
        return 1
    fi
    
    # Extract image path and tag from source image (e.g., cp.icr.io/cp/concert/rojacore:tag -> cp/concert/rojacore:tag)
    local image_path=$(echo "$source_image" | sed 's|^[^/]*/||')
    
    # Construct mirrored image location
    local concert_image="${QUAY_REGISTRY}/${QUAY_ORGANIZATION}/${image_path}"
    
    log_info "Updating rojacore deployment with new image..."
    log_info "New image: $concert_image"
    
    # Update the deployment image
    if oc set image deploy/rojacore rojacore-server="$concert_image" -n "$concert_namespace"; then
        log_info "Successfully updated rojacore deployment"
    else
        log_error "Failed to update rojacore deployment"
        return 1
    fi
    
    # Monitor the rollout
    log_info "Monitoring rollout status..."
    if oc rollout status deploy/rojacore -n "$concert_namespace" --timeout=5m; then
        log_info "Rollout completed successfully"
    else
        log_error "Rollout failed or timed out"
        return 1
    fi
    
    # Verify the new pod is running
    log_info "Verifying new pod status..."
    local pod_name=$(oc get pods -n "$concert_namespace" -l component=rojacore --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -n "$pod_name" ]; then
        log_info "New rojacore pod is running: $pod_name"
        
        # Verify the image version
        local current_image=$(oc get pod "$pod_name" -n "$concert_namespace" -o jsonpath='{.spec.containers[?(@.name=="rojacore-server")].image}')
        log_info "Current image: $current_image"
        
        # Retry loop for image verification
        local max_retries=20
        local retry_delay=15
        local retry_count=0
        while [ $retry_count -lt $max_retries ]; do
            if [ "$current_image" = "$concert_image" ]; then
                log_info "Image version verified successfully"
                return 0
            else
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    log_warning "Image version mismatch detected (attempt $retry_count/$max_retries)"
                    log_warning "Expected: $concert_image"
                    log_warning "Current: $current_image"
                    log_info "Retrying in ${retry_delay} seconds..."
                    sleep $retry_delay
                    
                    # Re-fetch the current image
                    current_image=$(oc get pod "$pod_name" -n "$concert_namespace" -o jsonpath='{.spec.containers[?(@.name=="rojacore-server")].image}')
                    log_info "Current image: $current_image"
                else
                    log_error "Image version mismatch after $max_retries attempts"
                    log_error "Expected: $concert_image"
                    log_error "Current: $current_image"
                    return 1
                fi
            fi
        done
    else
        log_error "No running rojacore pod found"
        return 1
    fi
}

refresh_cuga_argo() {
    local cluster_name=$1

    APPS=(
        acm-cuga-system-${cluster_name}
        agent-service-broker-${cluster_name}
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

sync_cuga_argo() {
    local cluster_name=$1

    APPS=(
        acm-cuga-system-${cluster_name}
        agent-service-broker-${cluster_name}
    )

    NS="openshift-gitops"

    for app in "${APPS[@]}"; do
        log_info "Syncing $app"
        oc patch application.argoproj.io "$app" -n "$NS" \
            --type merge \
            -p '{"operation":{"initiatedBy":{"username":"v100-patch1"},"sync":{"syncStrategy":{"hook":{}}}}}'
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

# apply machine config patch for CVE-2026-31431
update_machine_config() {
    # Capture initial generation numbers to verify updates occurred
    master_generation=$(oc get machineconfigpool/master -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "0")
    worker_generation=$(oc get machineconfigpool/worker -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "0")

    log_info "Initial master machineconfigpool generation: $master_generation"
    log_info "Initial worker machineconfigpool generation: $worker_generation"
    log_info ""
    log_info "=========================================="
    log_info "Updating MachineConfig for CVE-2026-31431"
    log_info "=========================================="

    oc apply -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-disable-algif-builtin-worker
spec:
  kernelArguments:
    - initcall_blacklist=algif_aead_init
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-disable-algif-builtin-master
spec:
  kernelArguments:
    - initcall_blacklist=algif_aead_init
EOF

    wait_for_machineconfigpool "$master_generation" "$worker_generation"
    
    log_info ""
    log_info "✅ Machine Config updated successfully"

}

wait_for_machineconfigpool() {
    master_generation=$1
    worker_generation=$2
    log_info ""
    log_info "=========================================="
    log_info "Waiting for MachineConfigPool to apply changes"
    log_info "=========================================="
    log_info "This may take 30 minutes or more depending on cluster size."
    log_info "The cluster nodes will be updated one by one."
    log_info ""

    # Wait for worker pool to start updating (Updating=True) with 5 minute timeout
    log_info ">> Waiting for worker MachineConfigPool to start updating..."
    if oc wait --for=condition=Updating machineconfigpool/worker --timeout=5m 2>/dev/null; then
        log_info "✓ Worker MachineConfigPool update has started"
        
        # Wait for update to complete (Updated=True) with 120 minute timeout
        log_info ">> Waiting for worker MachineConfigPool update to complete..."
        if oc wait --for=condition=Updated machineconfigpool/worker --timeout=120m 2>/dev/null; then
            log_info "✓ Worker MachineConfigPool updated successfully"
        else
            log_warning "⚠️  Worker MachineConfigPool update timed out or failed"
            log_warning "Continuing anyway, but some nodes may still be updating"
        fi
    else
        log_warning "⚠️  Worker MachineConfigPool did not start updating within 5 minutes"
        log_warning "This might mean no changes were needed, or there's an issue"
    fi
    
    # For master pool, check if it's already updated or still updating
    log_info ">> Checking master MachineConfigPool status..."
    local master_updated=$(oc get machineconfigpool/master -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || echo "Unknown")
    local master_updating=$(oc get machineconfigpool/master -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo "Unknown")
    local master_current_generation=$(oc get machineconfigpool/master -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "0")
    
    log_info "Master pool - Updated: $master_updated, Updating: $master_updating, Generation: $master_current_generation"
    
    # Check if master pool has already been updated (generation changed and Updated=True)
    if [[ "$master_current_generation" != "$master_generation" ]] && [[ "$master_updated" == "True" ]]; then
        log_info "✓ Master MachineConfigPool already updated (generation changed from $master_generation to $master_current_generation)"
    elif [[ "$master_updating" == "True" ]]; then
        # Master is currently updating, wait for it to complete
        log_info "Master MachineConfigPool is currently updating, waiting for completion..."
        if oc wait --for=condition=Updated machineconfigpool/master --timeout=120m 2>/dev/null; then
            log_info "✓ Master MachineConfigPool updated successfully"
        else
            log_warning "⚠️  Master MachineConfigPool update timed out or failed"
            log_warning "Continuing anyway, but some nodes may still be updating"
        fi
    else
        # Master hasn't started updating yet, wait for it to start
        log_info ">> Waiting for master MachineConfigPool to start updating..."
        if oc wait --for=condition=Updating machineconfigpool/master --timeout=5m 2>/dev/null; then
            log_info "✓ Master MachineConfigPool update has started"
            
            # Wait for update to complete (Updated=True) with 120 minute timeout
            log_info ">> Waiting for master MachineConfigPool update to complete..."
            if oc wait --for=condition=Updated machineconfigpool/master --timeout=120m 2>/dev/null; then
                log_info "✓ Master MachineConfigPool updated successfully"
            else
                log_warning "⚠️  Master MachineConfigPool update timed out or failed"
                log_warning "Continuing anyway, but some nodes may still be updating"
            fi
        else
            log_warning "⚠️  Master MachineConfigPool did not start updating within 5 minutes"
            log_warning "This might mean no changes were needed, or there's an issue"
        fi
    fi

    # Wait for all nodes to be ready (30 minute timeout)
    log_info ""
    log_info ">> Waiting for all nodes to be ready..."
    if oc wait --for=condition=Ready nodes --all --timeout=30m 2>/dev/null; then
        log_info "✓ All nodes are ready"
    else
        log_warning "⚠️  Some nodes may not be ready yet"
        log_warning "Continuing anyway, but cluster may be in transition"
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
