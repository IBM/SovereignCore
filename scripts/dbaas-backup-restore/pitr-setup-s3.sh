#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script: pitr-setup-s3.sh
# Purpose: Configure S3 / IBM Cloud Object Storage for PostgreSQL Backup & Restore
# Target Version: IBM Sovereign Core 1.3
# ==============================================================================

# Default configurations (override via environment variables or flags)
NAMESPACE="${NAMESPACE:-}"
CLUSTER_NAME="${CLUSTER_NAME:-nova-pg}"
SECRET_NAME="${SECRET_NAME:-barman}"
S3_REGION="${S3_REGION:-us-east-1}"
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"
DESTINATION_PATH="${DESTINATION_PATH:-}"

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY:-}}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${AWS_ACCESS_KEY_SECRET:-${AWS_SECRET_KEY:-}}}"

# Parse command line flags if provided
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -c|--cluster)
      CLUSTER_NAME="$2"
      shift 2
      ;;
    -s|--secret-name)
      SECRET_NAME="$2"
      shift 2
      ;;
    -d|--destination)
      DESTINATION_PATH="$2"
      shift 2
      ;;
    -e|--endpoint)
      S3_ENDPOINT_URL="$2"
      shift 2
      ;;
    -r|--region)
      S3_REGION="$2"
      shift 2
      ;;
    --access-key)
      AWS_ACCESS_KEY_ID="$2"
      shift 2
      ;;
    --secret-key)
      AWS_SECRET_ACCESS_KEY="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  -n, --namespace <ns>       Target namespace (REQUIRED, e.g. nova-system-myinstance)"
      echo "  -d, --destination <s3://>  S3 Destination path (REQUIRED, e.g. s3://my-bucket/path)"
      echo "  -c, --cluster <name>       Cluster name (default: nova-pg)"
      echo "  -s, --secret-name <name>   Secret name for S3 credentials (default: barman)"
      echo "  -e, --endpoint <url>       S3 Endpoint URL (optional; omit for AWS S3)"
      echo "  -r, --region <region>      S3 Region (default: us-east-1)"
      echo ""
      echo "Credentials (Required if Secret '$SECRET_NAME' does not already exist):"
      echo "      --access-key <key>     AWS / IBM COS Access Key ID"
      echo "      --secret-key <key>     AWS / IBM COS Secret Access Key"
      echo "  -h, --help                 Show this help message"
      echo ""
      echo "Examples:"
      echo "  # Case 1: Secret already exists on cluster"
      echo "  $0 -n nova-system-myinstance -d s3://my-bucket/cluster-backups"
      echo ""
      echo "  # Case 2: Creating secret and configuring backup in one step"
      echo "  $0 -n nova-system-myinstance \\"
      echo "     -d s3://my-bucket/cluster-backups \\"
      echo "     --access-key \"YOUR_ACCESS_KEY\" \\"
      echo "     --secret-key \"YOUR_SECRET_KEY\" \\"
      echo "     --endpoint \"https://s3.us-south.cloud-object-storage.appdomain.cloud\""
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$NAMESPACE" ]]; then
  echo "Error: Target namespace is required."
  echo "Please specify with -n / --namespace or set NAMESPACE environment variable."
  echo "Example: -n nova-system"
  exit 1
fi

if [[ -z "$DESTINATION_PATH" ]]; then
  echo "Error: S3 destination path is required."
  echo "Please specify with -d / --destination or set DESTINATION_PATH environment variable."
  echo "Example: -d s3://my-bucket/my-cluster-backups"
  exit 1
fi

# Ensure S3 endpoint has protocol scheme (http:// or https://)
if [[ -n "$S3_ENDPOINT_URL" && "$S3_ENDPOINT_URL" != http://* && "$S3_ENDPOINT_URL" != https://* ]]; then
  S3_ENDPOINT_URL="https://${S3_ENDPOINT_URL}"
fi

echo "=========================================================="
echo " Starting S3 Backup Configuration for PostgreSQL"
echo " Namespace:        $NAMESPACE"
echo " Cluster:          $CLUSTER_NAME"
echo " Secret:           $SECRET_NAME"
echo " Destination:      $DESTINATION_PATH"
echo " S3 Endpoint:      ${S3_ENDPOINT_URL:-<not set>}"
echo " Region:           $S3_REGION"
echo "=========================================================="

# Check if oc or kubectl is available
CLI="oc"
if ! command -v oc &> /dev/null; then
  if command -v kubectl &> /dev/null; then
    CLI="kubectl"
  else
    echo "Error: Neither 'oc' nor 'kubectl' found in PATH."
    exit 1
  fi
fi

# Step 1: Create or Update S3 Credentials Secret
echo ""
echo "[Step 1/4] Setting up S3 secret '$SECRET_NAME' in '$NAMESPACE'..."

# If credentials are not provided via flags/env and secret does not exist, prompt interactively
if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
  if ! $CLI get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
    echo "Secret '$SECRET_NAME' was not found in namespace '$NAMESPACE'."
    if [[ -t 0 ]]; then
      echo "Please enter your S3 / IBM Cloud Object Storage credentials to create it automatically:"
      read -r -p "  Access Key ID: " AWS_ACCESS_KEY_ID
      read -r -s -p "  Secret Access Key: " AWS_SECRET_ACCESS_KEY
      echo ""
      if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
        echo "Error: Both Access Key ID and Secret Access Key are required."
        exit 1
      fi
    else
      echo "Error: S3 credentials are required to create secret '$SECRET_NAME'."
      echo "Please pass --access-key and --secret-key, or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
      exit 1
    fi
  fi
fi

if [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]]; then
  echo "Creating/Updating S3 secret '$SECRET_NAME'..."
  $CLI create secret generic "$SECRET_NAME" \
    -n "$NAMESPACE" \
    --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    --from-literal=AWS_DEFAULT_REGION="$S3_REGION" \
    --dry-run=client -o yaml | $CLI apply -f -
  echo "✔ Secret '$SECRET_NAME' configured successfully."
else
  echo "✔ Existing secret '$SECRET_NAME' found and will be used."
fi

# Step 2: Patch Cluster-scoped BNRConfig CR
echo ""
echo "[Step 2/4] Patching BNRConfig 'default'..."
if $CLI get bnrconfig default &> /dev/null; then
  # In a JSON merge patch, null removes the key (used when no endpoint is set).
  if [[ -n "$S3_ENDPOINT_URL" ]]; then
    ENDPOINT_JSON="\"$S3_ENDPOINT_URL\""
  else
    ENDPOINT_JSON="null"
  fi
  $CLI patch bnrconfig default --type=merge -p "{
    \"spec\": {
      \"configMapTemplates\": {
        \"destinationPath\": \"$DESTINATION_PATH\",
        \"cloudCredentialsSecret\": \"$SECRET_NAME\",
        \"s3EndpointURL\": $ENDPOINT_JSON
      }
    }
  }"
  echo "✔ BNRConfig 'default' patched."
else
  echo "ℹ BNRConfig 'default' not found, skipping cluster-scoped config."
fi

# Step 3: Patch Cluster CR plugins
#
# A JSON merge patch REPLACES arrays, so patching spec.plugins with only the
# barman entry would silently delete every other plugin (e.g. the
# nova-restapi.ibm.com plugin that injects the nova-rest sidecar). Instead, read
# the current plugin list, update/add only the barman entry, and write back the
# full list so all other plugins are preserved.
echo ""
echo "[Step 3/4] Patching Cluster CR '$CLUSTER_NAME' in '$NAMESPACE'..."
if ! command -v python3 &> /dev/null; then
  echo "Error: python3 is required to merge the Cluster CR plugin list."
  exit 1
fi

CURRENT_PLUGINS="$($CLI get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.plugins}')"
CURRENT_PLUGINS="${CURRENT_PLUGINS:-[]}"
CURRENT_PG_IDENT="$($CLI get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.postgresql.pg_ident}')"
CURRENT_PG_IDENT="${CURRENT_PG_IDENT:-[]}"

if [[ "$CURRENT_PLUGINS" != *"nova-restapi.ibm.com"* ]]; then
  echo "⚠ WARNING: plugin 'nova-restapi.ibm.com' is not in Cluster '$CLUSTER_NAME'."
  echo "  The nova-rest API sidecar is NOT injected, so nova-cli / the REST API will not"
  echo "  work. This script will not add it. Restore it with 'helm upgrade' (the chart"
  echo "  defines its parameters, including bnrRestUrl) before or after this script."
fi

# Remember the current instance pods so we can tell whether the operator starts
# its own rolling restart after the patch.
LABEL="nova.ibm.com/cluster=$CLUSTER_NAME,nova.ibm.com/podRole=instance"
UIDS_BEFORE="$($CLI get pod -n "$NAMESPACE" -l "$LABEL" -o jsonpath='{range .items[*]}{.metadata.uid}{" "}{end}')"

PLUGIN_PATCH="$(
  CURRENT_PLUGINS="$CURRENT_PLUGINS" \
  CURRENT_PG_IDENT="$CURRENT_PG_IDENT" \
  DESTINATION_PATH="$DESTINATION_PATH" \
  SECRET_NAME="$SECRET_NAME" \
  S3_ENDPOINT_URL="$S3_ENDPOINT_URL" \
  python3 - <<'PY'
import json, os

BARMAN = "nova-barman.ibm.com"
plugins = json.loads(os.environ.get("CURRENT_PLUGINS") or "[]")
updates = {
    "destinationPath": os.environ["DESTINATION_PATH"],
    "cloudCredentialsSecret": os.environ["SECRET_NAME"],
}
endpoint = os.environ.get("S3_ENDPOINT_URL", "")
if endpoint:
    updates["s3EndpointURL"] = endpoint

for p in plugins:
    if p.get("name") == BARMAN:
        p["enabled"] = True
        params = p.setdefault("parameters", {})
        params.update(updates)
        if not endpoint:
            params.pop("s3EndpointURL", None)  # drop stale endpoint
        break
else:
    plugins.append({"name": BARMAN, "enabled": True, "parameters": updates})

spec = {"plugins": plugins}

# Ensure pg_ident maps client cert (CN=streaming_replica) to barman & streaming_barman
pg_ident = json.loads(os.environ.get("CURRENT_PG_IDENT") or "[]")
required_maps = [
    "barman_map  streaming_replica  barman",
    "barman_map  streaming_replica  streaming_barman"
]
for req in required_maps:
    req_tokens = req.split()
    if not any(entry.split() == req_tokens for entry in pg_ident):
        pg_ident.append(req)

spec["postgresql"] = {"pg_ident": pg_ident}

print(json.dumps({"spec": spec}))
PY
)"

$CLI patch cluster "$CLUSTER_NAME" -n "$NAMESPACE" --type=merge -p "$PLUGIN_PATCH"
echo "✔ Cluster CR '$CLUSTER_NAME' patched. Plugins now:"
$CLI get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{range .spec.plugins[*]}  - {.name}{"\n"}{end}'

# Step 4: Make sure the database pods pick up the new S3 settings
#
# If the plugin change makes the operator roll the pods itself (it did when the
# plugin list changed), just wait for that rollout to finish - restarting pods
# on top of it would cause a second full rollout. If the operator does nothing
# (settings unchanged, or only a Secret/ConfigMap changed), restart the pods
# ourselves, one at a time with a graceful delete (replicas first, primary last).

# Prints "ok" when every expected instance pod exists, is not terminating, and
# has all containers ready; otherwise prints the reason.
pods_ready_state() {
  local instances
  instances="$($CLI get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.instances}')"
  $CLI get pod -n "$NAMESPACE" -l "$LABEL" -o json | EXPECTED="${instances:-1}" python3 -c '
import json, os, sys
items = json.load(sys.stdin)["items"]
exp = int(os.environ["EXPECTED"])
if len(items) != exp:
    print(f"{len(items)}/{exp} pods"); sys.exit()
for p in items:
    n = p["metadata"]["name"]
    if p["metadata"].get("deletionTimestamp"):
        print(n + " terminating"); sys.exit()
    cs = p.get("status", {}).get("containerStatuses", [])
    if not cs or not all(c.get("ready") for c in cs):
        print(n + " not ready"); sys.exit()
print("ok")'
}

# Waits until the pods are ready AND the cluster reports healthy, on two
# consecutive checks (a freshly recreated pod can look ready for a moment).
wait_for_cluster_ready() {
  local timeout="$1" waited=0 stable=0 state phase
  while (( waited < timeout )); do
    state="$(pods_ready_state 2>/dev/null || echo "unknown")"
    phase="$($CLI get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$state" == "ok" && "$phase" == *"healthy"* ]]; then
      stable=$((stable + 1))
      (( stable >= 2 )) && return 0
    else
      stable=0
    fi
    sleep 10
    waited=$((waited + 10))
  done
  echo "Error: cluster '$CLUSTER_NAME' not healthy after ${timeout}s (last state: $state / $phase)."
  return 1
}

echo ""
echo "[Step 4/4] Applying new S3 settings to cluster pods..."

# Did the operator start rolling the pods? (a pod was replaced or is terminating)
ROLLOUT_STARTED=false
for _ in $(seq 1 12); do
  sleep 5
  UIDS_NOW="$($CLI get pod -n "$NAMESPACE" -l "$LABEL" -o jsonpath='{range .items[*]}{.metadata.uid}{" "}{end}')"
  TERMINATING="$($CLI get pod -n "$NAMESPACE" -l "$LABEL" -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{end}')"
  if [[ "$UIDS_NOW" != "$UIDS_BEFORE" || -n "$TERMINATING" ]]; then
    ROLLOUT_STARTED=true
    break
  fi
done

if [[ "$ROLLOUT_STARTED" == "true" ]]; then
  echo "  Operator is rolling the pods itself; waiting for it to finish (up to 20 min)..."
  wait_for_cluster_ready 1200
else
  echo "  Operator did not restart the pods; restarting them one at a time..."
  PODS="$($CLI get pod -n "$NAMESPACE" -l "$LABEL,role!=primary" -o name 2>/dev/null || true)"
  PRIMARY="$($CLI get pod -n "$NAMESPACE" -l "$LABEL,role=primary" -o name 2>/dev/null || true)"
  for pod in $PODS $PRIMARY; do
    name="${pod#pod/}"
    echo "  Restarting $name..."
    # The primary can take several minutes to shut down gracefully.
    $CLI delete pod "$name" -n "$NAMESPACE" --wait=true --timeout=900s
    wait_for_cluster_ready 900
  done
fi

echo ""
echo "=========================================================="
echo "✔ S3 Backup Setup Complete!"
echo ""
echo "Next steps:"
echo "1. Verify health:       nova-cli backup health"
echo "2. Trigger backup:      nova-cli backup create --type full"
echo "3. List backups:        nova-cli backup list"
echo "=========================================================="
