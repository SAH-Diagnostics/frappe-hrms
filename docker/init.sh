#!/bin/bash

set -e

DB_HOST_VALUE="${DB_HOST:-${RDS_HOSTNAME:-}}"
DB_PORT_VALUE="${DB_PORT:-${RDS_PORT:-3306}}"
DB_USER_VALUE="${DB_USER:-${RDS_USERNAME:-root}}"
DB_PASSWORD_VALUE="${DB_PASSWORD:-${RDS_PASSWORD:?DB_PASSWORD or RDS_PASSWORD must be set}}"
DB_NAME_VALUE="${DB_NAME:-${RDS_DB_NAME:-}}"
ADMIN_PASSWORD_VALUE="${ADMIN_PASSWORD:?ADMIN_PASSWORD must be set}"
DEVELOPER_MODE_VALUE="${DEVELOPER_MODE:-0}"
SITE_NAME="${SITE_NAME:-hrms.localhost}"
EXISTING_SITE_VALUE="${EXISTING_SITE:-false}"

echo "=== Installing AWS CLI ==="
# Install aws-cli if not already installed
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."
    
    # Update package list and install dependencies (use sudo for apt-get)
    sudo apt-get update -qq
    sudo apt-get install -y -qq unzip curl
    
    # Detect architecture
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
    else
        echo "Unsupported architecture: $ARCH. Using pip install."
        pip install awscli
    fi
    
    # Download and install AWS CLI
    if [ -n "$AWS_CLI_URL" ]; then
        echo "Downloading AWS CLI for $ARCH..."
        if curl -f "$AWS_CLI_URL" -o "/tmp/awscliv2.zip" 2>/dev/null; then
            echo "Extracting and installing AWS CLI..."
            unzip -q /tmp/awscliv2.zip -d /tmp
            sudo /tmp/aws/install
            rm -rf /tmp/aws /tmp/awscliv2.zip
        else
            echo "Failed to download AWS CLI. Using pip install as fallback..."
            pip install awscli
        fi
    fi
    
    # Verify installation
    if command -v aws &> /dev/null; then
        echo "✓ AWS CLI installed successfully: $(aws --version)"
    else
        echo "✗ AWS CLI installation failed. Trying pip install..."
        pip install awscli
        if command -v aws &> /dev/null; then
            echo "✓ AWS CLI installed via pip: $(aws --version)"
        else
            echo "✗ Warning: AWS CLI installation failed. Backup scripts may not work."
        fi
    fi
else
    echo "✓ AWS CLI already installed: $(aws --version)"
fi

echo "=== Initializing bench and site (${SITE_NAME}) ==="

# Ensure node in PATH for bench
export PATH="${NVM_DIR}/versions/node/v${NODE_VERSION_DEVELOP}/bin/:${PATH}"

# Pinned application versions.
#
# These were `version-16` -- a *branch*, which moves every time upstream merges. Because
# `sites/` is not a Docker volume, `compose down && up` rebuilds the bench from scratch and
# re-clones every app, so an unpinned deploy installs whatever was newest that day.
#
# They are tags, not commit SHAs, because `bench init --frappe-branch` and `bench get-app
# --branch` both forward the value to `git clone --branch`, which accepts a branch or a tag
# but NOT an arbitrary SHA.
#
# WHY THESE VALUES (VC-648, 2026-09-23)
#
# The previous pins (v16.29.0 / v16.30.0 / v16.15.0) were the versions production had been
# running since 2026-07-29. Checking them against the GitHub Advisory API found **20 open
# high/critical advisories** on the v16 line -- 4 critical, the oldest published 2026-08-13,
# i.e. 27 days past the 14-day remediation standard the business is certifying against.
# Every ceiling in that set is `< 16.35.0`, so the values below are the clearing versions.
#
# Keeping the old pins would have frozen an HR and payroll system on a known SQL injection
# (GHSA-v38v-9h2p-hr8v), a server-side template injection (GHSA-6w83-8777-v93q) and two
# account-takeover XSS issues. Pinning is only safe when the pin is maintained; an unmaintained
# pin is worse than no pin, because it looks deliberate.
#
# THESE VALUES HAVE A DATE ON THEM. They were the `version-16` tips on 2026-09-23. Before this
# reaches `main` -- which is what deploys production -- RE-DERIVE them and re-run
# `.github/workflows/security-advisory-check.yml`. Merging a stale set is the same bug in a
# new costume. The process that owns this is `helper/docs/erp-patch-and-dependency-process.md`
# (SAH-root helper/, NOT in this repository -- do not "fix" this into a repo-relative link; that
# folder holds production IP addresses and security-group ids and this repository is public).
FRAPPE_REF="${FRAPPE_REF:-v16.35.0}"    # 012667b9c
ERPNEXT_REF="${ERPNEXT_REF:-v16.36.0}"  # b30aa5334
HRMS_REF="${HRMS_REF:-v16.20.0}"        # c0a04b80e

# Initialize bench directory if it does not exist (non-destructive)
BENCH_DIR="/home/frappe/frappe-bench"
cd /home/frappe
if [ ! -d "$BENCH_DIR" ]; then
    echo "Creating bench at ${BENCH_DIR}"
    bench init --skip-redis-config-generation --frappe-branch "$FRAPPE_REF" frappe-bench
fi
cd "$BENCH_DIR"

# Basic ownership to avoid permission surprises
chown -R frappe:frappe /home/frappe/frappe-bench 2>/dev/null || true
chmod -R u+w /home/frappe/frappe-bench/sites 2>/dev/null || true

# Database configuration (write to common_site_config before site exists)
if [ -n "$DB_HOST_VALUE" ]; then
    echo "Configuring external database: $DB_HOST_VALUE:$DB_PORT_VALUE"
    bench set-config --global db_host "$DB_HOST_VALUE" 2>/dev/null || true
    bench set-config --global db_port "$DB_PORT_VALUE" 2>/dev/null || true
else
    echo "Configuring local MariaDB container"
    bench set-config --global db_host mariadb 2>/dev/null || true
    bench set-config --global db_port 3306 2>/dev/null || true
fi

# Redis endpoints (global scope)
bench set-config --global redis_cache redis://redis:6379 || true
bench set-config --global redis_queue redis://redis:6379 || true
bench set-config --global redis_socketio redis://redis:6379 || true

# Remove unused processes
sed -i '/redis/d' ./Procfile 2>/dev/null || true
sed -i '/watch/d' ./Procfile 2>/dev/null || true

echo "=== Getting apps ==="
bench get-app --branch "$ERPNEXT_REF" erpnext || echo "Warning: Failed to get erpnext app (may already exist)"
bench get-app --branch "$HRMS_REF" hrms || echo "Warning: Failed to get hrms app (may already exist)"

SAH_CRM_REPO="${SAH_CRM_REPO:-https://github.com/SAH-Diagnostics/sah_crm}"
# SAH_CRM_BRANCH is set per environment by each deploy workflow (prod `main`, staging and
# dev `staging`) and passed in through docker-compose.yml. It is deliberately not a literal
# here: this file is promoted from staging to main unchanged, so a literal would travel with
# it. The `main` fallback only applies to runs outside the deploy workflows (local compose).
#
# sah_crm is deliberately NOT pinned, unlike frappe/erpnext/hrms above. It is our own
# actively developed app, and the point of tracking a branch here is that a deploy picks up
# the CRM work that was just merged. The upstream apps are pinned because we do not control
# their release cadence; this one we do.
#
# It also CANNOT be pinned the way they are: `--branch` takes a branch or a tag, and the
# sah_crm repository has zero tags. Cutting a release tag there is tracked as a follow-up;
# until then the deploy records the resolved SHA below so a rebuild is at least auditable
# after the fact, which is what the 14-day process needs from it.
SAH_CRM_BRANCH="${SAH_CRM_BRANCH:-main}"
bench get-app "$SAH_CRM_REPO" --branch "$SAH_CRM_BRANCH" || echo "Warning: Failed to get sah_crm app (may already exist)"

# Record the resolved sah_crm commit. It is branch-tracked, so this line is the only record of
# what a given deploy actually installed; without it "which CRM code is in production?" is
# unanswerable after the fact.
if [ -d "$BENCH_DIR/apps/sah_crm/.git" ]; then
    echo "=== sah_crm resolved to: $(git -C "$BENCH_DIR/apps/sah_crm" rev-parse HEAD 2>/dev/null || echo unknown) (branch $SAH_CRM_BRANCH) ==="
else
    echo "=== WARNING: sah_crm was not cloned; its get-app failure above was swallowed ==="
fi

echo "=== Preparing site: $SITE_NAME ==="

# Decide whether the target database already holds a Frappe site.
#
# This MUST fail closed. The caller below treats "no Frappe schema" as permission to run
# `bench new-site`, which is destructive against a production database. If a connection
# failure were allowed to look like an empty database, a transient fault -- notably the
# MariaDB "Too many connections" condition behind the 24 Jun and 8 Sep 2026 outages
# (VC-620) -- would route a redeploy straight into site re-creation over live data.
#
# Three properties are load-bearing; each replaced an earlier attempt that looked correct:
#
#   1. ONE connection decides. An earlier version probed reachability with a separate
#      `SELECT 1` and then ran the real query through `... | grep -q`. Without
#      `set -o pipefail` a pipeline reports grep's status, so the real query's failure was
#      still invisible, and a pool flap between the two calls landed back in `bench
#      new-site`. Status and output must come from the same call that makes the decision.
#
#   2. NO `-D`. Selecting the database up front makes a not-yet-created database raise
#      ERROR 1049, which is indistinguishable from a connection fault -- that would abort
#      legitimate first-time provisioning and, under `restart: unless-stopped`, crash-loop
#      a brand-new environment forever. `SHOW TABLES FROM` asks the same question without
#      requiring the database to exist.
#
#   3. `exit`, not `return`, on a fault. init.sh runs under `set -e`, but a non-zero return
#      from a function used as an `if` condition is exempt from it, so `return 1` here
#      would be silently swallowed -- which is exactly how the original bug read as safe.
database_has_frappe_site() {
    local probe_output
    local probe_status=0

    if [ -z "$DB_HOST_VALUE" ] || [ -z "$DB_NAME_VALUE" ]; then
        echo "FATAL: database_has_frappe_site called without DB_HOST and DB_NAME set." >&2
        echo "Refusing to guess: answering 'no site' here would authorise bench new-site." >&2
        exit 1
    fi

    echo "Checking whether database '$DB_NAME_VALUE' on '$DB_HOST_VALUE' holds a Frappe site..."

    probe_output=$(mysql -h "$DB_HOST_VALUE" -P "$DB_PORT_VALUE" -u "$DB_USER_VALUE" \
        -p"$DB_PASSWORD_VALUE" \
        -e "SHOW TABLES FROM \`$DB_NAME_VALUE\` LIKE 'tabUser';" 2>&1) || probe_status=$?

    if [ "$probe_status" -eq 0 ]; then
        case "$probe_output" in
            *tabUser*)
                echo "Detected an existing Frappe schema in '$DB_NAME_VALUE'."
                return 0
                ;;
        esac
        echo "Database '$DB_NAME_VALUE' exists and holds no Frappe schema; safe to provision."
        return 1
    fi

    # A database that does not exist yet is a legitimate first-run state, not a fault.
    case "$probe_output" in
        *"ERROR 1049"*)
            echo "Database '$DB_NAME_VALUE' does not exist yet; safe to provision."
            return 1
            ;;
    esac

    echo "FATAL: cannot determine the state of database '$DB_NAME_VALUE' on '$DB_HOST_VALUE'." >&2
    echo "Refusing to continue: an unreachable database must not be treated as an empty one," >&2
    echo "because that would create a new site over existing production data." >&2
    echo "mysql reported: $probe_output" >&2
    exit 1
}

# Second, independent guard on site creation.
#
# database_has_frappe_site() *infers* whether a site exists. EXISTING_SITE is a *declaration*
# from the environment's own configuration that one does. Where an operator has declared it,
# no inference may authorise `bench new-site`: if the schema it declares cannot be found,
# the fault is in the database or the configuration, never a reason to provision over it.
#
# The two guards fail independently, which is the point of having both. The probe covers a
# database that cannot be reached. This covers one that is reached and answers wrongly --
# a DB_NAME typo, an instance restored empty, a replica pointed at by mistake. In each of
# those the probe honestly reports "no schema" and would, on its own, authorise creation.
assert_provisioning_allowed() {
    if [ "$EXISTING_SITE_VALUE" = "true" ]; then
        echo "FATAL: EXISTING_SITE=true declares that site '$SITE_NAME' already exists," >&2
        echo "but no Frappe schema was found in '$DB_NAME_VALUE' on '$DB_HOST_VALUE'." >&2
        echo "Refusing to run bench new-site: creating a site here would write over the" >&2
        echo "data this environment is declared to hold." >&2
        echo "Investigate the database first. If this environment genuinely must be" >&2
        echo "provisioned from empty, set EXISTING_SITE=false deliberately." >&2
        exit 1
    fi
}

# Fail fast on a half-configured external database. Without this, a deploy that sets
# DB_HOST but loses DB_NAME falls through to the local-MariaDB branch below, which runs
# `bench new-site --force` and still forwards --db-host -- provisioning an orphan schema
# on the production RDS instance and bringing the ERP up empty. One orphan per container
# recreate, which `restart: unless-stopped` makes considerably more likely.
if { [ -n "$DB_HOST_VALUE" ] && [ -z "$DB_NAME_VALUE" ]; } || \
   { [ -z "$DB_HOST_VALUE" ] && [ -n "$DB_NAME_VALUE" ]; }; then
    echo "FATAL: DB_HOST and DB_NAME must be set together (got host='$DB_HOST_VALUE', name='$DB_NAME_VALUE')." >&2
    echo "Refusing to continue: a half-configured external database would be provisioned as a local one." >&2
    exit 1
fi

# For external RDS databases, try to reuse existing site/DB if present,
# otherwise create the site once (non-destructive on subsequent runs).
if [ -n "$DB_HOST_VALUE" ] && [ -n "$DB_NAME_VALUE" ]; then
    echo "Using external RDS database for site: $SITE_NAME"

    if bench --site "$SITE_NAME" list-apps >/dev/null 2>&1; then
        echo "Existing RDS-backed site detected; running migrate without dropping database..."
        bench --site "$SITE_NAME" migrate || true
    else
        echo "No existing site detected in bench; checking RDS database state..."

        if database_has_frappe_site; then
            echo "Attaching bench to existing RDS-backed site without reinitializing database..."

            # Create site directory structure if missing
            mkdir -p "/home/frappe/frappe-bench/sites/$SITE_NAME/logs"
            mkdir -p "/home/frappe/frappe-bench/sites/$SITE_NAME/private"
            mkdir -p "/home/frappe/frappe-bench/sites/$SITE_NAME/public"

            # Create site_config.json with RDS credentials (only if it does not already exist)
            if [ ! -f "/home/frappe/frappe-bench/sites/$SITE_NAME/site_config.json" ]; then
                cat > "/home/frappe/frappe-bench/sites/$SITE_NAME/site_config.json" << EOF
{
 "db_name": "$DB_NAME_VALUE",
 "db_password": "$DB_PASSWORD_VALUE",
 "db_port": $DB_PORT_VALUE,
 "db_host": "$DB_HOST_VALUE",
 "db_type": "mariadb",
 "db_user": "$DB_USER_VALUE",
 "developer_mode": $DEVELOPER_MODE_VALUE,
 "webserver_port": "443"
}
EOF
            fi

            # Ensure global config matches RDS
            bench set-config --global db_host "$DB_HOST_VALUE" 2>/dev/null || true
            bench set-config --global db_port "$DB_PORT_VALUE" 2>/dev/null || true

            # Only migrate the existing database; do NOT recreate or reinstall.
            bench --site "$SITE_NAME" migrate || true
        else
            echo "Empty (or non-Frappe) database on RDS; creating site on RDS (one-time operation)..."
            assert_provisioning_allowed

            # Try bench new-site first (might work if RDS allows it for master user)
            if bench new-site "$SITE_NAME" \
                --db-host "$DB_HOST_VALUE" \
                --db-port "$DB_PORT_VALUE" \
                --db-user "$DB_USER_VALUE" \
                --db-password "$DB_PASSWORD_VALUE" \
                --db-name "$DB_NAME_VALUE" \
                --db-type "mariadb" \
                --db-root-password "$DB_PASSWORD_VALUE" \
                --db-root-username "$DB_USER_VALUE" \
                --admin-password "$ADMIN_PASSWORD_VALUE" \
                --verbose \
                --no-mariadb-socket 2>&1; then
                echo "Site created successfully using bench new-site"
            else
                echo "bench new-site failed (likely CREATE USER restriction), creating site manually..."

                # Create site directory structure
                mkdir -p "/home/frappe/frappe-bench/sites/$SITE_NAME/logs"
                mkdir -p "/home/frappe/frappe-bench/sites/$SITE_NAME/private"
                mkdir -p "/home/frappe/frappe-bench/sites/$SITE_NAME/public"

                # Ensure target database exists (idempotent; requires privileges on RDS user)
                mysql -h "$DB_HOST_VALUE" -P "$DB_PORT_VALUE" -u "$DB_USER_VALUE" -p"$DB_PASSWORD_VALUE" \
                    -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME_VALUE\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || true

                # Create site_config.json with RDS credentials (only if it does not already exist)
                if [ ! -f "/home/frappe/frappe-bench/sites/$SITE_NAME/site_config.json" ]; then
                    cat > "/home/frappe/frappe-bench/sites/$SITE_NAME/site_config.json" << EOF
{
 "db_name": "$DB_NAME_VALUE",
 "db_password": "$DB_PASSWORD_VALUE",
 "db_port": $DB_PORT_VALUE,
 "db_host": "$DB_HOST_VALUE",
 "db_type": "mariadb",
 "db_user": "$DB_USER_VALUE",
 "developer_mode": $DEVELOPER_MODE_VALUE,
 "webserver_port": "443"
}
EOF
                fi

                # Set global config
                bench set-config --global db_host "$DB_HOST_VALUE" 2>/dev/null || true
                bench set-config --global db_port "$DB_PORT_VALUE" 2>/dev/null || true

                # Initialize database schema using install-app frappe (no force, DB is known-empty)
                echo "Initializing database schema..."
                bench --site "$SITE_NAME" install-app frappe || {
                    echo "Warning: install-app frappe failed, trying migrate..."
                    bench --site "$SITE_NAME" migrate || true
                }
            fi
        fi
    fi
else
    # Local MariaDB: reuse existing site if present, otherwise create it once.
    if bench --site "$SITE_NAME" list-apps >/dev/null 2>&1; then
        echo "Existing local site detected; running migrate without dropping database..."
        bench --site "$SITE_NAME" migrate || true
    else
        echo "No existing local site detected; creating new local site..."
        assert_provisioning_allowed
        bench new-site "$SITE_NAME" \
            --force \
            ${DB_NAME_VALUE:+--db-name "$DB_NAME_VALUE"} \
            ${DB_HOST_VALUE:+--db-host "$DB_HOST_VALUE"} \
            ${DB_PORT_VALUE:+--db-port "$DB_PORT_VALUE"} \
            --mariadb-root-password "$DB_PASSWORD_VALUE" \
            --mariadb-root-username "$DB_USER_VALUE" \
            --admin-password "$ADMIN_PASSWORD_VALUE" \
            --no-mariadb-socket
    fi
fi

# Ensure the site knows its public URL so generated links use the correct host
if [ -n "$SITE_URL" ]; then
    HOST_URL="${SITE_URL%/}"
    # Default to https if no scheme provided
    if [[ "$HOST_URL" != http*://* ]]; then
        HOST_URL="https://${HOST_URL}"
    fi
    echo "=== Setting host_name to ${HOST_URL} ==="
    bench --site "$SITE_NAME" set-config host_name "$HOST_URL"
fi

# Force webserver_port to 443 so generated links do not append :8000
echo "=== Setting webserver_port to 443 ==="
bench set-config --global webserver_port 443 || true
bench --site "$SITE_NAME" set-config webserver_port 443

echo "=== Installing HRMS app (idempotent) ==="
bench --site "$SITE_NAME" install-app hrms || true

echo "=== Installing SAH CRM app (idempotent) ==="
bench --site "$SITE_NAME" install-app sah_crm || true
bench --site "$SITE_NAME" set-config developer_mode "$DEVELOPER_MODE_VALUE"
bench --site "$SITE_NAME" enable-scheduler

# Two-factor authentication is re-asserted on every boot, so a rebuilt instance always comes
# up with authenticator-app 2FA on. Policy and knobs: docker/configure_2fa.py.
# Non-fatal on purpose: exiting here would take the whole ERP down. The settings persist in the
# database, so a failed re-assert keeps whatever policy was last applied -- which, on a site that
# never had one, means 2FA stays OFF. Check the boot log for "2FA policy applied" after a deploy.
TWO_FACTOR_POLICY_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/configure_2fa.py"
apply_two_factor_policy() {
    echo "=== Applying two-factor authentication policy ==="
    if ! (cd "$BENCH_DIR/sites" && "$BENCH_DIR/env/bin/python" "$TWO_FACTOR_POLICY_SCRIPT" "$SITE_NAME"); then
        echo "✗ 2FA policy NOT applied — the site keeps its previous 2FA settings; check the error above" >&2
    fi
}
apply_two_factor_policy

bench --site "$SITE_NAME" clear-cache || true
bench use "$SITE_NAME" || true

echo "=== Installing bucket helper scripts ==="

# Determine the directory where this init.sh lives (inside the container image)
INIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# In this deployment, helper scripts live next to init.sh (in /workspace)
SCRIPTS_DIR="${INIT_DIR}"

echo "Using scripts from: ${SCRIPTS_DIR}"

# Copy S3 helper scripts into /home/frappe so they are easy to run
cp "${SCRIPTS_DIR}/bucket-env.sh" "/home/frappe/bucket-env.sh"
cp "${SCRIPTS_DIR}/push-to-bucket.sh" "/home/frappe/push-to-bucket.sh"
cp "${SCRIPTS_DIR}/fetch-from-bucket.sh" "/home/frappe/fetch-from-bucket.sh"
cp "${SCRIPTS_DIR}/create-push-cron-job.sh" "/home/frappe/create-push-cron-job.sh"

chmod +x /home/frappe/push-to-bucket.sh /home/frappe/fetch-from-bucket.sh /home/frappe/create-push-cron-job.sh 2>/dev/null || true
chown frappe:frappe /home/frappe/push-to-bucket.sh /home/frappe/fetch-from-bucket.sh /home/frappe/create-push-cron-job.sh /home/frappe/bucket-env.sh 2>/dev/null || true

echo "=== Running initial fetch-from-bucket to populate site files (if any) ==="
/home/frappe/fetch-from-bucket.sh || echo "Warning: initial fetch-from-bucket.sh failed (bucket may be empty or AWS not configured)"

echo "=== Configuring cron job for periodic push-to-bucket backups ==="
/home/frappe/create-push-cron-job.sh || echo "Warning: create-push-cron-job.sh failed; automatic backups may not run"

echo "=== Starting bench ==="
bench start