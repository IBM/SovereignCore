#!/bin/bash

# Quay Pull Secret Generator
# This script generates a Kubernetes pull secret using a Quay application
# token or OAuth token from a Quay user account.

set -e

# Default values
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/generated"
NAMESPACE="acm-service-broker"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "This script generates a Kubernetes pull secret using a Quay application"
    echo "token or OAuth token from a Quay user account."
    echo ""
    echo "Options:"
    echo "  -o, --output-dir DIR      Output directory for generated files (default: ${OUTPUT_DIR})"
    echo "  -h, --help                Show this help message"
    echo ""
    echo "Required Environment Variables:"
    echo "  QUAY_URL                  Quay registry URL (e.g., https://quay.example.com)"
    echo "  TEAM_USER_NAME            Username for the pull secret"
    echo "  TEAM_USER_APP_TOKEN       Application token from Quay UI"
    echo "  TEAM_USER_OAUTH_TOKEN     OAuth token from Quay UI"
    echo "                            Set either TEAM_USER_APP_TOKEN or TEAM_USER_OAUTH_TOKEN"
    echo ""
    echo "Optional Environment Variables:"
    echo "  NAMESPACE                 Kubernetes namespace for secret (default: acm-service-broker)"
    echo ""
    echo "Examples:"
    echo "  # Set environment variables for an application token"
    echo "  export QUAY_URL=https://quay.example.com"
    echo "  export TEAM_USER_NAME=readonly-user"
    echo "  export TEAM_USER_APP_TOKEN=your-application-token"
    echo ""
    echo "  # Or use an OAuth token"
    echo "  export TEAM_USER_OAUTH_TOKEN=your-oauth-token"
    echo ""
    echo "  # Run the script"
    echo "  $0"
    echo ""
    echo "  # Custom output directory"
    echo "  $0 --output-dir /tmp/secrets"
    echo ""
    echo "Prerequisites:"
    echo "  - base64: Base64 encoder"
    echo ""
    echo "Note:"
    echo "  The application token or OAuth token should be generated from Quay UI."
    echo "  If both TEAM_USER_APP_TOKEN and TEAM_USER_OAUTH_TOKEN are set,"
    echo "  TEAM_USER_OAUTH_TOKEN takes precedence."
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

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
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

# Check prerequisites
log_info "Checking prerequisites..."

if ! command -v base64 &> /dev/null; then
    log_error "'base64' command not found."
    exit 1
fi

log_info "✓ All prerequisites satisfied"

# Validate required environment variables
log_info "Validating environment variables..."

if [ -z "$QUAY_URL" ]; then
    log_error "QUAY_URL environment variable is required"
    exit 1
fi

if [ -z "$TEAM_USER_NAME" ]; then
    log_error "TEAM_USER_NAME environment variable is required"
    exit 1
fi

if [ -z "$TEAM_USER_APP_TOKEN" ] && [ -z "$TEAM_USER_OAUTH_TOKEN" ]; then
    log_error "Either TEAM_USER_APP_TOKEN or TEAM_USER_OAUTH_TOKEN environment variable is required"
    log_error "Please generate a token from Quay UI:"
    log_error "  1. Log in to Quay: $QUAY_URL"
    log_error "  2. Go to: Account Settings"
    log_error "  3. Generate an application token or OAuth token"
    log_error "  4. Set it as TEAM_USER_APP_TOKEN or TEAM_USER_OAUTH_TOKEN"
    exit 1
fi

if [ -n "$TEAM_USER_OAUTH_TOKEN" ]; then
    SELECTED_TOKEN="$TEAM_USER_OAUTH_TOKEN"
    DOCKER_USERNAME='$oauthtoken'
    TOKEN_TYPE="OAuth token"
    if [ -n "$TEAM_USER_APP_TOKEN" ]; then
        log_warn "Both TEAM_USER_APP_TOKEN and TEAM_USER_OAUTH_TOKEN are set; using TEAM_USER_OAUTH_TOKEN"
    fi
else
    SELECTED_TOKEN="$TEAM_USER_APP_TOKEN"
    DOCKER_USERNAME='$app'
    TOKEN_TYPE="application token"
fi

# Set namespace from environment or use default
if [ -n "$NAMESPACE" ]; then
    log_info "Using namespace: $NAMESPACE"
else
    NAMESPACE="acm-service-broker"
    log_info "Using default namespace: $NAMESPACE"
fi

# Remove trailing slash from QUAY_URL
QUAY_URL="${QUAY_URL%/}"

log_info "✓ Environment variables validated"
log_info "Quay URL: $QUAY_URL"
log_info "Team User: $TEAM_USER_NAME"
log_info "Namespace: $NAMESPACE"
log_info "Credential type: $TOKEN_TYPE"

# Generate Kubernetes pull secret
log_info ""
log_info "Generating Kubernetes pull secret..."

mkdir -p "$OUTPUT_DIR"

# Create docker config JSON
DOCKER_CONFIG=$(cat <<EOF
{
  "auths": {
    "${QUAY_URL#https://}": {
      "auth": "$(echo -n "${DOCKER_USERNAME}:${SELECTED_TOKEN}" | base64)",
      "username": "${DOCKER_USERNAME}",
      "password": "${SELECTED_TOKEN}"
    }
  }
}
EOF
)

# Base64 encode the docker config
DOCKER_CONFIG_BASE64=$(echo -n "$DOCKER_CONFIG" | base64)

# Generate Kubernetes Secret YAML
OUTPUT_FILE="${OUTPUT_DIR}/pull-secret-${TEAM_USER_NAME}.yaml"

cat > "$OUTPUT_FILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: quay-pull-secret-${TEAM_USER_NAME}
  namespace: ${NAMESPACE}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${DOCKER_CONFIG_BASE64}
EOF

log_info "✓ Kubernetes pull secret generated: $OUTPUT_FILE"

# Summary
echo ""
echo "=========================================="
log_info "Pull secret generation completed!"
echo "=========================================="
echo ""
echo "Team User: $TEAM_USER_NAME"
echo "Namespace: $NAMESPACE"
echo "Generated secret file: $OUTPUT_FILE"
echo ""
echo "To apply the secret to your cluster:"
echo "  kubectl apply -f $OUTPUT_FILE"
echo ""
echo "To use this secret in a Pod:"
echo "  spec:"
echo "    imagePullSecrets:"
echo "    - name: quay-pull-secret-${TEAM_USER_NAME}"
echo ""
echo "=========================================="

# Made with Bob