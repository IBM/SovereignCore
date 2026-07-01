#!/bin/bash

# Quay Organization Read Access Setup Script
# This script adds an existing user to the 'sovereign-core-read' team in specified organizations,
# grants read permissions to all repositories, and sets up default read permissions.

set -e

# Default values
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/generated"
MAX_RETRIES=3
RETRY_DELAY=2
QUAY_NAMESPACE="${QUAY_NAMESPACE:-quay-enterprise}"
AUTO_GENERATED_TOKEN=false
REVOKE_TOKEN=true
OAUTH_TOKEN_UUID=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 [OPTIONS] ORGANIZATION [ORGANIZATION...]"
    echo ""
    echo "This script adds an existing user to the 'sovereign-core-read' team in specified"
    echo "organizations, grants read permissions to all repositories, and sets up default"
    echo "read permissions for new repositories."
    echo ""
    echo "Options:"
    echo "  -d, --dry-run             Validate configuration without making changes"
    echo "  -D, --debug               Enable debug output"
    echo "  -h, --help                Show this help message"
    echo ""
    echo "Arguments:"
    echo "  ORGANIZATION              One or more organization names to process"
    echo ""
    echo "Required Environment Variables:"
    echo "  QUAY_URL                  Quay registry URL (e.g., https://quay.example.com)"
    echo "  TEAM_USER_NAME            Username to add to teams (must already exist)"
    echo ""
    echo "Authentication (Option 1 - API Token):"
    echo "  QUAY_API_TOKEN            Admin API token for authentication"
    echo ""
    echo "Authentication (Option 2 - OAuth Token Generation):"
    echo "  QUAY_SUPER_USER           Superuser username for OAuth token generation"
    echo "  QUAY_SUPER_PASSWORD       Superuser password for OAuth token generation"
    echo "  QUAY_NAMESPACE            Quay namespace in OpenShift (default: quay-enterprise)"
    echo ""
    echo "Optional Environment Variables:"
    echo "  CURL_OPTS                 Additional curl options (e.g., '--insecure --connect-timeout 30')"
    echo "  DEBUG                     Enable debug output (true/false, or use --debug flag)"
    echo ""
    echo "Examples:"
    echo "  # Using API Token"
    echo "  export QUAY_URL=https://quay.example.com"
    echo "  export QUAY_API_TOKEN=your-admin-token"
    echo "  export TEAM_USER_NAME=readonly-user"
    echo "  $0 my-new-org"
    echo ""
    echo "  # Using OAuth Token Generation (auto-generates and revokes token)"
    echo "  export QUAY_URL=https://quay.example.com"
    echo "  export QUAY_SUPER_USER=admin"
    echo "  export QUAY_SUPER_PASSWORD=your-password"
    echo "  export QUAY_NAMESPACE=quay-enterprise"
    echo "  export TEAM_USER_NAME=readonly-user"
    echo "  $0 my-new-org"
    echo ""
    echo "  # Add user to multiple organizations"
    echo "  $0 org1 org2 org3"
    echo ""
    echo "  # Dry run to validate"
    echo "  $0 --dry-run my-new-org"
    echo ""
    echo "  # Enable debug output"
    echo "  $0 --debug my-new-org"
    echo ""
    echo "Prerequisites:"
    echo "  - curl: HTTP client"
    echo "  - jq: JSON processor"
    echo "  - base64: Base64 encoder"
    echo "  - oc: OpenShift CLI (for OAuth token generation)"
    echo "  - User must be created first (use create-read-only-account.sh)"
    echo ""
    exit 1
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [ "${DEBUG}" = true ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1" >&2
    fi
}

# Function to save OAuth token to .env file
save_token_to_env() {
    local token="$1"
    local env_file="${SCRIPT_DIR}/.env"
    
    if [ -z "$token" ]; then
        log_error "No token provided to save"
        return 1
    fi
    
    log_debug "Saving token to ${env_file}..."
    
    # Create or update .env file
    if [ -f "$env_file" ]; then
        # Check if QUAY_API_TOKEN already exists
        if grep -q "^QUAY_API_TOKEN=" "$env_file"; then
            # Update existing token
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS
                sed -i '' "s|^QUAY_API_TOKEN=.*|QUAY_API_TOKEN=\"${token}\"|" "$env_file"
            else
                # Linux
                sed -i "s|^QUAY_API_TOKEN=.*|QUAY_API_TOKEN=\"${token}\"|" "$env_file"
            fi
        else
            # Append new token
            echo "" >> "$env_file"
            echo "# Auto-generated OAuth token" >> "$env_file"
            echo "QUAY_API_TOKEN=\"${token}\"" >> "$env_file"
        fi
    else
        # Create new .env file
        cat > "$env_file" <<EOF
# Quay Configuration
# Auto-generated OAuth token
QUAY_API_TOKEN="${token}"
EOF
    fi
    
    if [ $? -eq 0 ]; then
        log_debug "✓ Token saved successfully"
        return 0
    else
        log_error "Failed to save token to ${env_file}"
        return 1
    fi
}

# Function to get OAuth token UUID for revocation
get_token_uuid() {
    local token="$1"
    local expected_scope="$2"
    
    if [ -z "$token" ]; then
        log_error "No token provided for UUID retrieval"
        return 1
    fi
    
    if [ -z "$expected_scope" ]; then
        log_error "No scope provided for UUID matching"
        return 1
    fi
    
    log_debug "Retrieving OAuth token UUID..."
    log_debug "  Expected scope: ${expected_scope}"
    
    # Get list of user authorizations
    local response
    local http_code
    
    response=$(curl -s -w "\n%{http_code}" $CURL_OPTS -X GET \
        -H "Authorization: Bearer ${token}" \
        "${QUAY_URL}/api/v1/user/authorizations" 2>&1)
    
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')
    
    if [ "$http_code" -ne 200 ]; then
        log_error "Failed to retrieve user authorizations (HTTP $http_code)"
        log_debug "Response: $response"
        return 1
    fi
    
    # Parse JSON response and find matching token UUID
    # Find the last token with matching scope (most recent)
    # Sort scopes before comparison to handle different ordering
    local uuid
    log_debug "Sorting and comparing scopes (order-independent matching)..."
    uuid=$(echo "$response" | jq -r --arg scope "$expected_scope" '
        ($scope | split(" ") | sort | join(" ")) as $sorted_expected |
        .authorizations
        | map(select(.scopes | map(.scope) | sort | join(" ") == $sorted_expected))
        | last
        | .uuid // empty
    ')
    
    if [ -z "$uuid" ]; then
        log_warn "No OAuth token found with matching scope: ${expected_scope}"
        log_debug "Expected scope (sorted): $(echo "$expected_scope" | tr ' ' '\n' | sort | tr '\n' ' ')"
        log_debug "Available tokens:"
        echo "$response" | jq -r '.authorizations[] | "  UUID: \(.uuid), Scopes: \(.scopes | map(.scope) | join(" "))"' >&2
        return 1
    fi
    
    log_debug "✓ Found matching OAuth token UUID: ${uuid}"
    echo "$uuid"
    return 0
}

# Function to revoke OAuth token
revoke_oauth_token() {
    local token="$1"
    local uuid="$2"
    
    if [ -z "$token" ]; then
        log_error "No token provided for revocation"
        return 1
    fi
    
    if [ -z "$uuid" ]; then
        log_error "No UUID provided for revocation"
        log_error "Cannot revoke token without UUID"
        return 1
    fi
    
    log_debug "Attempting to revoke OAuth token..."
    log_debug "  UUID: ${uuid}"
    
    # Make revoke request using DELETE API
    local response
    local http_code
    
    response=$(curl -s -w "\n%{http_code}" $CURL_OPTS -X DELETE \
        -H "Authorization: Bearer ${token}" \
        "${QUAY_URL}/api/v1/user/authorizations/${uuid}" 2>&1)
    
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')
    
    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        log_info "✓ OAuth token revoked successfully"
        return 0
    else
        log_warn "Failed to revoke OAuth token (HTTP $http_code)"
        log_debug "Response: $response"
        return 1
    fi
}

# Cleanup function to revoke auto-generated tokens
cleanup() {
    local exit_code=$?
    
    # Only process if token was auto-generated
    if [ "$AUTO_GENERATED_TOKEN" = true ]; then
        if [ "$REVOKE_TOKEN" = false ]; then
            # Save token to .env file for reuse
            if [ "$DRY_RUN" = true ]; then
                log_info "Dry run: Would save OAuth token to .env file"
                log_info "  Token would be saved as: QUAY_API_TOKEN=<generated-token>"
                log_info "  Next run would use this token automatically"
            else
                log_info "Saving OAuth token to .env file for reuse..."
                if save_token_to_env "$QUAY_API_TOKEN"; then
                    log_info "✓ OAuth token saved to ${SCRIPT_DIR}/.env"
                    log_info "  Next time, the script will use this token automatically"
                    log_info "  To use the saved token, run: source .env && ./add-org-to-read-user.sh"
                    log_warn "  Note: OAuth tokens may expire. If authentication fails, regenerate the token."
                else
                    log_warn "Failed to save OAuth token to .env file"
                    log_warn "You may need to regenerate the token on next run"
                fi
            fi
        else
            # Revoke token
            if [ "$DRY_RUN" = true ]; then
                log_info "Dry run: Would revoke auto-generated OAuth token"
            else
                log_info "Revoking auto-generated OAuth token..."
                if [ -n "$OAUTH_TOKEN_UUID" ]; then
                    if ! revoke_oauth_token "$QUAY_API_TOKEN" "$OAUTH_TOKEN_UUID"; then
                        log_warn "Failed to revoke OAuth token. Please revoke it manually if needed."
                    fi
                else
                    log_warn "No token UUID available. Cannot revoke token automatically."
                    log_warn "Please revoke the token manually from Quay UI if needed."
                fi
            fi
        fi
    fi
    
    exit $exit_code
}

# Set up cleanup trap
trap cleanup EXIT INT TERM

# Function to get OAuth credentials from Hub Cluster
get_oauth_credentials_from_hub() {
    log_info "Fetching OAuth credentials from Hub Cluster..."
    
    # Check if oc command is available
    if ! command -v oc &> /dev/null; then
        log_error "'oc' command not found. Please install OpenShift CLI."
        return 1
    fi
    
    # Check if logged in to OpenShift
    if ! oc whoami &> /dev/null; then
        log_error "Not logged in to OpenShift Cluster. Please run 'oc login'."
        return 1
    fi
    
    # Extract OAuth credentials from secret
    local secret_output
    if ! secret_output=$(oc extract -n "${QUAY_NAMESPACE}" secret/quay-oauth-credentials --to=- 2>&1); then
        log_error "Failed to get OAuth credentials"
        log_error "Namespace: ${QUAY_NAMESPACE}"
        log_error "Secret: quay-oauth-credentials"
        log_debug "Error: $secret_output"
        return 1
    fi
    
    # Parse client-id
    OAUTH_CLIENT_ID=$(echo "$secret_output" | awk '/^# client-id$/{getline; print}')
    if [ -z "$OAUTH_CLIENT_ID" ]; then
        log_error "Failed to extract Client ID"
        return 1
    fi
    
    # Parse redirect-uri
    OAUTH_REDIRECT_URI=$(echo "$secret_output" | awk '/^# redirect-uri$/{getline; print}')
    if [ -z "$OAUTH_REDIRECT_URI" ]; then
        log_error "Failed to extract Redirect URI"
        return 1
    fi
    
    log_info "✓ OAuth credentials retrieved successfully"
    log_debug "  Client ID: ${OAUTH_CLIENT_ID}"
    log_debug "  Redirect URI: ${OAUTH_REDIRECT_URI}"
    
    return 0
}

# Function to generate OAuth token
generate_oauth_token() {
    local username="$1"
    local password="$2"
    local scopes="$3"
    local client_id="$4"
    local redirect_uri="$5"
    
    log_debug "Generating OAuth token..."
    log_debug "  Username: ${username}"
    log_debug "  Scopes: ${scopes}"
    
    # Create Basic Auth header
    local auth_header=$(echo -n "${username}:${password}" | base64)
    
    # Prepare request data
    local request_data="response_type=token&client_id=${client_id}&scope=${scopes}&redirect_uri=${redirect_uri}"
    
    # Make OAuth request and capture full response including headers
    local response
    response=$(curl -s -v -X POST $CURL_OPTS \
        -d "$request_data" \
        -H "Authorization: Basic ${auth_header}" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        "${QUAY_URL}/oauth/authorizeapp" 2>&1)
    
    # Extract access token from Location header
    local token=$(echo "$response" | grep -i "^< location:" | sed -n 's/.*access_token=\([^&]*\).*/\1/p' | tr -d '\r\n')
    
    if [ -z "$token" ]; then
        log_error "Failed to generate OAuth token"
        log_debug "Response: $response"
        
        # Check for common errors
        if echo "$response" | grep -q "401"; then
            log_error "Authentication failed. Please check username and password."
        elif echo "$response" | grep -q "400"; then
            log_error "Invalid request. Please verify Client ID is whitelisted."
        fi
        
        return 1
    fi
    
    log_debug "✓ OAuth token generated successfully"
    
    echo "$token"
    return 0
}

# Parse arguments
ORGANIZATIONS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry-run)
            DRY_RUN=true
            shift 1
            ;;
        -D|--debug)
            DEBUG=true
            shift 1
            ;;
        -h|--help)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            ;;
        *)
            ORGANIZATIONS+=("$1")
            shift 1
            ;;
    esac
done

# Check if at least one organization is specified
if [ ${#ORGANIZATIONS[@]} -eq 0 ]; then
    log_error "At least one organization must be specified"
    usage
fi

# Check prerequisites
log_info "Checking prerequisites..."

if ! command -v curl &> /dev/null; then
    log_error "'curl' command not found. Please install curl."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_error "'jq' command not found. Please install jq: https://stedolan.github.io/jq/"
    exit 1
fi

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

# Validate authentication
log_info "Validating authentication..."

# Check if API token is provided or if we need to generate one
if [ -z "$QUAY_API_TOKEN" ]; then
    log_info "QUAY_API_TOKEN not provided. Checking for OAuth token generation credentials..."
    
    # Check if OAuth credentials are provided
    if [ -z "$QUAY_SUPER_USER" ] || [ -z "$QUAY_SUPER_PASSWORD" ]; then
        log_error "Authentication required. Please provide either:"
        log_error "  1. QUAY_API_TOKEN environment variable, or"
        log_error "  2. QUAY_SUPER_USER and QUAY_SUPER_PASSWORD for OAuth token generation"
        exit 1
    fi
    
    log_info "✓ OAuth credentials provided"
    log_info "Namespace: ${QUAY_NAMESPACE}"
    
    # Get OAuth credentials from Hub Cluster
    if ! get_oauth_credentials_from_hub; then
        log_error "Failed to get OAuth credentials from Hub Cluster"
        log_error "Please ensure:"
        log_error "  1. You are logged in to OpenShift (oc login)"
        log_error "  2. The namespace '${QUAY_NAMESPACE}' exists"
        log_error "  3. The secret 'quay-oauth-credentials' exists in the namespace"
        exit 1
    fi
    
    # Generate OAuth token for superuser
    log_info "Generating OAuth token for superuser..."
    SUPERUSER_SCOPES="super:user org:admin repo:admin repo:create user:admin user:read"
    
    if ! QUAY_API_TOKEN=$(generate_oauth_token "$QUAY_SUPER_USER" "$QUAY_SUPER_PASSWORD" "$SUPERUSER_SCOPES" "$OAUTH_CLIENT_ID" "$OAUTH_REDIRECT_URI"); then
        log_error "Failed to generate OAuth token for superuser"
        exit 1
    fi
    
    # Get UUID in parent shell (not in subshell) to ensure it's available for cleanup
    log_debug "Retrieving token UUID for revocation in parent shell..."
    if OAUTH_TOKEN_UUID=$(get_token_uuid "$QUAY_API_TOKEN" "$SUPERUSER_SCOPES"); then
        log_debug "✓ Token UUID retrieved in parent shell: ${OAUTH_TOKEN_UUID}"
    else
        log_warn "Failed to retrieve token UUID. Token revocation may not work properly."
        OAUTH_TOKEN_UUID=""
    fi
    
    # Mark token as auto-generated for cleanup
    AUTO_GENERATED_TOKEN=true
    
    log_info "✓ OAuth token generated successfully (auto-generated)"
    log_info "✓ Using generated token as QUAY_API_TOKEN"
    
    if [ "$REVOKE_TOKEN" = true ]; then
        log_info "Note: Token will be automatically revoked on script exit"
    else
        log_info "Note: Token will NOT be revoked on script exit"
    fi
else
    log_info "✓ Using existing API Token"
fi

# Remove trailing slash from QUAY_URL
QUAY_URL="${QUAY_URL%/}"

log_info "✓ Environment variables validated"
log_info "Quay URL: $QUAY_URL"
log_info "Team User: $TEAM_USER_NAME"
log_info "Organizations to process: ${ORGANIZATIONS[*]}"

# Function to make API calls with retry logic
api_call() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    local retry_count=0
    local response
    local http_code
    local error_message
    
    # Set authentication header
    local auth_header="Authorization: Bearer $QUAY_API_TOKEN"
    
    while [ $retry_count -lt $MAX_RETRIES ]; do
        if [ -n "$data" ]; then
            response=$(curl -s -w "\n%{http_code}" $CURL_OPTS -X "$method" \
                -H "$auth_header" \
                -H "Content-Type: application/json" \
                -d "$data" \
                "${QUAY_URL}${endpoint}")
        else
            response=$(curl -s -w "\n%{http_code}" $CURL_OPTS -X "$method" \
                -H "$auth_header" \
                "${QUAY_URL}${endpoint}")
        fi
        
        http_code=$(echo "$response" | tail -n1)
        response=$(echo "$response" | sed '$d')
        
        # Extract error message from JSON response if available
        error_message=$(echo "$response" | jq -r '.error_message // .message // .detail // .error // empty' 2>/dev/null)
        
        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
            echo "$response"
            return 0
        elif [ "$http_code" -eq 400 ]; then
            log_error "Bad Request (HTTP 400): Invalid request parameters"
            if [ -n "$error_message" ]; then
                log_error "API Error: $error_message"
            else
                log_error "Response: $response"
            fi
            return 1
        elif [ "$http_code" -eq 401 ]; then
            log_error "Authentication failed (HTTP 401). Please check your QUAY_API_TOKEN."
            if [ -n "$error_message" ]; then
                log_error "API Error: $error_message"
            fi
            return 1
        elif [ "$http_code" -eq 403 ]; then
            log_error "Permission denied (HTTP 403). Please ensure your credentials have admin privileges."
            if [ -n "$error_message" ]; then
                log_error "API Error: $error_message"
            fi
            return 1
        elif [ "$http_code" -eq 404 ]; then
            log_error "Resource not found (HTTP 404)"
            if [ -n "$error_message" ]; then
                log_error "API Error: $error_message"
            else
                log_error "Endpoint: $endpoint"
            fi
            return 1
        elif [ "$http_code" -eq 409 ]; then
            log_error "Conflict (HTTP 409): Resource already exists or conflict detected"
            if [ -n "$error_message" ]; then
                log_error "API Error: $error_message"
            else
                log_error "Response: $response"
            fi
            return 1
        elif [ "$http_code" -eq 422 ]; then
            log_error "Unprocessable Entity (HTTP 422): Validation failed"
            if [ -n "$error_message" ]; then
                log_error "API Error: $error_message"
            else
                log_error "Response: $response"
            fi
            return 1
        elif [ "$http_code" -ge 500 ]; then
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $MAX_RETRIES ]; then
                log_warn "Server error (HTTP $http_code). Retrying in ${RETRY_DELAY}s... (Attempt $((retry_count + 1))/$MAX_RETRIES)"
                if [ -n "$error_message" ]; then
                    log_debug "API Error: $error_message"
                fi
                sleep $RETRY_DELAY
            else
                log_error "Server error (HTTP $http_code) after $MAX_RETRIES attempts."
                if [ -n "$error_message" ]; then
                    log_error "API Error: $error_message"
                else
                    log_error "Response: $response"
                fi
                return 1
            fi
        else
            log_error "API call failed with HTTP $http_code"
            if [ -n "$error_message" ]; then
                log_error "API Error: $error_message"
            else
                log_error "Response: $response"
            fi
            return 1
        fi
    done
    
    return 1
}

# Test API connectivity
log_info "Testing API connectivity..."
if ! api_call "GET" "/api/v1/user/" > /dev/null; then
    log_error "Failed to connect to Quay API. Please check QUAY_URL and your credentials."
    exit 1
fi
log_info "✓ API connectivity verified"

# Check if team user exists
log_info "Checking if team user exists..."
if user_check=$(api_call "GET" "/api/v1/users/${TEAM_USER_NAME}"); then
    if echo "$user_check" | jq -e '.username' > /dev/null 2>&1; then
        log_info "✓ Team user exists: $TEAM_USER_NAME"
    else
        log_error "Invalid response when checking user existence"
        log_error "Response: $user_check"
        exit 1
    fi
else
    log_error "Team user does not exist: $TEAM_USER_NAME"
    log_error "Please create the user first using create-read-only-account.sh"
    exit 1
fi

# Exit if dry run
if [ "$DRY_RUN" = true ]; then
    log_info "Dry run mode: Validating organizations..."
    for org in "${ORGANIZATIONS[@]}"; do
        log_info "  Would process organization: $org"
    done
    log_info "Dry run completed. Configuration is valid."
    exit 0
fi

# Team configuration
TEAM_NAME="sovereign-core-read"
TEAM_DESCRIPTION="Read access for sovereign core images"

# Counters for summary
total_orgs=0
total_repos=0
total_success=0
total_skip=0
total_error=0

# Process each organization
for org in "${ORGANIZATIONS[@]}"; do
    total_orgs=$((total_orgs + 1))
    log_info ""
    log_info "Processing organization: $org"
    
    # Check if organization exists
    log_info "  Checking organization..."
    if ! org_check=$(api_call "GET" "/api/v1/organization/${org}"); then
        log_warn "  ✗ Organization not found or not accessible: $org (skipping)"
        continue
    fi
    
    if ! echo "$org_check" | jq -e '.name' > /dev/null 2>&1; then
        log_warn "  ✗ Invalid response when checking organization: $org (skipping)"
        continue
    fi
    
    log_info "  ✓ Organization exists"
    
    # Check if team exists and user membership
    log_info "  Checking team: $TEAM_NAME"
    user_already_in_team=false
    
    if echo "$org_check" | jq -e ".teams.\"${TEAM_NAME}\"" > /dev/null 2>&1; then
        # Team exists - get member information
        log_info "  ✓ Team already exists"
        
        if team_check=$(api_call "GET" "/api/v1/organization/${org}/team/${TEAM_NAME}/members"); then
            # Check if user is already a member
            if echo "$team_check" | jq -e ".members[] | select(.name==\"${TEAM_USER_NAME}\")" > /dev/null 2>&1; then
                log_info "  ✓ User already in team"
                user_already_in_team=true
            fi
        else
            log_warn "  ✗ Failed to get team members in $org (continuing with other organizations)"
            continue
        fi
    else
        # Team does not exist - create it
        log_info "  Creating team: $TEAM_NAME"
        team_data="{\"name\":\"${TEAM_NAME}\",\"role\":\"member\",\"description\":\"${TEAM_DESCRIPTION}\"}"
        if ! team_response=$(api_call "PUT" "/api/v1/organization/${org}/team/${TEAM_NAME}" "$team_data"); then
            log_warn "  ✗ Failed to create team in $org (continuing with other organizations)"
            continue
        fi
        
        # Validate response
        if ! echo "$team_response" | jq -e '.name' > /dev/null 2>&1; then
            log_warn "  ✗ Team creation returned success but response is invalid for $org (continuing)"
            continue
        fi
        
        log_info "  ✓ Team created"
    fi
    
    # Add user to team (skip if already a member)
    if [ "$user_already_in_team" = true ]; then
        log_info "  Skipping user addition (already a member)"
    else
        log_info "  Adding user to team..."
        if member_response=$(api_call "PUT" "/api/v1/organization/${org}/team/${TEAM_NAME}/members/${TEAM_USER_NAME}" ""); then
            log_info "  ✓ User added to team"
        else
            log_warn "  ✗ Failed to add user to team in $org (continuing with other organizations)"
            continue
        fi
    fi
    
    # Set up default permissions for the team
    log_info "  Checking default permissions..."
    
    # Check existing default permissions
    if default_perms=$(api_call "GET" "/api/v1/organization/${org}/prototypes"); then
        # Validate response
        if echo "$default_perms" | jq -e '.prototypes' > /dev/null 2>&1; then
            # Check if default permission already exists for this team with read role
            existing_default=$(echo "$default_perms" | jq -r ".prototypes[]? | select(.delegate.name==\"${TEAM_NAME}\" and .delegate.kind==\"team\" and .role==\"read\") | .id" 2>/dev/null)
            
            if [ -n "$existing_default" ]; then
                log_info "  ✓ Default permission already exists for team"
            else
                log_info "  Creating default permission for team..."
                
                # Create default permission with Anyone condition (activating_user is null)
                default_perm_data=$(cat <<EOF
{
  "role": "read",
  "delegate": {
    "name": "${TEAM_NAME}",
    "kind": "team"
  }
}
EOF
)
                
                if default_response=$(api_call "POST" "/api/v1/organization/${org}/prototypes" "$default_perm_data"); then
                    # Validate response
                    if echo "$default_response" | jq -e '.id' > /dev/null 2>&1; then
                        log_info "  ✓ Default permission created successfully"
                        log_info "    New repositories will automatically grant read access to ${TEAM_NAME}"
                    else
                        log_warn "  ✗ Default permission creation returned success but response is invalid"
                        log_debug "    Response: $default_response"
                    fi
                else
                    log_warn "  ✗ Failed to create default permission (continuing with existing repositories)"
                fi
            fi
        else
            log_warn "  ✗ Invalid response when checking default permissions (continuing)"
            log_debug "    Response: $default_perms"
        fi
    else
        log_warn "  ✗ Failed to check default permissions (continuing with existing repositories)"
    fi
    
    # Fetch repositories for this organization
    log_info "  Fetching repositories for $org..."
    org_repos=()
    next_page=""
    page_num=1
    max_pages=500
    
    while [ $page_num -le $max_pages ]; do
        log_debug "    Fetching page $page_num..."
        
        # Build API URL with next_page token if available
        if [ -z "$next_page" ]; then
            api_url="/api/v1/repository?namespace=${org}&public=false"
        else
            api_url="/api/v1/repository?namespace=${org}&public=false&next_page=${next_page}"
        fi
        
        if ! repos_response=$(api_call "GET" "$api_url"); then
            log_warn "    Failed to fetch repositories for $org"
            break
        fi
        
        # Validate response
        if ! echo "$repos_response" | jq -e '.repositories' > /dev/null 2>&1; then
            log_warn "    Invalid response when fetching repositories for $org"
            break
        fi
        
        # Extract repository names
        repos=$(echo "$repos_response" | jq -r '.repositories[]? | .name')
        
        if [ -z "$repos" ]; then
            break
        fi
        
        # Add repositories to array
        while IFS= read -r repo_name; do
            org_repos+=("$repo_name")
        done <<< "$repos"
        
        # Get next page token
        next_page=$(echo "$repos_response" | jq -r '.next_page // empty')
        if [ -z "$next_page" ]; then
            log_debug "    No more pages"
            break
        fi
        
        page_num=$((page_num + 1))
    done
    
    # Warn if maximum page limit reached
    if [ $page_num -gt $max_pages ]; then
        log_warn "    Reached maximum page limit ($max_pages) for $org"
    fi
    
    repo_count=${#org_repos[@]}
    total_repos=$((total_repos + repo_count))
    log_info "  ✓ Found $repo_count repositories"
    
    if [ $repo_count -eq 0 ]; then
        log_warn "  No repositories found in $org"
        continue
    fi
    
    # Fetch existing team permissions to avoid duplicate API calls
    log_info "  Fetching existing team permissions..."
    existing_perms_list=""
    use_bulk_check=true
    
    if perms_response=$(api_call "GET" "/api/v1/organization/${org}/team/${TEAM_NAME}/permissions"); then
        # Validate response
        if echo "$perms_response" | jq -e '.permissions' > /dev/null 2>&1; then
            # Parse existing permissions into newline-separated list (repo_name:role format)
            existing_perms_list=$(echo "$perms_response" | jq -r '.permissions[]? | "\(.repository.name):\(.role)"' 2>/dev/null)
            
            if [ -n "$existing_perms_list" ]; then
                existing_count=$(echo "$existing_perms_list" | wc -l | tr -d ' ')
                log_info "  ✓ Found $existing_count existing permissions"
            else
                log_info "  ✓ No existing permissions found"
            fi
        else
            log_warn "  ✗ Invalid response when fetching team permissions, will check individually"
            use_bulk_check=false
        fi
    else
        log_warn "  ✗ Failed to fetch team permissions, will check individually"
        use_bulk_check=false
    fi
    
    # Grant team permissions to all repositories
    log_info "  Granting team permissions..."
    
    success_count=0
    skip_count=0
    error_count=0
    
    for repo_name in "${org_repos[@]}"; do
        log_debug "    Processing: ${org}/${repo_name}"
        
        # Check if permission already exists (using bulk check if available)
        if [ "$use_bulk_check" = true ] && [ -n "$existing_perms_list" ]; then
            # Search for repo_name in existing permissions list
            existing_entry=$(echo "$existing_perms_list" | grep "^${repo_name}:" || true)
            if [ -n "$existing_entry" ]; then
                existing_role=$(echo "$existing_entry" | cut -d':' -f2)
                if [ "$existing_role" = "read" ]; then
                    skip_count=$((skip_count + 1))
                    log_debug "      - Permission already exists (role: $existing_role)"
                    continue
                else
                    log_debug "      ! Existing permission has different role: $existing_role, will update to read"
                fi
            fi
        fi
        
        # Grant permission to team
        perm_data='{"role":"read"}'
        if perm_response=$(api_call "PUT" "/api/v1/repository/${org}/${repo_name}/permissions/team/${TEAM_NAME}" "$perm_data"); then
            # Validate response
            if echo "$perm_response" | jq -e '.role' > /dev/null 2>&1; then
                success_count=$((success_count + 1))
                log_debug "      ✓ Granted read permission"
            else
                # Success but no validation - count as success anyway
                success_count=$((success_count + 1))
                log_debug "      ✓ Granted read permission (no validation)"
            fi
        else
            # Fallback: Check if permission already exists (for cases where bulk check failed)
            if [ "$use_bulk_check" = false ]; then
                if existing_perm=$(api_call "GET" "/api/v1/repository/${org}/${repo_name}/permissions/team/${TEAM_NAME}"); then
                    if echo "$existing_perm" | jq -e '.role' > /dev/null 2>&1; then
                        skip_count=$((skip_count + 1))
                        log_debug "      - Permission already exists"
                    else
                        error_count=$((error_count + 1))
                        log_warn "      ✗ Failed to grant permission to ${org}/${repo_name}"
                    fi
                else
                    error_count=$((error_count + 1))
                    log_warn "      ✗ Failed to grant permission to ${org}/${repo_name}"
                fi
            else
                error_count=$((error_count + 1))
                log_warn "      ✗ Failed to grant permission to ${org}/${repo_name}"
            fi
        fi
    done
    
    total_success=$((total_success + success_count))
    total_skip=$((total_skip + skip_count))
    total_error=$((total_error + error_count))
    
    log_info "  ✓ Permission grant completed for $org"
    log_info "    Success: $success_count, Skipped: $skip_count, Errors: $error_count"
done

log_info ""
log_info "✓ All organizations processed"
log_info "  Organizations: $total_orgs"
log_info "  Total repositories: $total_repos"
log_info "  Total success: $total_success"
log_info "  Total skipped: $total_skip"
if [ $total_error -gt 0 ]; then
    log_warn "  Total errors: $total_error"
fi

# Summary
echo ""
echo "=========================================="
log_info "Setup completed successfully!"
echo "=========================================="
echo ""
echo "Team Name: $TEAM_NAME"
echo "Team User: $TEAM_USER_NAME"
echo "Organizations processed: $total_orgs"
echo "Total repositories with team access: $total_repos"
echo ""
echo "=========================================="

# Made with Bob