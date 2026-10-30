#!/usr/bin/env bash
#
# Script: pgdump-backup-s3.sh
# Purpose: Stream logical PostgreSQL backup (pg_dump) to external S3 storage
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

NAMESPACE="nova-system-${INSTANCE_NAME}"

echo "==> [1/3] Identifying primary PostgreSQL pod in ${NAMESPACE}..."
PRIMARY_POD=$(oc get cluster nova-pg -n "${NAMESPACE}" -o jsonpath='{.status.currentPrimary}')
echo "Found primary pod: ${PRIMARY_POD}"

echo "==> [2/3] Retrieving superuser credentials..."
PG_PASS=$(oc get secret nova-pg-superuser -n "${NAMESPACE}" -o jsonpath='{.data.password}' | base64 -d)

echo "==> [3/3] Streaming pg_dump to S3: s3://${S3_BUCKET}/${S3_PREFIX}/${DATABASE_NAME}.dump.gz..."
oc exec -n "${NAMESPACE}" "${PRIMARY_POD}" -c nova-bnr -- \
  env S3_ENDPOINT="${S3_ENDPOINT}" \
      S3_ACCESS_KEY="${S3_ACCESS_KEY}" \
      S3_SECRET_KEY="${S3_SECRET_KEY}" \
      S3_BUCKET="${S3_BUCKET}" \
      S3_PREFIX="${S3_PREFIX}" \
      SOURCE_DB="${DATABASE_NAME}" \
      S3_REGION="${S3_REGION}" \
  bash -c "
set -o pipefail
PGPASSWORD='${PG_PASS}' pg_dump \
  -U postgres -h 127.0.0.1 -p 5432 -Fp \${SOURCE_DB} \
  | gzip \
  | python3 -c \"
import boto3, sys, os
s3 = boto3.client('s3',
    endpoint_url=os.environ['S3_ENDPOINT'],
    aws_access_key_id=os.environ['S3_ACCESS_KEY'],
    aws_secret_access_key=os.environ['S3_SECRET_KEY'],
    region_name=os.environ.get('S3_REGION', 'us-east-1'))
s3.upload_fileobj(sys.stdin.buffer,
    os.environ['S3_BUCKET'],
    os.environ['S3_PREFIX'] + '/' + os.environ['SOURCE_DB'] + '.dump.gz')
print('Stream upload complete.', flush=True)
\"
"
