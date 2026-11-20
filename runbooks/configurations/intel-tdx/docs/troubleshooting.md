# Troubleshooting

Symptom, cause and fix for failures in the [hub](manual-install-hub.md), [tenant](manual-install-tenant.md)
and [confidential GPU](manual-install-tenant-gpu.md) runbooks. `oc` (hub) and `oc` (tenant) are the hub and tenant
clients from the runbooks' shell setup. Run commands in Bash from `runbooks/configurations/intel-tdx`;
`oc debug` (tenant) creates privileged temporary pods even when the host command only reads. Vendor gaps with shipped workarounds are in
[known-issues.md](known-issues.md).

**Where to look first.** Read the hub Trustee log and the guest's CDH log together:

Hub (`export KUBECONFIG=$HUB_KUBECONFIG`):

```bash
oc logs -n trustee-operator-system deploy/trustee-deployment --since=15m \
  | grep -E 'POST /kbs/v0/(auth|attest)|GET /kbs/v0/resource|PolicyDeny|hardware|configuration'
```

| Trustee log shows | Go to |
|---|---|
| only `POST /kbs/v0/auth`, no `/attest` | [Trustee loops on /auth](#trustee-loops-on-auth-with-no-attest) |
| `TDX Quote is empty` | [TDX Quote is empty](#tdx-quote-is-empty) |
| `/attest` and `/resource` 200, pod still fails | [Guest image pull fails](#guest-image-pull-fails) |
| nothing for the pod | [GPU pod stuck in ContainerCreating](#gpu-pod-stuck-in-containercreating-with-no-events), [vfio cdev missing](#vfio-cdev-missing-after-a-reboot) |

For a failed workload, inspect `oc -n <namespace> describe pod <pod>` (tenant) and
`oc -n <namespace> get events --field-selector involvedObject.name=<pod>` (tenant).
For unavailable Trustee, inspect `oc -n trustee-operator-system get pods -o wide` (hub),
`oc -n trustee-operator-system describe pod -l app=kbs` (hub) and its ExternalSecrets.

Exec and log streaming into a guest need `debug-initdata`. Switch a pod to it only to diagnose,
then switch back. Debug guests receive the same KBS resources; restrict access.

---

## Scripts and deployment

### Wrong-cluster guard error

`WRONG CLUSTER` or an unset kubeconfig means the client does not match the site target.
Compare `grep server: "$HUB_KUBECONFIG" "$TENANT_KUBECONFIG"` with the `EXPECT_*` URLs.
Overrides must name `--kubeconfig`; the guard never falls back to `~/.kube/config`.

### Control-plane drain is stuck

A MachineConfig rollout waits when a PodDisruptionBudget blocks eviction. After an hour the MCO
marks the node `NodeDegraded` ("failed to drain node") but keeps retrying; the installers then
pause and name the pods whose eviction was refused (from the machine-config-controller log).
A budget whose pods are all unhealthy (for example a logging component with a broken backend)
refuses every eviction and never clears by itself.
**Disruptive:** recovery resumes the rolling reboot; forced deletion can interrupt service.
Inspect the blocked workload's readiness and storage before changing its availability rules:

Hub (`export KUBECONFIG=$HUB_KUBECONFIG`):

```bash
oc get mcp master
oc get pdb -A
oc describe node <draining-node>
oc describe pdb -n <namespace> <pdb>
```

Restore the workload's required healthy replicas or have its owner repair storage/capacity;
do not bypass a PDB without understanding data/availability consequences. A pod that is already
unhealthy can be deleted (`oc delete pod -n <namespace> <pod>`): it restarts on another node and the
drain continues at the MCO's next retry (every 5 minutes). Resume only when
`oc get mcp master` (hub) is Updated and cluster operators are Available.

### Mirror mappings were overwritten

Raw oc-mirror IDMS/ITMS names can replace existing mappings. Always use the mirror
script or tenant step 01, which adds `coco-` prefixes. Recovery is **Disruptive**:

1. Pause rollout: `oc patch mcp master --type merge -p '{"spec":{"paused":true}}'` (hub).
2. Recover `registries.conf` from the rendered MachineConfig on a node that has not rebooted.
3. Build/apply additive `*-restore` IDMS/ITMS, inspect the new rendered config, then unpause:
   `oc patch mcp master --type merge -p '{"spec":{"paused":false}}'` (hub).

### Leftover Pattern CR

A competing Pattern CR can keep retrying GitHub clones. Retire it while deploying
with `RETIRE_PATTERN=true APPLY=true ./scripts/deploy-coco-hub.sh`.

### Vault loader push not Ready

Read the failing PushSecret's status:

| Error | Recovery |
|---|---|
| `secret not managed by external-secrets` | The entry was written outside ESO (`vault kv put`, the Vault UI); ESO will not overwrite it, and the loader stops naming the paths. A fresh install never has such entries. If nothing else maintains an entry, a Vault administrator deletes it, or sets its custom metadata `managed-by=external-secrets` (data untouched); then rerun the step. |
| Timeout | Restore Vault health (Sovereign Core), then rerun; ESO retries. |
| Permission denied | Grant the ESO role write access to hub `secret/data/hub/*`, or tenant `secret/data/<clusterName>/*`. |

The loader cleans its transient objects. After an interrupted run, use
`oc delete pushsecret,secret -n external-secrets -l app.kubernetes.io/managed-by=load-existing-vault` (hub).

### Tenant API down during a reboot

A single-node tenant loses its API on each MachineConfig reboot. Wait for the API
to return and `oc get mcp` (tenant) to show Updated before continuing.

### Pod creation denied by inject-initdata

The selected initdata ConfigMap is missing; injection fails closed. Add the namespace
to `workloadNamespaces`, wait for `oc get cm -n <ns> -l coco.io/type=initdata` (tenant) to show
both profiles, then recreate the pod.

### Vault pod does not start in TDX

A restarted Vault server pod stays in `ContainerCreating`/`CreateContainerError`, or is
denied at admission. Check, in order (hub):

| Check | Fix |
|---|---|
| `oc get cm initdata -n vault` is missing | Admission fails closed: confirm `vault` is in the hub `workloadNamespaces` and the propagate policy is Ready. |
| Trustee log shows no `POST /kbs/v0/attest` for the pod | Quote path: [TDX Quote is empty](#tdx-quote-is-empty), [PCK certificate import fails](#pck-certificate-import-fails). |
| `PolicyDeny` or 401 on `credential`/`security-policy` | Collateral expired ([refresh](operations-runbook.md#refresh-the-tdx-collateral)) or initdata not in RVPS ([coordinated initdata change](operations-runbook.md#coco-initdata-hub-and-tenants-together)). |
| Old pod stuck Terminating (`KillPodSandbox ... ttrpc: closed`) | Confirm on the node that no QEMU process remains for that sandbox, then `oc delete pod <pod> -n vault --force --grace-period=0` (hub). A remaining replica keeps its endpoint because the Service publishes not-ready addresses. |

**Leave TDX when attestation cannot be fixed in time** (quorum at risk): remove the opt-in
label, then delete the failing pod; it restarts under the default runtime.

Hub (`export KUBECONFIG=$HUB_KUBECONFIG`):

```bash
oc label namespace vault coco.io/confidential-workloads-
oc delete pod <pod> -n vault
```

Repeat [step 12](manual-install-hub.md#step-12-move-vault-into-tdx) after the fix.

### Wrong kind returned for clusterpolicy or policy

Kyverno also owns these short names. Use `clusterpolicies.nvidia.com` and
`policies.policy.open-cluster-management.io` for NVIDIA and ACM respectively.

### GPU operator and ClusterPolicy

The GPU operator uses Manual approval; the pinned-InstallPlan approval CronJob runs every
five minutes. If blocked, verify the plan is for the pinned CSV before approving:

Tenant (`export KUBECONFIG=$TENANT_KUBECONFIG`):

```bash
oc get installplan -n nvidia-gpu-operator
oc patch installplan <name> -n nvidia-gpu-operator --type merge -p '{"spec":{"approved":true}}'
oc get csv -n nvidia-gpu-operator
```

Once the pinned CSV succeeds, verify the API retained the sandbox fields. If mode is
`kubevirt` instead of `kata`, re-sync after the operator's CRD is ready:

Tenant (`export KUBECONFIG=$TENANT_KUBECONFIG`):

```bash
oc get clusterpolicies.nvidia.com gpu-cluster-policy -o jsonpath='{.spec.sandboxWorkloads.mode}'
oc patch applications.argoproj.io nvidia-gpu -n openshift-gitops --type merge \
  -p '{"operation":{"sync":{"syncOptions":["Replace=true"]}}}'
```

Expect `kata`, with CC manager and sandbox plugin enabled. **Disruptive:** replacing
ClusterPolicy can restart GPU services; finish before starting confidential GPU workloads.

---

## Host and node

### TDX does not initialise

Missing `/dev/kvm`, TDX/SGX labels or KataConfig, `Operation not supported` from
`kvm_intel`, or GPU CC mode forced off can all follow failed TDX initialization.
Check the BIOS against Intel's [Hardware Setup](https://cc-enabling.trustedservices.intel.com/intel-tdx-enabling-guide/04/hardware_setup/) guide.
Ask the server vendor about supported DIMM population: memory configuration can
prevent SGX/TDX even when BIOS switches are enabled.

### TDX Quote is empty

A 401 with `TDX Quote is empty`, zero enclave allocation and Pending QGS usually
means the SGX plugin failed registration. Its fixed 100m CPU limit can throttle it:

Tenant (`export KUBECONFIG=$TENANT_KUBECONFIG`):

```bash
oc get pods -n intel-device-plugins-operator | grep sgx
oc adm top node
oc get ds -n intel-device-plugins-operator intel-sgx-plugin-sgxdeviceplugin-sample \
  -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
oc get node <node> -o jsonpath='{.status.allocatable}' | tr ',' '\n' | grep sgx
oc get pods -n intel-dcap-operator-system
oc get events -n intel-dcap-operator-system --sort-by=.lastTimestamp | tail
```

Tenant `sgx-plugin-resources` raises resources at admission and through background
mutation of existing DaemonSets. If still `100m`, inspect
`oc logs -n kyverno deploy/kyverno-background-controller` (tenant) for
`sgx-plugin-daemonset-resources-existing` errors. On the hub use `oc` (hub) and namespace
`intel-device-plugins-operator`; opt in with `sgxPluginResources.enabled=true` in the hub profile.
Require enclave/provision > 0 and QGS Running.

### QGS runs but every quote fails

`TDX Quote is empty` while SGX enclave/provision are > 0, QGS is Running and its PCK Secret
exists: QGS looked for its certificate cache before the sidecar created it and now fails every
quote ([known issue](known-issues.md#qgs-can-stay-broken-after-a-node-reboot-tdx-quote-is-empty)).

Hub or tenant, wherever the guest runs:

```bash
p=$(oc get pods -n intel-dcap-operator-system -o name | grep qgs)
oc logs -n intel-dcap-operator-system "$p" -c tdx-qgs | grep -c 'Failed to get quote config'   # > 0
oc logs -n intel-dcap-operator-system "$p" -c tdx-qgs | head -5    # "Error creating directory '/run/dcap/cache/.dcap-qcnl/'"
oc get secret -n intel-dcap-operator-system | grep -- -pck          # the certificate is there
```

Fix: restart only the `tdx-qgs` container. The pod and its in-memory cache, which now holds the
certificate, stay; deleting the pod starts with an empty cache and can lose the same race again.
Guests retry attestation by themselves; restart pods stuck in `CreateContainerError`.

```bash
oc exec -n intel-dcap-operator-system "$p" -c tdx-qgs -- sh -c 'kill 1'
oc get "$p" -n intel-dcap-operator-system -w      # tdx-qgs RESTARTS +1, READY 2/2
```

### GPU pod stuck in ContainerCreating with no events

If GPU verification passes but pods only show repeated `AddedInterface`, inspect CRI-O:

Tenant (`export KUBECONFIG=$TENANT_KUBECONFIG`):

```bash
oc debug node/<node> -q -- chroot /host journalctl -u crio --since -10min \
  | grep -o 'cold plug: GetPodResources failed.*'
```

`PodResources API Get method disabled` requires the GPU profile's feature-gate
workaround on kubelet below 1.34. **Disruptive:** applying its MachineConfig reboots
nodes. Verify `oc debug node/<node> -q -- chroot /host systemctl show kubelet -p DropInPaths` (tenant)
includes `99-podresources-get.conf`.

### vfio cdev missing after a reboot

`pgpu` may remain advertised while `/dev/vfio/devices/` is empty. The sandbox plugin
logs `Unable to add device path to fsnotify watcher`; no GPU evidence reaches KBS.
**Disruptive:** restart vfio-manager, wait for the cdev, then restart the sandbox plugin:

Tenant (`export KUBECONFIG=$TENANT_KUBECONFIG`):

```bash
oc -n nvidia-gpu-operator get pods -o wide | grep -E 'vfio|sandbox'
oc delete pod -n nvidia-gpu-operator -l name=nvidia-vfio-manager
oc debug node/<node> -q -- chroot /host ls /dev/vfio/devices/   # wait for vfioN (~45s)
oc delete pod -n nvidia-gpu-operator -l app=nvidia-kata-sandbox-device-plugin-daemonset
./scripts/tenant/g08-verify-gpu-cc.sh
```

First clear any [stranded GPU](#stranded-gpu-after-a-failed-pod).

### Stranded GPU after a failed pod

- **Symptom.** A failed confidential-GPU pod stays `Terminating`
  (`KillPodSandbox ... InvalidContainerId`) and its replacement is `Pending` with
  `Insufficient nvidia.com/pgpu`.
- **Cause.** The container was never created in the guest, so the sandbox cannot be stopped and
  kubelet never frees the GPU allocation. Any first failure can trigger it, and it then hides
  that failure.
- **Never run `crictl rmp -f` on such a sandbox.** It crashes CRI-O, and only a node reboot
  recovers the node.
- **Fix.** Find out whether a guest still holds the GPU. Identify it by device, not by process
  name (the binary is `/usr/libexec/qemu-kvm`):

  Tenant (`export KUBECONFIG=$TENANT_KUBECONFIG`):

  ```bash
  oc debug node/<node> -q -- chroot /host fuser -v /dev/vfio/devices/vfio0
  ```
  - **Nothing holds it:** the guest is gone. Only then force-delete the pod:
    `oc delete pod -n <ns> <pod> --force --grace-period=0` (tenant). Kubelet frees the GPU within ~30 s.
  - **A `qemu-kvm` holds it** (a replaced pod whose guest is still alive): do not force-delete
    yet; that orphans a running VM that keeps the GPU. Check that the PID is a child of the
    sandbox's `containerd-shim-kata-v2`, then kill it (kata qemu ignores `SIGTERM`; the pod's
    containers are already terminated and the guest disk is ephemeral):

    Tenant (`export KUBECONFIG=$TENANT_KUBECONFIG`):

    ```bash
    oc debug node/<node> -q -- chroot /host kill -KILL <qemu-pid>
    oc debug node/<node> -q -- chroot /host fuser -v /dev/vfio/devices/vfio0   # empty
    oc delete pod -n <ns> <pod> --force --grace-period=0
    ```
    The exiting qemu can take a minute to free its memory.
- Stale sandboxes from failed attempts can keep CRI-O logging `StopPodSandbox` retries; they are
  harmless once their pods are gone, and a node reboot removes them.
  See [known-issues.md](known-issues.md#a-failed-confidential-gpu-pod-strands-the-gpu).

---

## Attestation

### Trustee loops on /auth with no /attest

`/auth` succeeds but no `/attest` follows: the guest got no quote. QGS signs quotes only with the
platform's PCK certificate, so check that every `platform-data` Secret has a matching
`<qe_id>-pck` Secret and that QGS runs (cluster of the guest):

```bash
oc get secrets -n intel-dcap-operator-system -l type=platform-data
oc get secrets -n intel-dcap-operator-system | grep -- '-pck$'
oc get pods -n intel-dcap-operator-system
./build/pattern/scripts/check-pck-expiry.sh
```

A missing or expired certificate: [renew PCK certificates](operations-runbook.md#renew-pck-certificates).
If the quote reaches the KBS but verification fails with collateral errors, run
`check-collateral-expiry.sh` (hub) and [refresh the collateral](operations-runbook.md#refresh-the-tdx-collateral).

### PCK certificate import fails

`dcap-pck.py provision` stops with a clear error; the common ones:

| Error | Fix |
|---|---|
| `INTEL_PCS_API_KEY is not set and no interactive terminal is available` | Write the key to `~/.coco-pattern/pccs_api_key` or export `INTEL_PCS_API_KEY` ([install](install.md#intel-pcs-api-key)). |
| `pcsclient.py not found` | Run `python3 ./build/pattern/scripts/dcap-pck.py tools` once. |
| Intel PCS rejects the request (401/404) | Check the subscription key; a platform must be registered with Intel before its PCK certificate exists. |
| no `platform-data` Secrets | The DCAP operator has not registered the platforms: check `oc get tdxquotegenerationservice` and the operator pods in `intel-dcap-operator-system`. |
| `response bundle platform data does not match current platform-data Secrets` | Platform data changed (new node, TCB recovery): run `provision` again; it exports a fresh request. |

### Guest TLS to the KBS fails

For KBS TLS failure, rerun tenant step 03 and check
`oc get externalsecret kbs-route-cert-eso -n imperative` (tenant) is synced. Coordinate
[measured configuration](operations-runbook.md#coco-initdata-hub-and-tenants-together)
before recreating pods: KBS certificate bytes are part of both initdata profiles.

## Guest image pull

### Guest image pull fails

The guest pulls inside the TEE and ignores the cluster IDMS/ITMS and `registries.conf`.

| guest CDH error | cause | fix |
|---|---|---|
| `Failed to pull image ... from all mirror/mapping locations or original location`, original public hostname in the log | no mirror mapping for that registry | re-run `collect-registry-config.sh` (with `EXTRA_KUBECONFIGS` for tenant-only mirrors), load `registryConfig`, restart the hub KBS pods (`oc -n trustee-operator-system delete pod -l app=kbs`), then the workload pods |
| `400 "plain HTTP request sent to HTTPS port"` | the config marks mirrors `insecure` (image-rs: use HTTP) | regenerate without `--insecure` |
| `401 Not authorized` or `Not authorized: registry.redhat.io/...` | no mirror credentials, or no mapping for that registry | check `$TDX_REGISTRY_AUTH_FILE` (an entry for that host or org), Vault `secret/hub/tdxRegistryAuth` and the `credential` KBS resource; add the tenant mirrors (G3) |
| `error sending request for url` with no HTTP status, image served from a route | missing/wrong mirror CA bytes in initdata | check the trusted CA bundle and regenerate matching hub/tenant initdata; each certificate must have its own `extra_root_certificates` element |
| `secure` works, `insecure-policy` shows the original hostname | one initdata template lacks the image block | both templates must carry it ([hub runbook](operations-runbook.md#change-guest-image-pull-configuration)) |

Check that the resources are served:
`oc get externalsecret -n trustee-operator-system | grep -E 'registry-config|credential'` (hub) shows
`SYNCED=True`.

### Guest pull times out

- **Symptom.** After successful attestation and resource release, the pod fails with
  `Init:CreateContainerError ... context deadline exceeded`. A retry may report
  `PID namespace requested, but sandbox infra container unexpectedly invalid`; that is a
  follow-on error.
- **Cause.** The in-guest pull runs inside CreateContainer. The effective timeout is the lower of
  Kata's `create_container_timeout` and kubelet's `runtimeRequestTimeout` (default
  2 minutes). Kyverno sets Kata's value per pod (`createContainerTimeoutSec`, 7200 s by default), so
  kubelet is normally the limit. Kata's value:
  `oc get pod <pod> -o jsonpath='{.metadata.annotations.io\.katacontainers\.config\.runtime\.create_container_timeout}'` (tenant).
- **Fix.** The GPU profile sets `runtimeRequestTimeout.enabled=true` and
  `runtimeRequestTimeout.value=20m` on its `kubelet-podresources-gate` application. If kubelet
  still shows the default, redeploy the GPU profile.
  **Disruptive:** applying the KubeletConfig the first time reboots the node (MachineConfig change). Kyverno sets Kata's timeout annotation;
  choose both values for the expected pull duration (the smaller wins). Check:
  `oc debug node/<node> -q -- chroot /host grep -o 'runtimeRequestTimeout.*' /etc/kubernetes/kubelet.conf` (tenant).
  Clear a [stranded GPU](#stranded-gpu-after-a-failed-pod) before retrying.

### No space left in the guest

`No space left on device` or layer-unpack failure requires more RAM-backed guest
storage: about half guest RAM. Raise guest memory and the container limit together;
use the [sizing recommendation](runbook-intel-tdx.md#guest-sizing).

### qemu killed by the cgroup OOM killer

`Memory cgroup out of memory: Killed process ... qemu-kvm` means the pod's memory
cgroup cannot contain the VM working set. Raise container request/limit using
[guest sizing](runbook-intel-tdx.md#guest-sizing), then clear the
[stranded GPU](#stranded-gpu-after-a-failed-pod).

---

## Workloads

### CUDA error 803 in the guest

- **Symptom.** Everything up to the image pull succeeds, then vLLM fails with
  `Error 803: system has unsupported display driver / cuda driver combination`
  (logged further up than `EngineCore failed to start`).
- **Cause.** The image's CUDA forward-compatibility `libcuda` (`/usr/local/cuda/compat`) is loaded
  instead of the newer guest driver's library.
- **Fix.** Kyverno injects `LD_LIBRARY_PATH=/usr/lib64:/usr/local/cuda/lib64`
  (`confidentialGpu.containerEnv`). If 803 persists, change the container command so that the
  guest driver libraries win:
  `echo /usr/lib64 >> /etc/ld.so.conf.d/nvidia.conf && ldconfig && <original command>`.

### Agent login loops

- **Symptom.** The CUGA agent UI redirect-loops at login. The agent logs
  `POST /auth/callback 500` and `ImmatureSignatureError: The token is not yet valid (iat)`; the
  identity provider logs successful logins.
- **Cause.** The TDX guest clock runs about 1 s behind and the agent validates JWTs with zero
  leeway.
- **Fix.** The interim `cuga-jwt-leeway` ConfigMap
  ([GPU step G11](manual-install-tenant-gpu.md#g11-move-the-cuga-agent-into-a-tdx-guest-optional)).
  See [known-issues.md](known-issues.md#tdx-guest-clock-offset-breaks-cuga-agent-login).
