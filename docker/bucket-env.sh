#!/bin/bash

# bucket-env.sh
# This file is meant to be *sourced* by other scripts.
# It exposes AWS CLI environment variables based on the container env.

# The scheduled push runs from cron, which starts jobs with an empty environment, so it does
# not inherit the BUCKET_* and SITE_NAME that docker-compose gave the container. PID 1 still
# holds that environment; read those variables from it rather than writing the keys to a file.
PROC_ENVIRON="${PROC_ENVIRON:-/proc/1/environ}"
if [ -z "${BUCKET_NAME:-}" ] && [ -r "$PROC_ENVIRON" ]; then
  while IFS= read -r -d '' kv; do
    case "$kv" in
      BUCKET_*=* | SITE_NAME=*) export "$kv" ;;
    esac
  done < "$PROC_ENVIRON"
fi

# Site name used to build local paths
export SITE_NAME="${SITE_NAME:-hrms.localhost}"

# Bucket configuration (from docker-compose env / secrets)
export S3_BUCKET="${BUCKET_NAME:-dev-erp-storage}"

# Map the BUCKET_* secrets to standard AWS env vars used by aws-cli
export AWS_ACCESS_KEY_ID="${BUCKET_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${BUCKET_SECRET_ACCESS_KEY:-}"
export AWS_DEFAULT_REGION="${BUCKET_REGION:-eu-west-2}"

if [ -z "${AWS_ACCESS_KEY_ID}" ] || [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
  echo "[bucket-env] Missing AWS credentials (BUCKET_ACCESS_KEY_ID / BUCKET_SECRET_ACCESS_KEY)." >&2
fi

if [ -z "${S3_BUCKET}" ]; then
  echo "[bucket-env] Missing bucket name (BUCKET_NAME / S3_BUCKET)." >&2
fi
