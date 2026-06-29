# Cluster Resource Quotas for VM Service

This document covers sample ClusterResourceQuota configurations for managing resource limits across namespaces managed by the VM Service. These resources are intended to be manually deployed to the shared cluster.

## Label Requirements

All quotas in this directory select namespaces with the following label:
- `app.kubernetes.io/managed-by: vm-service-broker`

## Files

### 1. `general-cluster-quota.yaml`
General-purpose quota for compute and storage resources.

**Resource Name:** `vm-service-general-quota`

**Limits:**
- CPU: 50 requests / 100 limits
- Memory: 100Gi requests / 200Gi limits
- Storage: 2Ti across 50 PVCs
- Pods: 100
- Services: 50
- Secrets: 100
- ConfigMaps: 50

### 2. `vm-specific-cluster-quota.yaml`
VM-specific quota focusing on KubeVirt resources.

**Resource Name:** `vm-service-vm-quota`

**Limits:**
- VMs: 30 VirtualMachines / 30 VirtualMachineInstances
- DataVolumes: 60
- VM Snapshots: 20
- VM ReplicaSets: 10
- VM Presets: 10
- CPU: 60 requests / 120 limits
- Memory: 120Gi requests / 240Gi limits
- Storage: 3Ti across 60 PVCs

### 3. `standard-plan-cluster-quota.yaml`
Quota specifically for the standard plan tier.

**Resource Name:** `vm-service-standard-plan-quota`

**Limits:**
- VMs: 10 VirtualMachines / 10 VirtualMachineInstances
- DataVolumes: 20
- VM Snapshots: 5
- CPU: 20 requests / 40 limits
- Memory: 40Gi requests / 80Gi limits
- Storage: 1Ti across 20 PVCs
- Pods: 30
- Services: 15
- Secrets: 30
- ConfigMaps: 15

## Deployment

### Apply a quota to the shared cluster:
```bash
oc apply -f scripts/vm-service-tech-preview/quotas/standard-plan-cluster-quota.yaml
```

### Apply all quotas:
```bash
oc apply -f scripts/vm-service-tech-preview/quotas/
```

### View all ClusterResourceQuotas:
```bash
oc get clusterresourcequota
```

### View specific quota details:
```bash
oc describe clusterresourcequota vm-service-standard-plan-quota
```

### Check which namespaces are affected:
```bash
oc get clusterresourcequota vm-service-standard-plan-quota -o yaml
```

### View quota usage:
```bash
oc get clusterresourcequota vm-service-standard-plan-quota -o jsonpath='{.status}' | jq
```

## Label Namespaces

To apply these quotas, ensure your namespaces have the required label:

```bash
# Label a namespace to match the quota selectors
oc label namespace my-vm-namespace \
  app.kubernetes.io/managed-by=vm-service-broker
```

### Verify namespace labels:
```bash
oc get namespace my-vm-namespace --show-labels
```

## Customization

Adjust the quota values based on your requirements:

1. **Development environments**: Lower limits for testing
2. **Production environments**: Higher limits for production workloads
3. **Different plan tiers**: Create separate quotas for premium/enterprise plans
4. **Per-tenant quotas**: Adjust limits based on tenant requirements

## Monitoring

Monitor quota usage regularly:

```bash
# Check quota status across all namespaces
oc get clusterresourcequota -o wide

# Get detailed usage for a specific quota
oc describe clusterresourcequota vm-service-vm-quota

# List all namespaces affected by a quota
oc get clusterresourcequota vm-service-standard-plan-quota \
  -o jsonpath='{.status.namespaces[*].namespace}' | tr ' ' '\n'

# Check quota usage percentage
oc get clusterresourcequota vm-service-vm-quota \
  -o jsonpath='{range .status.namespaces[*]}{.namespace}{"\t"}{.status.used}{"\n"}{end}'
```

## Important Notes

- **Label required**: Namespaces must have the `app.kubernetes.io/managed-by: vm-service-broker` label to match these quotas
- **Manual deployment**: These resources are intended to be manually deployed to the shared cluster by cluster administrators
- **Aggregate limits**: ClusterResourceQuotas aggregate limits across ALL matching namespaces
- **Enforcement**: Quotas are enforced at resource creation time - existing resources are not affected
- **Multiple quotas**: Multiple ClusterResourceQuotas can apply to the same namespace
- **Multiple enforcement**: When multiple quotas apply to the same namespace, a resource creation is blocked if it would exceed *any* of the applicable quotas

## Troubleshooting

### Quota not applying to namespace:
```bash
# Check namespace labels
oc get namespace <namespace-name> --show-labels

# Verify the required label is present
oc get namespace <namespace-name> -o jsonpath='{.metadata.labels}'
```

### Check why resource creation is blocked:
```bash
# View quota status
oc describe clusterresourcequota vm-service-vm-quota

# Check namespace-specific usage
oc get resourcequota -n <namespace-name>
```

### View quota events:
```bash
oc get events -n <namespace-name> --field-selector reason=FailedCreate