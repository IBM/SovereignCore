# Intel TDX pattern for IBM Sovereign Core

Intel TDX confidential containers and optional NVIDIA Hopper confidential GPUs for
IBM Sovereign Core, based on the Red Hat CoCo validated pattern. **Beta**: security
and vendor-support limitations apply.

## Install

Installation is one script per role, run from the landing zone. Prepare the site first, as described in the
[installation guide](docs/install.md#prepare).

```bash
export SITE=<site>                                    # deploy/env/<site>/site.env
APPLY=true ./scripts/install-hub.sh                   # once per hub
APPLY=true ./scripts/install-tenant.sh                # per tenant; PROFILE=gpu for confidential GPUs
APPLY=true ./scripts/install-tenant.sh --resume       # after a pause or a failure, continue where it stopped
```

Without `APPLY=true` each script prints its plan, with the disruptive steps marked. The scripts
stop with instructions for the inputs only you can supply: the Intel PCS API key, your
confirmation before platform data is sent to Intel PCS, the read-only registry credential and GPU
reference values.

The [step reference](docs/install.md#step-reference) says what each step does and how to check
it; `--only <step>` runs one step again.

## Data sent to Intel

Only the landing zone contacts Intel, through the Intel Provisioning Certification Service (Intel PCS,
`api.trustedservices.intel.com`); the hub and the tenants never do.

- **PCK certificates** (hub step 10, tenant step 06, PCK renewal): for each TDX platform, one
  request to `/sgx/certification/v4/pckcerts` with the platform's PCE ID and platform manifest, and
  your Intel PCS API key. The platform manifest, prepared by the BIOS, describes every CPU of the
  platform and carries the platform's shared keys, encrypted with the public key of Intel's
  registration service. Intel PCS forwards it to the Intel SGX and Intel TDX Registration Service for
  Scalable Platforms, which issues the PCK certificate. In the terms of the
  [Intel TDX enabling guide](https://cc-enabling.trustedservices.intel.com/intel-tdx-enabling-guide/02/infrastructure_setup/#platform-registration)
  this is an *indirect registration*: the registration service does not store the platform manifest,
  so every later PCK request sends it again. Once a platform is registered indirectly, a direct
  registration needs an SGX Factory Reset in the BIOS first. The other values the DCAP operator
  exports (encrypted PPID, CPU SVN, PCE SVN, QE ID) stay on the landing zone. The same run then
  downloads, without the API key, the TCB info for the platform's FMSPC (Family-Model-Stepping-Platform-CustomSKU,
  returned by Intel PCS with the certificates) and the PCK CRLs.
- **Verification collateral** (hub step 5e, collateral refresh): TCB info, QE identity and CRLs,
  downloaded anonymously for the whole platform family. No API key and no data about your
  platforms are sent.

Before the first PCK request the installers pause and describe what is collected, sent and
stored; create `~/.coco-pattern/intel-pcs-consent` on the landing zone to confirm.

The results are cached in the clusters (PCK certificate Secrets, KBS collateral), so attestation
itself never calls Intel PCS.

## Compliance check

`compliance/LLM_TDX_GPU_Check.json` is a Compliance center Workflows workflow that checks every
LLM inference pod on a tenant: confidential GPU runtime, confidential GPU only, a TDX node with the
GPU in CC mode, and the hub's locked initdata. It uploads the result to the Compliance center as
an assessment. It checks configuration, not attestation evidence.

Zip the JSON and import it in Compliance center Workflows (**Workflows → Import**), then set the
tenant and hub API URLs and credentials:
[import](docs/runbook-intel-tdx.md#import-the-compliance-check) ·
[variables](docs/compliance-workflow.md).

## Documentation

[Intel TDX runbook](docs/runbook-intel-tdx.md) (versions, hardware, air gap) ·
[architecture](docs/architecture.md) · [known issues](docs/known-issues.md) ·
[operations](docs/operations-runbook.md) · [troubleshooting](docs/troubleshooting.md) ·
[compliance check](docs/compliance-workflow.md) ·
[glossary](docs/glossary.md)
