# Configuring Platform Storage Fallback

## Overview

By default, VM as a Service (VMaaS) provisions virtual machines using tenant-dedicated Ceph RBD storage delivered through `sov-core-storage`. In environments where `sov-core-storage` is not deployed or tenant storage is not yet registered, VM provisioning requests fail with `TenantStorageNotConfigured`.

Platform Storage Fallback allows the VM service broker operator to fall back to a shared platform StorageClass instead of requiring tenant-specific storage registration.

## Prerequisites

Before enabling platform storage fallback, verify the following conditions:

- The configured StorageClass must exist on every managed cluster where platform fallback may be used. If the StorageClass does not exist on the target managed cluster, VM provisioning will fail during DataVolume creation.
- The StorageClass must support the volume mode and access mode required for VM disks (ReadWriteOnce, Block or Filesystem mode).
- The platform storage pool has sufficient capacity and quota to host VM disks for tenants using fallback.
- Operational and security policies permit using shared platform storage rather than tenant-dedicated storage pools in the target environment.

## Target Audience and Scope

This configuration is managed by Platform Administrators and MSP Operators on the hub cluster. Tenant users and LOB Admins do not configure this setting from the Tenant UI.

The setting applies cluster-wide through the singleton `VMServiceBrokerConfig` Custom Resource (`vmbcfg`) in the `vm-service-broker` namespace on the hub cluster.

## Behavior and Trigger Conditions

### Default Mode (`allowPlatformFallback: false`)

In production environments, `allowPlatformFallback` should remain `false`. If a tenant attempts to provision a VM without a valid `StorageRegistration` in `sov-core-storage`, the VM request enters the `Failed` phase with the reason `TenantStorageNotConfigured`.

### Fallback Mode (`allowPlatformFallback: true`)

When enabled, the operator falls back to the StorageClass configured under `spec.vminstance.storageClass` only under specific conditions:

- Fallback is triggered only when `sov-core-storage` successfully responds that no `StorageRegistration` exists for the tenant (`ErrStorageRegistrationNotFound`).
- Timeouts, authentication failures (HTTP 401), network errors, and unexpected server errors (HTTP 5xx) do not trigger fallback. These are treated as transient errors and retried.
- If storage delivery was already requested or confirmed, fallback is not evaluated.

### Impact on Existing VMs

Changing this setting does not migrate or modify storage used by existing VMs. The setting is evaluated only when processing new VM provisioning requests.

If fallback is later disabled (`allowPlatformFallback: false`), existing VMs that were provisioned using the platform StorageClass remain operational and their storage is not affected.

## Configuration Methods

### Option 1: Direct Runtime Configuration via CR

`allowPlatformFallback` is hot-reloadable. You can enable or disable fallback at runtime without restarting the operator pod.

The change remains in the Custom Resource across operator restarts, but may be reverted by GitOps synchronization or replaced during an upgrade if not reflected in the Git repository.

To enable fallback on the hub cluster:

```bash
oc patch vmbcfg vm-service-broker -n vm-service-broker \
  --type=merge -p '{"spec":{"storageClient":{"allowPlatformFallback":true}}}'
```

To disable fallback and enforce tenant storage:

```bash
oc patch vmbcfg vm-service-broker -n vm-service-broker \
  --type=merge -p '{"spec":{"storageClient":{"allowPlatformFallback":false}}}'
```

Alternatively, edit the `VMServiceBrokerConfig` resource directly:

```bash
oc edit vmservicebrokerconfig vm-service-broker -n vm-service-broker
```

Under `spec`, update the `storageClient` and `vminstance` sections:

```yaml
apiVersion: vmaas.ibm.com/v1alpha1
kind: VMServiceBrokerConfig
metadata:
  name: vm-service-broker
  namespace: vm-service-broker
spec:
  vminstance:
    storageClass: "ocs-external-storagecluster-ceph-rbd"
  storageClient:
    allowPlatformFallback: true
```

### Option 2: Persistent Configuration via GitOps / Helm Values

To make the setting permanent across cluster upgrades and ArgoCD sync cycles, configure the setting in the GitOps values override file (or ArgoCD Application parameters) and sync the application. Note that boolean values should be specified as YAML booleans:

```yaml
vminstance:
  storageClass: "ocs-external-storagecluster-ceph-rbd"

storageClient:
  allowPlatformFallback: true
```

After updating the GitOps repository, sync the ArgoCD Application corresponding to the VM service broker:

```bash
oc patch application vm-service-broker -n openshift-gitops --type merge \
  -p '{"operation":{"sync":{"prune":true,"syncStrategy":{"hook":{"force":true}}}}}'
```

## Verifying Configuration

### Step 1: Verify Custom Resource Values

Verify that the expected values are present in the `VMServiceBrokerConfig` CR on the hub cluster:

```bash
# Check allowPlatformFallback setting
oc get vmbcfg vm-service-broker -n vm-service-broker \
  -o jsonpath='{.spec.storageClient.allowPlatformFallback}{"\n"}'

# Check the configured platform StorageClass
oc get vmbcfg vm-service-broker -n vm-service-broker \
  -o jsonpath='{.spec.vminstance.storageClass}{"\n"}'
```

### Step 2: Verify ConfigLoaded Condition

Confirm that the operator successfully reloaded the configuration:

```bash
oc get vmbcfg vm-service-broker -n vm-service-broker \
  -o jsonpath='{.status.conditions[?(@.type=="ConfigLoaded")]}' | jq .
```

The condition should display `status: "True"` and `reason: "Loaded"`.

### Step 3: Verify Operator Logs During Provisioning

When a new VM is provisioned under fallback mode for a tenant without `StorageRegistration`, the operator logs will confirm fallback activation:

```
delivery request: no StorageRegistration found but allowPlatformFallback=true; falling back to platform StorageClass
```
