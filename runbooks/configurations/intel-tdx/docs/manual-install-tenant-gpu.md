# Step reference: confidential GPU tenant

`PROFILE=gpu` [`install-tenant.sh`](install.md#install-each-tenant) adds these steps to the
[tenant steps](manual-install-tenant.md) for NVIDIA Hopper confidential GPUs (H100/H200 in CC
mode). This page says what each GPU step changes, how to check it and where to look when it
fails. To run one step again, use its installer step name (always with the same `PROFILE`):

```bash
PROFILE=gpu APPLY=true ./scripts/install-tenant.sh --only <step>
```

How GPU attestation works: [architecture.md](architecture.md#confidential-gpu). Beta limits,
including the NVIDIA verifier support status: [known-issues.md](known-issues.md). Fixes:
[troubleshooting.md](troubleshooting.md). Sizing a guest for your own model:
[guest sizing](runbook-intel-tdx.md#guest-sizing).

## Before you start

The [installation prerequisites](install.md#before-you-start) apply, including the confidential
GPU ones, and the [tenant shell setup](manual-install-tenant.md#shell-setup). Once Kyverno is
installed, always use full resource names (`clusterpolicies.nvidia.com`,
`policies.policy.open-cluster-management.io`): the short names `clusterpolicy` and `policy`
resolve to Kyverno's kinds.

The GPU steps run at these points of the tenant installation:

| Installer steps | Step |
|---|---|
| (hub mirror, before tenant step 01) | [G1](#g1-mirror-the-gpu-operator) |
| `gpu-rim`, `gpu-registry-config`, `gpu-vault`, `gpu-trustee-restart`, `handover` (before tenant step 04) | [G2](#g2-gpu-reference-values) to [G5](#g5-hand-the-nvidia-stack-over) |
| `deploy`, `deploy-wait` with the GPU profile | [G6](#g6-deploy-with-the-gpu-profile) |
| `gpu-runtime`, `gpu-check` (before tenant step 05) | [G7](#g7-gpu-runtimeclass), [G8](#g8-verify-the-gpu-host) |
| `verify` | [G9](#g9-verify-attestation-on-the-gpu-tenant) |
| `llm`, `agent` (last) | [G10](#g10-move-the-llm-into-a-tdx-guest), [G11](#g11-move-the-cuga-agent-into-a-tdx-guest-optional) |

## G1. Mirror the GPU operator

The hub mirror (hub step 4) includes the GPU operator and verifier. Mirror again
(`APPLY=false ./scripts/mirror-coco-pattern.sh`) only if those artifacts are missing or changed,
before tenant step 01. This **writes the registry** and regenerates the cluster resources, but
does not apply the hub mirror sets; if the mappings changed, use the hub mirror procedure in a
maintenance window.

**Installer step:** none. **Runs on:** Mirror host with source-registry and site-registry access.

**Verify:** the run lists the pinned `gpu-operator-certified` catalog and images without errors.

**If it fails:** check the source credentials and the mirror CA; do not overwrite existing
mappings with raw oc-mirror output.

## G2. GPU reference values

Verified NVIDIA RIM values for the **guest** driver and the GPU VBIOS, in
`~/.coco-pattern/gpu-reference-values.json`. The installer pauses here until the file exists:
collect it on a host with NVIDIA RIM/OCSP access and copy it to the bastion.

```bash
DRIVER_VERSION=<kata-guest-driver> VBIOS_VERSION=<GPU-VBIOS> ./scripts/collect-gpu-refvals.sh
```

- **Guest driver version:** in the name of the OSC GPU guest image, on any node with the kata RPM
  (the hub's are enough): `ls /usr/share/kata-containers/osbuilder-images/*/kata-cc-nvidia-gpu-*.initrd`
  (OSC 1.13.1: `580.105.08`).
- **VBIOS version:** `nvidia-smi -q | grep VBIOS` while a driver owns the GPU, so before the
  handover (G5).
- The collector needs `curl`, `jq`, `openssl`, `xmlsec1` and `python3` with `lxml`
  (`requirements-bastion.txt`). SHA256, the signature chain to the pinned NVIDIA root and the
  signer OCSP must verify or collection stops. The hub's Local verifier does not check revocation;
  the OCSP check happens only here, at collection time.
- Collect and load again when the guest driver, VBIOS or signer changes.

**Installer step:** `gpu-rim` (pauses for the file).

**Verify:** the file contains driver and VBIOS RIM `_indices` and `_m<index>` keys.

**If it fails:** check the exact guest driver and VBIOS versions and connectivity; do not bypass
verification.

## G3. Registry configuration with tenant mirrors

Adds the tenant-only mirror mappings to the shared KBS registry resource
(`EXTRA_KUBECONFIGS=$TENANT_KUBECONFIG ./scripts/collect-registry-config.sh`).

**Installer step:** `gpu-registry-config`. **Runs on:** Bastion, reads Hub and Tenant.

**Verify:** `~/.coco-pattern/registry-configuration.toml` includes the model and runtime mirrors;
the read-only robots can read `aiiaas-models` and all required mirror organizations. If the
mirror CA bytes changed, coordinate the [measured configuration](operations-runbook.md#coco-initdata-hub-and-tenants-together).

**If it fails:** [guest image pulls](troubleshooting.md#guest-image-pull-fails).

## G4. Load GPU reference values on the hub

The hub profile already sets `kbs.gpu.enabled=true`. Loads the GPU reference values and the
registry configuration into the hub Vault
(`ONLY=gpuReferenceValues,registryConfig ./scripts/load-existing-vault.sh`) and restarts Trustee
once `gpu-refvals-eso` is synced. Redeploy the hub only if its profile or version also changed.

**Installer steps:** `gpu-vault`, `gpu-trustee-restart`. **Runs on:** Bastion, then Hub.
**Disruptive:** the Trustee restart interrupts attestation.

**Verify:** `oc get externalsecret -n trustee-operator-system gpu-refvals-eso` (hub) is synced and
the RVPS contains the driver and VBIOS values. CPU samples must still attest and obtain
resources; GPU acceptance follows in G10.

## G5. Hand the NVIDIA stack over

Excludes the tenant from Sovereign Core's NVIDIA GPU policy, so that the pattern can run the GPU
in CC mode (`scripts/tenant/g05-handover-nvidia-gpu.sh`; without `APPLY` it shows the state).
It must run before step 04: otherwise IBM's `mustonlyhave` policy reverts the CC-mode
ClusterPolicy.

**Installer step:** `handover`. **Runs on:** Bastion, then Hub.

IBM keeps the OperatorGroup, NFD and workload CR ownership. ArgoCD takes the GPU Subscription and
ClusterPolicy; Kyverno mutates the workload pods. A Sovereign Core
`make deploy-plugin PLUGIN=nvidia-gpu` re-applies the placement: repeat the handover afterwards.
`ROLLBACK=true APPLY=true` removes this tenant's handover label; the shared exclusion remains
while other CC-GPU tenants need it.

**Verify:** the script ends with `handover done: no Sovereign Core NVIDIA policy on <cluster>`.

**If it fails:** inspect the hub ManagedCluster and ACM policy before deploying the GPU profile.

## G6. Deploy with the GPU profile

Tenant step 04 with `deploy/spoke/values-baremetal-spoke-gpu.yaml`. It is a superset of the CPU
profile: GPU operator, `nvidia-gpu` (ClusterPolicy and IOMMU MachineConfig) and
`kubelet-podresources-gate` (PodResources gate and kubelet `runtimeRequestTimeout` 20m), plus the
CUGA agent's rules and `cuga-jwt-leeway` when `TENANT_AGENT_NAMESPACE` is set. It deploys no GPU
sample; the first confidential-GPU guest is the LLM (G10).

Both kubelet settings apply to the `master` role only (single-node and compact tenants). For GPU
worker nodes, add their role to `podResourcesGet.roles` and `runtimeRequestTimeout.roles` in the
`kubelet-podresources-gate` overrides; each added role reboots its nodes.

**Installer steps:** `deploy`, `deploy-wait` (`PROFILE=gpu`). **Runs on:** Bastion, then Tenant.
**Disruptive:** 2 to 3 reboots of a single-node tenant (IOMMU, TDX and kubelet MachineConfigs
render separately).

**Verify:** `oc get mcp` (tenant) settled after the last reboot;
`oc get applications.argoproj.io -n openshift-gitops` (tenant) shows `nvidia-gpu` Synced.

**If it fails:** check the pinned GPU operator CSV and
[InstallPlan/ClusterPolicy recovery](troubleshooting.md#gpu-operator-and-clusterpolicy).

## G7. GPU RuntimeClass

Makes the KataConfig reconcile again, so that RuntimeClass `kata-cc-nvidia-gpu` appears once the
ClusterPolicy has labelled the GPU node (`scripts/tenant/g07-reconcile-kataconfig-gpu.sh`).

**Installer step:** `gpu-runtime`. **Runs on:** Bastion, then Tenant.

**Verify:** `oc get runtimeclass kata-cc-nvidia-gpu` (tenant).

**If it fails:** confirm the GPU node label and a ready ClusterPolicy, then reconcile again.

## G8. Verify the GPU host

Checks the GPU host (`scripts/tenant/g08-verify-gpu-cc.sh`, read-only): GPU present, CC mode on,
ClusterPolicy ready, RuntimeClass present, `nvidia.com/pgpu` >= 1. Run it again after every node
reboot.

**Installer step:** `gpu-check`. **Runs on:** Bastion, reads the Tenant.

**Verify:** PASS. The script checks the first GPU node and infers the cdev state from plugin
logs (missing logs only warn): on multi-GPU-node tenants check every node's labels and allocation
and `oc debug node/<node> -q -- chroot /host ls /dev/vfio/devices/` (tenant).

**If it fails:** [vfio cdev missing after a reboot](troubleshooting.md#vfio-cdev-missing-after-a-reboot),
[GPU not in CC mode](troubleshooting.md#tdx-does-not-initialise).

## G9. Verify attestation on the GPU tenant

Tenant step 08: the CPU samples prove the tenant's TDX attestation and resource release. GPU
attestation is checked with the first GPU guest, the LLM, in G10.

**Installer step:** `verify`. **Disruptive:** restarts the CPU samples.

**Verify:** `END-TO-END` PASS.

## G10. Move the LLM into a TDX guest

Recreates the Sovereign Core AI Inference Service LLM pod (`scripts/tenant/g10-move-llm-to-cc.sh`).
Kyverno mutates it at creation: runtime class `kata-cc-nvidia-gpu`, `nvidia.com/gpu` to
`nvidia.com/pgpu`, the locked `initdata`, guest memory and the create-container timeout. It does
so for a pod in the confidential-GPU namespaces that matches `confidentialGpu.podSelector`
(default `kserve.io/component: workload`), has a container limit on an `nvidia.com/` resource
and has no runtime class or `kata-cc-nvidia-gpu`. The
script checks the mutation, not application readiness. `MOVE_LLM=false` skips the step.

**Installer step:** `llm`. **Runs on:** Bastion, then Tenant. **Disruptive:** LLM outage until the
in-guest image pull completes (tens of minutes for a large model).

The default is the locked `confidentialGpu.initdata: initdata` (no `exec`, no log streaming). To
diagnose, deploy with `debug-initdata` explicitly, run this step, then switch back and run it again.

**Verify:** the pod is `Running` with `runtimeClassName: kata-cc-nvidia-gpu`
(`oc get pod -n llms -l kserve.io/component=workload`, tenant); the LLMInferenceService is `Ready`
and a test inference succeeds. The hub Trustee log shows the GPU guest's `POST /kbs/v0/attest 200`
with a `gpu0` submod and its resource requests without `PolicyDeny`:

Hub (`export KUBECONFIG=$HUB_KUBECONFIG`):

```bash
oc logs -n trustee-operator-system deploy/trustee-deployment --since=30m \
  | grep -E 'POST /kbs/v0/attest|GET /kbs/v0/resource|PolicyDeny|gpu0'
```

**If it fails:** [Guest pull times out](troubleshooting.md#guest-pull-times-out),
[No space left in the guest](troubleshooting.md#no-space-left-in-the-guest),
[CUDA error 803](troubleshooting.md#cuda-error-803-in-the-guest),
[guest sizing](runbook-intel-tdx.md#guest-sizing). After any failed attempt, check for a
[stranded GPU](troubleshooting.md#stranded-gpu-after-a-failed-pod) before retrying.

## G11. Move the CUGA agent into a TDX guest (optional)

Runs on both profiles, only with `MOVE_AGENT=true` and `TENANT_AGENT_NAMESPACE` set at deployment
(step 04; to add an agent to a tenant deployed without one, set it and deploy again). It writes
the JWT-leeway ConfigMap (`scripts/tenant/workaround-cuga-jwt-leeway.sh`) and recreates the agent
pod with g10's checks.

The agent uses a CPU-only `kata-cc` guest. The `confidentialWorkloads` Kyverno rule in
`deploy/spoke/values-cuga-agent.yaml` supplies runtime, locked initdata, 24576 MiB guest memory and
24Gi limit, and gives the guest 2 vCPUs (CPU limit 2, `OMP_NUM_THREADS=2`); kata-tdx otherwise
boots it with 1 vCPU. It also keeps LiteLLM and OpenLit from downloading their price tables from
GitHub (`LITELLM_LOCAL_MODEL_COST_MAP=True`, `OPENLIT_PRICING_JSON=/dev/null`): without network
access each agent process waits about 110 s for those downloads, and the agent misses its 240 s
startup probe. IBM's broker reconciles the CugaAgent CR, so custom `spec.patches` are not a
durable configuration path; change the mutation settings and recreate the pod.

The JWT-leeway script extracts the exact configured agent image's validator and adds a 30-second
leeway; a different digest or file shape fails closed. The ConfigMap supplies authentication code
from the host, weakening the attested-image boundary: see the
[security consequence](known-issues.md#tdx-guest-clock-offset-breaks-cuga-agent-login). Remove the
ConfigMap and the `cuga-jwt-leeway` application when the agent image supplies leeway, recreate
the pod and verify login; use the operations' child-Application finalizer safeguards.

**Installer step:** `agent` (`MOVE_AGENT=true`). **Runs on:** Bastion, then Tenant.
**Disruptive:** recreating the agent interrupts login and service.

**Verify:** agent `1/1 Ready`, `runtimeClassName: kata-cc`, locked initdata, and login works.

**If it fails:** [login diagnosis](troubleshooting.md#agent-login-loops),
[guest sizing](runbook-intel-tdx.md#guest-sizing) or
[initdata admission](troubleshooting.md#pod-creation-denied-by-inject-initdata).
