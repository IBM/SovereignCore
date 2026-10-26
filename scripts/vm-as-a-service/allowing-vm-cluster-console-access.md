# Allowing VM Console Access to the VM Cluster

This guide describes how to allow the VM Dashboard to reach the shared VM cluster, so that VNC and Serial consoles work. Use the [allow-vm-cluster-console-access.sh](./allow-vm-cluster-console-access.sh) script.

## Overview

The VM Dashboard connects to the shared VM cluster API server to provide VNC and Serial consoles. Outbound traffic from the `sovereign-ui` namespace on the hub cluster is blocked by default, so the API server IP of the VM cluster must be added to the allowed list. Without it, console connections fail.

The script adds the IP to the hub cluster configuration and applies the change.

**When to run:**
- Once, after the shared VM cluster is created.
- Again, if the API server IP of the VM cluster changes.
- With `--revert`, when the VM cluster is removed.

Only one VM cluster is supported.

## Prerequisites

- `oc` CLI logged in to the Hub cluster
- Write access to the `openshift-gitops` namespace (to update the `environment-config` ConfigMap, restart the repo-server deployment, and sync ArgoCD Applications)
- [`yq`](https://github.com/mikefarah/yq) v4 (mikefarah) and `dig` (or `getent`)

**Installation of yq:**
```bash
# macOS
brew install yq

# RHEL/Fedora
sudo dnf install yq   # or download the binary from the yq releases page
```

## Using the script

[allow-vm-cluster-console-access.sh](./allow-vm-cluster-console-access.sh) does the following:

1. Finds the VM cluster (the only ManagedCluster with the VM-enabled label) and checks that it is joined and available.
2. Resolves the API server IP from the ManagedCluster URL.
3. Adds `<ip>/32` to `sovereignUi.managedClusterApiCidrs` in `cluster-config.yaml` (skipped if already listed).
4. Reloads the ArgoCD repo-server, syncs the parent and `sovereign-ui-*` ArgoCD Applications, and waits for `Synced` / `Healthy`.
5. Verifies that the `EgressFirewall` in the `sovereign-ui` namespace contains the new `cidrSelector` rule (TCP port 6443).

**Usage:**
```bash
./allow-vm-cluster-console-access.sh [OPTIONS]
```

**Options:**

| Option | Description |
|---|---|
| `-c, --cluster NAME` | ManagedCluster name (e.g., `claas-vm-cluster`). If omitted, the only ManagedCluster with the VM-enabled label is used. The script stops if there is none or more than one. |
| `--ip IP` | Use this IP instead of resolving the API hostname. Useful with `--revert` when the ManagedCluster no longer exists. |
| `-a, --application NAME` | ArgoCD Application to sync (e.g., `sovereign-ui-example`). Default: auto-detect the Application named `sovereign-ui-*`. If several exist, the script stops and asks for this option. |
| `--revert` | Remove the entry instead of adding it, then sync the Application. Requires `-c` or `--ip`. |
| `-d, --dry-run` | Show the change to `cluster-config.yaml` without applying it. |
| `--no-sync` | Update the ConfigMap only; do not sync the ArgoCD Application. |
| `-h, --help` | Show the help message. |

**Examples:**
```bash
# Show what would change
./allow-vm-cluster-console-access.sh -c claas-vm-cluster -d

# Allow console access (the VM cluster is detected automatically)
./allow-vm-cluster-console-access.sh

# Specify the VM cluster explicitly
./allow-vm-cluster-console-access.sh -c claas-vm-cluster

# Specify the ArgoCD Application explicitly
./allow-vm-cluster-console-access.sh -c claas-vm-cluster -a sovereign-ui-example
```

The script saves the previous `cluster-config.yaml` to a temporary file and prints its path before it updates the ConfigMap.

**Environment settings:** The names of the ConfigMap, namespaces, `EgressFirewall`, parent Application name, ArgoCD Application prefix and the VM cluster label are variables at the top of the script. Adjust them there if your environment differs.

After the script completes, do the [smoke test](#smoke-test-the-vnc-console).

## Smoke test the VNC console

### CLI verification (optional)

You can confirm that the rule has been applied to the `EgressFirewall`:

```bash
oc get egressfirewall default -n sovereign-ui -o yaml | grep -A5 cidrSelector
```

### UI smoke test

1. Open the VM Dashboard UI in a browser.
2. Navigate to a VM instance hosted on the VM cluster.
3. Open the **VNC Console** or **Serial Console** tab.
4. Confirm that the WebSocket connection is established (no `502 Bad Gateway` and no immediate disconnect).

## Rollback and removal

If the change causes unexpected issues, or when the VM cluster is removed, run the script with `--revert` to remove its entry.

```bash
# Show what would change
./allow-vm-cluster-console-access.sh --revert -c claas-vm-cluster -d

# Remove the entry
./allow-vm-cluster-console-access.sh --revert -c claas-vm-cluster

# If the ManagedCluster no longer exists, specify the IP
./allow-vm-cluster-console-access.sh --revert --ip 192.0.2.10
```

Leaving a stale IP entry is harmless because the IP is no longer reachable, but it should be cleaned up.
## Troubleshooting

### Console still fails after the EgressFirewall has been updated

If the VNC or Serial console still shows "Connection lost unexpectedly" after the script has run successfully and the `EgressFirewall` contains the expected `cidrSelector` rule, the vm-service-broker may have started before the VM cluster PlacementDecision existed. In this case, the `console-credentials` endpoint panics on every request and the Portal receives a 500 error instead of a token.

Check the broker logs for either of these signatures:

```bash
oc logs -n vm-service-broker -l app=vm-service-broker --tail=200 | \
  grep -E "console-credentials handler disabled|nil pointer dereference"
```

If either message appears, restart the broker deployment. The PlacementDecision already exists by the time a VM cluster is usable, so the restart initializes the handler correctly:

```bash
oc rollout restart deployment vm-service-broker-deployment -n vm-service-broker
oc rollout status deployment vm-service-broker-deployment -n vm-service-broker
```

Confirm that the new pod logs contain `"Console-credentials endpoint handler initialized"` with a `clusterNamespace` field. After that, retry the [smoke test](#smoke-test-the-vnc-console).

This is a known issue in version 1.3.0. The restart workaround above is required in this version. It is tracked in [sov-core-tracker#558](https://github.ibm.com/Sovereign-Core/sov-core-tracker/issues/558) and will not be necessary in the next release.