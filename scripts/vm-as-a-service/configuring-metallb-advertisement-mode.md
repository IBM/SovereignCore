# Configuring the MetalLB Advertisement Mode

## Overview

VMaaS uses MetalLB to assign each VM a dedicated external IP address and announce it on the
cluster network so that SSH clients can reach the VM. The way MetalLB announces these addresses
depends on the advertisement mode configured for the VM cluster. This guide explains how to
choose and configure the mode before the VM cluster is initialized.

The advertisement mode must be set before the first VM is provisioned on the cluster. Once
the cluster-init ManifestWork has been created by the operator, the mode cannot be changed for
that cluster without reprovisioning.

## Advertisement Modes

VMaaS supports two advertisement modes: L2 and BGP.

### L2 Mode

In L2 mode, MetalLB responds to ARP requests to announce each VM's IP address on the Layer 2
network connected to the cluster nodes. This mode requires no router configuration and is the
default for new deployments.

L2 mode is suitable when the VM IP address pool is reachable through the same Layer 2 network
segment as the cluster nodes. SSH clients may be on a different routed subnet provided the
network has a route to the VM IP subnet; the deciding factor is the network reachability of
the IP pool, not the physical location of the SSH clients.

### BGP Mode

In BGP mode, MetalLB peers with a BGP router and advertises VM IP routes over the BGP session.
This mode is required when the network design does not allow the VM IP pool to be announced
through Layer 2, or when VM IP routes must be dynamically advertised to upstream routers.

BGP mode requires the MSP to provide the BGP router's IP address and AS numbers via Helm, and
requires the network administrator to configure the corresponding BGP peer entry on the router.
Router-side BGP configuration is outside the scope of VMaaS and must be completed by the
network administrator before provisioning VMs.

## Before You Begin

Confirm which network topology applies to the VM cluster before proceeding.

Use L2 mode when the VM IP address pool is reachable through the Layer 2 network connected to
the cluster nodes. SSH clients may be on another routed subnet, provided the network has a
route to the VM IP subnet.

Use BGP mode when VM IP routes must be dynamically advertised to upstream routers, or when the
network design does not allow the VM IP pool to be announced through Layer 2. In this case,
obtain the following values from the network administrator before proceeding:

- The BGP router's IPv4 address (the peer address MetalLB will connect to).
- The BGP AS number assigned to the router (peerASN).
- The BGP AS number to assign to MetalLB itself (myASN). Private AS numbers in the 16-bit
  range are 64512 to 65534. If the network uses 32-bit private ASNs (4200000000 to
  4294967294), confirm the specific value with the network administrator.

## Configuring L2 Mode

L2 mode is the default. If the deployment values file does not include a `metallb` section, L2
mode is used automatically. To make the setting explicit, add the following to the Helm values
override file for the VM cluster:

```yaml
metallb:
  advertisementMode: "l2"
```

No additional values are required for L2 mode.

## Configuring BGP Mode

To use BGP mode, set `advertisementMode` to `"bgp"` and provide all three BGP peer values.

```yaml
metallb:
  advertisementMode: "bgp"
  bgp:
    peerAddress: "192.168.1.1"   # IPv4 address of the BGP router
    peerASN: 65000               # AS number assigned to the BGP router
    myASN: 64512                 # AS number assigned to MetalLB on this cluster
```

Replace the example values with the actual values obtained from the network administrator.
`peerAddress` must be a valid IPv4 address in dotted-decimal notation. Both ASN values must be
in the range 1 to 4294967295, which is the full range validated by the CRD schema.

All three BGP fields are required when BGP mode is selected. If any field is absent when the
VMServiceBrokerConfig CR is applied, the operator sets a `ValidationFailed` status condition on
the CR and does not apply the new configuration. The configuration loaded at startup from
environment variables (or the last successfully applied CR configuration) remains in effect.
The operator pod continues running.

The network administrator must configure the router to accept a BGP session from the cluster
nodes using the `myASN` value set above. This router-side step is outside VMaaS and must be
completed before VMs are provisioned.

## Applying the Configuration

The `metallb` values are written into the `VMServiceBrokerConfig` CR the first time the Helm
chart is installed. The CR template includes a lookup guard: if the CR already exists, a
subsequent `helm upgrade` does not overwrite it.

In a GitOps environment managed by ArgoCD, add the `metallb` block to the values override file
in the GitOps repository and sync the Application. ArgoCD renders Helm templates without
server-side lookup, so the CR is updated on every sync. Apply the change before provisioning
the first VM on the cluster.

In a direct Helm environment where the chart has not yet been installed, include the MetalLB
values in the initial install:

```bash
helm install vm-service-broker charts/vm-service-broker \
  --namespace vm-service-broker \
  --create-namespace \
  --set metallb.advertisementMode=bgp \
  --set metallb.bgp.peerAddress=192.168.1.1 \
  --set metallb.bgp.peerASN=65000 \
  --set metallb.bgp.myASN=64512
```

If the chart is already installed and the VMServiceBrokerConfig CR already exists, `helm upgrade`
does not update the MetalLB fields. Edit the CR directly before the first VM is provisioned:

```bash
oc edit vmservicebrokerconfig vm-service-broker -n vm-service-broker
```

## Verifying the Configuration

After the first VM has been provisioned on the cluster, confirm that MetalLB is configured by
checking the cluster-init ManifestWork on the hub and the advertisement resource on the VM
cluster.

Check that the cluster-init ManifestWork exists and has been Applied by ACM on the hub cluster:

```bash
CLUSTER_NAME="<cluster-name>"

oc get manifestwork "vmaas-metallb-init-${CLUSTER_NAME}" \
  -n "${CLUSTER_NAME}" \
  -o jsonpath='{.status.conditions}' | jq \
  '[.[] | select(.type == "Applied")]'
```

The Applied condition must show `status: "True"`. If the ManifestWork does not exist yet, the
first VM provisioning is still in progress driving MetalLB cluster initialization.

Verify the advertisement resource on the VM cluster. For L2 mode:

```bash
oc --kubeconfig ~/.kube/config-"${CLUSTER_NAME}" \
  get l2advertisement vmaas-l2-advertisement -n metallb-system
```

For BGP mode:

```bash
oc --kubeconfig ~/.kube/config-"${CLUSTER_NAME}" \
  get bgpadvertisement vmaas-bgp-advertisement -n metallb-system

oc --kubeconfig ~/.kube/config-"${CLUSTER_NAME}" \
  get bgppeer vmaas-bgp-peer -n metallb-system -o yaml
```

Confirm that the BGPPeer shows the correct `peerAddress` and AS numbers in its spec.

## Known Limitations

The advertisement mode is set once at cluster initialization and cannot be changed for a running
cluster. The cluster-init ManifestWork (`vmaas-metallb-init-<cluster-name>`, where
`<cluster-name>` is the ACM ManagedCluster name) is created once and is not updated if Helm
values are changed after initialization. If a different advertisement mode is needed, the
cluster must be deprovisioned and reprovisioned with the new Helm values.

VM IP addresses are allocated from the XPM IPAM pool at provisioning time and released at
deletion time. If a VM is deleted and a new VM is created, the new VM may receive a different
IP address. SSH clients that connect by IP will need to update their `known_hosts` entry if the
address changes.
