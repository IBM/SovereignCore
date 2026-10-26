#!/bin/bash

# Mirror containerdisk (VM guest OS) images from quay.io/containerdisks to target registry
# Source: https://quay.io/containerdisks/<name>:<tag>
#   e.g. https://quay.io/containerdisks/fedora:44
#   e.g. https://quay.io/containerdisks/ubuntu:22.04
# Target: <target-registry>/vm-containerdisks/<name>:<tag> (tag is identical to the source)

set -e

# Default values
SOURCE_REGISTRY="quay.io/containerdisks"
TARGET_REGISTRY=""
TARGET_ORGANIZATION="vm-containerdisks" # DO NOT CHANGE THIS
ARCH="amd64"
DRY_RUN=false
SPECIFIC_IMAGES=""
INSECURE=false

usage() {
    echo "Usage: $0 -r TARGET_REGISTRY -i IMAGES [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  -r, --target-registry URL    Target registry URL (e.g., registry-quay-quay-enterprise.apps.example.com)"
    echo "  -i, --images IMAGES          Source images to mirror as name:tag (comma-separated)"
    echo ""
    echo "Options:"
    echo "  -s, --source-registry URL    Source registry (default: $SOURCE_REGISTRY)"
    echo "  -a, --arch ARCH              Architecture to mirror, or 'all' for every platform (default: $ARCH)"
    echo "  -d, --dry-run                Show what would be mirrored without executing"
    echo "  -k, --insecure               Skip TLS certificate verification"
    echo "  -h, --help                   Show this help message"
    echo ""
    echo "The tag of the mirrored image is always the same as the source image tag."
    echo ""
    echo "Examples:"
    echo "  # Mirror a single image"
    echo "  $0 -r registry-quay-quay-enterprise.apps.example.com -i fedora:44"
    echo ""
    echo "  # Mirror multiple images"
    echo "  $0 -r registry-quay-quay-enterprise.apps.example.com -i fedora:44,ubuntu:22.04"
    echo ""
    echo "  # Dry run to see what would be mirrored"
    echo "  $0 -r registry-quay-quay-enterprise.apps.example.com -i fedora:44 -d"
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
            SPECIFIC_IMAGES="$2"
            shift 2
            ;;
        -a|--arch)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: Option $1 requires a value"
                usage
            fi
            ARCH="$2"
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

# Pre-flight check 1: registry login
# skopeo login --get-login prints the stored username when credentials exist,
# and exits non-zero when no credentials are found.
echo "Checking registry login for $TARGET_REGISTRY..."
TLS_VERIFY_FLAG="--tls-verify=true"
if [ "$INSECURE" = true ]; then
    TLS_VERIFY_FLAG="--tls-verify=false"
fi
if ! skopeo login --get-login "$TLS_VERIFY_FLAG" "$TARGET_REGISTRY" &>/dev/null; then
    echo ""
    echo "Error: Not logged in to registry '$TARGET_REGISTRY'."
    echo ""
    echo "  Please log in first:"
    if [ "$INSECURE" = true ]; then
        echo "    skopeo login --tls-verify=false $TARGET_REGISTRY"
    else
        echo "    skopeo login $TARGET_REGISTRY"
    fi
    echo ""
    exit 1
fi
echo "  ✓ Registry login OK"

# Pre-flight check 2: TLS connectivity
# Try a lightweight registry ping. If it fails with a TLS/certificate error and
# the user did not pass -k, hint at the --insecure flag.
echo "Checking TLS connectivity to $TARGET_REGISTRY..."
TLS_CHECK_ERR=$(skopeo inspect --raw "$TLS_VERIFY_FLAG" \
    "docker://${TARGET_REGISTRY}/${TARGET_ORGANIZATION}/preflight-probe:latest" 2>&1 || true)
if echo "$TLS_CHECK_ERR" | grep -qiE "tls|certificate|x509|ssl"; then
    if [ "$INSECURE" = false ]; then
        echo ""
        echo "Error: TLS certificate verification failed for '$TARGET_REGISTRY'."
        echo "       The registry may be using a self-signed or untrusted certificate."
        echo ""
        echo "  If you trust this registry, re-run the script with the -k flag:"
        if [ -n "$SPECIFIC_IMAGES" ]; then
            echo "    $0 -r $TARGET_REGISTRY -i $SPECIFIC_IMAGES -k"
        else
            echo "    $0 -r $TARGET_REGISTRY -i <images> -k"
        fi
        echo ""
        exit 1
    fi
fi
echo "  ✓ TLS connectivity OK"

echo "Configuration:"
echo "  Source Registry:    $SOURCE_REGISTRY"
echo "  Target Registry:    $TARGET_REGISTRY"
echo "  Target Organization: $TARGET_ORGANIZATION (fixed)"
echo "  Dry Run:            $DRY_RUN"
echo "  Architecture:       $ARCH"
echo "  Insecure:           $INSECURE"
echo "--------------------------------------------------------"

# Function to mirror a single image (name:tag). The tag is kept as-is.
mirror_image() {
    local image=$1

    # Validate image format: name:tag with both parts non-empty
    local image_name="${image%%:*}"
    local image_tag="${image#*:}"
    if [[ "$image" != *:* ]] || [ -z "$image_name" ] || [ -z "$image_tag" ]; then
        echo "Error: Invalid image '$image'. Expected format: name:tag (e.g., fedora:44)"
        exit 1
    fi

    local source_image="${SOURCE_REGISTRY}/${image}"
    local target_image="${TARGET_REGISTRY}/${TARGET_ORGANIZATION}/${image}"

    echo ""
    echo "Mirroring: $source_image -> $target_image"

    # "all" copies every platform in the manifest list; otherwise only the given linux architecture
    if [ "$ARCH" = "all" ]; then
        MIRROR_OPTS="--all"
    else
        MIRROR_OPTS="--override-os linux --override-arch $ARCH"
    fi
    if [ "$INSECURE" = true ]; then
        MIRROR_OPTS="$MIRROR_OPTS --src-tls-verify=false --dest-tls-verify=false"
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would execute: skopeo copy docker://$source_image docker://$target_image $MIRROR_OPTS"
    else
        skopeo copy "docker://$source_image" "docker://$target_image" $MIRROR_OPTS
        echo "✓ Successfully mirrored: $image -> ${TARGET_ORGANIZATION}/${image}"
    fi
}

# Get list of images to mirror
if [ -n "$SPECIFIC_IMAGES" ]; then
    # Mirror specific images
    echo "Mirroring specific images..."
    IFS=',' read -ra IMAGES <<< "$SPECIFIC_IMAGES"
    for image in "${IMAGES[@]}"; do
        image="${image#"${image%%[![:space:]]*}"}"
        image="${image%"${image##*[![:space:]]}"}"
        mirror_image "$image"
    done
else
    # No images specified - show help
    echo "Error: No images specified. Please use -i option to specify images to mirror."
    echo ""
    echo "Common containerdisk images:"
    echo "  fedora:44"
    echo "  ubuntu:22.04"
    echo ""
    echo "Example:"
    echo "  $0 -r $TARGET_REGISTRY -i fedora:44,ubuntu:22.04"
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
