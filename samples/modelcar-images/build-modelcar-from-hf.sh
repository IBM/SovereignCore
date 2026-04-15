#!/bin/bash

# Build modelcar images from Hugging Face models
# This script downloads a model from Hugging Face and packages it as a modelcar OCI image

set -e

# Default values
DEFAULT_MODEL_ID="ibm-granite/granite-4.0-1b"
MODEL_ID="$DEFAULT_MODEL_ID"
TARGET_REGISTRY=""
TARGET_NAMESPACE="aiiaas-models" # DO NOT CHANGE THIS
IMAGE_TAG="v1"
SKIP_DOWNLOAD=false

usage() {
    echo "Usage: $0 [MODEL_ID] -r TARGET_REGISTRY [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  -r, --target-registry URL Target registry URL (e.g., registry-quay-quay-enterprise.apps.example.com)"
    echo ""
    echo "Arguments:"
    echo "  MODEL_ID                  Hugging Face Model ID (default: $DEFAULT_MODEL_ID)"
    echo ""
    echo "Options:"
    echo "  -t, --tag TAG             Image tag (default: $IMAGE_TAG)"
    echo "  -s, --skip-download       Skip downloading model if files exist"
    echo "  -k, --insecure            Skip TLS certificate verification"
    echo "  -h, --help                Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  HF_TOKEN                  Hugging Face token (optional, for private models)"
    echo ""
    echo "Examples:"
    echo "  # Build and push granite model"
    echo "  $0 ibm-granite/granite-4.0-micro -r registry-quay-quay-enterprise.apps.example.com"
    echo ""
    echo "  # Build with custom tag"
    echo "  $0 ibm-granite/granite-4.0-micro -r registry-quay-quay-enterprise.apps.example.com -t v2"
    echo ""
    echo "  # Skip download if model already exists locally"
    echo "  $0 ibm-granite/granite-4.0-micro -r registry-quay-quay-enterprise.apps.example.com -s"
    echo ""
    exit 1
}

# Parse positional argument (MODEL_ID)
if [[ "$1" != -* ]] && [[ -n "$1" ]]; then
    MODEL_ID="$1"
    shift
fi

# Parse options
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
            IMAGE_TAG="$2"
            shift 2
            ;;
        -s|--skip-download)
            SKIP_DOWNLOAD=true
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
    echo "Error: Target registry is required (-r/--target-registry)"
    usage
fi

# Generate image name from model ID
MODEL_IMAGE_NAME=$(basename "${MODEL_ID}" | tr '[:upper:]' '[:lower:]')
FULL_IMAGE_NAME="${TARGET_REGISTRY}/${TARGET_NAMESPACE}/${MODEL_IMAGE_NAME}:${IMAGE_TAG}"

# Create model-specific directory
MODEL_DIR_NAME=$(echo "${MODEL_ID}" | tr '/' '_' | tr '[:upper:]' '[:lower:]')
WORK_DIR="./model_build_temp/${MODEL_DIR_NAME}"
MODEL_DIR="$WORK_DIR/model"

echo "Checking prerequisites..."
if ! command -v podman &> /dev/null; then
    echo "Error: 'podman' not found. Please install podman."
    echo "  macOS: brew install podman"
    echo "  RHEL/Fedora: sudo dnf install podman"
    exit 1
fi

if ! command -v hf &> /dev/null; then
    echo "Error: 'hf' command not found."
    echo "Please install Hugging Face CLI:"
    echo "  curl -LsSf https://hf.co/cli/install.sh | bash"
    exit 1
fi

echo "Configuration:"
echo "  Model ID:      $MODEL_ID"
echo "  Image Name:    $FULL_IMAGE_NAME"
echo "  Skip Download: $SKIP_DOWNLOAD"
echo "--------------------------------------------------------"

echo ""
echo "--- Step 1: Preparing Model Files ---"

should_download=true

if [ "$SKIP_DOWNLOAD" = true ]; then
    if [ -d "$MODEL_DIR" ]; then
        shopt -s nullglob dotglob
        model_dir_contents=("$MODEL_DIR"/*)
        shopt -u nullglob dotglob

        if [ ${#model_dir_contents[@]} -gt 0 ]; then
            echo "SKIP_DOWNLOAD is set. Found existing files in $MODEL_DIR"
            echo "Skipping download step"
            should_download=false
        else
            echo "Warning: SKIP_DOWNLOAD is set, but $MODEL_DIR is missing or empty"
            echo "Proceeding with download..."
        fi
    else
        echo "Warning: SKIP_DOWNLOAD is set, but $MODEL_DIR is missing or empty"
        echo "Proceeding with download..."
    fi
fi

if [ "$should_download" = true ]; then
    echo "Downloading Model: ${MODEL_ID}"

    rm -rf "$WORK_DIR"
    mkdir -p "$MODEL_DIR"

    echo "Downloading to $MODEL_DIR ..."

    # Set HF_TOKEN if provided
    if [ -n "$HF_TOKEN" ]; then
        export HF_TOKEN
    fi

    hf download "$MODEL_ID" \
        --local-dir "$MODEL_DIR"

    echo "✓ Download complete"
else
    mkdir -p "$WORK_DIR"
fi

echo ""
echo "--- Step 2: Creating Containerfile ---"

cat <<EOF > "$WORK_DIR/Containerfile"
FROM registry.access.redhat.com/ubi9/ubi-micro:latest
COPY --chown=0:0 model /models
RUN chmod -R a=rX /models
USER 65534
EOF

echo "✓ Containerfile created"

echo ""
echo "--- Step 3: Building Image (${FULL_IMAGE_NAME}) ---"
podman build --platform linux/amd64 -t "$FULL_IMAGE_NAME" -f "$WORK_DIR/Containerfile" "$WORK_DIR"
echo "✓ Image built successfully"

echo ""
echo "--- Step 4: Pushing Image to Registry ---"
PUSH_OPTS=""
if [ "${INSECURE:-false}" = true ]; then
    PUSH_OPTS="--tls-verify=false"
fi
podman push $PUSH_OPTS "$FULL_IMAGE_NAME"
echo "✓ Image pushed successfully"

echo ""
echo "--------------------------------------------------------"
echo "✓ Success! The modelcar image has been created and pushed:"
echo ""
echo "  Image URI: $FULL_IMAGE_NAME"
echo ""
echo "Use this in your ModelDeployment or InferenceService:"
echo "  storageUri: oci://$FULL_IMAGE_NAME"
echo "--------------------------------------------------------"
