#!/bin/bash
# Manually install an app into a site using Frappe Python API

set -e

BENCH_DIR="${BENCH_DIR:-/home/frappe/frappe-bench}"
SITE_NAME="${SITE_NAME:-hrms.localhost}"
APP_NAME="$1"

if [ -z "$APP_NAME" ]; then
    echo "Usage: $0 <app_name>"
    exit 1
fi

echo "=== Installing app: $APP_NAME ==="

cd "$BENCH_DIR"

# Check if app directory exists
if [ ! -d "$BENCH_DIR/apps/$APP_NAME" ]; then
    echo "✗ ERROR: App directory not found: $BENCH_DIR/apps/$APP_NAME"
    exit 1
fi

# Check if site exists
if [ ! -f "$BENCH_DIR/sites/$SITE_NAME/site_config.json" ]; then
    echo "✗ ERROR: Site not found: $SITE_NAME"
    exit 1
fi

# Install app using Frappe Python API
export FRAPPE_SITE="$SITE_NAME"
if ! "$BENCH_DIR/env/bin/python" << PYTHON_SCRIPT
import frappe
import sys

site = '$SITE_NAME'
app_name = '$APP_NAME'

frappe.init(site=site)
frappe.connect()

try:
    # Check if app is already installed
    installed_apps = frappe.get_installed_apps()
    if app_name in installed_apps:
        print(f"✓ App '{app_name}' is already installed")
    else:
        # Install the app
        print(f"Installing app '{app_name}'...")
        frappe.installer.install_app(app_name)
        frappe.db.commit()
        print(f"✓ App '{app_name}' installed successfully")
except Exception as e:
    print(f"✗ ERROR: Failed to install app '{app_name}': {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYTHON_SCRIPT
then
    echo "✗ WARNING: install-app $APP_NAME failed. The app may already be installed, or there may be permission problems."
    exit 1
fi

echo "✓ App installation complete"
