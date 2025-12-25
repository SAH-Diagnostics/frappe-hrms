#!/bin/bash
# Get and install apps (erpnext, hrms) manually using git clone

set -e

BENCH_DIR="${BENCH_DIR:-/home/frappe/frappe-bench}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-develop}"

echo "=== Getting apps ==="

cd "$BENCH_DIR"

# Ensure Frappe is on the latest branch
if [ -d "$BENCH_DIR/apps/frappe" ]; then
    cd "$BENCH_DIR/apps/frappe"
    git fetch origin 2>/dev/null || true
    git checkout "$FRAPPE_BRANCH" 2>/dev/null || \
    git checkout develop 2>/dev/null || \
    git checkout main 2>/dev/null || true
    cd "$BENCH_DIR"
fi

# Get ERPNext app
if [ ! -d "$BENCH_DIR/apps/erpnext" ]; then
    echo "Cloning ERPNext (branch: $FRAPPE_BRANCH)..."
    git clone --branch "$FRAPPE_BRANCH" --depth 1 \
        https://github.com/frappe/erpnext.git "$BENCH_DIR/apps/erpnext" || {
        echo "Failed to clone $FRAPPE_BRANCH, trying develop..."
        git clone --branch develop --depth 1 \
            https://github.com/frappe/erpnext.git "$BENCH_DIR/apps/erpnext" || {
            echo "Warning: Failed to get erpnext app (may already exist)"
        }
    }
    
    if [ -d "$BENCH_DIR/apps/erpnext" ]; then
        # Install ERPNext dependencies
        echo "Installing ERPNext..."
        "$BENCH_DIR/env/bin/pip" install -e apps/erpnext || true
        # Add to apps.txt if not present
        if ! grep -q "^erpnext$" "$BENCH_DIR/apps.txt" 2>/dev/null; then
            echo "erpnext" >> "$BENCH_DIR/apps.txt"
        fi
    fi
else
    echo "✓ ERPNext already exists"
fi

# Get HRMS app
if [ ! -d "$BENCH_DIR/apps/hrms" ]; then
    echo "Cloning HRMS (branch: $FRAPPE_BRANCH)..."
    git clone --branch "$FRAPPE_BRANCH" --depth 1 \
        https://github.com/frappe/hrms.git "$BENCH_DIR/apps/hrms" || {
        echo "Failed to clone $FRAPPE_BRANCH, trying develop..."
        git clone --branch develop --depth 1 \
            https://github.com/frappe/hrms.git "$BENCH_DIR/apps/hrms" || {
            echo "Warning: Failed to get hrms app (may already exist)"
        }
    }
    
    if [ -d "$BENCH_DIR/apps/hrms" ]; then
        # Install HRMS dependencies
        echo "Installing HRMS..."
        "$BENCH_DIR/env/bin/pip" install -e apps/hrms || true
        # Add to apps.txt if not present
        if ! grep -q "^hrms$" "$BENCH_DIR/apps.txt" 2>/dev/null; then
            echo "hrms" >> "$BENCH_DIR/apps.txt"
        fi
    fi
else
    echo "✓ HRMS already exists"
fi

# Fix missing Node.js dependencies in frappe app
if [ -d "$BENCH_DIR/apps/frappe" ]; then
    echo "Installing Node.js dependencies for frappe app..."
    cd "$BENCH_DIR/apps/frappe"
    if [ -f "package.json" ]; then
        yarn install --check-files 2>/dev/null || npm install 2>/dev/null || \
            echo "Warning: Failed to install frappe node dependencies"
    fi
    cd "$BENCH_DIR"
fi

echo "✓ Apps setup complete"

