# VM Service Tech Preview - Operations Runbook

## Table of Contents

1. [Overview](#overview)
2. [Operations](#operations)
3. [Monitoring](#monitoring)
4. [Troubleshooting](#troubleshooting)
5. [Maintenance](#maintenance)
6. [Security](#security)

---

## Overview

The VM Service Tech Preview enables users to provision and manage virtual machines on OpenShift clusters through a service broker interface. The service integrates with IBM Cloud's Sovereign Core platform and uses OpenShift Virtualization (CNV) for VM management.

### Key Features

- **Service Broker Integration**: OSB API-compliant broker for VM provisioning
- **Multi-Tenant Support**: Isolated namespaces per tenant with RBAC
- **ACM Policy Management**: Automated deployment to managed clusters
- **OpenShift Virtualization**: Leverages CNV for VM lifecycle management
- **Metering & Audit**: Usage tracking and audit logging
- **Self-Service Dashboard**: OpenShift console integration for VM management

### Components

- **VM Service Broker**: OSB API server handling provision/deprovision requests
- **VM Operator**: Kubernetes operator managing VMNamespaceRequest CRs
- **ACM Policies**: Automated configuration of shared VM clusters
- **OpenShift Virtualization**: VM runtime environment

---

## Operations

### Provisioning a VM Namespace

When a user provisions a VM service instance through the broker:

1. **Broker receives provision request** with tenant information
2. **VMNamespaceRequest CR is created** in the `vm-service-broker` namespace:
```yaml
apiVersion: sovereign.cloud.ibm.com/v1alpha1
kind: VMNamespaceRequest
metadata:
  name: <instance-id>
  namespace: vm-service-broker
spec:
  instanceId: <instance-id>
  serviceId: <service-id>
  planId: <plan-id>
  partNumber: <part-number>
  tenantName: <tenant-name>
  tenantNamespace: <tenant-namespace>
  tenantOwnerEmail: owner@example.com
  tenantOwnerEmails:
    - owner@example.com
  tenantAdminEmails:
    - admin@example.com
  tenantUserEmails:
    - user@example.com
  active: true
  enabled: true
```

3. **Operator reconciles the request** and immediately sets status to `Provisioned`:
```yaml
status:
  state: Provisioned
  dashboardUrl: https://console-openshift-console.apps.<domain>/k8s/ns/<tenant-namespace>/catalog
  lastOperation:
    type: create
    state: succeeded
    description: VMNamespaceRequest created successfully
  lastActive: <timestamp>
```

4. **Operator fetches IAM data** on each reconcile loop (every 5 minutes) and syncs `tenantOwnerEmails`, `tenantAdminEmails`, and `tenantUserEmails` from the IAM service instance roles (`ServiceOwner`, `ServiceAdmin`, `ServiceUser`).

### Viewing VM Namespace Requests

```bash
# List all namespace requests
oc get vmnamespacerequest -n vm-service-broker

# Get detailed information
oc describe vmnamespacerequest <instance-id> -n vm-service-broker

# Check status
oc get vmnsr -n vm-service-broker -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.state}{"\t"}{.spec.tenantNamespace}{"\n"}{end}'
```

### Deprovisioning a VM Namespace

When a user deprovisions their VM service instance:

1. **Broker receives deprovision request**
2. **Broker sets `spec.active: false` and `spec.enabled: false`** on the VMNamespaceRequest CR
3. **ACM policy detects the change** and removes resources from the shared cluster:
   - Deletes tenant namespace RoleBindings
   - Deletes tenant namespace
4. **Broker deletes the VMNamespaceRequest CR**
5. **Operator enters grace period** — the finalizer blocks CR deletion until the configured grace period elapses
6. **Finalizer is removed** after the grace period and the CR is fully deleted

### Managing Guest OS Images

See [Adding Guest OS Images](./adding-guest-os-images.md) for detailed instructions on adding additional operating system images to the shared VM cluster.

Quick reference:
```bash
# List available images
oc get dataimportcron -n openshift-virtualization-os-images

# Check image import status
oc get datasource -n openshift-virtualization-os-images

# View import progress
oc get datavolume -n openshift-virtualization-os-images
```

---

## Monitoring

### Health Checks

The broker exposes health endpoints:

```bash
# Liveness probe
curl -k https://<broker-service>:7331/liveness

# Readiness probe
curl -k https://<broker-service>:7331/readiness
```

### Metrics

Monitor key metrics:

1. **CNV Metrics**:
   - VM count per namespace
   - Resource utilization
   - Image import status

### Logs

```bash
# Broker logs
oc logs -n vm-service-broker deployment/vm-service-broker-deployment -f

# Operator logs
oc logs -n vm-service-broker deployment/vm-service-broker-operator -f

# CNV operator logs (on shared cluster)
oc logs -n openshift-cnv deployment/virt-operator -f
```

### Audit Logging

The operator maintains audit logs for:
- VMNamespaceRequest creation/updates/deletion
- Tenant provisioning events
- Metering submissions

Access audit logs:
```bash
oc logs -n vm-service-broker deployment/vm-service-broker-operator | grep "audit"
```

---

## Troubleshooting

### Common Issues

#### 1. Broker Pod Not Starting

**Symptoms**: Broker pod in CrashLoopBackOff or Error state

**Diagnosis**:
```bash
oc get pods -n vm-service-broker
oc describe pod <broker-pod> -n vm-service-broker
oc logs <broker-pod> -n vm-service-broker
```

**Common Causes**:
- Missing or invalid TLS certificates
- IAM authentication configuration issues
- ConfigMap misconfiguration

**Resolution**:
```bash
# Check certificates
oc get secret -n vm-service-broker | grep tls

# Verify ConfigMap
oc get configmap vm-service-broker-config-map -n vm-service-broker -o yaml

# Check service account
oc get sa vm-service-broker-service-account -n vm-service-broker
```

#### 2. ACM Policy Not Compliant

**Symptoms**: Policy shows as NonCompliant in ACM

**Diagnosis**:
```bash
# Check policy status
oc get policy -n vm-service-broker

# View policy details
oc describe policy vms-cnv-installation-policy -n vm-service-broker

# Check placement
oc get placement -n vm-service-broker
oc get placementdecision -n vm-service-broker
```

**Common Causes**:
- Managed cluster not labeled correctly
- CNV operator installation failed
- Network connectivity issues

**Resolution**:
```bash
# Verify cluster label
oc get managedcluster <cluster-name> --show-labels

# Check CNV on managed cluster
oc get csv -n openshift-cnv
oc get hyperconverged -n openshift-cnv

# Force policy remediation
oc patch policy vms-cnv-installation-policy -n vm-service-broker \
  --type=merge -p '{"spec":{"remediationAction":"enforce"}}'
```

#### 3. CR Stuck in Pending or Failed State

**Symptoms**: VMNamespaceRequest not reaching `Provisioned` state

**Diagnosis**:
```bash
# Check VMNamespaceRequest status
oc get vmnsr <instance-id> -n vm-service-broker -o yaml

# Check operator logs
oc logs -n vm-service-broker deployment/vm-service-broker-operator
```

**Common Causes**:
- Operator pod not running
- IAM cache not populated (instanceId missing or IAM unreachable)
- Status update failed due to RBAC issue

**Resolution**:
```bash
# Verify operator is running
oc get pods -n vm-service-broker -l app=vm-service-broker-operator

# Check for RBAC issues on status subresource
oc auth can-i update vmnamespacerequests/status --as=system:serviceaccount:vm-service-broker:vm-service-broker-operator-sa -n vm-service-broker
```

#### 4. VM Image Import Failing

**Symptoms**: DataImportCron not creating DataVolumes

**Diagnosis**:
```bash
# Check DataImportCron status
oc get dataimportcron -n openshift-virtualization-os-images
oc describe dataimportcron <name> -n openshift-virtualization-os-images

# Check CDI logs
oc logs -n openshift-cnv deployment/cdi-deployment
```

**Common Causes**:
- Registry authentication issues
- Network connectivity to registry
- Insufficient storage

**Resolution**:
```bash
# Verify registry access
oc get secret -n openshift-virtualization-os-images

# Check storage
oc get pv
oc get storageclass

# Test image pull manually
oc run test-pull --image=<registry-url> --rm -it -- /bin/sh
```

#### 5. IAM Token Expiry (401 Auth Errors)

**Symptoms**: Metering stops working after the operator has been running for an extended period; operator logs show repeated 401 errors:

```
"failed to fetch IAM data from cache" error="no cached data for service instance …"
"failed to retrieve instance info for metering" error="request failed with status 401: Auth validation error …"
Warning: Failed to refresh cache for service instance …: failed to fetch users: API returned status 401 …
```

**Cause**: The operator fetches an IAM token once at startup (`NewCache` → `initializeToken`) and reuses it indefinitely. Once the token expires all IAM API calls fail.

**Workaround**: Apply a CronJob that restarts the operator every 30 minutes to obtain a fresh token:

```bash
# Run against the hub cluster
oc login <hub-cluster>
./scripts/vm-service-tech-preview/apply-operator-restart-cronjob.sh
```

The script automatically derives the image registry from the running operator Deployment and applies the required RBAC and CronJob. The rolling update strategy (`maxUnavailable: 0`) on the operator Deployment ensures no downtime during the restart.

After each restart the operator logs should confirm successful token initialisation:
```
{"level":"info","message":"Account IAM cache initialized"}
```

**Permanent fix**: Automatic re-authentication on 401 is implemented in `internal/iam/cache.go` and `internal/iam/service.go` and will ship in the next release. Once deployed, remove the workaround:

```bash
oc delete cronjob vm-service-broker-operator-token-refresh -n vm-service-broker
oc delete rolebinding operator-restart-rolebinding -n vm-service-broker
oc delete role operator-restart-role -n vm-service-broker
```

#### 6. Metering Not Working

**Symptoms**: No metering data being submitted

**Diagnosis**:
```bash
# Check operator logs for metering
oc logs -n vm-service-broker deployment/vm-service-broker-operator | grep metering

# Verify metering configuration
oc get configmap vm-service-broker-operator-config-map -n vm-service-broker -o yaml | grep METERING
```

**Resolution**:
```bash
# Check if metering is enabled
# METERING_ENABLED should be "true"
# METERING_DRY_RUN should be "false" for production

# Verify Prometheus connectivity
oc get route -n open-cluster-management-observability

# Check metering endpoint
curl -k <METERING_BASE_URL>/health
```

---

## Maintenance

### Backup and Recovery

#### Backup VMNamespaceRequest CRs

```bash
# Export all VMNamespaceRequests
oc get vmnsr -n vm-service-broker -o yaml > vmnsr-backup.yaml

# Backup specific instance
oc get vmnsr <instance-id> -n vm-service-broker -o yaml > vmnsr-<instance-id>.yaml
```

#### Restore VMNamespaceRequest CRs

```bash
# Restore from backup
oc apply -f vmnsr-backup.yaml
```

### Scaling

#### Scale Broker Replicas

```bash
oc scale deployment vm-service-broker-deployment -n vm-service-broker --replicas=3
```

### Cleanup

#### Remove a Specific Instance

Deprovisioning should be triggered through the service broker to ensure `spec.active` and `spec.enabled` are set to `false` before deletion, allowing ACM to clean up the tenant namespace on the shared cluster first.

If the CR must be removed directly (e.g. the broker is unavailable):

```bash
# Patch active and enabled to false to signal ACM to clean up shared cluster resources
oc patch vmnsr <instance-id> -n vm-service-broker --type=merge \
  -p '{"spec":{"active":false,"enabled":false}}'

# Allow time for ACM to remove the tenant namespace, then delete the CR
oc delete vmnsr <instance-id> -n vm-service-broker

# Verify namespace deletion on shared cluster
oc get namespace <tenant-namespace>
```

---

## Security

### Authentication

The broker uses IAM-based authentication:
- JWT tokens validated against JWKS endpoint
- Service broker credentials stored in Kubernetes Secret
- mTLS support available (optional)

### Authorization

RBAC is enforced at multiple levels:

1. **Hub Cluster**:
   - Service account for broker and operator
   - Limited permissions to manage VMNamespaceRequest CRs

2. **Shared VM Cluster**:
   - Tenant owners get `vm-admin` role in their namespace
   - `view` role for namespace visibility
   - No cluster-admin access

### Network Security

- Broker exposes HTTPS endpoint only (port 7331)
- TLS certificates managed by cert-manager
- Network policies restrict pod-to-pod communication

### Secrets Management

```bash
# List secrets
oc get secrets -n vm-service-broker

# Key secrets:
# - service-broker-secret: IAM credentials
# - vm-service-broker-tls: TLS certificates
# - vm-service-broker-operator-token: Operator SA token
```

### Audit Trail

All operations are logged:
- VMNamespaceRequest lifecycle events
- Broker API requests
- Operator reconciliation actions
- Metering submissions

---

## Appendix

### API Reference

#### VMNamespaceRequest CRD

**Spec Fields**:
- `spec.instanceId`: Unique identifier for the service instance (used for IAM and metering lookups)
- `spec.serviceId`: Service identifier
- `spec.planId`: Plan identifier
- `spec.partNumber`: Part number for metering
- `spec.tenantName`: Tenant identifier
- `spec.tenantNamespace`: Namespace name on the shared VM cluster
- `spec.tenantOwnerEmail`: Primary owner email (auto-populated from `tenantOwnerEmails[0]` if empty)
- `spec.tenantOwnerEmails`: List of owner emails (synced from IAM `ServiceOwner` role)
- `spec.tenantAdminEmails`: List of admin emails (synced from IAM `ServiceAdmin` role)
- `spec.tenantUserEmails`: List of user emails (synced from IAM `ServiceUser` role)
- `spec.active`: Whether the namespace request is active
- `spec.enabled`: Whether the namespace is enabled

**Status Fields**:
- `status.state`: Current state — `Pending`, `Provisioning`, `Provisioned`, `Updating`, `Deprovisioning`, `Failed`
- `status.dashboardUrl`: OpenShift console URL (`/k8s/ns/<tenantNamespace>/catalog`)
- `status.lastActive`: Timestamp of last reconcile activity
- `status.lastOperation.type`: Operation type — `create`, `update`, `delete`
- `status.lastOperation.state`: Operation state — `in progress`, `succeeded`, `failed`
- `status.lastOperation.description`: Human-readable description
- `status.conditions`: Standard Kubernetes conditions array

### Useful Commands

```bash
# Quick status check
oc get vmnsr -n vm-service-broker -o custom-columns=NAME:.metadata.name,STATE:.status.state,TENANT:.spec.tenantName,NAMESPACE:.spec.tenantNamespace,ACTIVE:.spec.active

# Watch namespace requests
oc get vmnsr -n vm-service-broker -w

# Get all VM-related resources
oc get all -n vm-service-broker

# Check ACM policy compliance
oc get policy -n vm-service-broker -o custom-columns=NAME:.metadata.name,COMPLIANCE:.status.compliant

# List tenant namespaces on shared cluster
oc get namespace -l app.kubernetes.io/managed-by=vm-service-broker
```

### Related Documentation

- [Adding Guest OS Images](./adding-guest-os-images.md)
- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about-virt.html)
- [ACM Policy Documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes)

---

*Last Updated: 2026-06-17*
*Version: 0.1.0*