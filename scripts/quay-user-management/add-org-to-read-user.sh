#!/bin/bash

# Quay Organization Read Access Setup Script
# This script adds an existing user to the 'sovereign-core-read' team in specified organizations,
# grants read permissions to all repositories, and sets up default read permissions.

set -e

# Default values
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_RETRIES=3
RETRY_DELAY=2

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
    echo "  -h, --help                Show this help message"
    echo ""
    echo "Arguments:"
    echo "  ORGANIZATION              One or more organization names to process"
    echo ""
    echo "Required Environment Variables:"
    echo "  QUAY_URL                  Quay registry URL (e.g., https://quay.example.com)"
    echo "  TEAM_USER_NAME            Username to add to teams (must already exist)"
    echo ""
    echo "Authentication:"
    echo "  QUAY_API_TOKEN            Admin API token for authentication"
    echo ""
    echo "Optional Environment Variables:"
    echo "  CURL_OPTS                 Additional curl options (e.g., '--insecure --connect-timeout 30')"
    echo ""
    echo "Examples:"
    echo "  # Set environment variables"
    echo "  export QUAY_URL=https://quay.example.com"
    echo "  export QUAY_API_TOKEN=your-admin-token"
    echo "  export TEAM_USER_NAME=readonly-user"
    echo ""
    echo "  # Add user to single organization"
    echo "  $0 my-new-org"
    echo ""
    echo "  # Add user to multiple organizations"
    echo "  $0 org1 org2 org3"
    echo ""
    echo "  # Dry run to validate"
    echo "  $0 --dry-run my-new-org"
    echo ""
    echo "Prerequisites:"
    echo "  - curl: HTTP client"
    echo "  - jq: JSON processor"
    echo "  - base64: Base64 encoder"
    echo "  - User must be created first (use create-read-only-account.sh)"
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
ORGANIZATIONS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry-run)
            DRY_RUN=true
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

if [ -z "$QUAY_API_TOKEN" ]; then
    log_error "QUAY_API_TOKEN environment variable is required"
    exit 1
fi

log_info "✓ Using API Token authentication"

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
    
    if team_check=$(api_call "GET" "/api/v1/organization/${org}/team/${TEAM_NAME}/members"); then
        if echo "$team_check" | jq -e '.name' > /dev/null 2>&1; then
            log_info "  ✓ Team already exists"
            
            # Check if user is already a member
            if echo "$team_check" | jq -e ".members[] | select(.name==\"${TEAM_USER_NAME}\")" > /dev/null 2>&1; then
                log_info "  ✓ User already in team"
                user_already_in_team=true
            fi
        else
            log_warn "  ✗ Invalid response when checking team in $org (continuing with other organizations)"
            continue
        fi
    else
        # Create team
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