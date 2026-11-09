# Hardening virt-launcher Network Access

## Overview

Each virtual machine in VMaaS runs inside a KubeVirt virt-launcher Pod on the VM cluster. Without a NetworkPolicy, any Pod on the VM cluster can reach guest OS ports on the virt-launcher Pod IP, regardless of namespace. This guide explains how to apply a NetworkPolicy that limits cross-namespace access to TCP/22, while leaving same-namespace traffic unrestricted.

This procedure applies to VMaaS v1.3.x. The operator does not distribute the policy automatically in this release; it must be applied manually. The policy has been tested on Clear Edition (Canal/Calico) and Purple Edition (OVN-Kubernetes).

When to apply:

- Once, during initial rollout, to cover all existing VMs using the bulk script below.
- After each new VM is provisioned, to apply a policy to that VM individually.
- When a VM is deleted and its namespace is kept, to remove the leftover policy.

## What the policy does

The policy selects virt-launcher Pods by the `kubevirt.io: virt-launcher` label and applies the following ingress rules.

Pods in the same namespace as the VM can reach all guest ports. TCP/22 is reachable from every source, including Pods in other namespaces and traffic arriving through the LoadBalancer Service. All other ports are denied to Pods in other namespaces.

Egress is not restricted.

## Limitations

This policy is an interim hardening measure. The following restrictions are known and intentional for v1.3.x.

Same-namespace traffic is not restricted. Every Pod in the same tenant namespace can reach all guest ports. Tenant namespace isolation is a v1.4.0 feature.

TCP/22 is open to every source for compatibility with SSH access and the Concert compliance scanner. The source IP seen by the guest for SSH through the LoadBalancer is a node IP or an overlay address, not the external client IP, because the Service uses `externalTrafficPolicy: Cluster`. Restricting SSH sources at the pod level is therefore not effective; use `loadBalancerSourceRanges` on the LoadBalancer Service or an upstream network control instead.

The policy does not apply automatically to new VMs. Each new VM must have a policy applied separately after provisioning.

## Prerequisites

Run all commands against the VM cluster (`kubectl` or `oc` with cluster-admin rights).

The tenant namespace on the VM cluster is `vmaas-<accountID>`, where `<accountID>` is the account ID shown in the Sovereign Core admin console. For example, account ID `ws-abc123` maps to namespace `vmaas-ws-abc123`.

## Applying the policy

### Apply to all existing VMs

This script iterates over every VirtualMachineInstance in every `vmaas-*` namespace and creates or updates a NetworkPolicy for each one. Run it once during initial rollout to cover all existing VMs.

```bash
kubectl get vmi -A --no-headers | \
  awk '$1 ~ /^vmaas-/ { print $1, $2 }' | \
  while read -r NAMESPACE VM_NAME; do
    echo "Applying policy for ${VM_NAME} in ${NAMESPACE}"
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: protect-virt-launcher-${VM_NAME}
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      kubevirt.io: virt-launcher
      vm.kubevirt.io/name: ${VM_NAME}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
    - ports:
        - protocol: TCP
          port: 22
EOF
  done
```

The script is idempotent. Re-running it updates existing policies without side effects.

### Apply to a single VM

Use this form for a VM that was provisioned after the initial rollout.

```bash
NAMESPACE="<namespace>"
VM_NAME="<vm-name>"

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: protect-virt-launcher-${VM_NAME}
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      kubevirt.io: virt-launcher
      vm.kubevirt.io/name: ${VM_NAME}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
    - ports:
        - protocol: TCP
          port: 22
EOF
```

## Verifying the policy

### Confirm all policies are present

List every NetworkPolicy across all `vmaas-*` namespaces and confirm that each running VM has a corresponding entry.

```bash
kubectl get networkpolicy -A | grep vmaas-
```

Each row should show a `POD-SELECTOR` containing `kubevirt.io=virt-launcher,vm.kubevirt.io/name=<vm-name>`.

To cross-check against running VMs:

```bash
echo "=== Running VMIs ==="
kubectl get vmi -A --no-headers | awk '$1 ~ /^vmaas-/ { print $1, $2 }'

echo ""
echo "=== NetworkPolicies ==="
kubectl get networkpolicy -A --no-headers | awk '$1 ~ /^vmaas-/ { print $1, $2 }'
```

Every VM name that appears in the VMI list should have a matching policy name `protect-virt-launcher-<vm-name>` in the policy list.

### Confirm cross-namespace access is blocked

Run a probe Pod in a separate namespace and attempt a connection to a non-SSH port on the VM Pod IP. The VM Pod IP is shown in `kubectl get vmi -n <namespace>`.

```bash
VM_POD_IP=$(kubectl get vmi <vm-name> -n <namespace> \
  -o jsonpath='{.status.interfaces[0].ipAddress}')

kubectl run netpol-probe --rm -it --restart=Never \
  --image=busybox:1.36 \
  --namespace=default \
  -- sh -c "nc -zv -w 5 ${VM_POD_IP} 8080; echo exit=\$?"
```

With the policy applied, the connection times out after 5 seconds. Without the policy, a port with no listener returns `Connection refused` immediately. Only a timeout confirms that the policy is dropping the traffic.

### Confirm TCP/22 remains reachable

```bash
kubectl run netpol-probe --rm -it --restart=Never \
  --image=busybox:1.36 \
  --namespace=default \
  -- sh -c "nc -zv -w 5 ${VM_POD_IP} 22; echo exit=\$?"
```

Expected result: `open` with `exit=0`.

### Confirm SSH through the LoadBalancer still works

Retrieve the external IP of the SSH LoadBalancer Service and attempt a connection from outside the cluster.

```bash
kubectl get svc -n <namespace> -l vm.kubevirt.io/name=<vm-name> \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'
```

The connection to port 22 on that IP should succeed.

## Removing the policy

### Remove the policy for a single VM

Run this when a VM is deleted and its namespace is not also deleted.

```bash
kubectl delete networkpolicy protect-virt-launcher-<vm-name> -n <namespace>
```

### Remove all policies across all VM namespaces

```bash
kubectl get networkpolicy -A --no-headers | \
  awk '$1 ~ /^vmaas-/ && $2 ~ /^protect-virt-launcher-/ { print $1, $2 }' | \
  while read -r NAMESPACE POLICY_NAME; do
    echo "Deleting ${POLICY_NAME} from ${NAMESPACE}"
    kubectl delete networkpolicy "${POLICY_NAME}" -n "${NAMESPACE}"
  done
```

Confirm removal:

```bash
kubectl get networkpolicy -A | grep "protect-virt-launcher"
```

No output means all policies have been removed.

## Troubleshooting

### The probe returns "Connection refused" instead of a timeout

A `Connection refused` result means the packet reached the guest OS and the guest rejected it, because nothing is listening on that port. This is not a policy drop. A policy drop produces a timeout, not a refusal.

To confirm the policy is enforcing correctly, use a port that has an active listener inside the guest. Start a listener on the guest (for example `python3 -m http.server 8080`) and retry the probe. With the policy applied, the connection to port 8080 from another namespace should time out.

### TCP/22 is blocked from another namespace

The policy allows TCP/22 from every source. If TCP/22 is timing out from another namespace, check that the policy selector matches the virt-launcher Pod. The `vm.kubevirt.io/name` label value in the policy must match the VMI name exactly.

```bash
kubectl get networkpolicy protect-virt-launcher-<vm-name> -n <namespace> \
  -o jsonpath='{.spec.podSelector}'
kubectl get pod -n <namespace> -l kubevirt.io=virt-launcher --show-labels
```

The `vm.kubevirt.io/name` value in both outputs must be identical.

### The policy does not appear to take effect immediately

NetworkPolicy enforcement is handled by the CNI plugin (Canal/Calico on Clear Edition, OVN-Kubernetes on Purple Edition). Both CNIs apply rules within a few seconds of the policy being created. If traffic is not blocked after 10 seconds, verify that the policy exists and that its `podSelector` matches the virt-launcher Pod as described above.

### A VM was deleted but the policy is still present

If the VM namespace is not deleted when the VM is removed, the policy is left behind. Remove it manually:

```bash
kubectl delete networkpolicy protect-virt-launcher-<vm-name> -n <namespace>
```
