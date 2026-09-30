#!/bin/bash

# bucket-env.sh
# This file is meant to be *sourced* by other scripts.
# It exposes AWS CLI environment variables based on the container env.

# The scheduled push runs from cron, which starts jobs with an empty environment, so it does
# not inherit the BUCKET_* and SITE_NAME that docker-compose gave the container. PID 1 still
# holds that environment; read those variables from it rather than writing the keys to a file.
PROC_ENVIRON="${PROC_ENVIRON:-/proc/1/environ}"
if [ -z "${BUCKET_NAME:-}" ]; then
  if [ -r "$PROC_ENVIRON" ]; then
    while IFS= read -r -d '' kv; do
      case "$kv" in
        BUCKET_*=* | SITE_NAME=*)
          # `export` fails on a name that is not a valid identifier, and that would abort the
          # whole push under set -e; skip such a name instead.
          if [[ "${kv%%=*}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            export "$kv"
          fi
          ;;
      esac
    done < "$PROC_ENVIRON"
  else
    echo "[bucket-env] $PROC_ENVIRON is not readable, so the container's bucket settings are unknown." >&2
  fi
fi

# Fail closed. This used to fall back to dev-erp-storage, a bucket that exists, so a push that
# lost its settings synced to the wrong bucket and reported success. Local development sets
# BUCKET_NAME in docker/.env (see docker/.env.example).
if [ -z "${BUCKET_NAME:-}" ]; then
  echo "[bucket-env] FATAL: BUCKET_NAME is not set; refusing to guess a bucket." >&2
  return 1 2>/dev/null || exit 1
fi

# Site name used to build local paths
export SITE_NAME="${SITE_NAME:-hrms.localhost}"

# Bucket configuration (from docker-compose env / secrets)
export S3_BUCKET="$BUCKET_NAME"

# Map the BUCKET_* secrets to standard AWS env vars used by aws-cli
export AWS_ACCESS_KEY_ID="${BUCKET_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${BUCKET_SECRET_ACCESS_KEY:-}"
export AWS_DEFAULT_REGION="${BUCKET_REGION:-eu-west-2}"

if [ -z "${AWS_ACCESS_KEY_ID}" ] || [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
  echo "[bucket-env] Missing AWS credentials (BUCKET_ACCESS_KEY_ID / BUCKET_SECRET_ACCESS_KEY)." >&2
fi
