#!/bin/bash
# Site creation and configuration - completely manual, no bench commands

set -e

BENCH_DIR="${BENCH_DIR:-/home/frappe/frappe-bench}"
SITE_NAME="${SITE_NAME:-hrms.localhost}"
DB_HOST_VALUE="${DB_HOST:-${RDS_HOSTNAME:-}}"
DB_PORT_VALUE="${DB_PORT:-${RDS_PORT:-3306}}"
DB_USER_VALUE="${DB_USER:-${RDS_USERNAME:-root}}"
DB_PASSWORD_VALUE="${DB_PASSWORD:-${RDS_PASSWORD:-123}}"
DB_NAME_VALUE="${DB_NAME:-${RDS_DB_NAME:-}}"
ADMIN_PASSWORD_VALUE="${ADMIN_PASSWORD:-admin}"
SITE_URL="${SITE_URL:-}"

echo "=== Preparing site: $SITE_NAME ==="

cd "$BENCH_DIR"

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/frappe-utils.sh" 2>/dev/null || true

# Ensure apps.txt exists in sites directory (required by Frappe)
if [ ! -f "$BENCH_DIR/sites/apps.txt" ]; then
    echo "Creating apps.txt file..."
    {
        echo "frappe"
        [ -d "$BENCH_DIR/apps/erpnext" ] && echo "erpnext"
        [ -d "$BENCH_DIR/apps/hrms" ] && echo "hrms"
    } > "$BENCH_DIR/sites/apps.txt"
fi

# Ensure logs directory exists (required by Frappe logger)
mkdir -p "$BENCH_DIR/logs"
mkdir -p "$BENCH_DIR/$SITE_NAME/logs" 2>/dev/null || true  # Frappe may use this path
mkdir -p "/home/frappe/logs" 2>/dev/null || true

# Helper: test database connection and permissions
test_database_connection() {
    if [ -z "$DB_HOST_VALUE" ] || [ -z "$DB_NAME_VALUE" ] || [ -z "$DB_USER_VALUE" ] || [ -z "$DB_PASSWORD_VALUE" ]; then
        echo "Error: Missing database configuration (DB_HOST, DB_NAME, DB_USER, or DB_PASSWORD)"
        return 1
    fi

    echo "Testing database connection to $DB_USER_VALUE@$DB_HOST_VALUE:$DB_PORT_VALUE/$DB_NAME_VALUE..."
    
    # Test basic connection
    if ! mysql -h "$DB_HOST_VALUE" -P "$DB_PORT_VALUE" -u "$DB_USER_VALUE" -p"$DB_PASSWORD_VALUE" \
        -e "SELECT 1;" 2>/dev/null; then
        echo "✗ ERROR: Cannot connect to database. Please check credentials and permissions."
        return 1
    fi

    # Check if database exists
    DB_EXISTS=$(mysql -h "$DB_HOST_VALUE" -P "$DB_PORT_VALUE" -u "$DB_USER_VALUE" -p"$DB_PASSWORD_VALUE" \
        -e "SHOW DATABASES LIKE '$DB_NAME_VALUE';" 2>/dev/null | grep -c "$DB_NAME_VALUE" || echo "0")
    
    if [ "$DB_EXISTS" = "0" ]; then
        echo "Database '$DB_NAME_VALUE' does not exist. Attempting to create it..."
        # Try to create the database
        if mysql -h "$DB_HOST_VALUE" -P "$DB_PORT_VALUE" -u "$DB_USER_VALUE" -p"$DB_PASSWORD_VALUE" \
            -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME_VALUE\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null; then
            echo "✓ Database '$DB_NAME_VALUE' created successfully"
        else
            echo "✗ WARNING: Could not create database '$DB_NAME_VALUE'. User may not have CREATE privilege."
            echo "Please create the database manually or ensure the user has CREATE privilege."
            return 1
        fi
    fi
    
    # Test database access
    # if ! mysql -h "$DB_HOST_VALUE" -P "$DB_PORT_VALUE" -u "$DB_USER_VALUE" -p"$DB_PASSWORD_VALUE" \
    #     -D "$DB_NAME_VALUE" \
    #     -e "SELECT 1;" 2>/dev/null; then
    #     echo "Cannot access database '$DB_NAME_VALUE'. Attempting to grant privileges..."
        
    #     # Try to grant privileges (this may fail if user doesn't have GRANT privilege)
    #     if mysql -h "$DB_HOST_VALUE" -P "$DB_PORT_VALUE" -u "$DB_USER_VALUE" -p"$DB_PASSWORD_VALUE" \
    #         -e "GRANT ALL PRIVILEGES ON \`$DB_NAME_VALUE\`.* TO '$DB_USER_VALUE'@'%'; FLUSH PRIVILEGES;" 2>/dev/null; then
    #         echo "✓ Privileges granted successfully"
    #         # Test access again
    #         if mysql -h "$DB_HOST_VALUE" -P "$DB_PORT_VALUE" -u "$DB_USER_VALUE" -p"$DB_PASSWORD_VALUE" \
    #             -D "$DB_NAME_VALUE" \
    #             -e "SELECT 1;" 2>/dev/null; then
    #             echo "✓ Database access confirmed"
    #         else
    #             echo "✗ ERROR: Still cannot access database after granting privileges."
    #             return 1
    #         fi
    #     else
    #         echo "✗ WARNING: Could not grant privileges automatically. User may not have GRANT privilege."
    #         echo ""
    #         echo "To fix this, connect to your MySQL/MariaDB server as an administrator and run:"
    #         echo "  GRANT ALL PRIVILEGES ON \`$DB_NAME_VALUE\`.* TO '$DB_USER_VALUE'@'%';"
    #         echo "  FLUSH PRIVILEGES;"
    #         echo ""
    #         echo "Or if you need to grant from a specific host:"
    #         echo "  GRANT ALL PRIVILEGES ON \`$DB_NAME_VALUE\`.* TO '$DB_USER_VALUE'@'your-host-ip';"
    #         echo "  FLUSH PRIVILEGES;"
    #         return 1
    #     fi
    # fi

    echo "✓ Database connection successful"
    return 0
}

# Helper: detect whether the target database already contains a Frappe schema
database_has_frappe_site() {
    if [ -z "$DB_HOST_VALUE" ] || [ -z "$DB_NAME_VALUE" ]; then
        return 1
    fi

    echo "Checking if database '$DB_NAME_VALUE' already contains a Frappe site..."
    if mysql -h "$DB_HOST_VALUE" -P "$DB_PORT_VALUE" -u "$DB_USER_VALUE" -p"$DB_PASSWORD_VALUE" \
        -D "$DB_NAME_VALUE" \
        -e "SHOW TABLES LIKE 'tabUser';" 2>/dev/null | grep -q "tabUser"; then
        echo "Detected existing Frappe schema in database '$DB_NAME_VALUE'."
        return 0
    fi

    echo "No Frappe schema detected in database '$DB_NAME_VALUE'."
    return 1
}

# For external RDS databases
if [ -n "$DB_HOST_VALUE" ] && [ -n "$DB_NAME_VALUE" ]; then
    echo "Using external database for site: $SITE_NAME"

    # Test database connection before proceeding
    if ! test_database_connection; then
        echo "✗ FATAL: Database connection test failed. Cannot proceed with site setup."
        exit 1
    fi

    # Check if site directory exists
    if [ -f "$BENCH_DIR/sites/$SITE_NAME/site_config.json" ]; then
        echo "Existing site detected; checking database state..."
        
        if database_has_frappe_site; then
            echo "Site exists with database schema; running migrations..."
            # Ensure logs directories exist
            mkdir -p "$BENCH_DIR/logs"
            mkdir -p "$BENCH_DIR/sites/$SITE_NAME/logs"
            # Run migrations using Frappe Python API
            export FRAPPE_SITE="$SITE_NAME"
            cd "$BENCH_DIR"
            "$BENCH_DIR/env/bin/python" -c "
import frappe
import os
os.chdir('$BENCH_DIR')
os.makedirs('$BENCH_DIR/logs', exist_ok=True)
os.makedirs('$BENCH_DIR/sites/$SITE_NAME/logs', exist_ok=True)
os.makedirs('/home/frappe/logs', exist_ok=True)
frappe.init(site='$SITE_NAME', sites_path='$BENCH_DIR/sites')
frappe.connect()
frappe.db.commit()
" 2>/dev/null || true
        else
            echo "Site directory exists but database is empty; initializing..."
            # Create apps.txt file in sites directory (required by Frappe)
            if [ ! -f "$BENCH_DIR/sites/apps.txt" ]; then
                echo "Creating apps.txt file..."
                {
                    echo "frappe"
                    [ -d "$BENCH_DIR/apps/erpnext" ] && echo "erpnext"
                    [ -d "$BENCH_DIR/apps/hrms" ] && echo "hrms"
                } > "$BENCH_DIR/sites/apps.txt"
            fi
            # Ensure logs directories exist
            mkdir -p "$BENCH_DIR/logs"
            mkdir -p "$BENCH_DIR/sites/$SITE_NAME/logs"
            mkdir -p "$BENCH_DIR/$SITE_NAME/logs"  # Frappe may use this path
            # Initialize database schema
            export FRAPPE_SITE="$SITE_NAME"
            cd "$BENCH_DIR"
            "$BENCH_DIR/env/bin/python" <<- PYTHON_SCRIPT
import frappe
import sys
import os

site = '$SITE_NAME'
os.chdir('$BENCH_DIR')
os.makedirs('$BENCH_DIR/logs', exist_ok=True)
os.makedirs('$BENCH_DIR/sites/$SITE_NAME/logs', exist_ok=True)
os.makedirs('$BENCH_DIR/$SITE_NAME/logs', exist_ok=True)  # Alternative log path
os.makedirs('/home/frappe/logs', exist_ok=True)
frappe.init(site=site, sites_path='$BENCH_DIR/sites')
frappe.connect()

# Install Frappe app (creates database schema)
try:
    from frappe.installer import install_app, install_db
    
    # Check if database is empty (no tables)
    tables = frappe.db.sql("SHOW TABLES", as_dict=False)
    is_empty = len(tables) == 0
    
    if is_empty:
        print("Database is empty, creating initial schema...")
        # For empty databases, we need to create the schema first
        try:
            install_db(
                db_name=frappe.conf.db_name,
                db_user=frappe.conf.db_user,
                db_password=frappe.conf.db_password,
                force=True,
                verbose=False,
                mariadb_user_host_login_scope='%'
            )
        except (EOFError, KeyboardInterrupt) as e:
            # Expected error for external databases without root access
            print("Skipping install_db (not needed for external databases)...")
        except Exception as db_err:
            # Other errors - try to continue anyway
            print(f"Note: install_db had issues: {db_err}")
            print("Continuing with install_app...")
    
    # Install Frappe app (creates tables and initial data)
    print("Installing Frappe app...")
    install_app('frappe')
    frappe.db.commit()
    print("✓ Database schema initialized")
except Exception as e:
    print(f"Error initializing database: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYTHON_SCRIPT
            if [ $? -ne 0 ]; then
                echo "Error initializing database schema"
                exit 1
            fi
        fi
    else
        echo "No existing site detected; creating new site..."

        if database_has_frappe_site; then
            echo "Attaching to existing database-backed site..."

            # Create site directory structure
            mkdir -p "$BENCH_DIR/sites/$SITE_NAME"/{logs,private,public}

            # Create site_config.json
            cat > "$BENCH_DIR/sites/$SITE_NAME/site_config.json" << EOF
{
 "db_name": "$DB_NAME_VALUE",
 "db_password": "$DB_PASSWORD_VALUE",
 "db_port": $DB_PORT_VALUE,
 "db_host": "$DB_HOST_VALUE",
 "db_type": "mariadb",
 "db_user": "$DB_USER_VALUE",
 "developer_mode": 1,
 "webserver_port": 443
}
EOF

            # Create apps.txt file in sites directory (required by Frappe)
            if [ ! -f "$BENCH_DIR/sites/apps.txt" ]; then
                echo "Creating apps.txt file..."
                {
                    echo "frappe"
                    [ -d "$BENCH_DIR/apps/erpnext" ] && echo "erpnext"
                    [ -d "$BENCH_DIR/apps/hrms" ] && echo "hrms"
                } > "$BENCH_DIR/sites/apps.txt"
            fi

            # Ensure logs directories exist
            mkdir -p "$BENCH_DIR/logs"
            mkdir -p "$BENCH_DIR/sites/$SITE_NAME/logs"
            mkdir -p "$BENCH_DIR/$SITE_NAME/logs"  # Frappe may use this path
            # Run migrations
            export FRAPPE_SITE="$SITE_NAME"
            cd "$BENCH_DIR"
            "$BENCH_DIR/env/bin/python" -c "
import frappe
import os
os.chdir('$BENCH_DIR')
os.makedirs('$BENCH_DIR/logs', exist_ok=True)
os.makedirs('$BENCH_DIR/sites/$SITE_NAME/logs', exist_ok=True)
os.makedirs('$BENCH_DIR/$SITE_NAME/logs', exist_ok=True)  # Alternative log path
os.makedirs('/home/frappe/logs', exist_ok=True)
frappe.init(site='$SITE_NAME', sites_path='$BENCH_DIR/sites')
frappe.connect()
frappe.db.commit()
" 2>/dev/null || true
        else
            echo "Creating new site on empty database..."

            # Create site directory structure
            mkdir -p "$BENCH_DIR/sites/$SITE_NAME"/{logs,private,public}

            # Ensure target database exists
            if ! mysql -h "$DB_HOST_VALUE" -P "$DB_PORT_VALUE" -u "$DB_USER_VALUE" -p"$DB_PASSWORD_VALUE" \
                -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME_VALUE\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null; then
                echo "✗ WARNING: Could not create database '$DB_NAME_VALUE'. It may already exist or user lacks CREATE privilege."
                echo "Attempting to continue with existing database..."
            else
                echo "✓ Database '$DB_NAME_VALUE' ready"
            fi

            # Create site_config.json
            cat > "$BENCH_DIR/sites/$SITE_NAME/site_config.json" << EOF
{
 "db_name": "$DB_NAME_VALUE",
 "db_password": "$DB_PASSWORD_VALUE",
 "db_port": $DB_PORT_VALUE,
 "db_host": "$DB_HOST_VALUE",
 "db_type": "mariadb",
 "db_user": "$DB_USER_VALUE",
 "developer_mode": 1,
 "webserver_port": 443
}
EOF

            # Create apps.txt file in sites directory (required by Frappe)
            # This file lists all apps available for sites
            if [ ! -f "$BENCH_DIR/sites/apps.txt" ]; then
                echo "Creating apps.txt file..."
                {
                    echo "frappe"
                    [ -d "$BENCH_DIR/apps/erpnext" ] && echo "erpnext"
                    [ -d "$BENCH_DIR/apps/hrms" ] && echo "hrms"
                } > "$BENCH_DIR/sites/apps.txt"
            fi

            # Ensure logs directories exist before Frappe initialization
            mkdir -p "$BENCH_DIR/logs"
            mkdir -p "$BENCH_DIR/sites/$SITE_NAME/logs"
            mkdir -p "$BENCH_DIR/$SITE_NAME/logs"  # Frappe may use this path for logs
            mkdir -p "/home/frappe/logs" 2>/dev/null || true

            # Initialize database schema using Frappe Python API
            echo "Initializing database schema..."
            export FRAPPE_SITE="$SITE_NAME"
            cd "$BENCH_DIR"
            "$BENCH_DIR/env/bin/python" <<- PYTHON_SCRIPT
import frappe
import sys
import os

site = '$SITE_NAME'
admin_password = '$ADMIN_PASSWORD_VALUE'
sites_path = '$BENCH_DIR/sites'

# Ensure we're in the bench directory
os.chdir('$BENCH_DIR')

# Ensure logs directory exists (Frappe may use different paths)
os.makedirs('$BENCH_DIR/logs', exist_ok=True)
os.makedirs('$BENCH_DIR/sites/$SITE_NAME/logs', exist_ok=True)
os.makedirs('$BENCH_DIR/$SITE_NAME/logs', exist_ok=True)  # Alternative log path
os.makedirs('/home/frappe/logs', exist_ok=True)

# Initialize Frappe with explicit sites path
frappe.init(site=site, sites_path=sites_path)
frappe.connect()

try:
    # Import installer functions
    from frappe.installer import install_app
    
    # Check if database is empty (no tables)
    tables = frappe.db.sql("SHOW TABLES", as_dict=False)
    is_empty = len(tables) == 0
    
    if is_empty:
        print("Database is empty, creating initial schema...")
        # For empty databases, we need to create the schema first
        # Use install_db but skip root password requirement for external databases
        from frappe.installer import install_db
        try:
            # Try install_db - it may fail for root password, but that's OK for external DBs
            install_db(
                db_name=frappe.conf.db_name,
                db_user=frappe.conf.db_user,
                db_password=frappe.conf.db_password,
                force=True,
                verbose=False,
                mariadb_user_host_login_scope='%'
            )
        except (EOFError, KeyboardInterrupt) as e:
            # Expected error for external databases without root access
            print("Skipping install_db (not needed for external databases)...")
        except Exception as db_err:
            # Other errors - try to continue anyway
            print(f"Note: install_db had issues: {db_err}")
            print("Continuing with install_app...")
    
    # Install Frappe app (creates tables and initial data)
    print("Installing Frappe app...")
    install_app('frappe')
    
    # Set admin password
    frappe.utils.user.set_system_user_password(admin_password)
    
    frappe.db.commit()
    print("✓ Database schema initialized")
except Exception as e:
    print(f"Error initializing database: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYTHON_SCRIPT
            if [ $? -ne 0 ]; then
                echo "✗ ERROR: Database initialization failed"
                exit 1
            fi
        fi
    fi
else
    # Local MariaDB: create site if it doesn't exist
    if [ ! -f "$BENCH_DIR/sites/$SITE_NAME/site_config.json" ]; then
        echo "Creating new local site..."
        
        # Create site directory structure
        mkdir -p "$BENCH_DIR/sites/$SITE_NAME"/{logs,private,public}
        
            # Create site_config.json for local MariaDB
        cat > "$BENCH_DIR/sites/$SITE_NAME/site_config.json" << EOF
{
 "db_name": "${DB_NAME_VALUE:-$SITE_NAME}",
 "db_password": "$DB_PASSWORD_VALUE",
 "db_port": 3306,
 "db_host": "mariadb",
 "db_type": "mariadb",
 "db_user": "$DB_USER_VALUE",
 "developer_mode": 1,
 "webserver_port": 443
}
EOF
        
        # Create apps.txt file in sites directory (required by Frappe)
        if [ ! -f "$BENCH_DIR/sites/apps.txt" ]; then
            echo "Creating apps.txt file..."
            {
                echo "frappe"
                [ -d "$BENCH_DIR/apps/erpnext" ] && echo "erpnext"
                [ -d "$BENCH_DIR/apps/hrms" ] && echo "hrms"
            } > "$BENCH_DIR/sites/apps.txt"
        fi
        
        # Ensure logs directories exist
        mkdir -p "$BENCH_DIR/logs"
        mkdir -p "$BENCH_DIR/sites/$SITE_NAME/logs"
        mkdir -p "$BENCH_DIR/$SITE_NAME/logs"  # Frappe may use this path
        
        # Initialize database schema
        export FRAPPE_SITE="$SITE_NAME"
        cd "$BENCH_DIR"
        "$BENCH_DIR/env/bin/python" <<- PYTHON_SCRIPT
import frappe
import sys
import os

site = '$SITE_NAME'
admin_password = '$ADMIN_PASSWORD_VALUE'
os.chdir('$BENCH_DIR')
os.makedirs('$BENCH_DIR/logs', exist_ok=True)
os.makedirs('$BENCH_DIR/sites/$SITE_NAME/logs', exist_ok=True)
os.makedirs('$BENCH_DIR/$SITE_NAME/logs', exist_ok=True)  # Alternative log path

frappe.init(site=site, sites_path='$BENCH_DIR/sites')
frappe.connect()

try:
    from frappe.installer import install_db, install_app
    
    install_db(
        db_name=frappe.conf.db_name,
        db_user=frappe.conf.db_user,
        db_password=frappe.conf.db_password
    )
    install_app('frappe')
    frappe.utils.user.set_system_user_password(admin_password)
    frappe.db.commit()
    print("✓ Local site initialized")
except Exception as e:
    print(f"Error: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYTHON_SCRIPT
        if [ $? -ne 0 ]; then
            echo "✗ ERROR: Local site initialization failed"
            exit 1
        fi
    else
        echo "Existing local site detected; running migrations..."
        # Ensure logs directories exist
        mkdir -p "$BENCH_DIR/logs"
        mkdir -p "$BENCH_DIR/sites/$SITE_NAME/logs"
        mkdir -p "$BENCH_DIR/$SITE_NAME/logs"  # Frappe may use this path
        export FRAPPE_SITE="$SITE_NAME"
        cd "$BENCH_DIR"
        "$BENCH_DIR/env/bin/python" -c "
import frappe
import os
os.chdir('$BENCH_DIR')
os.makedirs('$BENCH_DIR/logs', exist_ok=True)
os.makedirs('$BENCH_DIR/sites/$SITE_NAME/logs', exist_ok=True)
os.makedirs('$BENCH_DIR/$SITE_NAME/logs', exist_ok=True)  # Alternative log path
os.makedirs('/home/frappe/logs', exist_ok=True)
frappe.init(site='$SITE_NAME', sites_path='$BENCH_DIR/sites')
frappe.connect()
frappe.db.commit()
" 2>/dev/null || true
    fi
fi

# Configure site settings
if [ -n "$SITE_URL" ]; then
    HOST_URL="${SITE_URL%/}"
    if [[ "$HOST_URL" != http*://* ]]; then
        HOST_URL="https://${HOST_URL}"
    fi
    echo "Setting host_name to ${HOST_URL}..."
    "$BENCH_DIR/env/bin/python" -c "
import json
site_config = '$BENCH_DIR/sites/$SITE_NAME/site_config.json'
with open(site_config, 'r') as f:
    config = json.load(f)
config['host_name'] = '$HOST_URL'
with open(site_config, 'w') as f:
    json.dump(config, f, indent=2)
"
fi

# Set webserver_port
echo "Setting webserver_port to 443..."
"$BENCH_DIR/env/bin/python" -c "
import json
site_config = '$BENCH_DIR/sites/$SITE_NAME/site_config.json'
with open(site_config, 'r') as f:
    config = json.load(f)
config['webserver_port'] = 443
with open(site_config, 'w') as f:
    json.dump(config, f, indent=2)
"

echo "✓ Site setup complete"

