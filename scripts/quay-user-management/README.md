# Quay Read-Only Account Setup

Automatically create read-only user accounts in Quay Enterprise and generate Kubernetes pull secrets for image pulling.

## What This Does

This script creates:
- ✅ A read-only user account across all your Quay organizations
- ✅ A Kubernetes pull secret ready to use in your clusters
- ✅ Automatic read permissions for all repositories

**Result**: Your applications can pull images from Quay without manual token management.

---

## Quick Start (Recommended)

**For users with Hub Cluster access** - Complete setup in one command:

```bash
# 1. Login to your Hub Cluster
oc login https://api.your-cluster.example.com:6443

# 2. Create configuration file
cat > .env <<EOF
QUAY_URL=https://your-quay-registry.example.com
QUAY_SUPER_USER=admin
QUAY_SUPER_PASSWORD=your-password
TEAM_USER_NAME=readonly-user
EOF

# 3. Run the script
source .env
./create-read-only-account.sh

# 4. Apply the generated pull secret
kubectl apply -f generated/pull-secret-readonly-user.yaml
```

**What you get**:
- `generated/auth-readonly-user.json` - User credentials with OAuth token
- `generated/pull-secret-readonly-user.yaml` - Ready-to-use Kubernetes secret

**Done!** Your applications can now pull images using this secret.

---

## Before You Begin

### Required Access

- [ ] Quay superuser credentials (username and password)
- [ ] Hub Cluster access (for automatic setup) OR Quay API token (for manual setup)
- [ ] `kubectl` or `oc` CLI installed

### Required Tools

Install these if not already available:

```bash
# RHEL/Fedora
sudo dnf install jq
```

---

## Setup Methods

Choose the method that fits your environment:

### Method A: Automatic Setup (Recommended)

**Best for**: Users with Hub Cluster access

**What happens**:
1. Script automatically generates OAuth token
2. Creates read-only user in all organizations
3. Generates Kubernetes pull secret
4. Everything ready in one command

**Requirements**:
- Logged in to Hub Cluster (`oc login`)
- Quay superuser credentials

**Steps**:

```bash
# Create .env file
cat > .env <<EOF
QUAY_URL=https://your-quay-registry.example.com
QUAY_SUPER_USER=admin
QUAY_SUPER_PASSWORD=your-password
TEAM_USER_NAME=readonly-user
EOF

# Run
source .env
./create-read-only-account.sh

# Apply to Kubernetes
kubectl apply -f generated/pull-secret-readonly-user.yaml
```

**Output files**:
- `generated/auth-readonly-user.json` - Contains OAuth token
- `generated/pull-secret-readonly-user.yaml` - Kubernetes secret

---

### Method B: Manual Setup

**Best for**: Users without Hub Cluster access

**What happens**:
1. Script creates read-only user in all organizations
2. You manually create token in Quay UI
3. You manually create Kubernetes pull secret

**Requirements**:
- Quay superuser API token

**Steps**:

```bash
# 1. Create .env file
cat > .env <<EOF
QUAY_URL=https://your-quay-registry.example.com
QUAY_API_TOKEN=your-superuser-api-token
TEAM_USER_NAME=readonly-user
EOF

# 2. Run script
source .env
./create-read-only-account.sh

# 3. Create token in Quay UI
# - Login to Quay with credentials from generated/auth-readonly-user.json
# - Go to: Account Settings → Application Tokens
# - Generate new token
# - Copy the token

# 4. Create Kubernetes pull secret manually
kubectl create secret docker-registry quay-pull-secret-readonly-user \
  --docker-server=your-quay-registry.example.com \
  --docker-username='$oauthtoken' \
  --docker-password=<your-token> \
  --namespace=default
```

**Output files**:
- `generated/auth-readonly-user.json` - User credentials (no OAuth token)

---

## Verify Setup

After setup, verify everything works:

```bash
# Check the secret exists
kubectl get secret quay-pull-secret-readonly-user

# Test pulling an image
kubectl run test-pod \
  --image=your-quay-registry.example.com/org/image:tag \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"quay-pull-secret-readonly-user"}]}}'

# Check pod status
kubectl get pod test-pod
```

If the pod starts successfully, your setup is complete!

---

## Common Tasks

### Add Organizations to Existing User

If you create new organizations later, add them to the read-only user:

```bash
source .env
./add-org-to-read-user.sh new-org-name
```

### Use Custom Namespace

By default, pull secrets are created in `acm-service-broker` namespace. To use a different namespace:

```bash
export NAMESPACE=production
source .env
./create-read-only-account.sh
```

### Validate Configuration (Dry Run)

Test your configuration without making changes:

```bash
source .env
./create-read-only-account.sh --dry-run
```

### Reuse Generated Token

Save the OAuth token for future runs (automatic setup only):

```bash
# First run: Generate and save token
./create-read-only-account.sh --no-revoke-token

# Token is saved to .env automatically
# Next runs will reuse the saved token
source .env
./create-read-only-account.sh
```

---

## When Things Go Wrong

### Cannot Connect to Quay

**Problem**: `Failed to connect to Quay API`

**Solution**:
```bash
# Check URL is correct
echo $QUAY_URL

# Test connectivity
curl -k $QUAY_URL/health/instance

# If using self-signed certificates, add to .env:
export CURL_OPTS="--insecure"
```

---

### Hub Cluster Not Accessible

**Problem**: `'oc' command not found` or `OpenShift Cluster not logged in`

**Solution**:
```bash
# Install OpenShift CLI
brew install openshift-cli  # macOS
# or download from Red Hat

# Login to cluster
oc login https://api.your-cluster.example.com:6443

# Verify login
oc whoami
```

---

### Authentication Failed

**Problem**: `Authentication failed. Please check your credentials.`

**Solution**:
```bash
# For automatic setup: Verify superuser credentials
echo $QUAY_SUPER_USER
echo $QUAY_SUPER_PASSWORD

# For manual setup: Verify API token
echo $QUAY_API_TOKEN

# Generate new API token from Quay UI if needed:
# Account Settings → Application Tokens → Generate Token
```

---

### SSL Certificate Error

**Problem**: `SSL certificate problem: self signed certificate`

**Solution**:
```bash
# Quick fix (development/test only):
export CURL_OPTS="--insecure"
source .env
./create-read-only-account.sh

# Production fix: Add CA certificate to system trust store
# macOS:
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain quay-ca.crt

# RHEL/Fedora:
sudo cp quay-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust

# Ubuntu/Debian:
sudo cp quay-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

---

### Permission Denied

**Problem**: `Permission denied. Please ensure your credentials have admin privileges.`

**Solution**:
- Verify your user has superuser role in Quay
- Check API token has `super:user` scope
- Ensure you can create users and teams in Quay UI

---

### Pull Secret Not Working

**Problem**: Pod fails to pull image with `ImagePullBackOff`

**Solution**:
```bash
# Check secret exists
kubectl get secret quay-pull-secret-readonly-user -n <namespace>

# Verify secret content
kubectl get secret quay-pull-secret-readonly-user -o yaml

# Check pod is using correct secret
kubectl describe pod <pod-name>

# Test token manually
TOKEN=$(kubectl get secret quay-pull-secret-readonly-user \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | \
  jq -r '.auths | to_entries[0].value.password')

curl -H "Authorization: Bearer $TOKEN" \
  $QUAY_URL/api/v1/user/
```

---

### Connection Timeout

**Problem**: `curl: (28) Connection timed out`

**Solution**:
```bash
# Increase timeout in .env:
export CURL_OPTS="--connect-timeout 60 --max-time 600"
source .env
./create-read-only-account.sh
```

---

## Configuration Reference

### Environment Variables

Create a `.env` file with these variables:

#### Required Variables

```bash
# Quay registry URL
QUAY_URL=https://your-quay-registry.example.com

# Username for the read-only account
TEAM_USER_NAME=readonly-user
```

#### Authentication (Choose One)

**Option 1: Automatic (OAuth)**
```bash
QUAY_SUPER_USER=admin
QUAY_SUPER_PASSWORD=your-password
QUAY_NAMESPACE=quay-enterprise  # Optional, default: quay-enterprise
```

**Option 2: Manual (API Token)**
```bash
QUAY_API_TOKEN=your-superuser-api-token
```

#### Optional Variables

```bash
# Additional curl options (SSL, timeouts, etc.)
CURL_OPTS="--insecure --connect-timeout 30"

# Kubernetes namespace for pull secret (automatic setup only)
NAMESPACE=acm-service-broker  # Default: acm-service-broker
```

### Command-Line Options

```bash
./create-read-only-account.sh [OPTIONS]

Options:
  -d, --dry-run             Validate configuration without making changes
  --no-revoke-token         Save OAuth token for reuse (automatic setup only)
  -o, --output-dir DIR      Custom output directory (default: ./generated)
  -h, --help                Show help message
```

### Example Configurations

**Automatic Setup (Recommended)**:
```bash
# .env
QUAY_URL=https://quay.example.com
QUAY_SUPER_USER=admin
QUAY_SUPER_PASSWORD=your-password
TEAM_USER_NAME=readonly-user
```

**Manual Setup**:
```bash
# .env
QUAY_URL=https://quay.example.com
QUAY_API_TOKEN=abcdef1234567890
TEAM_USER_NAME=readonly-user
```

**With SSL Certificate Issues**:
```bash
# .env
QUAY_URL=https://quay.example.com
QUAY_SUPER_USER=admin
QUAY_SUPER_PASSWORD=your-password
TEAM_USER_NAME=readonly-user
CURL_OPTS="--insecure"
```

---

## Generated Files

### Automatic Setup Output

```
generated/
├── auth-readonly-user.json           # User credentials with OAuth token
└── pull-secret-readonly-user.yaml    # Kubernetes pull secret (ready to apply)
```

**auth-readonly-user.json** format:
```json
{
  "username": "readonly-user",
  "email": "readonly-user@example.com",
  "password": "auto-generated-password",
  "encrypted_password": "...",
  "oauth_token": "generated-oauth-token"
}
```

**pull-secret-readonly-user.yaml** format:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: quay-pull-secret-readonly-user
  namespace: acm-service-broker
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: <base64-encoded-config>
```

### Manual Setup Output

```
generated/
└── auth-readonly-user.json           # User credentials only
```

**auth-readonly-user.json** format:
```json
{
  "username": "readonly-user",
  "email": "readonly-user@example.com",
  "password": "auto-generated-password",
  "encrypted_password": "..."
}
```

---

## How It Works

For users interested in the technical details:

### What the Script Does

1. **Creates User**: Checks if user exists, creates if needed with auto-generated password
2. **Creates Teams**: Creates `sovereign-core-read` team in each organization
3. **Adds User to Teams**: Adds the user to all teams
4. **Grants Permissions**: Automatically discovers and grants read access to all repositories
5. **Generates Token** (automatic setup): Creates OAuth token with `repo:read` scope
6. **Creates Pull Secret** (automatic setup): Generates Kubernetes secret with the token

### Security Notes

- User has **read-only** access to all repositories
- OAuth tokens (automatic setup) have `repo:read` scope only
- Passwords are auto-generated by Quay API
- Generated files are excluded from git (`.gitignore`)
- Tokens can be revoked at any time from Quay UI

### API Endpoints Used

The script uses these Quay API endpoints:
- User management: `/api/v1/user/`, `/api/v1/superuser/users/`
- Team management: `/api/v1/organization/{org}/team/{team}`
- Repository permissions: `/api/v1/repository/{org}/{repo}/permissions/team/{team}`
- OAuth token generation: `/oauth/authorizeapp` (automatic setup only)

---

## Additional Scripts

### test-oauth-token.sh

Test if an OAuth token is valid:

```bash
./test-oauth-token.sh <oauth-token>
```

### add-org-to-read-user.sh

Add new organizations to existing read-only user:

```bash
source .env
./add-org-to-read-user.sh org1 org2 org3
```

---

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Verify your configuration with `--dry-run`
3. Review generated files in `./generated/` directory
4. Check Quay logs for detailed error messages

---

## Directory Structure

```
quay-user-management/
├── create-read-only-account.sh    # Main script
├── add-org-to-read-user.sh        # Add organizations to existing user
├── test-oauth-token.sh            # Test OAuth token validity
├── .env.example                   # Configuration template
├── .env                           # Your configuration (create from .env.example)
├── README.md                      # This file
└── generated/                     # Generated files (created by scripts)
    ├── auth-<username>.json
    └── pull-secret-<username>.yaml
