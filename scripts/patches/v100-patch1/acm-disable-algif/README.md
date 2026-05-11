# ACM Disable ALGIF Builtin Helm Chart

This Helm chart deploys a Red Hat Advanced Cluster Management (ACM) governance policy that disables the algif builtin kernel module on OpenShift clusters by creating MachineConfig resources.

## Overview

The chart creates the following resources:
- **Policy**: Defines the MachineConfig resources for both master and worker nodes
- **Placement**: Targets specific cluster sets for policy deployment
- **PlacementBinding**: Binds the policy to the placement
- **ManagedClusterSetBinding**: Binds cluster sets to the namespace

## Prerequisites

- Red Hat Advanced Cluster Management (ACM) installed on the hub cluster
- Appropriate cluster sets configured in ACM
- Sufficient permissions to create policies and placements

## Installation

### Install the chart

```bash
helm install acm-disable-algif ./acm-mc
```

### Install with custom values

```bash
helm install acm-disable-algif ./acm-mc -f custom-values.yaml
```

### Install in a specific namespace

```bash
helm install acm-disable-algif ./acm-mc --create-namespace -n my-policies
```

## Configuration

The following table lists the configurable parameters and their default values:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `common.namespace` | Namespace for all resources | `acm-disable-algif` |
| `policy.name` | Name of the policy | `disable-algif-builtin-policy` |
| `policy.remediationAction` | Remediation action (enforce/inform) | `enforce` |
| `policy.severity` | Policy severity level | `medium` |
| `placement.name` | Name of the placement | `disable-algif-builtin-placement` |
| `placement.clusterSets` | List of cluster sets to target | `[account, platform]` |
| `placementBinding.name` | Name of the placement binding | `disable-algif-builtin-placement-binding` |
| `machineConfig.worker.name` | Worker MachineConfig name | `99-disable-algif-builtin-worker` |
| `machineConfig.master.name` | Master MachineConfig name | `99-disable-algif-builtin-master` |
| `machineConfig.kernelArguments` | Kernel arguments to apply | `[initcall_blacklist=algif_aead_init]` |

## Example Custom Values

```yaml
common:
  namespace: my-custom-namespace

policy:
  remediationAction: inform
  severity: high

placement:
  clusterSets:
    - production
    - staging
```

## Verification

After installation, verify the resources:

```bash
# Check policy status
kubectl get policy -n acm-disable-algif

# Check placement decisions
kubectl get placementdecision -n acm-disable-algif

# Check policy compliance
kubectl get policy disable-algif-builtin-policy -n acm-disable-algif -o jsonpath='{.status.compliant}'
```

## Important Notes

- After the MachineConfig is applied, affected nodes will **reboot** to apply the kernel argument changes
- The policy targets both master and worker nodes
- Ensure proper maintenance windows are scheduled before deploying with `remediationAction: enforce`

## Uninstallation

```bash
helm uninstall acm-disable-algif
```

Note: This will remove the policy and related resources, but MachineConfigs already applied to clusters may need manual cleanup.

## Troubleshooting

### Policy not compliant

Check the policy status for details:
```bash
kubectl describe policy disable-algif-builtin-policy -n acm-disable-algif
```

### No clusters selected

Verify placement decisions:
```bash
kubectl get placementdecision -n acm-disable-algif -o yaml
```

Ensure the specified cluster sets exist and contain clusters:
```bash
kubectl get managedclustersets
kubectl get managedclusters -l cluster.open-cluster-management.io/clusterset=<clusterset-name>