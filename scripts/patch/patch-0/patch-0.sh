#!/usr/bin/env bash

set -e

# determine location in dir structure
# let's assume we live in the partner-install directory with the other IBM scripts
patch_dir=`dirname $0`
cd "${patch_dir}"
export patch_dir=`pwd`

MANIFEST=$1
export WORKSPACE_DIR="./patch-mirror-workspace"

function main() {

# need to validate parameters
    if [ -z "$MANIFEST" ]; then
        echo "Manifest file not specified. Please rerun script in format: ./patch-0.sh <path to manifest-file>"
        exit 1
    fi
    if [ ! -f "$MANIFEST" ]; then
        echo "Error: Manifest file $MANIFEST does not exist."
        exit 1
    fi
    if [ ! -f "$patch_dir/mcsp/resources/charts/bootstrap-cd-pipeline/mirror/scripts/mirror.sh" ]; then
        echo "place this script and the manifest file in the SovereignCore/partner-install directory and re-run"
        exit 1
    fi
# need to mirror images based on image manifest file
    # should be able to call mirror.sh script using the image manifest file
    echo "calling mirroring script using manifest file $MANIFEST"
    ./mcsp/resources/charts/bootstrap-cd-pipeline/mirror/scripts/mirror.sh -f $MANIFEST
    echo "done mirroring images"
# run Dhyey's commands
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
    echo "Refreshing $app"
    oc patch application.argoproj.io "$app" -n "$NS" \
        --type merge \
        -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
    oc annotate application.argoproj.io "$app" -n "$NS" \
        cache-buster="$(date +%s)" --overwrite
    done
}


main "$@"
