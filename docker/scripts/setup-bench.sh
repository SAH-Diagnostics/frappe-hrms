#!/bin/bash
# Manual bench initialization - creates directory structure, clones Frappe, sets up venv

set -e

BENCH_DIR="${BENCH_DIR:-/home/frappe/frappe-bench}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-14}"

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
    
    # Clone Frappe
    echo "Cloning Frappe (branch: $FRAPPE_BRANCH)..."
    git clone --branch "$FRAPPE_BRANCH" --depth 1 \
        https://github.com/frappe/frappe.git "$BENCH_DIR/apps/frappe" || {
        echo "Failed to clone from GitHub, trying alternative..."
        git clone --branch "$FRAPPE_BRANCH" --depth 1 \
            https://gitlab.com/frappe/frappe.git "$BENCH_DIR/apps/frappe"
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

# Check if virtual environment uses Python 3.12+ (incompatible with hiredis==2.0.0)
if [ -d "$BENCH_DIR/env" ]; then
    VENV_PYTHON="$BENCH_DIR/env/bin/python"
    if [ -f "$VENV_PYTHON" ]; then
        VENV_VERSION=$("$VENV_PYTHON" --version 2>&1 | grep -oP '\d+\.\d+' | head -1 || echo "0.0")
        
        # Check if venv uses Python 3.12+
        if [ "$(printf '%s\n' "3.12" "$VENV_VERSION" | sort -V | head -n1)" = "3.12" ]; then
            echo "Virtual environment uses Python $VENV_VERSION, which is incompatible with hiredis==2.0.0"
            echo "Recreating virtual environment with Python 3.11..."
            
            # Get Python 3.11 from pyenv if available
            if command -v pyenv &> /dev/null; then
                export PATH="$(pyenv root)/shims:$PATH"
                eval "$(pyenv init -)" 2>/dev/null || true
                # Install Python 3.11 if not available
                if ! pyenv versions --bare 2>/dev/null | grep -q "^3\.11\."; then
                    echo "Installing Python 3.11.9 (latest 3.11.x) for compatibility..."
                    pyenv install -s 3.11.9 2>/dev/null || pyenv install -s 3.11.8 2>/dev/null || pyenv install -s 3.11.0 2>/dev/null || true
                fi
                # Use latest 3.11.x available
                PY311_VERSION=$(pyenv versions --bare 2>/dev/null | grep "^3\.11\." | sort -V | tail -1)
                if [ -n "$PY311_VERSION" ]; then
                    PYTHON311_CMD="$(pyenv root)/versions/$PY311_VERSION/bin/python3"
                    if [ -f "$PYTHON311_CMD" ]; then
                        echo "Recreating venv with Python $PY311_VERSION..."
                        rm -rf "$BENCH_DIR/env"
                        "$PYTHON311_CMD" -m venv "$BENCH_DIR/env"
                        "$BENCH_DIR/env/bin/python" -m pip install --quiet --upgrade pip wheel
                        # Reinstall Frappe
                        "$BENCH_DIR/env/bin/pip" install --upgrade -e apps/frappe
                        echo "✓ Virtual environment recreated with Python $PY311_VERSION"
                    fi
                fi
            else
                # Fallback: try system Python 3.11 if available
                if command -v python3.11 &> /dev/null; then
                    echo "Recreating venv with system Python 3.11..."
                    rm -rf "$BENCH_DIR/env"
                    python3.11 -m venv "$BENCH_DIR/env"
                    "$BENCH_DIR/env/bin/python" -m pip install --quiet --upgrade pip wheel
                    "$BENCH_DIR/env/bin/pip" install --upgrade -e apps/frappe
                    echo "✓ Virtual environment recreated with Python 3.11"
                else
                    echo "⚠ Warning: Python 3.11 not found. Frappe installation may fail due to hiredis compatibility."
                fi
            fi
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

