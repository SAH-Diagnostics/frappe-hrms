#!/bin/bash
# Manual bench initialization - creates directory structure, clones Frappe, sets up venv

set -e

BENCH_DIR="${BENCH_DIR:-/home/frappe/frappe-bench}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-develop}"

echo "=== Setting up bench directory structure ==="

cd /home/frappe

# Check if bench exists but is broken (missing apps.txt or incomplete)
if [ -d "$BENCH_DIR" ] && [ ! -f "$BENCH_DIR/apps.txt" ]; then
    echo "Detected broken bench installation (missing apps.txt), cleaning up..."
    rm -rf "$BENCH_DIR"
fi

if [ ! -d "$BENCH_DIR" ]; then
    echo "Creating bench at ${BENCH_DIR}"
    
    # Ensure we use the upgraded Python version
    if command -v pyenv &> /dev/null; then
        export PATH="$(pyenv root)/shims:$PATH"
        eval "$(pyenv init -)" 2>/dev/null || true
    fi
    
    PYTHON_CMD=$(which python3)
    echo "Using Python: $PYTHON_CMD ($($PYTHON_CMD --version))"
    
    # Create bench directory structure
    mkdir -p "$BENCH_DIR"/{apps,sites,config,logs}
    
    # Clone Frappe (latest develop branch)
    echo "Cloning Frappe (branch: $FRAPPE_BRANCH)..."
    git clone --branch "$FRAPPE_BRANCH" --depth 1 \
        https://github.com/frappe/frappe.git "$BENCH_DIR/apps/frappe" || {
        echo "Failed to clone branch $FRAPPE_BRANCH, trying develop..."
        git clone --branch develop --depth 1 \
            https://github.com/frappe/frappe.git "$BENCH_DIR/apps/frappe" || {
            echo "Failed to clone develop, trying main..."
            git clone --branch main --depth 1 \
                https://github.com/frappe/frappe.git "$BENCH_DIR/apps/frappe" || {
                echo "Failed to clone from GitHub, trying GitLab..."
                git clone --branch develop --depth 1 \
                    https://gitlab.com/frappe/frappe.git "$BENCH_DIR/apps/frappe"
            }
        }
    }
    
    # Create virtual environment
    echo "Creating virtual environment..."
    "$PYTHON_CMD" -m venv "$BENCH_DIR/env"
    
    # Upgrade pip and install wheel
    "$BENCH_DIR/env/bin/python" -m pip install --quiet --upgrade pip wheel
    
    # Install Frappe in editable mode
    echo "Installing Frappe..."
    cd "$BENCH_DIR"
    if command -v uv &> /dev/null; then
        uv pip install --upgrade -e apps/frappe --python "$BENCH_DIR/env/bin/python" || \
        "$BENCH_DIR/env/bin/pip" install --upgrade -e apps/frappe
    else
        "$BENCH_DIR/env/bin/pip" install --upgrade -e apps/frappe
    fi
    
    # Create apps.txt
    echo "frappe" > "$BENCH_DIR/apps.txt"
    
    echo "✓ Bench initialized successfully"
else
    echo "✓ Bench already exists"
fi

cd "$BENCH_DIR"

# Check if virtual environment uses Python 3.12+ (may have compatibility issues with older Frappe versions)
# With latest Frappe (develop), newer Python versions should work, but we'll try 3.11 first for maximum compatibility
if [ -d "$BENCH_DIR/env" ]; then
    VENV_PYTHON="$BENCH_DIR/env/bin/python"
    if [ -f "$VENV_PYTHON" ]; then
        VENV_VERSION=$("$VENV_PYTHON" --version 2>&1 | grep -oP '\d+\.\d+' | head -1 || echo "0.0")
        
        # With latest Frappe (develop branch), Python 3.12+ should be supported
        # We'll use whatever Python version is available
        echo "Virtual environment uses Python $VENV_VERSION"
        if [ "$(printf '%s\n' "3.12" "$VENV_VERSION" | sort -V | head -n1)" = "3.12" ]; then
            echo "Using Python $VENV_VERSION with latest Frappe (develop branch)"
        fi
    fi
fi

# Check if frappe is properly installed
if [ -d "$BENCH_DIR/apps/frappe" ] && ! "$BENCH_DIR/env/bin/python" -c "import frappe" 2>/dev/null; then
    echo "Frappe directory exists but module not importable - reinstalling frappe..."
    cd "$BENCH_DIR"
    if command -v uv &> /dev/null; then
        uv pip install --upgrade -e apps/frappe --python "$BENCH_DIR/env/bin/python" || true
    else
        "$BENCH_DIR/env/bin/pip" install --upgrade -e apps/frappe || true
    fi
    echo "✓ Attempted to reinstall frappe"
fi

# Basic ownership to avoid permission surprises
chown -R frappe:frappe "$BENCH_DIR" 2>/dev/null || true
chmod -R u+w "$BENCH_DIR/sites" 2>/dev/null || true

echo "✓ Bench setup complete"

