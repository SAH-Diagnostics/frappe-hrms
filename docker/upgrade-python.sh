#!/bin/bash

# upgrade-python.sh
# Purpose: Upgrade Python to 3.12+ using pyenv for Frappe compatibility
# This script ensures Python 3.12+ is available before bench initialization

set -e

TARGET_PYTHON_VERSION="${TARGET_PYTHON_VERSION:-3.12}"
MINOR_VERSION="${MINOR_VERSION:-3.12.0}"

echo "=== Upgrading Python using pyenv ==="

# Check if pyenv is available
if ! command -v pyenv &> /dev/null; then
    echo "pyenv is not available. Checking if it needs to be initialized..."
    
    # Check if pyenv is installed but not in PATH
    if [ -d "$HOME/.pyenv" ]; then
        echo "pyenv directory found at $HOME/.pyenv, initializing..."
        export PYENV_ROOT="$HOME/.pyenv"
        export PATH="$PYENV_ROOT/bin:$PATH"
        
        # Initialize pyenv
        if [ -f "$PYENV_ROOT/bin/pyenv" ]; then
            eval "$(pyenv init -)"
        else
            echo "✗ pyenv binary not found. Installing pyenv..."
            install_pyenv
        fi
    else
        echo "✗ pyenv is not installed. Attempting to install..."
        install_pyenv
    fi
fi

# Function to install pyenv
install_pyenv() {
    echo "Installing pyenv..."
    
    # Install dependencies
    sudo apt-get update -qq
    sudo apt-get install -y -qq make build-essential libssl-dev zlib1g-dev \
        libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
        libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
        libffi-dev liblzma-dev git
    
    # Install pyenv
    if [ ! -d "$HOME/.pyenv" ]; then
        curl https://pyenv.run | bash || {
            # Fallback installation method
            git clone https://github.com/pyenv/pyenv.git ~/.pyenv
        }
    fi
    
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"
    
    # Initialize pyenv for this session
    if [ -f "$PYENV_ROOT/bin/pyenv" ]; then
        eval "$(pyenv init -)"
        echo "✓ pyenv installed successfully"
    else
        echo "✗ pyenv installation failed"
        return 1
    fi
}

# Ensure pyenv is in PATH and initialized
if command -v pyenv &> /dev/null || [ -d "$HOME/.pyenv" ]; then
    if [ -z "$PYENV_ROOT" ]; then
        export PYENV_ROOT="$HOME/.pyenv"
    fi
    export PATH="$PYENV_ROOT/bin:$PATH"
    
    # Initialize pyenv
    if [ -f "$PYENV_ROOT/bin/pyenv" ]; then
        eval "$(pyenv init -)" 2>/dev/null || true
    fi
fi

# Check if pyenv is now available
if ! command -v pyenv &> /dev/null; then
    echo "✗ pyenv is still not available after installation attempt"
    echo "Falling back to system Python check..."
    
    # Fallback: check system Python version
    if command -v python3 &> /dev/null; then
        CURRENT_VERSION=$(python3 --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
        echo "Current system Python version: $CURRENT_VERSION"
        
        if [ "$(printf '%s\n' "$TARGET_PYTHON_VERSION" "$CURRENT_VERSION" | sort -V | head -n1)" = "$TARGET_PYTHON_VERSION" ]; then
            echo "✓ System Python $CURRENT_VERSION is >= $TARGET_PYTHON_VERSION"
            return 0
        else
            echo "⚠ System Python $CURRENT_VERSION is < $TARGET_PYTHON_VERSION"
            echo "⚠ Consider using a Docker image with Python 3.12+ or manually installing Python 3.12"
            return 1
        fi
    else
        echo "✗ python3 not found"
        return 1
    fi
fi

# Check current Python version
echo "Checking current Python version..."
if command -v python3 &> /dev/null; then
    CURRENT_VERSION=$(python3 --version 2>&1 | grep -oP '\d+\.\d+' | head -1 || echo "0.0")
    echo "Current Python version: $CURRENT_VERSION"
else
    CURRENT_VERSION="0.0"
fi

# Check if we need to upgrade
NEEDS_UPGRADE=false
if [ "$CURRENT_VERSION" = "0.0" ]; then
    NEEDS_UPGRADE=true
elif [ "$(printf '%s\n' "$TARGET_PYTHON_VERSION" "$CURRENT_VERSION" | sort -V | head -n1)" != "$TARGET_PYTHON_VERSION" ]; then
    NEEDS_UPGRADE=true
fi

if [ "$NEEDS_UPGRADE" = true ]; then
    echo "Python $TARGET_PYTHON_VERSION+ is required. Current version: $CURRENT_VERSION"
    echo "Installing Python $MINOR_VERSION via pyenv..."
    
    # Install Python 3.12 using pyenv
    # Try specific version first, then fall back to major.minor
    if pyenv install -s "$MINOR_VERSION" 2>/dev/null; then
        echo "✓ Python $MINOR_VERSION installed successfully"
        INSTALLED_VERSION="$MINOR_VERSION"
    else
        echo "Trying to install latest Python $TARGET_PYTHON_VERSION..."
        # Try to install latest patch version of 3.12
        LATEST_312=$(pyenv install --list | grep -E "^\s+3\.12\.[0-9]+$" | tail -1 | xargs)
        if [ -n "$LATEST_312" ]; then
            if pyenv install -s "$LATEST_312"; then
                echo "✓ Python $LATEST_312 installed successfully"
                INSTALLED_VERSION="$LATEST_312"
            else
                echo "✗ Failed to install Python $TARGET_PYTHON_VERSION"
                return 1
            fi
        else
            echo "✗ Could not find Python $TARGET_PYTHON_VERSION in pyenv"
            return 1
        fi
    fi
    
    # Set the installed version as global
    if [ -n "$INSTALLED_VERSION" ]; then
        pyenv global "$INSTALLED_VERSION"
        echo "✓ Set Python $INSTALLED_VERSION as global version"
    fi
    
    # Update PATH to include pyenv shims
    export PATH="$(pyenv root)/shims:$PATH"
    
    # Verify the upgrade
    NEW_VERSION=$(python3 --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
    if [ "$(printf '%s\n' "$TARGET_PYTHON_VERSION" "$NEW_VERSION" | sort -V | head -n1)" = "$TARGET_PYTHON_VERSION" ]; then
        echo "✓ Python upgraded successfully to: $NEW_VERSION"
    else
        echo "⚠ Python version after upgrade: $NEW_VERSION (expected >= $TARGET_PYTHON_VERSION)"
        return 1
    fi
else
    echo "✓ Python version is already sufficient: $CURRENT_VERSION (>= $TARGET_PYTHON_VERSION)"
    
    # Still ensure pyenv shims are in PATH
    if command -v pyenv &> /dev/null; then
        export PATH="$(pyenv root)/shims:$PATH"
    fi
fi

# Display final Python version
echo "Final Python version: $(python3 --version)"
echo "Python path: $(which python3)"

echo "=== Python upgrade completed ==="

