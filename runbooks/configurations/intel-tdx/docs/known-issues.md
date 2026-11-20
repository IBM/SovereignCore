# Known issues (Beta)

Read these limits before following the [Intel TDX runbook](runbook-intel-tdx.md).
Diagnosis and recovery commands belong in [troubleshooting](troubleshooting.md).

## Issues

### Kubelet `PodResourcesGet` feature gate (confidential GPU, OpenShift 4.20)

Kata GPU cold plug needs `KubeletPodResourcesGet` on kubelet below 1.34. The GPU profile
ships an unsupported systemd-generator workaround; changing it reboots nodes.

### TDX guest clock offset breaks CUGA agent login

A guest clock offset of about one second can break zero-leeway JWT validation and other
time-sensitive checks. The [CUGA workaround](manual-install-tenant-gpu.md#g11-move-the-cuga-agent-into-a-tdx-guest-optional)
mounts a validator with 30-second leeway for the configured image only. **Authentication
code then comes from a host ConfigMap, not the attested image.** Remove the workaround
when the agent image supplies leeway; image changes require revalidation.

### vfio cdev missing after a node reboot (confidential GPU)

The GPU can advertise `pgpu` while its vfio cdev is missing. Run GPU verification after
every reboot; [recreate vfio-manager then the sandbox plugin](troubleshooting.md#vfio-cdev-missing-after-a-reboot).

### A failed confidential-GPU pod strands the GPU

A failed pod can stay Terminating and hold allocation. [Check GPU ownership before force-delete](troubleshooting.md#stranded-gpu-after-a-failed-pod).
Never use `crictl rmp -f`: it can crash CRI-O and require a reboot.

### QGS can stay broken after a node reboot ("TDX Quote is empty")

The DCAP operator's QGS reads PCK certificates from an in-memory cache that its
`pck-certs-watcher` sidecar fills from the `<qe_id>-pck` Secret when the pod starts. `tdx-qgs`
mounts that cache read-only and starts at the same time as the sidecar: if it looks for the cache
directory before the sidecar has created it (`Error creating directory
'/run/dcap/cache/.dcap-qcnl/'`), it never looks again and fails every quote with `0xb031`,
although the certificate is then in place. A restart of the `tdx-qgs` container fixes it. See
[diagnosis](troubleshooting.md#qgs-runs-but-every-quote-fails). Remove when the operator starts
`tdx-qgs` only after the cache is filled, or QGS retries a missing cache.

### NVIDIA verifier in Local mode; H200

Red Hat does not support Local mode or list H200 for confidential GPU in this configuration.
The air-gap path depends on both. [Collect verified RIM values](manual-install-tenant-gpu.md#g2-gpu-reference-values)
when the guest driver, VBIOS or signer changes. Optional revocation bundles are retained
operator evidence only; the hub does not consume them.

### Compliance check: no attestation evidence

The check assesses **all** non-terminating GPU-requesting LLM pods and fails if none
exist or any fails. It checks runtime/GPU/node configuration and locked initdata bytes
against the hub ConfigMap. PASS does not prove the running guests attested or obtained resources.

### Hub Vault depends on hub attestation

After [hub step 12](manual-install-hub.md#step-12-move-vault-into-tdx) a Vault server pod starts
only when its guest attests and pulls its image through the KBS: Trustee, QGS, the SGX plugin
unexpired TDX collateral and imported PCK certificates must work. Expired collateral or a hub `initdata` change
not yet in RVPS keeps restarted Vault pods from starting; losing two of three pods loses
quorum and every ExternalSecret on the hub. Restart Vault pods one at a time and only after a
sample guest has attested. Trustee keeps its synced Secrets, so it can start without Vault.
The opt-in is the namespace label `coco.io/confidential-workloads=enabled`; removing it returns
newly started Vault pods to the default runtime.
`oc exec` (including the chart's `preStop` hook) and `oc port-forward` into Vault pods are
refused by the locked guest policy. A kata pod can hang in Terminating (`KillPodSandbox ...
ttrpc: closed`); see [troubleshooting](troubleshooting.md#vault-pod-does-not-start-in-tdx).
