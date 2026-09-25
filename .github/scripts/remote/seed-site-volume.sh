#!/usr/bin/env bash
#
# Copy a site's uploaded files from the running frappe container into the frappe-site-data
# volume, once, before `compose down` discards the container.
#
# Runs ON the target box from deploy-docker-app.sh, after the .env is installed and before
# the stack is recreated.
#
# Why this exists
# ---------------
# Until the volume existed, sites/<site> lived inside the container and every deploy threw
# it away. The first deploy that mounts the volume would otherwise start from an empty one,
# losing whatever files were uploaded since the previous deploy. This copies public/ and
# private/ across so that first deploy loses nothing.
#
# site_config.json is deliberately NOT copied. Its encryption_key was generated at random by
# the old container; init.sh writes the pinned FRAPPE_ENCRYPTION_KEY into a fresh config.
#
# It does nothing when there is no running container, when the running container already
# uses the volume, or when the volume already holds the site. It prints counts, never paths
# or contents: this output lands in a public GitHub Actions log.
set -euo pipefail

DEPLOY_DIR="${1:?DEPLOY_DIR is required}"
COMPOSE_FILE="${2:?COMPOSE_FILE is required}"

cd "$DEPLOY_DIR" || { echo "FATAL: $DEPLOY_DIR is not accessible." >&2; exit 1; }

SITE_NAME="$(sudo grep -E '^SITE_NAME=' "$DEPLOY_DIR/.env" | head -1 | cut -d= -f2-)"
SITE_NAME="${SITE_NAME%\"}"; SITE_NAME="${SITE_NAME#\"}"
if [ -z "$SITE_NAME" ]; then
    echo "FATAL: SITE_NAME is not set in $DEPLOY_DIR/.env." >&2
    exit 1
fi

COMPOSE=(sudo docker compose --env-file "$DEPLOY_DIR/.env" -f "$COMPOSE_FILE")
SITE_IN_BENCH="/home/frappe/frappe-bench/sites/$SITE_NAME"
SITE_IN_VOLUME="/home/frappe/site-data/$SITE_NAME"

echo "=== Seeding the site-data volume ==="

container="$("${COMPOSE[@]}" ps -q frappe 2>/dev/null || true)"
if [ -z "$container" ]; then
    echo "No running frappe container; nothing to seed."
    exit 0
fi

if sudo docker exec "$container" test -L "$SITE_IN_BENCH"; then
    echo "The running container already uses the volume; nothing to seed."
    exit 0
fi

if ! sudo docker exec "$container" test -d "$SITE_IN_BENCH"; then
    echo "The running container has no site directory; nothing to seed."
    exit 0
fi

# A throwaway container of the same service mounts the same named volume. `compose run`
# forwards stdin, and this script runs inside the deploy's `ssh ... bash -s` heredoc, whose
# stdin is the rest of that script: only the tar stream may read stdin (into_volume).
into_volume() { "${COMPOSE[@]}" run --rm --no-deps -T --user root --entrypoint sh frappe -c "$1"; }
in_volume() { into_volume "$1" < /dev/null; }

if in_volume "test -e '$SITE_IN_VOLUME'"; then
    echo "The volume already holds $SITE_NAME; not overwriting it."
    exit 0
fi

for part in public private; do
    if sudo docker exec "$container" test -d "$SITE_IN_BENCH/$part"; then
        sudo docker cp "$container:$SITE_IN_BENCH/$part" - \
            | into_volume "mkdir -p '$SITE_IN_VOLUME' && tar -x -C '$SITE_IN_VOLUME'"
    fi
done
in_volume "mkdir -p '$SITE_IN_VOLUME' && chown -R 1000:1000 /home/frappe/site-data"

count="$(in_volume "find '$SITE_IN_VOLUME' -type f | wc -l" | tr -d '[:space:]')"
echo "✓ Seeded the volume with $count file(s) from the running container."
