#!/usr/bin/env bash
#
# Script: pgdump-restore-s3.sh
# Purpose: Stream logical PostgreSQL restore from external S3 storage
# Target Version: IBM Sovereign Core 1.3
#
set -euo pipefail

# Required environment variables check
: "${INSTANCE_NAME:?Environment variable INSTANCE_NAME must be set}"
: "${DATABASE_NAME:?Environment variable DATABASE_NAME must be set}"
: "${S3_ENDPOINT:?Environment variable S3_ENDPOINT must be set}"
: "${S3_ACCESS_KEY:?Environment variable S3_ACCESS_KEY must be set}"
: "${S3_SECRET_KEY:?Environment variable S3_SECRET_KEY must be set}"
: "${S3_BUCKET:?Environment variable S3_BUCKET must be set}"
: "${S3_REGION:=us-east-1}"
: "${S3_PREFIX:=pg-dumps}"
: "${SOURCE_DB:=${DATABASE_NAME}}"

NAMESPACE="nova-system-${INSTANCE_NAME}"

echo "==> [1/3] Identifying primary PostgreSQL pod in ${NAMESPACE}..."
PRIMARY_POD=$(oc get cluster nova-pg -n "${NAMESPACE}" -o jsonpath='{.status.currentPrimary}')
echo "Found primary pod: ${PRIMARY_POD}"

echo "==> [2/3] Retrieving superuser credentials..."
PG_PASS=$(oc get secret nova-pg-superuser -n "${NAMESPACE}" -o jsonpath='{.data.password}' | base64 -d)

echo "==> [3/3] Streaming from S3 (s3://${S3_BUCKET}/${S3_PREFIX}/${SOURCE_DB}.dump.gz) into target database '${DATABASE_NAME}'..."
oc exec -n "${NAMESPACE}" "${PRIMARY_POD}" -c nova-bnr -- \
  env S3_ENDPOINT="${S3_ENDPOINT}" \
      S3_ACCESS_KEY="${S3_ACCESS_KEY}" \
      S3_SECRET_KEY="${S3_SECRET_KEY}" \
      S3_BUCKET="${S3_BUCKET}" \
      S3_PREFIX="${S3_PREFIX}" \
      TARGET_DB="${DATABASE_NAME}" \
      SOURCE_DB="${SOURCE_DB}" \
      TGT_PG_PASS="${PG_PASS}" \
      S3_REGION="${S3_REGION}" \
  bash -c "
python3 -c \"
import boto3, subprocess, sys, os
s3 = boto3.client('s3',
    endpoint_url=os.environ['S3_ENDPOINT'],
    aws_access_key_id=os.environ['S3_ACCESS_KEY'],
    aws_secret_access_key=os.environ['S3_SECRET_KEY'],
    region_name=os.environ.get('S3_REGION', 'us-east-1'))

psql = subprocess.Popen(
    ['psql', '-U', 'postgres', '-h', '127.0.0.1', '-p', '5432',
     '-d', os.environ['TARGET_DB'], '-v', 'ON_ERROR_STOP=1'],
    stdin=subprocess.PIPE,
    env={**os.environ, 'PGPASSWORD': os.environ['TGT_PG_PASS']})

gz = subprocess.Popen(['gunzip'], stdin=subprocess.PIPE, stdout=psql.stdin)

obj = s3.get_object(Bucket=os.environ['S3_BUCKET'],
                    Key=os.environ['S3_PREFIX'] + '/' + os.environ['SOURCE_DB'] + '.dump.gz')
for chunk in obj['Body'].iter_chunks(chunk_size=8 * 1024 * 1024):
    gz.stdin.write(chunk)
gz.stdin.close()
gz.wait()
psql.stdin.close()
rc = psql.wait()
print(f'Stream restore complete -- psql exit code: {rc}', file=sys.stderr, flush=True)
sys.exit(rc)
\"
"
