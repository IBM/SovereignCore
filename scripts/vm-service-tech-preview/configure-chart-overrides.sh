#!/bin/bash
set -e

echo "Fetching cluster configuration..."

# Get Account IAM route for app domain
ACCOUNT_IAM_ROUTE=$(oc get routes -n msp-user-manager -l "app.kubernetes.io/component=account-iam" -o json | jq -r '.items[0].spec.host')
if [ -z "$ACCOUNT_IAM_ROUTE" ] || [ "$ACCOUNT_IAM_ROUTE" == "null" ]; then
  echo "Error: Could not find Account IAM route"
  exit 1
fi
echo "Account IAM route (app domain): $ACCOUNT_IAM_ROUTE"

# Get Quay registry route
QUAY_ROUTE=$(oc get route -n quay-enterprise registry-quay -o json | jq -r '.spec.host')
if [ -z "$QUAY_ROUTE" ] || [ "$QUAY_ROUTE" == "null" ]; then
  echo "Error: Could not find Quay registry route"
  exit 1
fi
echo "Quay registry: $QUAY_ROUTE"

# Use provided VM_CLUSTER_ROUTE or generate from managed cluster
if [ -n "$1" ]; then
  VM_CLUSTER_ROUTE="$1"
  echo "Using provided VM_CLUSTER_ROUTE: $VM_CLUSTER_ROUTE"
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

# Construct registry images repo
IMAGES_REPO="$QUAY_ROUTE/sovcloud"
echo "Images repo: $IMAGES_REPO"

# Extract domain from VM cluster route for sharedCluster.url
# Example: https://oauth-openshift.apps.cluster.example.com -> apps.cluster.example.com
SHARED_CLUSTER_DOMAIN=$(echo "$VM_CLUSTER_ROUTE" | sed 's|https://[^.]*\.||')
SHARED_CLUSTER_URL="https://console-openshift-console.$SHARED_CLUSTER_DOMAIN"
echo "Shared cluster URL: $SHARED_CLUSTER_URL"

# VM sample image path (without registry prefix)
VM_SAMPLE_IMAGE="/cp/sovereign-cloud-platform/automation-saas-platform-dev/containerdisks/fedora:43-1.6"
echo "VM sample image: $VM_SAMPLE_IMAGE"
echo ""

# Generate values override file
VALUES_OVERRIDE_FILE="values-override.yaml"
cat > "$VALUES_OVERRIDE_FILE" <<EOF
# Generated values override file
# Generated on: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

cluster:
  appdomain: $ACCOUNT_IAM_ROUTE

registry:
  imagesRepo: $IMAGES_REPO

sharedCluster:
  url: $SHARED_CLUSTER_URL
  vmImageRepo: $IMAGES_REPO
  vmSampleImage: $VM_SAMPLE_IMAGE
EOF

echo "=========================================="
echo "Values override file created successfully!"
echo "=========================================="
echo ""
echo "File: $VALUES_OVERRIDE_FILE"
echo ""
echo "Configuration values:"
echo "  cluster.appdomain: $ACCOUNT_IAM_ROUTE"
echo "  registry.imagesRepo: $IMAGES_REPO"
echo "  sharedCluster.url: $SHARED_CLUSTER_URL"
echo "  sharedCluster.vmImageRepo: $IMAGES_REPO"
echo "  sharedCluster.vmSampleImage: $VM_SAMPLE_IMAGE"
echo ""
echo "To use this file with Helm, run:"
echo "  helm install vm-service-broker ./charts/vm-service-broker -f $VALUES_OVERRIDE_FILE"
echo ""
echo "Or to upgrade an existing release:"
echo "  helm upgrade vm-service-broker ./charts/vm-service-broker -f $VALUES_OVERRIDE_FILE"