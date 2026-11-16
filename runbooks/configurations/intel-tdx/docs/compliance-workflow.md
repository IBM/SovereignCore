# Compliance check workflow

`compliance/LLM_TDX_GPU_Check.json` is a Compliance center Workflows workflow. It reads the
tenant and the hub through their Kubernetes APIs and uploads one assessment to the Compliance
center. The check passes only if every non-terminating GPU-requesting LLM pod:

- runs with a RuntimeClass whose handler is the confidential GPU runtime,
- has a confidential GPU and no plain GPU,
- runs on a node labelled TDX whose GPU is in CC mode and ready,
- carries `cc_init_data` byte-identical to the hub's locked `initdata`.

It checks configuration, not attestation evidence ([known issues](known-issues.md#compliance-check-no-attestation-evidence)).
Import it as described in the [runbook](runbook-intel-tdx.md#import-the-compliance-check).

## What it reads

| block | request | credential |
|---|---|---|
| `HTTPRequest_1` | `GET /api/v1/namespaces/<llm_namespace>/pods?labelSelector=<llm_pod_selector>` | `spoke_ocp_auth` |
| `HTTPRequest_2` | `GET /apis/node.k8s.io/v1/runtimeclasses` | `spoke_ocp_auth` |
| `HTTPRequest_3` | `GET /api/v1/nodes?labelSelector=<tdx_label>=true` | `spoke_ocp_auth` |
| `HTTPRequest_6` | `GET /api/v1/namespaces/<initdata_namespace>/configmaps/<expected_initdata>` | `hub_ocp_auth` |
| `IBM_1` | uploads `assessment_result` to the Compliance center | `concert_auth_key` |

The tenant token therefore needs `list` on pods in `llm_namespace` and on the cluster-scoped
runtimeclasses and nodes; the hub token needs `get` on that one ConfigMap. Read-only access is
enough.

## Variables

Values are expressions: string values keep their double quotes (`"llms"`, not `llms`).

### Required inputs

| variable | value |
|---|---|
| `SpokeHostname` | Tenant API URL, `https://api.<tenant-cluster-domain>:6443` (`EXPECT_TENANT_API_SERVER` in `site.env`). |
| `HubHostname` | Hub API URL, `https://api.<hub-cluster-domain>:6443` (`EXPECT_HUB_API_SERVER`). |
| `spoke_ocp_auth` | Compliance center authentication of type Bearer token holding the tenant token, as `<user>@local/<name>`. |
| `hub_ocp_auth` | Bearer token authentication for the hub token. |
| `concert_auth_key` | Concert API key authentication to the Compliance center. |

### Optional inputs

The defaults match this pattern's deployment; change them only if your tenant differs.

| variable | default | meaning |
|---|---|---|
| `llm_namespace` | `llms` | Namespace of the LLM inference pods. |
| `llm_pod_selector` | `kserve.io/component=workload` | Label selector for the inference pods; same as `confidentialGpu.podSelector` of the Kyverno policy. |
| `expected_handler` | `kata-tdx-nvidia-gpu` | RuntimeClass handler a pod's runtime class must have (runtime class `kata-cc-nvidia-gpu`). |
| `expected_initdata` | `initdata` | Name of the hub ConfigMap holding the locked initdata; `debug-initdata` pods fail. |
| `initdata_namespace` | `imperative` | Hub namespace of that ConfigMap. |
| `gpu_resource` | `nvidia.com/pgpu` | Confidential GPU resource; each pod needs at least one. |
| `plain_gpu_resource` | `nvidia.com/gpu` | Plain GPU resource; a pod with it in any container, init containers included, fails. |
| `tdx_label` | `intel.feature.node.kubernetes.io/tdx` | Node label that must be `true` (set by NFD). |
| `cc_mode_label` | `nvidia.com/cc.mode.state` | Node label that must be `on`. |
| `cc_ready_label` | `nvidia.com/cc.ready.state` | Node label that must be `true`. |
| `oscal_environment` | `ControlPlane_1.0.0` | `target` property of the assessment: the Compliance center environment. |
| `oscal_profile_name` | `profile_llm_tdx_gpu` | Compliance profile the assessment reports against. |
| `oscal_target_type` | `MSP-Controlled Confidential Computing` | `target_type` property of the assessment. |
| `oscal_check_ids` | `msp_confidential_computing_runtime_validation_check` | Comma-separated control check IDs that receive the result; empty fails the run. |
| `data_type` | `compliance_posture` | Upload data type. |

### Set by the workflow

Leave these empty; the blocks fill them during a run and the run panel shows them.

| variable | set by | content |
|---|---|---|
| `llm_pods` | `Resolve_LlmWorkload` | JSON list of the assessed pods: name, runtime class, node, initdata annotation, GPU limits. |
| `llm_cc_init_data` | `Resolve_LlmWorkload` | JSON list of each pod's `cc_init_data` annotation, in `llm_pods` order. |
| `check_runtime` | `Check_ConfidentialRuntime` | Verdict for the runtime check. |
| `check_gpu` | `Check_ConfidentialGpuPassthrough` | Verdict for the GPU check. |
| `check_platform` | `Check_PlatformTdxAndGpuCcMode` | Verdict for the node check. |
| `check_initdata` | `Check_LockedMeasuredBootPolicy` | Verdict for the initdata check. |
| `assessment_result` | `Build_AssessmentResult` | The OSCAL assessment uploaded by `IBM_1`. |
| `result` | `Assign_2` | Upload response. |

A run fails instead of reporting when no non-terminating GPU-requesting pod matches, when the
hub ConfigMap has no `INITDATA`, or when `oscal_check_ids` is empty.
