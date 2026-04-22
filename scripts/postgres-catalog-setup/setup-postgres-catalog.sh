#!/bin/bash

# PostgreSQL Image Catalog Setup Script
# This script generates OpenShift Policy YAML files for PostgreSQL image catalogs
# and optionally applies them to the cluster.

set -e

# Default values
CONFIG_FILE=""
APPLY=false
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/templates/install-postgres-image-catalog-template.yaml"
OUTPUT_DIR="${SCRIPT_DIR}/generated"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 -c CONFIG_FILE [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  -c, --config FILE         Path to configuration YAML file"
    echo ""
    echo "Options:"
    echo "  -a, --apply               Apply the generated YAML to the cluster using 'oc apply'"
    echo "  -d, --dry-run             Validate configuration and check images without generating YAML"
    echo "  -o, --output-dir DIR      Output directory for generated YAML (default: ${OUTPUT_DIR})"
    echo "  -h, --help                Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Generate YAML only"
    echo "  $0 -c config.yaml"
    echo ""
    echo "  # Generate and apply to cluster"
    echo "  $0 -c config.yaml --apply"
    echo ""
    echo "  # Dry run to validate configuration and check images"
    echo "  $0 -c config.yaml --dry-run"
    echo ""
    echo "Prerequisites:"
    echo "  - yq: YAML processor (https://github.com/mikefarah/yq)"
    echo "  - podman: Container tool for image verification"
    echo "  - oc: OpenShift CLI (required only with --apply)"
    echo "  - Authentication: Run 'podman login' to your registry before using this script"
    echo ""
    exit 1
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                log_error "Option $1 requires a value"
                usage
            fi
            CONFIG_FILE="$2"
            shift 2
            ;;
        -a|--apply)
            APPLY=true
            shift 1
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift 1
            ;;
        -o|--output-dir)
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                log_error "Option $1 requires a value"
                usage
            fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [ -z "$CONFIG_FILE" ]; then
    log_error "Configuration file is required (-c/--config)"
    usage
fi

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration file not found: $CONFIG_FILE"
    exit 1
fi

if [ ! -f "$TEMPLATE_FILE" ]; then
    log_error "Template file not found: $TEMPLATE_FILE"
    exit 1
fi

# Check prerequisites
log_info "Checking prerequisites..."

if ! command -v yq &> /dev/null; then
    log_error "'yq' command not found. Please install yq: https://github.com/mikefarah/yq"
    exit 1
fi

if ! command -v podman &> /dev/null; then
    log_error "'podman' command not found. Please install podman."
    exit 1
fi

if [ "$APPLY" = true ] && ! command -v oc &> /dev/null; then
    log_error "'oc' command not found. Please install OpenShift CLI or remove --apply flag."
    exit 1
fi

log_info "✓ All prerequisites satisfied"

# Read and validate configuration
log_info "Reading configuration from: $CONFIG_FILE"

CATALOG_VERSION=$(yq eval '.catalog_version' "$CONFIG_FILE")
if [ -z "$CATALOG_VERSION" ] || [ "$CATALOG_VERSION" = "null" ]; then
    log_error "Missing required field: catalog_version"
    exit 1
fi

# Validate version format (basic check)
if ! [[ "$CATALOG_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_warn "catalog_version should follow semantic versioning (e.g., 1.0.0)"
fi

log_info "Catalog Version: $CATALOG_VERSION"

# Read postgres_images array
IMAGES_COUNT=$(yq eval '.postgres_images | length' "$CONFIG_FILE")
if [ "$IMAGES_COUNT" -eq 0 ] || [ "$IMAGES_COUNT" = "null" ]; then
    log_error "No PostgreSQL images defined in configuration"
    exit 1
fi

log_info "Found $IMAGES_COUNT PostgreSQL image(s) in configuration"

# Validate and check each image
log_info "Validating PostgreSQL images..."
VALIDATION_FAILED=false

for i in $(seq 0 $((IMAGES_COUNT - 1))); do
    MAJOR=$(yq eval ".postgres_images[$i].major" "$CONFIG_FILE")
    IMAGE=$(yq eval ".postgres_images[$i].image" "$CONFIG_FILE")
    
    if [ -z "$MAJOR" ] || [ "$MAJOR" = "null" ]; then
        log_error "Missing 'major' field for image at index $i"
        VALIDATION_FAILED=true
        continue
    fi
    
    if [ -z "$IMAGE" ] || [ "$IMAGE" = "null" ]; then
        log_error "Missing 'image' field for image at index $i"
        VALIDATION_FAILED=true
        continue
    fi
    
    # Validate major is a number
    if ! [[ "$MAJOR" =~ ^[0-9]+$ ]]; then
        log_error "Invalid 'major' value for image at index $i: $MAJOR (must be an integer)"
        VALIDATION_FAILED=true
        continue
    fi
    
    log_info "  PostgreSQL $MAJOR: $IMAGE"
    
    # Check if image exists in registry using podman manifest inspect
    log_info "    Checking image existence..."
    if podman manifest inspect "$IMAGE" &> /dev/null; then
        log_info "    ✓ Image verified"
    else
        log_error "    ✗ Image not found or not accessible: $IMAGE"
        log_error "      Make sure you have authenticated using 'podman login'"
        VALIDATION_FAILED=true
    fi
done

if [ "$VALIDATION_FAILED" = true ]; then
    log_error "Configuration validation failed. Please fix the errors above."
    exit 1
fi

log_info "✓ All images validated successfully"

# Exit if dry run
if [ "$DRY_RUN" = true ]; then
    log_info "Dry run completed. Configuration is valid and all images are accessible."
    exit 0
fi

# Generate YAML
OUTPUT_FILE="${OUTPUT_DIR}/install-postgres-image-catalog-${CATALOG_VERSION}.yaml"
mkdir -p "$OUTPUT_DIR"

log_info "Generating YAML file: $OUTPUT_FILE"

# Read template
TEMPLATE_CONTENT=$(cat "$TEMPLATE_FILE")

# Replace <version> placeholders
YAML_CONTENT="${TEMPLATE_CONTENT//<version>/$CATALOG_VERSION}"

# Build the images section
IMAGES_YAML=""
for i in $(seq 0 $((IMAGES_COUNT - 1))); do
    MAJOR=$(yq eval ".postgres_images[$i].major" "$CONFIG_FILE")
    IMAGE=$(yq eval ".postgres_images[$i].image" "$CONFIG_FILE")
    
    IMAGES_YAML+="              - image: $IMAGE"$'\n'
    IMAGES_YAML+="                major: $MAJOR"$'\n'
done

# Remove trailing newline
IMAGES_YAML="${IMAGES_YAML%$'\n'}"

# Replace the images section in the template
# Find the line with "images:" and replace the placeholder section
TEMP_FILE=$(mktemp)
echo "$YAML_CONTENT" > "$TEMP_FILE"

# Use awk to replace the images section
awk -v images="$IMAGES_YAML" '
/^[[:space:]]*images:/ {
    print
    # Skip the placeholder lines
    getline; while (/^[[:space:]]*- image: <image_path_in_quay>/ || /^[[:space:]]*major:/) getline
    print images
    next
}
{ print }
' "$TEMP_FILE" > "$OUTPUT_FILE"

rm "$TEMP_FILE"

log_info "✓ YAML file generated successfully"

# Apply if requested
if [ "$APPLY" = true ]; then
    log_info "Applying YAML to cluster..."
    
    if oc apply -f "$OUTPUT_FILE"; then
        log_info "✓ Successfully applied to cluster"
    else
        log_error "Failed to apply YAML to cluster"
        exit 1
    fi
fi

# Summary
echo ""
echo "=========================================="
log_info "Setup completed successfully!"
echo "=========================================="
echo ""
echo "Generated file: $OUTPUT_FILE"
echo "Catalog version: $CATALOG_VERSION"
echo "PostgreSQL versions: $IMAGES_COUNT"
echo ""

if [ "$APPLY" = true ]; then
    echo "The Policy has been applied to your OpenShift cluster."
    echo ""
    echo "To check the status:"
    echo "  oc get policy -n postgres-service-broker"
    echo "  oc get clusterimagecatalog"
else
    echo "To apply the generated YAML to your cluster, run:"
    echo "  oc apply -f $OUTPUT_FILE"
    echo ""
    echo "Or re-run this script with the --apply flag:"
    echo "  $0 -c $CONFIG_FILE --apply"
fi
echo ""
echo "=========================================="

# Made with Bob
