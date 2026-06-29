# Adding Additional Guest OS Images for VMs

This guide explains how to add additional guest operating system images for virtual machines by applying DataImportCron resources directly to the shared VM cluster.

## Overview

Guest OS images are managed through Kubernetes DataImportCron resources that automatically import and update container disk images from a registry. These images are stored in the `openshift-virtualization-os-images` namespace and made available to VMs through managed data sources.

**Important**: These resources should be applied directly to the shared VM cluster where OpenShift Virtualization is installed.

## Prerequisites

- OpenShift Virtualization (CNV) installed and configured on the shared VM cluster
- Access to a container registry with VM disk images
- Appropriate RBAC permissions to create DataImportCron resources in the cluster
- `oc` CLI configured to access the shared VM cluster

## Adding a New Guest OS Image

### Step 1: Prepare the Container Disk Image

Ensure your guest OS image is available as a container disk in your registry. The image should be in a format compatible with KubeVirt (e.g., qcow2 wrapped in a container).

Example registry URL format:
```
docker://registry.example.com/path/to/containerdisks/ubuntu:22.04
```

### Step 2: Create the DataImportCron YAML

Create a YAML file (e.g., `ubuntu-dataimportcron.yaml`) with your DataImportCron configuration:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataImportCron
metadata:
  name: ubuntu-image-cron-22-04
  namespace: openshift-virtualization-os-images
spec:
  garbageCollect: Outdated
  managedDataSource: ubuntu-22-04
  schedule: "0 2 * * *"
  template:
    metadata: {}
    spec:
      source:
        registry:
          pullMethod: node
          url: 'docker://registry.example.com/path/to/containerdisks/ubuntu:22.04'
      storage:
        resources:
          requests:
            storage: 30Gi
    status: {}
```

### Step 3: Apply to the Shared VM Cluster

Apply the DataImportCron resource directly to the shared VM cluster:

```bash
oc apply -f ubuntu-dataimportcron.yaml
```

## Configuration Parameters

### DataImportCron Specification

| Parameter | Description | Example |
|-----------|-------------|---------|
| `metadata.name` | Unique name for the DataImportCron resource | `ubuntu-image-cron-22-04` |
| `metadata.namespace` | Must be `openshift-virtualization-os-images` | `openshift-virtualization-os-images` |
| `spec.garbageCollect` | Cleanup policy for old images | `Outdated` |
| `spec.managedDataSource` | Name of the managed data source created | `ubuntu-22-04` |
| `spec.schedule` | Cron schedule for image updates | `"0 2 * * *"` (daily at 2 AM) |
| `spec.template.spec.source.registry.url` | Container registry URL for the disk image | `docker://registry.example.com/image:tag` |
| `spec.template.spec.storage.resources.requests.storage` | Storage size for the image | `30Gi` |

### Schedule Configuration

The `schedule` field uses standard cron syntax:
- `"*/5 * * * *"` - Every 5 minutes (development/testing)
- `"0 2 * * *"` - Daily at 2 AM (production)
- `"0 2 * * 0"` - Weekly on Sunday at 2 AM (stable images)

### Storage Sizing

Adjust the storage request based on your OS image size:
- Fedora/CentOS: 30Gi
- Ubuntu Server: 20-30Gi
- Windows Server: 50-100Gi
- Minimal Linux distributions: 10-15Gi

## Complete Example: Adding CentOS Stream 9

1. **Create `centos-stream9-dataimportcron.yaml`:**

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataImportCron
metadata:
  name: centos-image-cron-stream9
  namespace: openshift-virtualization-os-images
spec:
  garbageCollect: Outdated
  managedDataSource: centos-stream9
  schedule: "0 2 * * *"
  template:
    metadata: {}
    spec:
      source:
        registry:
          pullMethod: node
          url: 'docker://registry.example.com/path/to/containerdisks/centos:stream9'
      storage:
        resources:
          requests:
            storage: 30Gi
    status: {}
```

2. **Apply to the shared VM cluster:**

```bash
oc apply -f centos-stream9-dataimportcron.yaml
```

## Verification

After applying the DataImportCron resource:

1. **Check DataImportCron status:**
```bash
oc get dataimportcron -n openshift-virtualization-os-images
```

2. **Verify DataSource creation:**
```bash
oc get datasource -n openshift-virtualization-os-images
```

3. **Check DataVolume status:**
```bash
oc get datavolume -n openshift-virtualization-os-images
```

4. **View import progress:**
```bash
oc describe dataimportcron <name> -n openshift-virtualization-os-images
```

5. **Monitor the first import:**
```bash
oc get datavolume -n openshift-virtualization-os-images -w
```

## Troubleshooting

### Image Import Fails

- Verify registry credentials and network connectivity from the cluster
- Check that the image URL is correct and accessible
- Review CDI controller logs: `oc logs -n openshift-cnv -l app=cdi-deployment`
- Verify image pull secrets if using a private registry

### Insufficient Storage

- Increase the storage request in the DataImportCron spec
- Verify available storage in the cluster: `oc get pv`
- Check StorageClass availability: `oc get storageclass`

### DataSource Not Created

- Check DataImportCron status: `oc describe dataimportcron <name> -n openshift-virtualization-os-images`
- Verify the managedDataSource name is unique
- Check CDI operator status: `oc get csv -n openshift-cnv`

### Permission Issues

- Verify you have permissions to create resources in `openshift-virtualization-os-images` namespace
- Check RBAC: `oc auth can-i create dataimportcron -n openshift-virtualization-os-images`

## Managing Multiple Images

To add multiple OS images, create separate DataImportCron resources for each:

```bash
# Apply multiple images
oc apply -f ubuntu-22-04-dataimportcron.yaml
oc apply -f centos-stream9-dataimportcron.yaml
oc apply -f rhel-9-dataimportcron.yaml

# View all configured images
oc get dataimportcron -n openshift-virtualization-os-images
```

## Updating an Existing Image

To update an image configuration:

1. Edit the DataImportCron resource:
```bash
oc edit dataimportcron <name> -n openshift-virtualization-os-images
```

2. Or apply an updated YAML file:
```bash
oc apply -f updated-dataimportcron.yaml
```

## Removing an Image

To remove an OS image:

```bash
# Delete the DataImportCron (this will also clean up associated resources)
oc delete dataimportcron <name> -n openshift-virtualization-os-images

# Verify removal
oc get datasource -n openshift-virtualization-os-images
```

## Best Practices

1. **Naming Convention**: Use descriptive names that include the OS and version (e.g., `ubuntu-22-04`, `centos-stream9`)
2. **Schedule Appropriately**: Use less frequent schedules for stable production images to reduce cluster load
3. **Storage Planning**: Allocate sufficient storage with some headroom for image growth
4. **Version Pinning**: Use specific version tags rather than `latest` for production environments
5. **Testing**: Test new images in a development cluster before applying to production
6. **Documentation**: Maintain a list of available images and their intended use cases
7. **Monitoring**: Set up alerts for failed DataImportCron jobs
8. **Registry Access**: Ensure the cluster has reliable access to the container registry

## Security Considerations

- Use private registries with authentication for production images
- Regularly update images to include security patches
- Scan container images for vulnerabilities before deployment
- Use image pull secrets for private registries:
  ```bash
  oc create secret docker-registry registry-secret \
    --docker-server=registry.example.com \
    --docker-username=user \
    --docker-password=password \
    -n openshift-virtualization-os-images
  ```

## Related Resources

- [Containerized Data Importer (CDI) — DataImportCron](https://github.com/kubevirt/containerized-data-importer/blob/main/doc/dataImportCron.md)
- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about-virt.html)