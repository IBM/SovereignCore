# Monitoring Setup for Datastore for PostgreSQL

> **Note:** This document applies to version 1.3.0 only.

This document describes how to enable metrics collection and open the monitoring dashboard for Datastore for PostgreSQL on OpenShift.

## Prerequisites

The target cluster is the OpenShift cluster where Datastore for PostgreSQL is deployed. The setup script creates the monitoring resources in this cluster and detects the PostgreSQL clusters running on it.

Log in to the target OpenShift cluster before running the setup script:

```bash
oc login <cluster-api-url>
```

The following tools must also be installed on your machine:

| Tool | Version | Notes |
|------|---------|-------|
| `bash` | 4.0 or later | macOS ships with bash 3 — install via `brew install bash` |
| `oc` or `kubectl` | any | Must be logged in to the target cluster |
| `python3` | 3.6 or later | Required for dashboard generation |

---

## Setup

### 1. Run the setup script

Run `setup-dbaas-monitoring.sh` from the root of the repository. The script auto-detects all Datastore for PostgreSQL clusters in the target OpenShift cluster and creates the following resources:

- **PodMonitor** for each PostgreSQL instance pod (port 9187)
- **PodMonitor** for each PgBouncer pooler pod (port 9127)
- **NetworkPolicy** allowing Prometheus to scrape metrics
- **PersesDashboard CR** registering the dashboard with the OpenShift Console (`openshift-cluster-observability-operator` namespace)

```bash
./scripts/setup-dbaas-monitoring.sh
```

The script is idempotent — running it multiple times on the same cluster is safe.

> **Note:** The dashboard is registered as a `PersesDashboard` CR (`perses.dev/v1alpha1`), which requires the Cluster Observability Operator with a running Perses instance (`perses-0` pod in the `openshift-cluster-observability-operator` namespace). This is available on OCP 4.20+.

#### Common options

| Option | Description | Example |
|--------|-------------|---------|
| `-t <tenant_id>` | Tenant ID attached to all metrics | `-t acme-corp` |
| `-s <suffix>` | Resource name suffix to avoid conflicts with service-broker-managed resources | `-s 1.3.0` |
| `-n <namespace>` | Restrict to a specific namespace | `-n nova-system-prod` |
| `-c <cluster>` | Restrict to a specific Cluster CR | `-c nova-pg` |
| `-k <kubeconfig>` | Path to kubeconfig file | `-k ~/.kube/my-cluster` |
| `--dry-run` | Print generated YAML without applying | |

#### Example: specify tenant ID and suffix

```bash
./scripts/setup-dbaas-monitoring.sh -t acme-corp -s 1.3.0
```

#### Example: dry-run to review generated resources before applying

```bash
./scripts/setup-dbaas-monitoring.sh --dry-run
```

#### Example: target a specific namespace and cluster

```bash
./scripts/setup-dbaas-monitoring.sh -n nova-system-prod -c nova-pg -t acme-corp
```

On success, the script prints the dashboard URL:

```
=== Done ===

-----------------------------------------------------------
 How to open the dashboard
-----------------------------------------------------------
 1. Open the OpenShift Console in your browser:
      https://console-openshift-console.apps.<cluster-domain>

 2. In the left navigation, go to:
      Observe -> Dashboards (Perses)

 3. In the Project dropdown, select:
      openshift-cluster-observability-operator

 4. Select 'Datastore for PostgreSQL' from the dashboard dropdown.

 5. Choose your Namespace and Cluster from the dropdowns at the top.
-----------------------------------------------------------
```

---

## Monitoring Dashboard

### 2. Open the OpenShift Console

Open the URL printed by the setup script, or retrieve it manually:

```bash
oc get route console -n openshift-console -o jsonpath='https://{.spec.host}'
```

### 3. Navigate to the dashboard

1. In the left navigation menu, click **Observe** → **Dashboards (Perses)**.
2. In the **Project** dropdown at the top of the page, select **openshift-cluster-observability-operator**.
3. In the dashboard dropdown, select **Datastore for PostgreSQL**.
4. Use the **Namespace** and **Cluster** dropdowns at the top to filter by instance.

The dashboard contains the following panels:

| Section | Panels |
|---------|--------|
| **Overview** | PostgreSQL Up, Replication Lag, Total Connections, Waiting Backends |
| **Transactions** | Commits/sec, Rollbacks/sec |
| **Cache & I/O** | Cache Hit Rate, Database Size |
| **Replication** | Replication Lag (seconds), Streaming Replicas |
| **Deadlocks & Errors** | Deadlocks/sec, Temp Files/sec |

---

## Troubleshooting

### Metrics targets are down (`context deadline exceeded`)

The NetworkPolicy may not allow Prometheus to reach the pods.
Re-run the setup script to ensure the NetworkPolicy is applied:

```bash
./scripts/setup-dbaas-monitoring.sh
```

### Dashboard does not appear in the dropdown

First, verify the `PersesDashboard` CR was created and reconciled successfully:

```bash
oc get persesdashboard dbaas-postgresql-manual -n openshift-cluster-observability-operator
oc describe persesdashboard dbaas-postgresql-manual -n openshift-cluster-observability-operator
```

Check that the Perses pod is running:

```bash
oc get pods -n openshift-cluster-observability-operator | grep perses
```

If the CR exists but the dashboard still does not appear, hard-reload the page (`Cmd+Shift+R` on macOS).

### `"Could not parse JSON data"` error in the dashboard view

This error occurs when the dashboard ConfigMap format does not match what the OpenShift Console expects. As of OCP 4.20, the console uses **Perses** (via the Cluster Observability Operator) instead of a Grafana-compatible ConfigMap.

The setup script registers a `PersesDashboard` CR. If you see this error after upgrading OCP or updating the script, re-run the setup script to replace any stale ConfigMap with the correct CR:

```bash
# Remove the old ConfigMap if it still exists
oc delete configmap dashboard-nova-postgresql -n openshift-config-managed --ignore-not-found

# Re-apply with the current script
./scripts/setup-dbaas-monitoring.sh
```
