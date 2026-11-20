# Operations runbook

Run from `runbooks/configurations/intel-tdx` in Bash with the [hub](manual-install-hub.md#shell-setup) and
[tenant](manual-install-tenant.md#shell-setup) shell setup (`SITE`, explicit kubeconfigs,
`oc` (hub), `oc` (tenant)). Script headers define all inputs/defaults. **Disruptive** marks reboots
and service/workload outages. Back up material outside the repository with mode 0600.

## TDX collateral and PCK certificates

Two kinds of Intel material keep TDX attestation working, both fetched on the bastion:

| Material | Where it lives | Refresh |
|---|---|---|
| TDX verification collateral (TCB info, QE identity, CRLs) for every TDX platform type | Hub Vault `tdxCollateral` → Secret `trustee-operator-system/tdx-collateral` → KBS (`file://`) | before its earliest `nextUpdate`, about every 30 days |
| PCK certificate of each TDX platform | Secret `<qe_id>-pck` in `intel-dcap-operator-system` on that cluster | after an Intel TCB recovery (new firmware or microcode), when a TDX node is added or replaced, and before it expires |

### Refresh the TDX collateral

**Runs on:** Bastion (Intel PCS, no API key), then Hub. Not disruptive: the KBS mounts the
collateral directly and reads the new file about a minute after the Secret changes, no restart.

```bash
./build/pattern/scripts/collect-dcap-collateral.sh \
  --pcsclient-dir ~/.coco-pattern/intel-dcap/tools/PcsClientTool
ONLY=tdxCollateral APPLY=true ./scripts/load-existing-vault.sh
```

Hub (`export KUBECONFIG=$HUB_KUBECONFIG`):

```bash
oc wait externalsecret/tdx-collateral-eso -n trustee-operator-system --for=condition=Ready --timeout=2m
./build/pattern/scripts/check-collateral-expiry.sh
```

**Verify:** `check-collateral-expiry.sh` reports every TCB info and QE identity valid, and a
sample guest attests ([hub step 11](manual-install-hub.md#step-11-accept-the-hub)). With KBS debug
logging, its attestation claim `earliest_expiration_date` shows the new collateral's date.

**If it fails:** an `invalid type: string` error from KBS means the collector's QE-identity fixup
did not run; rerun the collector. Keep the previous `~/.coco-pattern/dcap-offline/` as a backup.

### Renew PCK certificates

Run [hub step 10](manual-install-hub.md#step-10-pck-certificates) or
[tenant step 06](manual-install-tenant.md#step-06-pck-certificates) again for that cluster.
`dcap-pck.py provision` exports the current platform data, reuses the stored bundles when
nothing changed, and otherwise fetches and imports new certificates and restarts QGS.

**Runs on:** Bastion (Intel PCS, API key), then the cluster. **Disruptive:** QGS restarts.

### Schedule expiry checks

Both checks only read the cluster. Run them weekly, for example from cron on the bastion with
the matching `KUBECONFIG`:

```bash
KUBECONFIG=$HUB_KUBECONFIG ./build/pattern/scripts/check-collateral-expiry.sh
KUBECONFIG=$HUB_KUBECONFIG ./build/pattern/scripts/check-pck-expiry.sh      # and per tenant
```

Each exits non-zero when something is expired or close to it.

## Rotate registry credentials

Update every consumer of the dedicated read-only robots, preserving unrelated credentials.

**Runs on:** Bastion, registries, Hub and every Tenant.
**Disruptive:** `ROTATE=true` immediately invalidates each robot's token; pulls can fail
until redistribution. Tenant pull-secret updates roll kubelet configuration; restarting
guests interrupts workloads. Schedule the operation and retain protected backups.

```bash
ROTATE=true APPLY=true QUAY_TOKEN_FILE=<token-file> ./scripts/create-tdx-registry-credentials.sh
QUAY_HOST=$MIRROR_REGISTRY ORGS="<mirror orgs>" QUAY_TOKEN_FILE=<mirror-token-file> \
  ROTATE=true APPLY=true ./scripts/create-tdx-registry-credentials.sh
python3 scripts/lib/registry-auth.py check "$TDX_REGISTRY_AUTH_FILE"
ONLY=tdxRegistryAuth APPLY=true ./scripts/load-existing-vault.sh
# Guests receive the new tokens only from a restarted KBS (it copies its resources at start):
oc --kubeconfig=$HUB_KUBECONFIG delete pod -n trustee-operator-system -l app=kbs
# Repeat with each tenant's site/kubeconfig:
./scripts/tenant/00-add-mirror-pull-creds.sh
APPLY=true ./scripts/tenant/00-add-mirror-pull-creds.sh
APPLY=true ./scripts/tenant/02-ensure-gitops-repo-creds.sh
```

Rotate once per registry host (combine organizations if both hosts are the same).
Step 00 updates exact `host/org` keys for the **same user**, preserving keys held by
another user and unrelated keys. Inspect `~` updated and `=` preserved entries: a
conflicting user needs an administrator's explicit resolution. For ACM tenants, verify
repository credentials reconcile from `tdx-registry-auth`; step 00 is still manual.
The name check cannot prove read-only permissions; verify those in the registry.

**Verify:** loader succeeds, `credential-eso` synced, step 00 reports no changes on repeat,
new node/ArgoCD/guest pulls work. Recreate confidential workloads in their maintenance
window so they consume the replacement resource.

**If it fails:** check exact registry/org scope and ESO sync before revoking any additional
credential. A backup file cannot restore an invalidated robot token; issue a valid token
and redistribute it.

## Change guest image-pull configuration

Update mutable KBS resources before any initdata references them.

**Runs on:** Bastion, reads Hub/Tenant and writes Hub Vault.
**Disruptive:** restart affected guests after the change.

```bash
EXTRA_KUBECONFIGS=$TENANT_KUBECONFIG ./scripts/collect-registry-config.sh
ONLY=registryConfig APPLY=true ./scripts/load-existing-vault.sh
oc --kubeconfig "$HUB_KUBECONFIG" -n trustee-operator-system delete pod -l app=kbs --wait=true  # KBS reads resources at start
oc --kubeconfig "$HUB_KUBECONFIG" -n trustee-operator-system rollout status deploy/trustee-deployment --timeout=300s
```

For multiple tenants, `EXTRA_KUBECONFIGS` is colon-separated. Mirror mappings/credentials
are not measured; CA bytes and the `cdh.toml` image block are. If collection changes
`mirror-ca.pem`, coordinate it using the next procedure. Both initdata templates must
carry the image block. Deploy Vault paths and KBS `secretResources` before guests use them.

**Verify:** `registry-config`/`credential` ExternalSecrets synced and restarted guests
pull over HTTPS from the intended mirrors.

**If it fails:** [guest image-pull diagnosis](troubleshooting.md#guest-image-pull-fails).

## Check for drift

Report what differs between the published charts and the clusters. Read-only.

**Runs on:** Bastion, reads the Hub and the Tenant.

```bash
./scripts/report-drift.sh                       # hub and the site's tenant
TARGETS=hub ./scripts/report-drift.sh           # hub only
TENANT_OC="oc --kubeconfig=<other tenant kubeconfig>" EXPECT_TENANT_API_SERVER=<its API URL> \
  ./scripts/report-drift.sh                     # another tenant
```

Inspect chart pins, sync/health, hand-edited objects and both initdata hashes.
Missing or undecodable initdata is drift. Suggested fixes are not executed; inspect
any reboot or measured-configuration change before applying it.

**Verify:** exit code 0 and `no drift`. Exit code 2 means drift was found.

**If it fails:** exit code 1 with `WRONG CLUSTER`: see
[Wrong-cluster guard error](troubleshooting.md#wrong-cluster-guard-error).

## coco-initdata: hub and tenants together

Coordinate all measured changes: KBS certificate/URL, mirror CA and guest configuration. Matching chart versions alone do not guarantee identical bytes.

**Runs on:** Bastion, then Hub and every Tenant in one window.
**Disruptive:** guests starting or re-attesting during a hub/tenant mismatch can be denied.
Do not start/restart confidential workloads during the rollout gap, including the hub
Vault pods ([Vault depends on hub attestation](known-issues.md#hub-vault-depends-on-hub-attestation)).

1. Note both initdata hashes printed by `report-drift.sh` (lines `hash`).
2. Load required Vault/KBS resources first. For certificate/CA changes, wait for the new hub
   Secrets and copy them into **every** tenant Vault. For a changed mirror CA, load
   `ONLY=mirrorCA APPLY=true ./scripts/load-existing-vault.sh` on the hub first.
   ```bash
   APPLY=true ./scripts/tenant/03-load-kbs-route-cert.sh
   APPLY=true ./scripts/tenant/03b-copy-hub-secrets-to-vaultaas.sh
   ```
3. Deploy/sync hub `coco-initdata`; its PostSync generator must re-render **both** profiles.
   Confirm RVPS contains the new hashes. Deploy/sync each tenant's `coco-initdata` and wait
   for the generator and namespace propagation; an unchanged chart pin still needs a sync
   after measured input changes.
4. Compare each tenant with the hub, then restart and accept workloads:
   ```bash
   ./scripts/report-drift.sh
   APPLY=true ./scripts/tenant/08-verify-attestation.sh
   ```

**Verify:** both `initdata` and `debug-initdata` hashes equal the hub on every tenant,
RVPS has those hashes, restarted samples Ready, attestation/resource release and application
checks pass. Shared log counts alone are insufficient.

**If it fails:** never hand-edit generated ConfigMaps. Restore the previous measured inputs on the hub and
every tenant together; there is no documented dual-hash rollout switch.
