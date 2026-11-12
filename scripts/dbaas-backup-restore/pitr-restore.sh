#!/usr/bin/env bash
#
# pitr-restore.sh
#
# Automates the full restore / Point-in-Time Recovery (PITR) procedure
# for PostgreSQL clusters.
# Target Version: IBM Sovereign Core 1.3
#
# What it does, in order:
#   R1  list backups            R2  save the Cluster CR      R4  pre-flight check
#   R5  build recovery CR       R6  nova-restapi handling
#   --- asks you to confirm (point of no return) ---
#   R7  delete the cluster      R8  delete the PVCs          R9  apply + wait healthy
#   R10 clear recovery bootstrap R11 validate
#
# Everything before the confirmation is read-only for the cluster.
# Use --dry-run to stop right before the confirmation.
#
# Usage:
#   ./pitr-restore.sh [options]
#
# Options:
#   -n, --namespace NS        Namespace of the Cluster CR      (default: nova-system)
#   -c, --cluster NAME        Cluster CR name                  (default: nova-pg)
#   -b, --backup-id ID        Barman backup ID (YYYYMMDDTHHMMSS) or "latest" (default: latest)
#                             Do NOT pass a nova-cli job UUID.
#   -t, --target-time TIME    PITR target, 'YYYY-MM-DD HH:MM:SS[+TZ]' (UTC if no zone).
#                             Omit for a full restore.
#   -y, --yes                 Skip the confirmation prompt (non-interactive)
#       --dry-run             Run R1 to R6 only, then stop. Nothing is deleted.
#       --no-restapi-workaround
#                             Do not disable the nova-restapi plugin during restore
#       --timeout MIN         Minutes to wait for the cluster to become healthy (default: 60)
#   -h, --help                Show this help
#
# Requirements: oc (logged in as cluster admin), python3.

set -Eeuo pipefail

NS="nova-system"
CLUSTER="nova-pg"
BACKUP_ARG="latest"
TARGET_TIME=""
ASSUME_YES=0
DRY_RUN=0
RESTAPI_WORKAROUND=1
HEALTHY_TIMEOUT_MIN=60
TERMINATE_GRACE_SEC=600

# ---------------------------------------------------------------- helpers
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_OFF=""
fi

STAGE="init"          # init -> prechecks -> DESTRUCTIVE
WORKDIR=""

step() { printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_OFF"; }
info() { printf '%s\n' "$*"; }
ok()   { printf '%sOK%s  %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%sWARN%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }

oc_retry() {
  local max=4 count=1 delay=3
  while true; do
    if oc "$@"; then
      return 0
    fi
    if [ "$count" -ge "$max" ]; then
      return 1
    fi
    warn "oc command failed (attempt $count/$max), retrying in ${delay}s..."
    sleep "$delay"
    count=$((count + 1))
  done
}

print_rollback() {
  cat >&2 <<EOF

${C_BLD}Rollback / recovery information${C_OFF}
  Saved Cluster CR : ${WORKDIR}/cluster-backup.json
  Recovery CR      : ${WORKDIR}/recovery.json

  To see why it failed:
    oc describe cluster ${CLUSTER} -n ${NS} | grep -A 10 "Events:"
    oc logs -n ${NS} deployment/nova-barman-plugin-controller --tail=50

  To roll back (the recreated cluster starts EMPTY; old data stays on the retained PVs):
    oc delete cluster ${CLUSTER} -n ${NS}
    oc delete pvc -n ${NS} -l nova.ibm.com/cluster=${CLUSTER}
    oc apply -f ${WORKDIR}/cluster-backup.json
EOF
}

die() {
  printf '%sERROR%s %s\n' "$C_RED" "$C_OFF" "$*" >&2
  if [ "$STAGE" = "init" ] || [ "$STAGE" = "prechecks" ]; then
    printf 'Nothing has been deleted. The cluster is untouched.\n' >&2
  else
    printf '%sThe cluster was already deleted or changed. Do not rerun blindly.%s\n' "$C_RED" "$C_OFF" >&2
    print_rollback
  fi
  exit 1
}

on_err() {
  local line="$1"
  trap - ERR
  die "unexpected failure at line ${line}"
}
trap 'on_err $LINENO' ERR

usage() { sed -n '2,/^set -Eeuo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- args
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace)  NS="${2:?missing value for $1}"; shift 2 ;;
    -c|--cluster)    CLUSTER="${2:?missing value for $1}"; shift 2 ;;
    -b|--backup-id)  BACKUP_ARG="${2:?missing value for $1}"; shift 2 ;;
    -t|--target-time) TARGET_TIME="${2:?missing value for $1}"; shift 2 ;;
    -y|--yes)        ASSUME_YES=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --no-restapi-workaround) RESTAPI_WORKAROUND=0; shift ;;
    --timeout)       HEALTHY_TIMEOUT_MIN="${2:?missing value for $1}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- R0 prechecks
step "R0  Prechecks"
STAGE="prechecks"

if [ "$BACKUP_ARG" != "latest" ] && ! printf '%s' "$BACKUP_ARG" | grep -Eq '^[0-9]{8}T[0-9]{6}$'; then
  die "backup id '$BACKUP_ARG' is not a Barman backup ID (expected YYYYMMDDTHHMMSS or 'latest'). A nova-cli job UUID is not valid here; see 'nova-cli backup list' (BARMAN ID column) or step R1 output."
fi

command -v oc >/dev/null 2>&1      || die "'oc' not found in PATH"
command -v python3 >/dev/null 2>&1 || die "'python3' not found in PATH"
oc whoami >/dev/null 2>&1          || die "not logged in to the cluster (run 'oc login')"
ok "logged in as $(oc whoami)"

oc get cluster "$CLUSTER" -n "$NS" >/dev/null 2>&1 \
  || die "Cluster CR '$CLUSTER' not found in namespace '$NS'. Check with: oc get cluster -A"
ok "found Cluster CR $CLUSTER in namespace $NS"

WORKDIR="/tmp/nova-restore-${CLUSTER}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORKDIR"
info "work directory: $WORKDIR"

if [ -n "$TARGET_TIME" ]; then
  info "mode: PITR to '$TARGET_TIME' (backup: $BACKUP_ARG)"
else
  info "mode: full restore (backup: $BACKUP_ARG)"
fi

get_active_pod() {
  oc get pod -n "$NS" -l nova.ibm.com/bnr-active-source=true -o name 2>/dev/null | head -n 1 || true
}

POD="$(get_active_pod)"
[ -n "$POD" ] || die "no BNR-active pod found (label nova.ibm.com/bnr-active-source=true in $NS). BNR may be in 'no eligible source' state."
ok "BNR-active pod: $POD"

# ---------------------------------------------------------------- R1 list backups
step "R1  Available backups"
oc exec -n "$NS" "$POD" -c nova-bnr -- barman list-backups pg-sidecar || die "could not list backups"

# ---------------------------------------------------------------- R2 save CR
step "R2  Save the current Cluster CR"
oc get cluster "$CLUSTER" -n "$NS" -o json > "$WORKDIR/cluster-backup.json"
python3 -c "
import json
c = json.load(open('$WORKDIR/cluster-backup.json'))
print('OK — instances:', c['spec']['instances'])
" || die "saved Cluster CR is not valid"

# refuse to continue if the live CR is already a recovery CR (a previous run was not cleaned up)
python3 - "$WORKDIR/cluster-backup.json" <<'EOF' || die "the live Cluster CR already has bootstrap.recovery. A previous restore was not cleaned up (R10). Clean it up first."
import json, sys
spec = json.load(open(sys.argv[1]))["spec"]
sys.exit(1 if "recovery" in (spec.get("bootstrap") or {}) else 0)
EOF

# ---------------------------------------------------------------- R4 preflight
step "R4  Pre-flight check (read-only)"
PF_ARGS=(--backup-id "$BACKUP_ARG")
[ -n "$TARGET_TIME" ] && PF_ARGS+=(--target-time "$TARGET_TIME")

if RESOLVED="$(oc exec -n "$NS" "$POD" -c nova-bnr -- nova-restore-preflight "${PF_ARGS[@]}")"; then
  PF_RC=0
else
  PF_RC=$?
  RESOLVED=""
fi

RESOLVED="$(printf '%s' "$RESOLVED" | tail -n 1 | tr -d '[:space:]')"
if [ "$PF_RC" -ne 0 ] || [ -z "$RESOLVED" ]; then
  die "NOT SAFE TO RESTORE: pre-flight check failed (exit code $PF_RC). Fix the cause above and rerun."
fi
printf '%s' "$RESOLVED" | grep -Eq '^[0-9]{8}T[0-9]{6}$' \
  || die "NOT SAFE TO RESTORE: pre-flight returned '$RESOLVED', which is not a Barman backup ID"
BACKUP_ID="$RESOLVED"
ok "restore will use backup: $BACKUP_ID"

# ---------------------------------------------------------------- R5 + R6 build recovery CR
step "R5  Build the recovery Cluster CR"
export BACKUP_ID TARGET_TIME RESTAPI_WORKAROUND
export SAVED_CR="$WORKDIR/cluster-backup.json"
export RECOVERY_CR="$WORKDIR/recovery.json"

SUMMARY="$(python3 - <<'EOF'
import json, os, sys

backup_id   = os.environ["BACKUP_ID"]
target_time = os.environ.get("TARGET_TIME", "")
workaround  = os.environ.get("RESTAPI_WORKAROUND", "1") == "1"

if not backup_id or backup_id == "latest":
    sys.exit("BACKUP_ID is not resolved")

orig = json.load(open(os.environ["SAVED_CR"]))
spec = orig["spec"]

server_name, dest_path, s3_endpoint = "pg-sidecar", "", ""
for p in spec.get("plugins", []):
    if p.get("name") == "nova-barman.ibm.com" and p.get("parameters"):
        dest_path   = p["parameters"].get("destinationPath", dest_path)
        s3_endpoint = p["parameters"].get("s3EndpointURL", s3_endpoint)
        server_name = p["parameters"].get("serverName", server_name)
if not dest_path:
    sys.exit("destinationPath not found in nova-barman.ibm.com plugin parameters")

target = {"targetTime": target_time} if target_time else {"targetImmediate": True}
target["backupID"] = backup_id
spec["bootstrap"] = {"recovery": {"source": server_name, "recoveryTarget": target}}

plugin_params = {"serverName": server_name, "backupId": backup_id, "destinationPath": dest_path}
if target_time:
    plugin_params["targetTime"] = target_time
if s3_endpoint:
    plugin_params["s3EndpointURL"] = s3_endpoint
spec["externalClusters"] = [{"name": server_name,
    "plugin": {"name": "nova-barman.ibm.com", "parameters": plugin_params}}]

# R6: nova-restapi workaround (disable during the restore, re-enabled in R10)
disabled = 0
if workaround:
    for pl in spec.get("plugins", []):
        if pl.get("name") == "nova-restapi.ibm.com":
            pl["enabled"] = False
            disabled = 1

metadata = {
    "name": orig["metadata"]["name"],
    "namespace": orig["metadata"]["namespace"],
}
if "annotations" in orig["metadata"]:
    metadata["annotations"] = orig["metadata"]["annotations"]
if "labels" in orig["metadata"]:
    metadata["labels"] = orig["metadata"]["labels"]

cr = {"apiVersion": "nova.ibm.com/v1", "kind": "Cluster",
      "metadata": metadata,
      "spec": spec}
json.dump(cr, open(os.environ["RECOVERY_CR"], "w"), indent=2)

print("name=" + orig["metadata"]["name"])
print("namespace=" + orig["metadata"]["namespace"])
print("dest=" + dest_path)
print("restapi_disabled=" + str(disabled))
EOF
)" || die "could not build the recovery CR"

CR_NAME="$(printf '%s\n' "$SUMMARY" | sed -n 's/^name=//p')"
CR_NS="$(printf '%s\n' "$SUMMARY" | sed -n 's/^namespace=//p')"
DEST_PATH="$(printf '%s\n' "$SUMMARY" | sed -n 's/^dest=//p')"
RESTAPI_DISABLED="$(printf '%s\n' "$SUMMARY" | sed -n 's/^restapi_disabled=//p')"

[ "$CR_NAME" = "$CLUSTER" ] && [ "$CR_NS" = "$NS" ] \
  || die "recovery CR name/namespace ($CR_NAME/$CR_NS) do not match $CLUSTER/$NS"

step "R6  Recovery CR summary"
cat <<EOF
  cluster            : $CR_NAME (namespace $CR_NS)
  backup ID          : $BACKUP_ID
  restore type       : $([ -n "$TARGET_TIME" ] && echo "PITR to $TARGET_TIME" || echo "full restore")
  S3 destinationPath : $DEST_PATH
  nova-restapi plugin: $([ "$RESTAPI_DISABLED" = "1" ] && echo "disabled during restore, re-enabled in R10" || echo "unchanged")
  recovery CR file   : $WORKDIR/recovery.json
  rollback CR file   : $WORKDIR/cluster-backup.json
EOF

if [ "$DRY_RUN" -eq 1 ]; then
  printf '\n%sDry run finished. Nothing was deleted or changed.%s\n' "$C_GRN" "$C_OFF"
  exit 0
fi

# ---------------------------------------------------------------- confirmation
step "POINT OF NO RETURN"
cat <<EOF
The next steps will:
  - DELETE the Cluster CR '$CLUSTER' in '$NS' (all instance pods terminate, the cluster goes offline)
  - DELETE its PVCs (the PVs are kept if their ReclaimPolicy is Retain)
  - Rebuild the cluster from backup $BACKUP_ID. Data written after that point is lost.

Make sure application traffic is stopped.
EOF

if [ "$ASSUME_YES" -ne 1 ]; then
  [ -t 0 ] || die "no terminal for confirmation. Rerun with --yes to confirm non-interactively."
  printf 'Type the cluster name (%s) to continue: ' "$CLUSTER"
  read -r ANSWER || ANSWER=""
  [ "$ANSWER" = "$CLUSTER" ] || die "confirmation did not match. Aborted."
fi

# ---------------------------------------------------------------- health waiting
cluster_status() {
  # prints: phase|readyInstances|instances   (empty if the cluster does not exist)
  oc get cluster "$CLUSTER" -n "$NS" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    st = json.load(sys.stdin).get("status", {})
except Exception:
    sys.exit(0)
print("%s|%s|%s" % (st.get("phase", ""), st.get("readyInstances", 0), st.get("instances", 0)))
' || true
}

wait_healthy() {
  local initial_sleep="${1:-0}"
  local deadline=$(( $(date +%s) + HEALTHY_TIMEOUT_MIN * 60 ))
  local last="" cur phase ready inst
  [ "$initial_sleep" -gt 0 ] && sleep "$initial_sleep"
  while :; do
    cur="$(cluster_status)"
    if [ "$cur" != "$last" ]; then
      info "  $(date +%H:%M:%S)  phase/ready/instances: ${cur:-<cluster not visible yet>}"
      last="$cur"
    fi
    if [ -n "$cur" ]; then
      phase="${cur%%|*}"; cur="${cur#*|}"; ready="${cur%%|*}"; inst="${cur#*|}"
      [ "$phase" = "Failed" ] && die "cluster phase is Failed"
      if [ "$phase" = "Cluster in healthy state" ] && [ "$inst" != "0" ] && [ "$ready" = "$inst" ]; then
        ok "cluster is healthy ($ready/$inst)"
        return 0
      fi
    fi
    [ "$(date +%s)" -lt "$deadline" ] || die "timed out after ${HEALTHY_TIMEOUT_MIN} minutes waiting for a healthy cluster"
    sleep 10
  done
}

# ---------------------------------------------------------------- R7 delete cluster
STAGE="DESTRUCTIVE"

step "R7  Delete the Cluster CR"
oc delete cluster "$CLUSTER" -n "$NS"

info "waiting for instance pods to terminate (force-delete after ${TERMINATE_GRACE_SEC}s)..."
deadline=$(( $(date +%s) + TERMINATE_GRACE_SEC ))
forced=0
while :; do
  # pooler pods are recreated by their Deployments, so they are ignored here
  remaining="$(oc get pods -n "$NS" -l "nova.ibm.com/cluster=$CLUSTER" -o name 2>/dev/null | grep -v pooler || true)"
  [ -z "$remaining" ] && break
  if [ "$forced" -eq 0 ] && [ "$(date +%s)" -ge "$deadline" ]; then
    warn "pods still terminating, force-deleting"
    oc delete pod -n "$NS" -l "nova.ibm.com/cluster=$CLUSTER" --grace-period=0 --force || true
    forced=1
  fi
  [ "$forced" -eq 1 ] && [ "$(date +%s)" -ge $(( deadline + 120 )) ] && die "instance pods still present after force delete: $remaining"
  sleep 5
done
ok "instance pods are gone"

# ---------------------------------------------------------------- R8 delete PVCs
step "R8  Delete the pgdata and pg-wal PVCs"
oc delete pvc -n "$NS" -l "nova.ibm.com/cluster=$CLUSTER" || true
sleep 3
LEFT="$(oc get pvc -n "$NS" -l "nova.ibm.com/cluster=$CLUSTER" -o name 2>/dev/null || true)"
[ -z "$LEFT" ] || die "PVCs still present: $LEFT"
ok "no PVCs left for $CLUSTER"

# ---------------------------------------------------------------- R9 apply
step "R9  Apply the recovery CR and wait for the restore"
oc_retry apply -f "$WORKDIR/recovery.json"
info "restore in progress (this includes base backup download, WAL replay and replica creation)"
info "follow the Job logs in another terminal with:"
info "  oc logs -n $NS \$(oc get pods -n $NS -o name | grep full-recovery | head -1) -c nova-bnr -f"
wait_healthy 5

# ---------------------------------------------------------------- R10 clean up
step "R10 Clear bootstrap.recovery"
if [ "$RESTAPI_DISABLED" = "1" ]; then
  info "re-enabling plugins from the saved CR (instance pods roll once)"
  PATCH_PLUGINS="$(python3 -c '
import json, sys
orig = json.load(open(sys.argv[1]))
print(json.dumps({"spec": {"plugins": orig["spec"].get("plugins", [])}}))
' "$WORKDIR/cluster-backup.json")"
  oc_retry patch cluster "$CLUSTER" -n "$NS" --type=merge -p "$PATCH_PLUGINS"
  wait_healthy 20
fi

PATCH_BOOT="$(python3 -c '
import json, sys
orig = json.load(open(sys.argv[1]))
initdb = orig["spec"].get("bootstrap", {}).get("initdb", {"database": "app", "owner": "app"})
print(json.dumps({"spec": {"bootstrap": {"recovery": None, "initdb": initdb}, "externalClusters": None}}))
' "$WORKDIR/cluster-backup.json")"
oc_retry patch cluster "$CLUSTER" -n "$NS" --type=merge -p "$PATCH_BOOT"

BOOT="$(oc get cluster "$CLUSTER" -n "$NS" -o jsonpath='{.spec.bootstrap}')"
EXT="$(oc get cluster "$CLUSTER" -n "$NS" -o jsonpath='{.spec.externalClusters}')"
printf '%s' "$BOOT" | grep -q '"recovery"' && die "bootstrap.recovery is still present: $BOOT"
printf '%s' "$BOOT" | grep -q '"initdb"'   || die "bootstrap.initdb is missing: $BOOT"
[ -z "$EXT" ] || die "externalClusters is still present: $EXT"
ok "bootstrap is back to initdb and externalClusters is cleared"

# ---------------------------------------------------------------- R11 validate
STAGE="validating"
step "R11 Validate the restore"

PRIMARY="$(oc get cluster "$CLUSTER" -n "$NS" -o jsonpath='{.status.currentPrimary}' 2>/dev/null || true)"
[ -n "$PRIMARY" ] || PRIMARY="${CLUSTER}-1"
read -r APP_DB APP_USER < <(python3 -c '
import json, sys
i = json.load(open(sys.argv[1]))["spec"].get("bootstrap", {}).get("initdb", {})
print(i.get("database", "app"), i.get("owner", "app"))
' "$WORKDIR/cluster-backup.json")

VALIDATION_FAILED=0
run_check() {
  local title="$1"; shift
  info "-- $title"
  if ! "$@"; then
    warn "check failed: $title"
    VALIDATION_FAILED=1
  fi
}

run_check "timeline changed (must be higher than before the restore)" \
  oc exec -n "$NS" "$PRIMARY" -c postgres -- psql -U postgres -c "SELECT timeline_id FROM pg_control_checkpoint();"
run_check "data is at the expected point in time" \
  oc exec -n "$NS" "$PRIMARY" -c postgres -- psql -U "$APP_USER" -d "$APP_DB" -c "SELECT now(), pg_postmaster_start_time();"
run_check "WAL archiving resumed" \
  bash -c "oc exec -n '$NS' \"\$(oc get pod -n '$NS' -l nova.ibm.com/bnr-active-source=true -o name | head -n 1)\" -c nova-bnr -- barman check pg-sidecar 2>&1 | grep -E 'archive|WAL|replication'"
run_check "replicas are streaming" \
  oc exec -n "$NS" "$PRIMARY" -c postgres -- psql -U postgres -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;"

# ---------------------------------------------------------------- done
step "Done"
if [ "$VALIDATION_FAILED" -eq 1 ]; then
  warn "restore finished, but one or more validation checks failed. Review the output above."
else
  ok "restore finished and validation checks ran"
fi
cat <<EOF

Next:
  - Take a new full backup so a fresh base exists on the new timeline:
      nova-cli backup create --type full --label "post-restore"
  - For PITR, confirm the timeline is higher than before and only data before the target time is present.
  - Keep $WORKDIR/cluster-backup.json until you are sure the restore is good.
EOF
[ "$VALIDATION_FAILED" -eq 0 ] || exit 3
