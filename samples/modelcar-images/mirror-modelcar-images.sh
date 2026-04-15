#!/bin/bash

# Mirror modelcar images from Red Hat modelcar-catalog registry to target registry
# Source: https://quay.io/repository/redhat-ai-services/modelcar-catalog

set -e

# Default values
SOURCE_REGISTRY="quay.io/redhat-ai-services/modelcar-catalog"
TARGET_REGISTRY=""
TARGET_NAMESPACE="aiiaas-models" # DO NOT CHANGE THIS
TARGET_TAG="v1"
DRY_RUN=false
SPECIFIC_TAGS=""
INSECURE=false

usage() {
    echo "Usage: $0 -r TARGET_REGISTRY -i IMAGES [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  -r, --target-registry URL    Target registry URL (e.g., registry-quay-quay-enterprise.apps.example.com)"
    echo "  -i, --images TAGS            Source image tags to mirror (comma-separated)"
    echo ""
    echo "Options:"
    echo "  -t, --tag TAG                Target tag for all images (default: $TARGET_TAG)"
    echo "  -s, --source-registry URL    Source registry (default: $SOURCE_REGISTRY)"
    echo "  -d, --dry-run                Show what would be mirrored without executing"
    echo "  -k, --insecure               Skip TLS certificate verification"
    echo "  -h, --help                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Mirror with default target tag (v1)"
    echo "  $0 -r registry-quay-quay-enterprise.apps.example.com -i granite-4.0-h-small"
    echo ""
    echo "  # Mirror specific images with custom target tag"
    echo "  $0 -r registry-quay-quay-enterprise.apps.example.com -i granite-4.0-h-small -t v2"
    echo ""
    echo "  # Dry run to see what would be mirrored"
    echo "  $0 -r registry-quay-quay-enterprise.apps.example.com -i granite-4.0-h-small -d"
    echo ""
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--target-registry)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: Option $1 requires a value"
                usage
            fi
            TARGET_REGISTRY="$2"
            shift 2
            ;;
        -t|--tag)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: Option $1 requires a value"
                usage
            fi
            TARGET_TAG="$2"
            shift 2
            ;;
        -s|--source-registry)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: Option $1 requires a value"
                usage
            fi
            SOURCE_REGISTRY="$2"
            shift 2
            ;;
        -i|--images)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: Option $1 requires a value"
                usage
            fi
            SPECIFIC_TAGS="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift 1
            ;;
        -k|--insecure)
            INSECURE=true
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

# Validate required parameters
if [ -z "$TARGET_REGISTRY" ]; then
    echo "Error: Target registry is required"
    usage
fi

echo "Checking prerequisites..."
if ! command -v skopeo &> /dev/null; then
    echo "Error: 'skopeo' command not found. Please install skopeo."
    exit 1
fi

echo "Configuration:"
echo "  Source Registry:  $SOURCE_REGISTRY"
echo "  Target Registry:  $TARGET_REGISTRY"
echo "  Target Namespace: aiiaas-models (fixed)"
echo "  Target Tag:       $TARGET_TAG"
echo "  Dry Run:          $DRY_RUN"
echo "  Insecure:         $INSECURE"
echo "--------------------------------------------------------"

# Function to mirror a single image
mirror_image() {
    local source_tag=$1
    local source_image="${SOURCE_REGISTRY}:${source_tag}"

    # Extract repository name from source tag (remove version/tag suffix if present)
    local repo_name
    repo_name="${source_tag%%:*}"
    local target_image="${TARGET_REGISTRY}/${TARGET_NAMESPACE}/${repo_name}:${TARGET_TAG}"

    echo ""
    echo "Mirroring: $source_image -> $target_image"

    if [ "$DRY_RUN" = true ]; then
        INSECURE_FLAG=""
        if [ "$INSECURE" = true ]; then
            INSECURE_FLAG="--src-tls-verify=false --dest-tls-verify=false"
        fi
        echo "[DRY RUN] Would execute: skopeo copy docker://$source_image docker://$target_image --all $INSECURE_FLAG"
    else
        MIRROR_OPTS="--all"
        if [ "$INSECURE" = true ]; then
            MIRROR_OPTS="$MIRROR_OPTS --src-tls-verify=false --dest-tls-verify=false"
        fi
        skopeo copy "docker://$source_image" "docker://$target_image" $MIRROR_OPTS
        echo "✓ Successfully mirrored: $source_tag -> ${repo_name}:${TARGET_TAG}"
    fi
}

# Get list of images to mirror
if [ -n "$SPECIFIC_TAGS" ]; then
    # Mirror specific images
    echo "Mirroring specific images..."
    IFS=',' read -ra TAGS <<< "$SPECIFIC_TAGS"
    for tag in "${TAGS[@]}"; do
        tag="${tag#"${tag%%[![:space:]]*}"}"
        tag="${tag%"${tag##*[![:space:]]}"}"
        mirror_image "$tag"
    done
else
    # No images specified - show help
    echo "Error: No images specified. Please use -i option to specify images to mirror."
    echo ""
    echo "Common modelcar images:"
    echo "  granite-4.0-h-small"
    echo "  granite-4.0-h-tiny"
    echo "  granite-4.0-h-micro"
    echo "  gpt-oss-20b"
    echo ""
    echo "Example:"
    echo "  $0 -r $TARGET_REGISTRY -i granite-4.0-h-small,granite-4.0-h-tiny"
    echo ""
    exit 1
fi

echo ""
echo "--------------------------------------------------------"
if [ "$DRY_RUN" = true ]; then
    echo "Dry run completed. No images were actually mirrored."
else
    echo "Mirror operation completed successfully!"
fi
echo "--------------------------------------------------------"
