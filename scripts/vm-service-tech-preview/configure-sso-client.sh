#!/bin/bash
set -e

# Accept optional VM_CLUSTER_ROUTE parameter
# Usage: ./configure-sso.sh [VM_CLUSTER_ROUTE]
# Example: ./configure-sso.sh https://oauth-openshift.apps.example.com

# Detect base64 decode flag (macOS uses -D, Linux uses -d)
BASE64_DECODE_FLAG="-d"
if [[ "$OSTYPE" == "darwin"* ]]; then
  BASE64_DECODE_FLAG="-D"
fi

echo "Fetching Account IAM route..."
ACCOUNT_IAM_ROUTE=$(oc get routes -n msp-user-manager -l "app.kubernetes.io/component=account-iam" -o json | jq -r '.items[0].spec.host')
if [ -z "$ACCOUNT_IAM_ROUTE" ] || [ "$ACCOUNT_IAM_ROUTE" == "null" ]; then
  echo "Error: Could not find Account IAM route"
  exit 1
fi
echo "Account IAM route: $ACCOUNT_IAM_ROUTE"

echo "Fetching API key..."
APIKEY=$(oc get secret xpm-secret --namespace=sovereign-ui --output=jsonpath='{.data.settings\.json}' | base64 $BASE64_DECODE_FLAG | jq --raw-output '.xpm.accountServices.apikey')
if [ -z "$APIKEY" ] || [ "$APIKEY" == "null" ]; then
  echo "Error: Could not retrieve API key"
  exit 1
fi

echo "Obtaining authentication token..."
TOKEN=$(
  curl \
    --request "POST" \
    --url "https://$ACCOUNT_IAM_ROUTE/api/2.0/accounts/global_account/apikeys/token" \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --insecure \
    --silent \
    --data @- <<EOF
{
  "apikey": "$APIKEY"
}
EOF
)

TOKEN=$(echo $TOKEN | jq -r .token)
if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
  echo "Error: Failed to obtain authentication token"
  exit 1
fi

# Generate a secure random client secret
CLIENT_ID="vm-service-sso"
CLIENT_SECRET=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)

echo "Extracting ROOT CA certificate..."
IVIA_APPS_WRP_ROUTE=$(oc get routes -n sovereign-ivia-apps ivia-apps-wrp-route -o json | jq -r .spec.host)
if [ -z "$IVIA_APPS_WRP_ROUTE" ] || [ "$IVIA_APPS_WRP_ROUTE" == "null" ]; then
  echo "Error: Could not find IVIA apps route"
  exit 1
fi

# Extract the second certificate from the chain (root CA)
# - openssl s_client: connects and retrieves certificate chain
# - awk: finds and extracts the second certificate (count==2) from the chain
ROOT_CA=$(echo | openssl s_client -showcerts -servername $IVIA_APPS_WRP_ROUTE -connect $IVIA_APPS_WRP_ROUTE:443 2>/dev/null | awk '/-----BEGIN CERTIFICATE-----/{flag=1; cert=""} flag{cert=cert $0 ORS} /-----END CERTIFICATE-----/ && flag{if(++count==2){print cert; exit}}')
if [ -z "$ROOT_CA" ]; then
  echo "Error: Failed to extract ROOT CA certificate"
  exit 1
fi

# Use provided VM_CLUSTER_ROUTE or generate from managed cluster
if [ -n "$1" ]; then
  VM_CLUSTER_ROUTE="$1"
  
  # Sanitize console-openshift-console URLs to oauth-openshift format
  # Example: https://console-openshift-console.apps.cluster.example.com -> https://oauth-openshift.apps.cluster.example.com
  if [[ "$VM_CLUSTER_ROUTE" == *"console-openshift-console.apps."* ]]; then
    VM_CLUSTER_ROUTE=$(echo "$VM_CLUSTER_ROUTE" | sed 's|console-openshift-console\.apps\.|oauth-openshift.apps.|')
    echo "Sanitized console URL to OAuth format: $VM_CLUSTER_ROUTE"
  else
    echo "Using provided VM_CLUSTER_ROUTE: $VM_CLUSTER_ROUTE"
  fi
else
  echo "Generating VM_CLUSTER_ROUTE from managed cluster..."
  # Transform API URL to OAuth URL format
  # Example: https://api.cluster.example.com:6443 -> https://oauth-openshift.apps.cluster.example.com
  # sed regex: captures domain between 'api.' and ':6443', then reconstructs as oauth-openshift.apps.[domain]
  VM_CLUSTER_ROUTE=$(oc get managedcluster -l vm.sovereign.cloud.ibm.com/virtualization-enabled=true -o json | jq -r '.items[0].spec.managedClusterClientConfigs[0].url' | sed 's|https://api\.\([^:]*\):6443|https://oauth-openshift.apps.\1|')
  if [ -z "$VM_CLUSTER_ROUTE" ] || [ "$VM_CLUSTER_ROUTE" == "null" ]; then
    echo "Error: Could not determine VM cluster route. Please provide it as a parameter."
    exit 1
  fi
  echo "Generated VM_CLUSTER_ROUTE: $VM_CLUSTER_ROUTE"
fi
echo ""

echo "Checking if SSO client exists..."
CHECK_RESPONSE=$(curl -X 'GET' \
  https://$ACCOUNT_IAM_ROUTE/api/2.0/apps/clients/$CLIENT_ID \
  -H 'accept: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  --insecure \
  --silent \
  --write-out "\n%{http_code}")

echo $CHECK_RESPONSE

CHECK_HTTP_CODE=$(echo "$CHECK_RESPONSE" | tail -n1)

if [ "$CHECK_HTTP_CODE" -eq 200 ]; then
  echo "Existing SSO client found. Deleting..."
  DELETE_RESPONSE=$(curl -X 'DELETE' \
    https://$ACCOUNT_IAM_ROUTE/api/2.0/apps/clients/$CLIENT_ID \
    -H 'accept: application/json' \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    --insecure \
    --silent \
    --write-out "\n%{http_code}")
  
  DELETE_HTTP_CODE=$(echo "$DELETE_RESPONSE" | tail -n1)
  if [ "$DELETE_HTTP_CODE" -ge 200 ] 2>/dev/null && [ "$DELETE_HTTP_CODE" -lt 300 ] 2>/dev/null; then
    echo "✓ Successfully deleted existing SSO client"
  else
    echo "✗ Failed to delete existing SSO client (HTTP $DELETE_HTTP_CODE)"
    echo "$DELETE_RESPONSE" | head -n-1
    exit 1
  fi
elif [ "$CHECK_HTTP_CODE" -eq 400 ]; then
  echo "No existing SSO client found. Proceeding with creation..."
else
  echo "✗ Unexpected response when checking for existing client (HTTP $CHECK_HTTP_CODE)"
  echo "$CHECK_RESPONSE" | head -n-1
  exit 1
fi
echo ""

echo "Creating SSO client..."
# Use --write-out to capture HTTP status code for error checking
SSO_RESPONSE=$(curl -X 'POST' \
  https://$ACCOUNT_IAM_ROUTE/api/2.0/apps/clients \
  -H 'accept: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --insecure \
  --silent \
  --write-out "\n%{http_code}" \
  --data @- <<EOF
{
  "redirectUris": [
    "$VM_CLUSTER_ROUTE/oauth2callback/$CLIENT_ID"
  ],
  "clientName": "$CLIENT_ID",
  "grantTypes": [
    "authorization_code"
  ],
  "scopes": [
    "openid",
    "email"
  ],
  "clientId": "$CLIENT_ID",
  "clientSecret": "$CLIENT_SECRET"
}
EOF
)

# Extract HTTP status code from last line of response
HTTP_CODE=$(echo "$SSO_RESPONSE" | tail -n1)
if [ "$HTTP_CODE" -lt 200 ] 2>/dev/null || [ "$HTTP_CODE" -ge 300 ] 2>/dev/null; then
  echo "Error: Failed to create SSO client (HTTP $HTTP_CODE)"
  echo "$SSO_RESPONSE" | head -n-1  # Show response body without status code
  exit 1
fi

echo ""
echo "SSO client created successfully"
echo ""

# Base64 encode the values for the Kubernetes secret
CLIENT_ID_B64=$(echo -n "$CLIENT_ID" | base64)
CLIENT_SECRET_B64=$(echo -n "$CLIENT_SECRET" | base64)

# Create Kubernetes secret manifest
SECRET_FILE="openid-client-secret-vm-service.yaml"
cat > "$SECRET_FILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openid-client-secret-vm-service
  namespace: openshift-config
type: Opaque
data:
  clientId: $CLIENT_ID_B64
  clientSecret: $CLIENT_SECRET_B64
EOF

echo "Kubernetes secret manifest created: $SECRET_FILE"
echo ""

# Create ConfigMap manifest for ROOT CA
# Certificate content will be indented by 4 spaces for proper YAML formatting
CONFIGMAP_FILE="openid-ca-vm-service.yaml"
cat > "$CONFIGMAP_FILE" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: openid-ca-vm-service
  namespace: openshift-config
data:
  ca.crt: |
$(echo "$ROOT_CA" | sed 's/^/    /')
EOF

echo "Kubernetes ConfigMap manifest created: $CONFIGMAP_FILE"
echo ""

# Create OAuth patch file using JSON patch to append (not replace) identity provider
ISSUER_URL="https://$IVIA_APPS_WRP_ROUTE/iviaop/oauth2"
OAUTH_PATCH_FILE="oauth-cluster-patch.json"

cat > "$OAUTH_PATCH_FILE" <<EOF
[
  {
    "op": "add",
    "path": "/spec/identityProviders/-",
    "value": {
      "name": "$CLIENT_ID",
      "mappingMethod": "claim",
      "type": "OpenID",
      "openID": {
        "clientID": "$CLIENT_ID",
        "clientSecret": {
          "name": "openid-client-secret-vm-service"
        },
        "ca": {
          "name": "openid-ca-vm-service"
        },
        "issuer": "$ISSUER_URL",
        "claims": {
          "preferredUsername": ["preferred_username"],
          "name": ["name"],
          "email": ["email"]
        }
      }
    }
  }
]
EOF

echo "OAuth cluster patch file created: $OAUTH_PATCH_FILE"
echo ""
echo "=========================================="
echo "Configuration files created successfully!"
echo "=========================================="
echo ""
echo "Files generated:"
echo "  - $SECRET_FILE"
echo "  - $CONFIGMAP_FILE"
echo "  - $OAUTH_PATCH_FILE"
echo ""
echo "To apply the configuration, run:"
echo "  kubectl apply -f $SECRET_FILE"
echo "  kubectl apply -f $CONFIGMAP_FILE"
echo "  kubectl patch oauth cluster --type json --patch-file $OAUTH_PATCH_FILE"
echo ""
echo "Configuration details:"
echo "  Client ID: $CLIENT_ID"
echo "  Issuer URL: $ISSUER_URL"
echo "  Redirect URI: $VM_CLUSTER_ROUTE/oauth2callback/$CLIENT_ID"
echo ""
echo "Note: Client secret is stored securely in $SECRET_FILE"