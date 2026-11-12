# Setting Up MetalLB IPAddressPool for VMaaS Clear Edition

This guide describes the MSP-side setup step for VMaaS Clear Edition external IP allocation. Use the [setup-metallb-pool-vmaas.sh](./setup-metallb-pool-vmaas.sh) script.

## Background

Purple Edition runs on OpenShift with XPM. VMaaS calls XPM IPAM to allocate a dedicated /32 IP per VM, then creates a per-VM IPAddressPool and LoadBalancer Service via ACM ManifestWork.

Clear Edition runs on CNCF Kubernetes (RKE2) without XPM. MetalLB is the standard LoadBalancer mechanism. Instead of calling XPM, VMaaS creates a LoadBalancer Service annotated with `metallb.io/address-pool`, and MetalLB assigns an IP automatically from a shared pool. That shared pool must exist before any VM is provisioned. This script creates it.

## Responsibility split

This script handles the MSP-side prerequisites:

- A check that the addresses of the pool are not already in use on the network
- IPAddressPool in `metallb-system` with the address range for VM SSH IPs
- L2Advertisement referencing the pool by name for standalone operation

The vmaas-service-broker operator handles the per-VM side:

- LoadBalancer Service with `metallb.io/address-pool` annotation per VM
- Reads the assigned IP back from ACM ManifestWork StatusFeedback
- Writes the IP to `VirtualMachineRequest.status.externalIP`

Neither MetalLB nor the VMaaS operator checks whether an address is free on the network. MetalLB in layer 2 mode answers ARP for the addresses it announces. It does not detect another host that uses the same address. Choosing the range, and confirming it with the network owner, is the MSP responsibility.

## Prerequisites

MetalLB must already be installed on the spoke cluster. The script checks for the `ipaddresspools.metallb.io` and `l2advertisements.metallb.io` CRDs and exits if absent.

The MetalLB controller must run with the load balancer class `metallb` (argument `--lb-class=metallb`), because the per-VM LoadBalancer Services carry `loadBalancerClass: metallb`. If it does not, the Service of a virtual machine stays in the `<pending>` state. Check it with:

```sh
kubectl get deployment controller --namespace metallb-system \
  --output=jsonpath='{.spec.template.spec.containers[0].args}'
```

A kubeconfig pointing directly to the spoke cluster is required.

### Verifying same-L2 segment reachability

For a meaningful address check, run the script from a host in the same Layer 2 segment as the worker nodes (for example the master node or a bastion on the same node subnet). The check sends ARP, ICMP, and TCP probes directly from the machine that runs the script. If run from a routed network across a gateway, ARP probes will fail and hosts filtering routed ICMP/TCP may not answer.

Confirm that the execution host has a direct Layer 2 route to the worker node IP:

```sh
# Run on the host executing the script
ip route get <worker-node-ip>
```

Example of correct Layer 2 adjacency (direct route via interface, no gateway):

```text
192.0.2.15 dev eth0 src 192.0.2.10 uid 0
```

If the output shows `via <gateway-ip>` (for example `192.0.2.15 via 192.0.2.1 dev eth0`), the host is on a different subnet and ARP probes cannot detect neighbours on the worker segment.

## Obtaining a spoke kubeconfig

The spoke clusters in Clear Edition environments are OCM-managed. A kubeconfig can be built
from the cluster CA and a service-account token.

```sh
# Read the cluster CA certificate and API server address.
# Use a dedicated service account with the minimum required permissions
# rather than a cluster-admin token.
# Note: kubectl receives the token as a command-line argument, so it is visible in the
# process list of the host while the command runs. Run this on a host that only trusted
# users can log in to.
SPOKE_API="<spoke-api-server-hostname-or-ip>"
SPOKE_CA_FILE="<path-to-cluster-ca.crt>"

KUBECONFIG_SPOKE=$(mktemp)
chmod 600 "$KUBECONFIG_SPOKE"

# Keep the token in a file with restricted permissions (chmod 600).
SPOKE_TOKEN_FILE="<path-to-token-file>"

kubectl config set-cluster spoke \
  --server=https://${SPOKE_API}:6443 \
  --certificate-authority="${SPOKE_CA_FILE}" \
  --embed-certs=true \
  --kubeconfig="${KUBECONFIG_SPOKE}"

kubectl config set-credentials spoke-admin \
  --token="$(cat "${SPOKE_TOKEN_FILE}")" \
  --kubeconfig="${KUBECONFIG_SPOKE}"

kubectl config set-context spoke \
  --cluster=spoke --user=spoke-admin \
  --kubeconfig="${KUBECONFIG_SPOKE}"

kubectl config use-context spoke --kubeconfig="${KUBECONFIG_SPOKE}"

# Delete the kubeconfig when done.
# trap "rm -f ${KUBECONFIG_SPOKE}" EXIT
```

The cluster CA file can be obtained from the cluster API server certificate:

```sh
kubectl --kubeconfig=<admin-kubeconfig> config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > cluster-ca.crt
```

Alternatively, run kubectl directly on the spoke master node:

```sh
ssh <non-root-user>@<spoke-master-ip>
kubectl get ipaddresspools -A
```

## Usage

Check a candidate range first. This needs no kubeconfig and changes nothing:

```sh
POOL_RANGE="192.0.2.10-192.0.2.13" CHECK_ONLY=true \
  ./setup-metallb-pool-vmaas.sh
```

The exit code is 0 when no address showed signs of use, and 2 when at least one did.

Then create the pool. The script runs the same check first and stops if an address answers:

```sh
KUBECONFIG=/path/to/spoke-kubeconfig.yaml \
POOL_RANGE="192.0.2.10-192.0.2.13" \
  ./setup-metallb-pool-vmaas.sh
```

If `POOL_RANGE` is omitted the script displays node IPs and prompts for the range.

Dry run (prints manifests without applying them; kubectl read operations still run against the cluster):

```sh
KUBECONFIG=/path/to/spoke-kubeconfig.yaml \
DRY_RUN=true \
  ./setup-metallb-pool-vmaas.sh
```

## Options

| Variable | Default | Description |
|---|---|---|
| `KUBECONFIG` | (required unless `CHECK_ONLY=true`) | Path to the spoke cluster kubeconfig |
| `POOL_NAME` | `vmaas` | Name of the IPAddressPool and L2Advertisement. Must match `metallb.addressPoolName` in the VMaaS Helm values. |
| `POOL_RANGE` | (prompted) | IP range for MetalLB to assign from. Range (`192.0.2.10-192.0.2.13`) or CIDR (`192.0.2.8/30`). Ranges larger than 1024 addresses are refused by the check. |
| `METALLB_NAMESPACE` | `metallb-system` | Namespace where MetalLB is installed |
| `DRY_RUN` | `false` | Print manifests without applying |
| `CHECK_ONLY` | `false` | Run the address check only. Needs `POOL_RANGE`, does not need a kubeconfig |
| `PROBE_TCP_PORTS` | `22 80 443` | TCP ports tried on each address |
| `PROBE_TIMEOUT` | `1` | Seconds per probe |
| `PROBE_IFACE` | (unset) | Interface passed to `arping`, if `arping` is installed |
| `KNOWN_OWN_ADDRESSES` | (read from the cluster) | Addresses that the cluster LoadBalancer Services already hold. They are reported as `OWN` and do not stop the script |

## Break-glass operations (exception handling)

The following options bypass safety checks. Do not use them in normal operations.

| Variable | Default | Description |
|---|---|---|
| `FORCE` | `false` | Continue even if addresses show signs of use. |
| `SKIP_ADDRESS_CHECK` | `false` | Do not probe addresses at all. |

Never use `FORCE=true` when an address returned `IN_USE` (active ping, TCP, or ARP response). Forcing an active IP into the pool will cause ARP conflicts and route SSH traffic to the wrong host.

`FORCE=true` is strictly intended for stale reverse DNS entries (`DNS_ONLY`) where the network owner has confirmed that the host is decommissioned and no longer exists on the network.

## The address check

For each address in `POOL_RANGE` the script tries, from the machine it runs on:

- `ping`
- TCP connect on `PROBE_TCP_PORTS`
- `arping`, if installed
- a reverse DNS lookup

Result per address:

| Result | Meaning | Effect |
|---|---|---|
| `IN_USE` | ping, TCP or ARP got an answer | The script stops |
| `DNS_ONLY` | Nothing answered, but a reverse DNS name exists | The script stops. A host may be down or filtering probes |
| `NO_SIGN` | Nothing answered and there is no DNS name | The script continues |
| `OWN` | The address is held by a LoadBalancer Service of this cluster | Skipped |

`NO_SIGN` does not prove that an address is free. A host can drop ICMP and the probed TCP ports, or sit on a segment that the probing machine cannot see. Confirm the range with the network owner before use.

Example output when addresses in the candidate range are already in use by other clusters sharing the same Layer 2 segment. The script stops at the first conflict:

```text
  ADDRESS          RESULT    EVIDENCE
  192.0.2.4        IN_USE    ping tcp/22 rdns=worker1.cluster-a.example.internal
  192.0.2.5        IN_USE    ping tcp/22 rdns=worker2.cluster-b.example.internal
  192.0.2.6        IN_USE    ping tcp/22 rdns=worker3.cluster-a.example.internal
  192.0.2.7        OWN       assigned to a Service of this cluster (skipped)
  192.0.2.8        NO_SIGN   -
  192.0.2.9        NO_SIGN   -
```

In this example, several addresses in the candidate range answered one of the probes or had a reverse DNS name, indicating use by other clusters. The address `192.0.2.7` belonged to an existing LoadBalancer Service of this cluster and was skipped. A normal run (with a kubeconfig) reports cluster-owned addresses as `OWN`.

## Choosing an IP range

The pool range must be in the same Layer 2 segment as the worker nodes so MetalLB can respond to ARP requests.

Before the range is used:

1. Ask the network owner which addresses of the segment are reserved for this cluster, and record the answer. Other clusters share the segment.
2. Run the address check from a host in the segment.
3. Avoid node IPs, the cluster VIP, and any address used by another cluster or host.
4. Avoid addresses already in use by existing IPAddressPools on the spoke.

Do not treat a range as safe because it avoids the node IPs and the VIP of the cluster. Choosing a range based solely on that rule is not sufficient: many addresses in a candidate range may already be used by other clusters sharing the same Layer 2 segment.

### CIDR vs Range notation

When specifying a CIDR block (for example `192.0.2.0/30` or `192.0.2.0/24`), MetalLB treats all addresses in the block as allocatable /32 host IPs, including the lowest (network) and highest (broadcast) addresses of the CIDR block.

- To prevent MetalLB from assigning network or broadcast boundary addresses of a subnet (such as `.0` and `.255`), use explicit range notation (for example `192.0.2.10-192.0.2.50`) instead of full subnet CIDRs.
- Sub-block CIDRs (such as `192.0.2.0/30` within a larger `/24` network) allocate all 4 addresses (`.0`, `.1`, `.2`, `.3`) as host IPs.

## What the script creates

IPAddressPool in `metallb-system`:

```yaml
metadata:
  name: vmaas
  namespace: metallb-system
  labels:
    vmaas.sovereign-core.ibm.com/managed: "true"   # selected by hub vmaas-l2-advertisement
spec:
  addresses:
    - <POOL_RANGE>
  autoAssign: false                                  # only assigned via annotation or selector
  serviceAllocation:
    serviceSelectors:
      - matchLabels:
          vmaas.sovereign.cloud.ibm.com/external-access: "true"   # VMaaS per-VM Services only
```

`autoAssign: false` prevents MetalLB from assigning IPs to Services that do not explicitly request this pool.

`serviceAllocation.serviceSelectors` restricts the pool to Services carrying the `external-access` label, which vmaas-service-broker sets on every per-VM LoadBalancer Service in pool mode. This ensures the pool is not consumed by unrelated Services. Requires MetalLB v0.13.2 or later.

The `managed=true` label is required for the `vmaas-l2-advertisement` (deployed by the hub vmaas-metallb-init ManifestWork) to select this pool automatically via `ipAddressPoolSelectors`.

L2Advertisement in `metallb-system`:

```yaml
metadata:
  name: vmaas
  namespace: metallb-system
  labels:
    vmaas.sovereign-core.ibm.com/managed: "true"
spec:
  ipAddressPools:
    - vmaas
```

## L2Advertisement coexistence and lifecycle

The setup involves two L2Advertisement resources:

1. `vmaas` (created by this script): references the pool by name (`ipAddressPools: ["vmaas"]`). This allows L2 advertisement to function immediately during standalone MSP setup and testing, before the hub cluster initializes the spoke.
2. `vmaas-l2-advertisement` (deployed by the hub `vmaas-metallb-init` ManifestWork): selects pools by label (`ipAddressPoolSelectors: managed=true`).

MetalLB allows multiple L2Advertisements to select the same IPAddressPool without conflict. Both advertisements safely coexist; there is no need to delete the script-created `vmaas` L2Advertisement after the hub ManifestWork is applied.

## Changing the range of an existing pool

Running the script again with a new `POOL_RANGE` updates the IPAddressPool.

- A LoadBalancer Service that already holds an address outside the new range keeps that address until the Service is recreated. MetalLB does not move it.
- A VM whose SSH address is in a conflicting range stays unreachable on that address. Recreate its LoadBalancer Service, or the VM, after the pool was changed.
- Check which Services hold addresses before changing the pool:

```sh
kubectl get svc -A \
  -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\t"}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}'
```

## VMaaS configuration

On Clear Edition, the vmaas-service-broker uses pool mode (`externalIPMode: "metallb-pool"`) and the pool name `vmaas` by default. If you changed `POOL_NAME`, or the environment was set up in XPM mode, set the pool mode and the pool name in the VMServiceBrokerConfig CR on the hub:

```sh
kubectl patch vmservicebrokerconfig vm-service-broker \
  -n vm-service-broker --type merge \
  -p '{"spec":{"metallb":{"externalIPMode":"metallb-pool","addressPoolName":"vmaas"}}}'
```

## Relationship to vmaas-metallb-init ManifestWork

The hub deploys a ManifestWork (`vmaas-metallb-init-<cluster>`) to the spoke when the first virtual machine namespace is requested for the VM cluster. You do not need to create it. That ManifestWork contains:

- ClusterRole and ClusterRoleBinding for the ACM klusterlet work agent
- `vmaas-l2-advertisement` with `ipAddressPoolSelectors: managed=true`

It does not contain an IPAddressPool. This script fills that gap.

The label `vmaas.sovereign-core.ibm.com/managed=true` on the IPAddressPool this script creates is how the hub-managed L2Advertisement finds and advertises the pool without needing to know its name in advance.
