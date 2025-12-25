#!/bin/bash
# Configure site settings (scheduler, developer mode, cache)

set -e

BENCH_DIR="${BENCH_DIR:-/home/frappe/frappe-bench}"
SITE_NAME="${SITE_NAME:-hrms.localhost}"

echo "=== Configuring site settings ==="

cd "$BENCH_DIR"

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/frappe-utils.sh" 2>/dev/null || true

# Set developer_mode
echo "Setting developer_mode to 1..."
"$BENCH_DIR/env/bin/python" -c "
import json
site_config = '$BENCH_DIR/sites/$SITE_NAME/site_config.json'
with open(site_config, 'r') as f:
    config = json.load(f)
config['developer_mode'] = 1
with open(site_config, 'w') as f:
    json.dump(config, f, indent=2)
"

# Enable scheduler by updating database
echo "Enabling scheduler..."
export FRAPPE_SITE="$SITE_NAME"
"$BENCH_DIR/env/bin/python" << PYTHON_SCRIPT
import frappe
import sys

site = '$SITE_NAME'

frappe.init(site=site)
frappe.connect()

try:
    # Enable scheduler
    frappe.db.set_value('System Settings', 'System Settings', 'enable_scheduler', 1)
    frappe.db.commit()
    print("✓ Scheduler enabled")
except Exception as e:
    print(f"⚠ Warning: Could not enable scheduler: {e}")
    # Try alternative method
    try:
        frappe.db.sql("""
            UPDATE `tabSingles` 
            SET `value` = '1' 
            WHERE `doctype` = 'System Settings' AND `field` = 'enable_scheduler'
        """)
        frappe.db.commit()
        print("✓ Scheduler enabled (alternative method)")
    except:
        print("⚠ Could not enable scheduler - continuing anyway")
PYTHON_SCRIPT
|| true

# Clear cache
echo "Clearing cache..."
clear_cache "$SITE_NAME" || true

echo "✓ Site configuration complete"

