#!/bin/bash
# configure-vm-oauth.sh
#
# Workaround for VM SSO not being automatically configured on bare metal clusters
# where the internal OpenShift image registry is unavailable and the ACM-managed
# Jobs (oauth-ca-decode, configure-vm-oauth) cannot pull their container image.
#
# This script replicates what those two Jobs do, run directly from the landing zone
# against the tenant cluster.
#
# Prerequisites (validated below):
#   - oc logged in to the tenant cluster
#   - ConfigMap openid-ca-vm-service-encoded exists in openshift-config  (mirrored by ACM)
#   - Secret openid-client-secret-vm-service exists in openshift-config  (mirrored by ACM)

set -e

NAMESPACE="openshift-config"

echo "=== Configure VM OAuth ==="
echo ""

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
echo "--- Checking prerequisites ---"

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to a cluster. Run 'oc login ...' first."
  exit 1
fi

echo "Logged in as: $(oc whoami)"
echo "Server:       $(oc whoami --show-server)"
echo ""

echo "Checking for ACM-mirrored ConfigMap 'openid-ca-vm-service-encoded' in $NAMESPACE..."
if ! oc get configmap openid-ca-vm-service-encoded -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: ConfigMap openid-ca-vm-service-encoded not found in $NAMESPACE."
  echo "       ACM has not yet mirrored it from the hub. Check the oauth-ca-mirror-encoded policy."
  exit 1
fi
echo "  Found."

echo "Checking for ACM-mirrored Secret 'openid-client-secret-vm-service' in $NAMESPACE..."
if ! oc get secret openid-client-secret-vm-service -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: Secret openid-client-secret-vm-service not found in $NAMESPACE."
  echo "       ACM has not yet mirrored it from the hub. Check the oauth-secret-mirror policy."
  exit 1
fi
echo "  Found."
echo ""

# ---------------------------------------------------------------------------
# Step 1: oauth-ca-decode Job logic
# Decode the base64-encoded CA cert and create the openid-ca-vm-service ConfigMap
# ---------------------------------------------------------------------------
echo "--- Step 1: Decoding CA certificate (oauth-ca-decode) ---"

CA_CERT=$(oc get configmap openid-ca-vm-service-encoded -n "$NAMESPACE" \
  -o jsonpath='{.binaryData.ca\.crt}' | base64 -d)

if [ -z "$CA_CERT" ]; then
  echo "ERROR: ca.crt in openid-ca-vm-service-encoded is empty."
  exit 1
fi

cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: openid-ca-vm-service
  namespace: $NAMESPACE
data:
  ca.crt: |
$(echo "$CA_CERT" | sed 's/^/    /')
EOF

echo "  ConfigMap openid-ca-vm-service created/updated."
echo ""

# ---------------------------------------------------------------------------
# Step 2: configure-vm-oauth Job logic
# Patch the cluster OAuth CR with the vm-service-sso identity provider
# ---------------------------------------------------------------------------
echo "--- Step 2: Configuring OAuth identity provider (configure-vm-oauth) ---"

ISSUER=$(oc get secret openid-client-secret-vm-service -n "$NAMESPACE" \
  -o jsonpath='{.data.issuer}' | base64 -d)

if [ -z "$ISSUER" ]; then
  echo "ERROR: issuer field in openid-client-secret-vm-service is empty."
  exit 1
fi

echo "  Issuer: $ISSUER"

IDENTITY_PROVIDER=$(cat <<'EOF'
{
  "name": "vm-service-sso",
  "mappingMethod": "claim",
  "type": "OpenID",
  "openID": {
    "clientID": "vm-service-sso",
    "clientSecret": {
      "name": "openid-client-secret-vm-service"
    },
    "ca": {
      "name": "openid-ca-vm-service"
    },
    "issuer": "ISSUER_PLACEHOLDER",
    "claims": {
      "preferredUsername": ["preferred_username"],
      "name": ["name"],
      "email": ["email"]
    }
  }
}
EOF
)

IDENTITY_PROVIDER=$(echo "$IDENTITY_PROVIDER" | sed "s|ISSUER_PLACEHOLDER|$ISSUER|g")

if oc get oauth cluster -o jsonpath='{.spec.identityProviders}' 2>/dev/null | grep -q '\['; then
  if oc get oauth cluster -o json | jq -e '.spec.identityProviders[] | select(.name=="vm-service-sso")' > /dev/null 2>&1; then
    echo "  Identity provider vm-service-sso already exists, updating..."
    INDEX=$(oc get oauth cluster -o json | jq '.spec.identityProviders | to_entries[] | select(.value.name=="vm-service-sso") | .key')
    oc patch oauth cluster --type json -p "[{\"op\": \"replace\", \"path\": \"/spec/identityProviders/$INDEX\", \"value\": $IDENTITY_PROVIDER}]"
  else
    echo "  Adding vm-service-sso to existing identity providers..."
    oc patch oauth cluster --type json -p "[{\"op\": \"add\", \"path\": \"/spec/identityProviders/-\", \"value\": $IDENTITY_PROVIDER}]"
  fi
else
  echo "  No existing identity providers, creating array..."
  oc patch oauth cluster --type merge -p "{\"spec\": {\"identityProviders\": [$IDENTITY_PROVIDER]}}"
fi

echo ""
echo "=== Done. OAuth configuration applied successfully. ==="