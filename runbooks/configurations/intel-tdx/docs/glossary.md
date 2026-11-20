# Glossary

Terms and abbreviations used in these docs.

## Confidential computing

| Term | Meaning |
|---|---|
| **TDX** | Intel Trust Domain Extensions: CPU feature that runs a VM (a trust domain) with encrypted, integrity-protected memory that the host cannot read. |
| **TD** | Trust domain: a VM protected by TDX. Here, the kata guest of a confidential pod. |
| **TEE** | Trusted execution environment: the protected guest (TD) in general terms. |
| **SEAM, TDX module** | The Intel-signed firmware module that implements TDX; loaded by the BIOS SEAM loader. |
| **TME, TME-MT** | Total Memory Encryption and its multi-key variant; TDX needs both, enabled in the BIOS. |
| **SGX** | Intel Software Guard Extensions. TDX uses an SGX enclave (the quoting enclave) to sign quotes. |
| **EPC, PRM** | SGX enclave page cache / processor reserved memory: the memory SGX enclaves run in. |
| **Quote** | Signed evidence of a guest's measurements, produced on the node and sent to the KBS. |
| **QE** | Quoting enclave: the SGX enclave that signs TDX quotes. |
| **QGS** | Quote Generation Service: the node daemon (`tdx-qgs`) that hosts the QE and answers quote requests from guests. |
| **MRTD, RTMR** | TD measurement registers: MRTD measures the initial guest (firmware), RTMR1/RTMR2 the kernel and command line. |
| **MRCONFIGID** | TD register that carries the hash of the guest's `initdata`. |
| **XFAM** | Extended feature mask: the CPU features (AVX-512, AMX, ...) enabled for the guest; part of its measurements. |
| **initdata** | The guest's configuration document (agent policy, KBS address, certificates), measured into MRCONFIGID. Two profiles: locked `initdata` and `debug-initdata`. |
| **CC** | Confidential computing. On a GPU, CC mode isolates the GPU's memory for a confidential guest. |
| **CoCo** | Confidential Containers: the upstream project behind kata confidential pods, Trustee and the guest components. |
| **kata, kata-cc** | Kata Containers runs each pod in its own VM; the `kata-cc` runtime class runs it as a TDX guest (`kata-cc-nvidia-gpu` with a passed-through GPU). |
| **CDH** | Confidential Data Hub: guest component that fetches secrets from the KBS after attestation. |

## Attestation services

| Term | Meaning |
|---|---|
| **Trustee** | The hub's attestation stack: KBS, attestation service and RVPS. |
| **KBS** | Key Broker Service: releases resources (secrets, registry credentials) to a guest only after its evidence passes the attestation and resource policies. |
| **AS** | Attestation service: verifies a quote against reference values. |
| **RVPS** | Reference Value Provider Service: holds the expected measurements (firmware, initdata, GPU). |
| **EAR** | Entity Attestation Result: the signed result of an appraisal that the KBS checks. |
| **PolicyDeny** | KBS log result when a guest attests but the policy refuses a resource. |
| **Reference values (refvals)** | Expected measurement values (MRTD, RTMR, XFAM, initdata, GPU RIM) that evidence is compared against. |

## Intel collateral

| Term | Meaning |
|---|---|
| **PCS** | Intel Provisioning Certification Service: Intel's internet service that issues PCK certificates and collateral. |
| **PCK** | Provisioning Certification Key: the per-platform key whose certificate chains a quote to Intel. |
| **PPID** | Platform provider ID: the identifier of one TDX platform (from its PCK certificate). |
| **Collateral** | The data the KBS needs to verify a quote: TCB info, QE identity and CRLs for every TDX platform type. Loaded from Vault; expires after about 30 days. |
| **DCAP operator** | Intel's TDX DCAP operator: runs QGS from a `TdxQuoteGenerationService` resource and registers each platform offline (`platform-data` Secrets). |
| **Platform data** | Per-platform registration data the DCAP operator exports (encrypted PPID, PCE ID, CPU SVN, PCE SVN, QE ID, platform manifest). Only the PCE ID and platform manifest are sent to Intel PCS to get the PCK certificate. |
| **TCB** | Trusted computing base: firmware and microcode levels of a platform; TCB info says which levels are up to date. |
| **FMSPC** | Family-model-stepping-platform-custom ID: identifies a platform type; TCB info is published per FMSPC. |
| **CRL, OCSP** | Certificate revocation list / Online Certificate Status Protocol: ways to check that a certificate has not been revoked. |
| **PcsClientTool** | Intel's tool that fetches collateral and PCK certificates from PCS; run on the bastion. |

## GPU

| Term | Meaning |
|---|---|
| **RIM, CoRIM** | NVIDIA reference integrity manifests (and their signed container): expected GPU driver and VBIOS measurements. |
| **VBIOS** | The GPU's firmware. |
| **vfio cdev** | The `/dev/vfio/devices/vfioN` device a confidential guest uses to get the passed-through GPU. |
| **pgpu** | `nvidia.com/pgpu`: the resource name of a GPU passed through to a kata guest. |
| **Local verifier** | NVIDIA GPU evidence checked offline in Trustee, without NVIDIA's online service. |

## OpenShift and Sovereign Core

| Term | Meaning |
|---|---|
| **Hub** | The Sovereign Core management cluster: runs Trustee, Vault and ACM. |
| **Tenant (spoke)** | A cluster that runs confidential workloads; "spoke" remains in file and application names. |
| **Bastion** | The admin host with this directory, the mirror tools and the site config. |
| **Connected host** | A host with access to NVIDIA RIM/OCSP services, used to collect GPU reference values. |
| **ACM** | Red Hat Advanced Cluster Management: manages tenants from the hub (policies, placements). |
| **ESO, PushSecret** | External Secrets Operator: syncs Vault values into cluster Secrets; a PushSecret writes a Secret into Vault. |
| **vaultaas** | The tenant's own Vault (Sovereign Core Vault as a service). |
| **IDMS, ITMS** | Image digest / tag mirror sets: redirect image pulls to the mirror registry. |
| **NFD** | Node Feature Discovery: labels nodes with hardware features such as `tdx` and `sgx`. |
| **MC, MCO** | MachineConfig and the Machine Config Operator; a MachineConfig change reboots nodes. |
| **SCC** | Security context constraints: OpenShift pod privilege rules. |
| **SNO** | Single-node OpenShift: every MachineConfig change takes the whole cluster down for a reboot. |
| **Kyverno** | Policy engine used to mutate pods (move them into TDX, inject initdata) and patch operator-managed objects. |
| **CUGA agent** | IBM's agent workload that can run in a TDX guest. |
| **Concert, Compliance center** | IBM's compliance tooling that runs the posture check (`compliance/LLM_TDX_GPU_Check.json`). |
| **Site config** | `deploy/env/<site>/site.env`: every site-specific value (registries, domains, kubeconfigs, CA files). |
