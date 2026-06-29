#!/bin/bash
# apply-operator-restart-cronjob.sh
#
# Workaround for vm-service-broker-operator IAM token expiry (401 auth errors).
#
# The operator fetches an IAM token once at startup and never refreshes it.
# When the token expires, metering stops working and 401 errors are logged.
# This script applies a CronJob that restarts the operator every 30 minutes,
# keeping the token fresh until the permanent fix ships.
#
# The image registry is derived automatically from the operator Deployment
# already running in vm-service-broker — no manual configuration required.
#
# Usage:
#   oc login <hub-cluster>
#   ./scripts/vm-service-tech-preview/apply-operator-restart-cronjob.sh
#
# Teardown (after permanent fix is deployed):
#   oc delete cronjob vm-service-broker-operator-token-refresh -n vm-service-broker
#   oc delete rolebinding operator-restart-rolebinding -n vm-service-broker
#   oc delete role operator-restart-role -n vm-service-broker

set -e

NAMESPACE="vm-service-broker"
OPERATOR_DEPLOYMENT="vm-service-broker-operator"
SERVICE_ACCOUNT="vm-service-broker-service-account"

echo "=== Operator Restart CronJob — Setup ==="
echo ""

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to a cluster. Run 'oc login ...' first."
  exit 1
fi

echo "Logged in as: $(oc whoami)"
echo "Server:       $(oc whoami --show-server)"
echo ""

echo "Checking for operator Deployment '$OPERATOR_DEPLOYMENT' in $NAMESPACE..."
if ! oc get deployment "$OPERATOR_DEPLOYMENT" -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: Deployment $OPERATOR_DEPLOYMENT not found in $NAMESPACE."
  exit 1
fi
echo "  Found."
echo ""

# ---------------------------------------------------------------------------
# Derive the image registry from the running operator Deployment.
# The operator image is: <registry.imagesRepo><operatorImage>
# e.g. registry-quay.example.com/sovcloud/automation-saas-platform-dev/vm-service-broker-operator:tag
# The ose-cli image path is: <registry.imagesRepo>/openshift4/ose-cli:latest
#
# We extract the registry prefix by stripping everything from
# /automation-saas-platform* onward (the known image path prefix in values.yaml).
# ---------------------------------------------------------------------------
OPERATOR_IMAGE=$(oc get deployment "$OPERATOR_DEPLOYMENT" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')

echo "Detected operator image: $OPERATOR_IMAGE"

# Strip from /automation-saas-platform onward to get the images repo prefix
IMAGES_REPO=$(echo "$OPERATOR_IMAGE" | sed 's|/automation-saas-platform.*||')

if [ -z "$IMAGES_REPO" ]; then
  echo "ERROR: Could not derive image registry from operator image."
  echo "       Expected image path to contain '/automation-saas-platform'."
  exit 1
fi

OSE_CLI_IMAGE="${IMAGES_REPO}/openshift4/ose-cli:latest"
echo "Derived ose-cli image:   $OSE_CLI_IMAGE"
echo ""

# ---------------------------------------------------------------------------
# Apply RBAC
# ---------------------------------------------------------------------------
echo "--- Applying RBAC ---"

oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: operator-restart-role
  namespace: $NAMESPACE
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: operator-restart-rolebinding
  namespace: $NAMESPACE
subjects:
  - kind: ServiceAccount
    name: $SERVICE_ACCOUNT
    namespace: $NAMESPACE
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: operator-restart-role
EOF

echo ""

# ---------------------------------------------------------------------------
# Apply CronJob
# ---------------------------------------------------------------------------
echo "--- Applying CronJob ---"

oc apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: vm-service-broker-operator-token-refresh
  namespace: $NAMESPACE
spec:
  schedule: "*/30 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app: vm-service-broker-operator
        spec:
          serviceAccountName: $SERVICE_ACCOUNT
          restartPolicy: Never
          containers:
            - name: restart
              image: $OSE_CLI_IMAGE
              command:
                - oc
                - rollout
                - restart
                - deployment/$OPERATOR_DEPLOYMENT
                - -n
                - $NAMESPACE
              resources:
                requests:
                  cpu: 10m
                  memory: 32Mi
                limits:
                  cpu: 50m
                  memory: 64Mi
              securityContext:
                allowPrivilegeEscalation: false
                runAsNonRoot: true
                capabilities:
                  drop: ["ALL"]
EOF

echo ""
echo "=== Done. ==="
echo ""
echo "Verify with:"
echo "  oc get cronjob vm-service-broker-operator-token-refresh -n $NAMESPACE"
echo "  oc get jobs -n $NAMESPACE"
echo ""
echo "To remove after the permanent fix ships:"
echo "  oc delete cronjob vm-service-broker-operator-token-refresh -n $NAMESPACE"
echo "  oc delete rolebinding operator-restart-rolebinding -n $NAMESPACE"
echo "  oc delete role operator-restart-role -n $NAMESPACE"
