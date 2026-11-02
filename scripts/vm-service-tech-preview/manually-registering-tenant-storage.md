# Manually Registering Tenant Storage

This guide explains how to manually create a tenant-specific StorageClass directly on the VM cluster for storage providers other than Ceph.

## Overview

Guest OS storage for VMs is provisioned through StorageClass resources on the VM cluster. When using a storage provider other than Ceph (i.e., Portworx), you must manually create the StorageClass on the VM cluster following the naming convention below.

The platform manages storage configuration per tenant on the Hub cluster. When a tenant's storage is registered with provider `portworx`, the platform expects a StorageClass named `{storageclass-name}-{tenant-id}` to exist on the target VM cluster. The platform does not create that StorageClass for you — this runbook explains how to create it.

**Important**: StorageClass resources must be applied directly to the VM cluster where OpenShift Virtualization is installed, not the Hub cluster.

## Prerequisites

- A CSI driver for your storage provider installed and running on the VM cluster
- Access to the VM cluster with permissions to create StorageClass resources
- The tenant ID for the tenant you are configuring
- `oc` CLI configured to access the VM cluster

## StorageClass Naming Convention

StorageClass names must follow this pattern:

```
{storageclass-name}-{tenant-id}
```

Where:
- `{storageclass-name}` — a descriptive name reflecting the provider and use case (e.g., `portworx-block`). This value is free-form but must comply with Kubernetes DNS subdomain naming rules: lowercase alphanumeric characters and hyphens only, starting and ending with an alphanumeric character, and no more than 253 characters in total (including the `-{tenant-id}` suffix).
- `{tenant-id}` — the tenant identifier assigned when the tenant's storage was registered with the platform

**Example**: if the tenant ID is `tenant-a` and the StorageClass name is `portworx-block`, the resulting StorageClass on the cluster must be named `portworx-block-tenant-a`.

Choose names that are unique and descriptive to avoid collisions across tenants and providers.

## Adding a StorageClass for a Tenant

### Step 1: Create the StorageClass YAML

Create a YAML file (e.g., `storageclass.yaml`) using the naming convention above:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: <storageclass-name>-<tenant-id>
provisioner: <csi-driver-name>
reclaimPolicy: Delete   # PVC deletion will permanently delete the underlying volume
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true   # Set to true if the CSI driver supports volume expansion
parameters:
  <param-key>: <param-value>
```

### Step 2: Apply to the VM Cluster

Apply the StorageClass manifest directly to the VM cluster:

```bash
oc apply -f storageclass.yaml --context <target-cluster>
```

## Configuration Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `metadata.name` | Must follow `{storageclass-name}-{tenant-id}` — case-sensitive | `portworx-block-tenant-a` |
| `provisioner` | CSI driver name for the storage provider | `pxd.portworx.com` |
| `reclaimPolicy` | Volume reclaim policy | `Delete` |
| `volumeBindingMode` | Use `WaitForFirstConsumer` where supported; `Immediate` for drivers that do not support topology-aware provisioning | `WaitForFirstConsumer` |
| `allowVolumeExpansion` | Set to `true` if the CSI driver supports online volume expansion; omit or set to `false` otherwise | `true` |
| `parameters` | Provider-specific CSI driver parameters | `repl: "2"` |

## Complete Example: Adding Portworx Storage for a Tenant

1. **Create `portworx-block-tenant-a.yaml`** (see the [Portworx provider example](#portworx) below for the full YAML).

2. **Apply to the VM cluster:**

```bash
oc apply -f portworx-block-tenant-a.yaml --context <target-cluster>
```

3. **Verify** — see the [Verification](#verification) section for detailed steps.

## Provider Examples

### Portworx

The tenant's storage must already be registered with the platform with provider `portworx` before you create the StorageClass. Contact your platform administrator if you are unsure whether registration has been completed for the tenant.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: portworx-block-tenant-a
provisioner: pxd.portworx.com
reclaimPolicy: Delete   # PVC deletion will permanently delete the underlying volume
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  repl: "2"
  io_profile: db_remote
```

Refer to your storage provider's CSI driver documentation for the required `provisioner` value and StorageClass parameters.

> **Note**: The platform supports `ceph` and `portworx` as storage providers. NFS is not a standalone supported provider. If your environment requires NFS-backed volumes, use Portworx as the provider and configure the appropriate volume type through the `parameters` field in the StorageClass.

## Verification

After applying the StorageClass resource:

1. **Confirm the StorageClass is present:**
```bash
oc get storageclass --context <target-cluster> | grep <tenant-id>
```

2. **Inspect the StorageClass details:**
```bash
oc describe storageclass <storageclass-name>-<tenant-id> --context <target-cluster>
```

3. **Check the CSI driver is healthy:**
```bash
oc get pods -n <csi-driver-namespace> --context <target-cluster>
```

## Platform Fallback (Testing Only)

When the platform is configured with a fallback mode and no storage has been registered for a tenant, the platform can provision VMs using a default platform-level StorageClass instead of a tenant-specific one.

**This mode must not be enabled in production.** It is intended for development environments where tenant storage is not yet configured. Refer to the platform operator documentation for configuration details.

## Troubleshooting

### DataVolume fails to provision

The StorageClass name may not match the expected convention.

- Verify the StorageClass name exactly follows `{storageclass-name}-{tenant-id}` (case-sensitive), where `{tenant-id}` is the tenant ID used when storage was registered with the platform
- Check that the StorageClass is present on the correct cluster:
```bash
oc get storageclass --context <target-cluster>
```

### StorageClass exists but DataVolume is stuck pending

The CSI driver may not be healthy or the `volumeBindingMode` may not be appropriate for the workload.

- Check the CSI driver pods: `oc get pods -n <csi-driver-namespace> --context <target-cluster>`
- Review the DataVolume events: `oc describe datavolume <name> -n <tenant-namespace> --context <target-cluster>`

### Permission issues

- Verify you have permissions to create StorageClass resources on the VM cluster
- Check RBAC: `oc auth can-i create storageclass --context <target-cluster>`

## Best Practices

1. **Follow the naming convention exactly** — the platform selects the StorageClass by the `{storageclass-name}-{tenant-id}` pattern; an incorrect name means the StorageClass will not be found
2. **Use descriptive provider prefixes** — choose names like `portworx-block` rather than generic names to avoid collisions across tenants and providers
3. **Set `volumeBindingMode: WaitForFirstConsumer`** where supported — this ensures volumes are provisioned in the same availability zone as the VM; use `Immediate` only when the CSI driver does not support topology-aware provisioning
4. **Apply to the correct cluster** — always target the specific VM cluster context using `--context <target-cluster>`
5. **Test new StorageClasses** in a development cluster before applying to production
6. **Confirm storage registration is complete** — before creating the StorageClass on the VM cluster, verify with your platform administrator that storage has been registered for the tenant and is in a ready state

## Related Resources

- [Kubernetes StorageClass documentation](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about-virt.html)
