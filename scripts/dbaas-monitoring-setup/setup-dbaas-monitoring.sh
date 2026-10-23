#!/usr/bin/env bash
# setup-dbaas-monitoring.sh
#
# Generates and applies resources required for Datastore for PostgreSQL metrics collection.
#
# Resources created:
#   1. PodMonitor (instance) — scrapes postgres instance pods on port 9187
#   2. PodMonitor (pooler)   — scrapes pgbouncer pooler pods on port 9127
#   3. NetworkPolicy         — allows ingress from openshift-user-workload-monitoring on ports 9187/9127
#   4. PersesDashboard (dbaas-postgresql-manual) — adds Datastore for PostgreSQL dashboard to OpenShift Console Observe -> Dashboards
#
# Usage:
#   ./setup-dbaas-monitoring.sh [OPTIONS]
#
# Options:
#   -n <namespace>       Target namespace (default: auto-detect all namespaces with Datastore Cluster CRs)
#   -c <cluster>         Target Cluster CR name within the namespace (default: all Cluster CRs in the namespace)
#   -t <tenant_id>       Tenant ID to attach to all metrics (default: "default")
#   -s <suffix>          Suffix appended to all generated resource names to avoid conflicts with
#                        resources created by postgres-service-broker (e.g. "1.3.0", default: "manual")
#   -k <kubeconfig>      Path to kubeconfig (default: KUBECONFIG env var or ~/.kube/config)
#   --dry-run            Print generated YAML to stdout without applying
#   --monitoring-ns      Namespace where Prometheus runs (default: openshift-user-workload-monitoring)
#   --monitoring-label   Label selector for Prometheus namespace (default: network.openshift.io/policy-group=monitoring)
#   -h                   Show this help

set -euo pipefail

# ---------- Preflight checks ----------
preflight_check() {
  local errors=0

  # bash version check (mapfile requires bash 4+)
  if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: bash 4 or later is required (current: ${BASH_VERSION})" >&2
    echo "       On macOS: brew install bash" >&2
    errors=$((errors + 1))
  fi

  # kubectl or oc check
  if ! command -v kubectl &>/dev/null && ! command -v oc &>/dev/null; then
    echo "ERROR: kubectl or oc is not installed" >&2
    errors=$((errors + 1))
  else
    local kube_cmd
    kube_cmd=$(command -v oc 2>/dev/null || command -v kubectl)
    echo "INFO: using ${kube_cmd}"
  fi

  # python3 check
  if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is not installed (required for dashboard generation)" >&2
    errors=$((errors + 1))
  else
    echo "INFO: $(python3 --version)"
  fi

  if [[ $errors -gt 0 ]]; then
    echo "" >&2
    echo "Preflight check failed with ${errors} error(s). Please fix them and retry." >&2
    exit 1
  fi

  # cluster connectivity check (must come after kctl wrapper is defined, called from main)
  if ! kctl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to the cluster. Run 'oc login' or check your kubeconfig." >&2
    exit 1
  fi
  echo "INFO: cluster connection OK"
}

# ---------- Defaults ----------
TARGET_NAMESPACES=()
TARGET_CLUSTER=""
TENANT_ID="default"
RESOURCE_SUFFIX="manual"
KUBECONFIG_OPT=""
DRY_RUN=false
MONITORING_LABEL_KEY="network.openshift.io/policy-group"
MONITORING_LABEL_VAL="monitoring"
MONITORING_NS="openshift-user-workload-monitoring"

# ---------- Help ----------
usage() {
  grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------- Argument parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) TARGET_NAMESPACES+=("$2"); shift 2 ;;
    -c) TARGET_CLUSTER="$2"; shift 2 ;;
    -t) TENANT_ID="$2"; shift 2 ;;
    -s) RESOURCE_SUFFIX="$2"; shift 2 ;;
    -k) KUBECONFIG_OPT="--kubeconfig=$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --monitoring-ns) MONITORING_NS="$2"; shift 2 ;;
    --monitoring-label)
      MONITORING_LABEL_KEY="${2%%=*}"
      MONITORING_LABEL_VAL="${2##*=}"
      shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# ---------- kubectl / oc wrapper ----------
kctl() {
  if command -v oc &>/dev/null; then
    oc ${KUBECONFIG_OPT} "$@"
  else
    kubectl ${KUBECONFIG_OPT} "$@"
  fi
}

# ---------- Verify Prometheus namespace label ----------
check_monitoring_ns() {
  local label
  # kubectl jsonpath cannot handle keys containing '/'; fall back to python3 or jq
  if command -v python3 &>/dev/null; then
    label=$(kctl get namespace "$MONITORING_NS" -o json 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['metadata']['labels'].get('${MONITORING_LABEL_KEY}',''))" 2>/dev/null || true)
  elif command -v jq &>/dev/null; then
    label=$(kctl get namespace "$MONITORING_NS" -o json 2>/dev/null \
      | jq -r ".metadata.labels[\"${MONITORING_LABEL_KEY}\"] // empty" 2>/dev/null || true)
  else
    # fallback: skip check
    label="$MONITORING_LABEL_VAL"
  fi
  if [[ "$label" != "$MONITORING_LABEL_VAL" ]]; then
    echo "WARNING: namespace '$MONITORING_NS' does not have label '$MONITORING_LABEL_KEY=$MONITORING_LABEL_VAL'." >&2
    echo "         Adjust with --monitoring-ns / --monitoring-label if needed." >&2
  fi
}

# ---------- Auto-discover target namespaces ----------
discover_namespaces() {
  kctl get clusters.nova.ibm.com -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null \
    | sort -u
}

# ---------- Generate: PodMonitor (instance) ----------
gen_podmonitor_instance() {
  local ns="$1"
  local cluster_name="$2"
  local instance_id="$3"
  cat <<EOF
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: ${cluster_name}-instance-metrics-${RESOURCE_SUFFIX}
  namespace: ${ns}
  labels:
    nova.ibm.com/managed-by: setup-dbaas-monitoring
    nova.ibm.com/cluster: ${cluster_name}
spec:
  selector:
    matchLabels:
      nova.ibm.com/cluster: ${cluster_name}
      nova.ibm.com/podRole: instance
  podMetricsEndpoints:
    - port: metrics
      scheme: http
      relabelings:
        - targetLabel: instance_id
          replacement: ${instance_id}
          action: replace
        - targetLabel: tenant_id
          replacement: ${TENANT_ID}
          action: replace
        - sourceLabels: [__meta_kubernetes_pod_label_nova_ibm_com_instanceName]
          targetLabel: pod
          action: replace
EOF
}

# ---------- Generate: PodMonitor (pooler) ----------
gen_podmonitor_pooler() {
  local ns="$1"
  local pooler_name="$2"
  local cluster_name="$3"
  local instance_id="$4"
  cat <<EOF
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: ${pooler_name}-metrics-${RESOURCE_SUFFIX}
  namespace: ${ns}
  labels:
    nova.ibm.com/managed-by: setup-dbaas-monitoring
    nova.ibm.com/cluster: ${cluster_name}
spec:
  selector:
    matchLabels:
      nova.ibm.com/podRole: pooler
      nova.ibm.com/poolerName: ${pooler_name}
  podMetricsEndpoints:
    - port: metrics
      scheme: http
      relabelings:
        - targetLabel: instance_id
          replacement: ${instance_id}
          action: replace
        - targetLabel: tenant_id
          replacement: ${TENANT_ID}
          action: replace
        - sourceLabels: [__meta_kubernetes_pod_label_nova_ibm_com_poolerName]
          targetLabel: pooler
          action: replace
EOF
}

# ---------- Generate: NetworkPolicy ----------
gen_networkpolicy() {
  local ns="$1"
  cat <<EOF
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: nova-allow-monitoring-ingress-${RESOURCE_SUFFIX}
  namespace: ${ns}
  labels:
    nova.ibm.com/managed-by: setup-dbaas-monitoring
spec:
  podSelector: {}
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              ${MONITORING_LABEL_KEY}: "${MONITORING_LABEL_VAL}"
      ports:
        - port: 9187
          protocol: TCP
        - port: 9127
          protocol: TCP
        - port: 8080
          protocol: TCP
  policyTypes:
    - Ingress
EOF
}

# ---------- Generate: PersesDashboard CR ----------
# OCP 4.20+ with Cluster Observability Operator uses PersesDashboard CR (perses.dev/v1alpha1).
# The CR must be created in the same namespace as the Perses instance
# (openshift-cluster-observability-operator).
gen_dashboard() {
  cat <<EOF
---
apiVersion: perses.dev/v1alpha1
kind: PersesDashboard
metadata:
  name: dbaas-postgresql-manual
  namespace: openshift-cluster-observability-operator
  labels:
    nova.ibm.com/managed-by: setup-dbaas-monitoring
spec:
  display:
    name: Datastore for PostgreSQL
  duration: 30m
  refreshInterval: 30s
  variables:
    - kind: ListVariable
      spec:
        name: namespace
        display:
          name: Namespace
          hidden: false
        allowAllValue: false
        allowMultiple: false
        plugin:
          kind: PrometheusLabelValuesVariable
          spec:
            labelName: namespace
            matchers:
              - cnpg_collector_up
    - kind: ListVariable
      spec:
        name: cluster
        display:
          name: Cluster
          hidden: false
        allowAllValue: false
        allowMultiple: false
        plugin:
          kind: PrometheusLabelValuesVariable
          spec:
            labelName: instance_id
            matchers:
              - 'cnpg_collector_up{namespace="\$namespace"}'
  panels:
    overview_up:
      kind: Panel
      spec:
        display:
          name: PostgreSQL Up
        plugin:
          kind: StatChart
          spec:
            calculation: last-number
            thresholds:
              steps:
                - color: red
                  value: 0
                - color: yellow
                  value: 0.5
                - color: green
                  value: 1
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'cnpg_collector_up{namespace="\$namespace", instance_id="\$cluster"}'
    overview_lag:
      kind: Panel
      spec:
        display:
          name: Replication Lag
        plugin:
          kind: StatChart
          spec:
            calculation: last-number
            format:
              unit: seconds
            thresholds:
              steps:
                - color: green
                  value: 0
                - color: yellow
                  value: 5
                - color: red
                  value: 30
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'max(cnpg_pg_replication_lag{namespace="\$namespace", instance_id="\$cluster"})'
    overview_connections:
      kind: Panel
      spec:
        display:
          name: Total Connections
        plugin:
          kind: StatChart
          spec:
            calculation: last-number
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum(cnpg_backends_total{namespace="\$namespace", instance_id="\$cluster"})'
    overview_waiting:
      kind: Panel
      spec:
        display:
          name: Waiting Backends
        plugin:
          kind: StatChart
          spec:
            calculation: last-number
            thresholds:
              steps:
                - color: green
                  value: 0
                - color: yellow
                  value: 1
                - color: red
                  value: 5
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'cnpg_backends_waiting_total{namespace="\$namespace", instance_id="\$cluster"}'
    txn_commits:
      kind: Panel
      spec:
        display:
          name: Commits / sec
        plugin:
          kind: TimeSeriesChart
          spec:
            visual:
              display: line
              areaOpacity: 0.2
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum by (datname) (rate(cnpg_pg_stat_database_xact_commit_total{namespace="\$namespace", instance_id="\$cluster", datname!~"template.*|"}[5m]))'
    txn_rollbacks:
      kind: Panel
      spec:
        display:
          name: Rollbacks / sec
        plugin:
          kind: TimeSeriesChart
          spec:
            visual:
              display: line
              areaOpacity: 0.2
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum by (datname) (rate(cnpg_pg_stat_database_xact_rollback_total{namespace="\$namespace", instance_id="\$cluster", datname!~"template.*|"}[5m]))'
    cache_hit:
      kind: Panel
      spec:
        display:
          name: Cache Hit Rate
        plugin:
          kind: TimeSeriesChart
          spec:
            visual:
              display: line
              areaOpacity: 0.2
            yAxis:
              format:
                unit: percent
              min: 0
              max: 100
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: '100 * sum by (datname) (rate(cnpg_pg_stat_database_blks_hit_total{namespace="\$namespace", instance_id="\$cluster", datname!~"template.*|"}[5m])) / clamp_min(sum by (datname) (rate(cnpg_pg_stat_database_blks_hit_total{namespace="\$namespace", instance_id="\$cluster", datname!~"template.*|"}[5m])) + sum by (datname) (rate(cnpg_pg_stat_database_blks_read_total{namespace="\$namespace", instance_id="\$cluster", datname!~"template.*|"}[5m])), 1)'
    db_size:
      kind: Panel
      spec:
        display:
          name: Database Size
        plugin:
          kind: TimeSeriesChart
          spec:
            visual:
              display: line
              areaOpacity: 0.2
            yAxis:
              format:
                unit: bytes
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'cnpg_pg_database_size_bytes{namespace="\$namespace", instance_id="\$cluster", datname!~"template.*"}'
    repl_lag:
      kind: Panel
      spec:
        display:
          name: Replication Lag (seconds)
        plugin:
          kind: TimeSeriesChart
          spec:
            visual:
              display: line
              areaOpacity: 0.2
            yAxis:
              format:
                unit: seconds
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'cnpg_pg_replication_lag{namespace="\$namespace", instance_id="\$cluster"}'
    repl_streaming:
      kind: Panel
      spec:
        display:
          name: Streaming Replicas
        plugin:
          kind: TimeSeriesChart
          spec:
            visual:
              display: line
              areaOpacity: 0.2
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'cnpg_pg_replication_streaming_replicas{namespace="\$namespace", instance_id="\$cluster"}'
    deadlocks:
      kind: Panel
      spec:
        display:
          name: Deadlocks / sec
        plugin:
          kind: TimeSeriesChart
          spec:
            visual:
              display: line
              areaOpacity: 0.2
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum by (datname) (rate(cnpg_pg_stat_database_deadlocks_total{namespace="\$namespace", instance_id="\$cluster", datname!~"template.*|"}[5m]))'
    temp_files:
      kind: Panel
      spec:
        display:
          name: Temp Files / sec
        plugin:
          kind: TimeSeriesChart
          spec:
            visual:
              display: line
              areaOpacity: 0.2
        queries:
          - kind: TimeSeriesQuery
            spec:
              plugin:
                kind: PrometheusTimeSeriesQuery
                spec:
                  query: 'sum by (datname) (rate(cnpg_pg_stat_database_temp_files_total{namespace="\$namespace", instance_id="\$cluster", datname!~"template.*|"}[5m]))'
  layouts:
    - kind: Grid
      spec:
        display:
          title: Overview
          collapse:
            open: true
        items:
          - content:
              \$ref: "#/spec/panels/overview_up"
            x: 0
            y: 0
            width: 6
            height: 4
          - content:
              \$ref: "#/spec/panels/overview_lag"
            x: 6
            y: 0
            width: 6
            height: 4
          - content:
              \$ref: "#/spec/panels/overview_connections"
            x: 12
            y: 0
            width: 6
            height: 4
          - content:
              \$ref: "#/spec/panels/overview_waiting"
            x: 18
            y: 0
            width: 6
            height: 4
    - kind: Grid
      spec:
        display:
          title: Transactions
          collapse:
            open: true
        items:
          - content:
              \$ref: "#/spec/panels/txn_commits"
            x: 0
            y: 0
            width: 12
            height: 8
          - content:
              \$ref: "#/spec/panels/txn_rollbacks"
            x: 12
            y: 0
            width: 12
            height: 8
    - kind: Grid
      spec:
        display:
          title: Cache & I/O
          collapse:
            open: true
        items:
          - content:
              \$ref: "#/spec/panels/cache_hit"
            x: 0
            y: 0
            width: 12
            height: 8
          - content:
              \$ref: "#/spec/panels/db_size"
            x: 12
            y: 0
            width: 12
            height: 8
    - kind: Grid
      spec:
        display:
          title: Replication
          collapse:
            open: true
        items:
          - content:
              \$ref: "#/spec/panels/repl_lag"
            x: 0
            y: 0
            width: 12
            height: 8
          - content:
              \$ref: "#/spec/panels/repl_streaming"
            x: 12
            y: 0
            width: 12
            height: 8
    - kind: Grid
      spec:
        display:
          title: Deadlocks & Errors
          collapse:
            open: true
        items:
          - content:
              \$ref: "#/spec/panels/deadlocks"
            x: 0
            y: 0
            width: 12
            height: 8
          - content:
              \$ref: "#/spec/panels/temp_files"
            x: 12
            y: 0
            width: 12
            height: 8
EOF
}

# ---------- Apply or dry-run ----------
apply_yaml() {
  local yaml="$1"
  if $DRY_RUN; then
    echo "$yaml"
  else
    echo "$yaml" | kctl apply -f -
  fi
}

# ---------- Main ----------
main() {
  preflight_check
  check_monitoring_ns

  # Auto-detect namespaces if none specified
  if [[ ${#TARGET_NAMESPACES[@]} -eq 0 ]]; then
    mapfile -t TARGET_NAMESPACES < <(discover_namespaces)
    if [[ ${#TARGET_NAMESPACES[@]} -eq 0 ]]; then
      echo "ERROR: No Datastore for PostgreSQL Cluster CRs found. Use -n to specify a namespace." >&2
      exit 1
    fi
    echo "Detected namespaces: ${TARGET_NAMESPACES[*]}"
  fi

  for ns in "${TARGET_NAMESPACES[@]}"; do
    echo ""
    echo "=== namespace: ${ns} ==="

    # Cluster CRs
    mapfile -t clusters < <(
      if [[ -n "$TARGET_CLUSTER" ]]; then
        echo "$TARGET_CLUSTER"
      else
        kctl get clusters.nova.ibm.com -n "$ns" \
          -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
      fi
    )

    for cluster in "${clusters[@]}"; do
      [[ -z "$cluster" ]] && continue
      echo "  Cluster: ${cluster}"

      # Look up app.kubernetes.io/instance from the Cluster CR and extract the UUID suffix
      local instance_id
      instance_id=$(kctl get clusters.nova.ibm.com -n "$ns" "$cluster" \
        -o json 2>/dev/null \
        | python3 -c "
import json, sys, re
d = json.load(sys.stdin)
val = d['metadata']['labels'].get('app.kubernetes.io/instance', '')
m = re.search(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', val, re.IGNORECASE)
print(m.group(0) if m else d['metadata']['name'])
" 2>/dev/null || echo "$cluster")
      echo "    instance_id: ${instance_id}"

      echo "    -> applying PodMonitor (instance)"
      apply_yaml "$(gen_podmonitor_instance "$ns" "$cluster" "$instance_id")"
    done

    # Pooler CRs
    mapfile -t poolers < <(
      kctl get poolers.nova.ibm.com -n "$ns" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.cluster.name}{"\n"}{end}' 2>/dev/null \
        | { [[ -n "$TARGET_CLUSTER" ]] && grep $'\t'"${TARGET_CLUSTER}"'$' || cat; } || true
    )

    for pooler_line in "${poolers[@]}"; do
      [[ -z "$pooler_line" ]] && continue
      pooler_name=$(echo "$pooler_line" | cut -f1)
      cluster_name=$(echo "$pooler_line" | cut -f2)
      echo "  Pooler: ${pooler_name} (cluster: ${cluster_name})"

      # Reuse the same instance_id as the parent Cluster CR
      local pooler_instance_id
      pooler_instance_id=$(kctl get clusters.nova.ibm.com -n "$ns" "$cluster_name" \
        -o json 2>/dev/null \
        | python3 -c "
import json, sys, re
d = json.load(sys.stdin)
val = d['metadata']['labels'].get('app.kubernetes.io/instance', '')
m = re.search(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', val, re.IGNORECASE)
print(m.group(0) if m else d['metadata']['name'])
" 2>/dev/null || echo "$cluster_name")

      echo "    -> applying PodMonitor (pooler)"
      apply_yaml "$(gen_podmonitor_pooler "$ns" "$pooler_name" "$cluster_name" "$pooler_instance_id")"
    done

    # NetworkPolicy (one per namespace)
    echo "  -> applying NetworkPolicy"
    apply_yaml "$(gen_networkpolicy "$ns")"
  done

  # PersesDashboard CR (one per installation)
  echo ""
  echo "=== Dashboard ==="
  echo "  -> applying PersesDashboard (dbaas-postgresql-manual) to openshift-cluster-observability-operator"
  apply_yaml "$(gen_dashboard)"

  echo ""
  if $DRY_RUN; then
    echo "=== Dry-run complete. Review the YAML above and re-run without --dry-run to apply. ==="
  else
    echo "=== Done ==="
    local console_host
    console_host=$(kctl get route console -n openshift-console \
      -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [[ -n "$console_host" ]]; then
      echo ""
      echo "-----------------------------------------------------------"
      echo " How to open the dashboard"
      echo "-----------------------------------------------------------"
      echo " 1. Open the OpenShift Console in your browser:"
      echo "      https://${console_host}"
      echo ""
      echo " 2. In the left navigation, go to:"
      echo "      Observe -> Dashboards (Perses)"
      echo ""
      echo " 3. In the Project dropdown, select:"
      echo "      openshift-cluster-observability-operator"
      echo ""
      echo " 4. Select 'Datastore for PostgreSQL' from the dashboard dropdown."
      echo ""
      echo " 5. Choose your Namespace and Cluster from the dropdowns at the top."
      echo "-----------------------------------------------------------"
    fi
  fi
}

main
