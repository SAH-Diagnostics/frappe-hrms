#!/bin/bash

# upgrade-python.sh
# Purpose: Upgrade Python to the latest stable version using pyenv
# This script automatically detects and installs the latest stable Python version

set -e

# Minimum Python version required (for compatibility checks)
MIN_REQUIRED_VERSION="${MIN_REQUIRED_VERSION:-3.11}"
# Maximum Python version (to avoid compatibility issues with older packages)
# Note: Python 3.12+ removed the 'imp' module which hiredis==2.0.0 requires
# Capped at 3.11 to ensure compatibility with hiredis 2.0.0
MAX_PYTHON_VERSION="${MAX_PYTHON_VERSION:-3.11}"

echo "=== Upgrading Python to latest stable version using pyenv ==="

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

# Function to get the latest stable Python version from pyenv
get_latest_stable_python() {
    if ! command -v pyenv &> /dev/null; then
        echo ""
        return 1
    fi
    
    # Get list of available Python versions from pyenv
    # Filter for stable releases (exclude dev, alpha, beta, rc versions)
    # Respect MAX_PYTHON_VERSION to avoid compatibility issues
    # Format: 3.12.0, 3.12.1, etc.
    MAX_MAJOR_MINOR=$(echo "$MAX_PYTHON_VERSION" | grep -oP '\d+\.\d+' | head -1)
    
    # Get all available versions
    ALL_VERSIONS=$(pyenv install --list 2>/dev/null | \
        grep -E "^\s+3\.[0-9]+\.[0-9]+$" | \
        grep -vE "(a|b|rc|dev)" | \
        sed 's/^[[:space:]]*//' | \
        sort -V)
    
    # Filter versions that are <= MAX_PYTHON_VERSION using version comparison
    if [ -n "$MAX_MAJOR_MINOR" ]; then
        # Add .999 to MAX to include all patch versions
        MAX_VERSION="${MAX_MAJOR_MINOR}.999"
        LATEST_VERSION=$(echo "$ALL_VERSIONS" | \
            while read version; do
                if [ "$(printf '%s\n' "$version" "$MAX_VERSION" | sort -V | head -n1)" = "$version" ]; then
                    echo "$version"
                fi
            done | tail -1)
    else
        # Default: cap at 3.12 to avoid compatibility issues
        LATEST_VERSION=$(echo "$ALL_VERSIONS" | \
            grep -E "^3\.(1[0-2]|[0-9])\." | tail -1)
    fi
    
    if [ -n "$LATEST_VERSION" ]; then
        echo "$LATEST_VERSION"
        return 0
    else
        echo ""
        return 1
    fi
}

# Function to get latest stable version from Python.org API (fallback)
get_latest_stable_python_from_api() {
    # Try to get latest stable version from Python.org
    LATEST_VERSION=$(curl -s https://www.python.org/api/v2/downloads/releases/ | \
        grep -oE '"name":\s*"Python\s+[0-9]+\.[0-9]+\.[0-9]+"' | \
        head -1 | \
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | \
        head -1) || true
    
    if [ -n "$LATEST_VERSION" ]; then
        echo "$LATEST_VERSION"
        return 0
    else
        # Fallback: try a simpler approach - get latest from pyenv's known versions
        # This is a conservative fallback
        echo "3.13.0"  # Update this if needed as a last resort
        return 0
    fi
}

# Check if pyenv is now available
if ! command -v pyenv &> /dev/null; then
    echo "✗ pyenv is still not available after installation attempt"
    echo "Falling back to system Python check..."
    
    # Fallback: check system Python version
    if command -v python3 &> /dev/null; then
        CURRENT_VERSION=$(python3 --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
        echo "Current system Python version: $CURRENT_VERSION"
        
        if [ "$(printf '%s\n' "$MIN_REQUIRED_VERSION" "$CURRENT_VERSION" | sort -V | head -n1)" = "$MIN_REQUIRED_VERSION" ]; then
            echo "✓ System Python $CURRENT_VERSION is >= $MIN_REQUIRED_VERSION"
            return 0
        else
            echo "⚠ System Python $CURRENT_VERSION is < $MIN_REQUIRED_VERSION"
            echo "⚠ Consider using a Docker image with Python $MIN_REQUIRED_VERSION+ or manually installing Python"
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
    CURRENT_VERSION=$(python3 --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || python3 --version 2>&1 | grep -oP '\d+\.\d+' | head -1 || echo "0.0.0")
    echo "Current Python version: $CURRENT_VERSION"
else
    CURRENT_VERSION="0.0.0"
fi

# Get the latest stable Python version
echo "Detecting latest stable Python version..."
LATEST_STABLE=$(get_latest_stable_python)

if [ -z "$LATEST_STABLE" ]; then
    echo "Could not get latest version from pyenv, trying API fallback..."
    LATEST_STABLE=$(get_latest_stable_python_from_api)
fi

if [ -z "$LATEST_STABLE" ]; then
    echo "✗ Could not determine latest stable Python version"
    echo "Falling back to minimum required version: $MIN_REQUIRED_VERSION"
    LATEST_STABLE="${MIN_REQUIRED_VERSION}.0"
fi

if [ -n "$MAX_PYTHON_VERSION" ] && [ "$MAX_PYTHON_VERSION" != "999.999" ]; then
    echo "Latest stable Python version available (capped at $MAX_PYTHON_VERSION for compatibility): $LATEST_STABLE"
else
    echo "Latest stable Python version available: $LATEST_STABLE"
fi

# Extract major.minor for comparison
CURRENT_MAJOR_MINOR=$(echo "$CURRENT_VERSION" | grep -oP '\d+\.\d+' | head -1 || echo "0.0")
LATEST_MAJOR_MINOR=$(echo "$LATEST_STABLE" | grep -oP '\d+\.\d+' | head -1)

# Check if we need to upgrade
NEEDS_UPGRADE=false
if [ "$CURRENT_VERSION" = "0.0.0" ] || [ "$CURRENT_VERSION" = "0.0" ]; then
    NEEDS_UPGRADE=true
    echo "Python not found, will install latest stable version"
elif [ "$(printf '%s\n' "$LATEST_STABLE" "$CURRENT_VERSION" | sort -V | head -n1)" != "$LATEST_STABLE" ]; then
    # Current version is older than latest stable
    NEEDS_UPGRADE=true
    echo "Current version ($CURRENT_VERSION) is older than latest stable ($LATEST_STABLE)"
elif [ "$(printf '%s\n' "$MIN_REQUIRED_VERSION" "$CURRENT_MAJOR_MINOR" | sort -V | head -n1)" != "$MIN_REQUIRED_VERSION" ]; then
    # Current version doesn't meet minimum requirement
    NEEDS_UPGRADE=true
    echo "Current version ($CURRENT_VERSION) doesn't meet minimum requirement ($MIN_REQUIRED_VERSION+)"
else
    echo "Current version ($CURRENT_VERSION) meets requirements (>= $MIN_REQUIRED_VERSION)"
    # Check if we should still upgrade to latest for better features
    if [ "$(printf '%s\n' "$LATEST_STABLE" "$CURRENT_VERSION" | sort -V | head -n1)" = "$LATEST_STABLE" ] && [ "$CURRENT_VERSION" != "$LATEST_STABLE" ]; then
        echo "Note: Latest stable version ($LATEST_STABLE) is available, but current version is sufficient"
        # Optionally upgrade anyway - uncomment the next line to always upgrade to latest
        # NEEDS_UPGRADE=true
    fi
fi

if [ "$NEEDS_UPGRADE" = true ]; then
    echo "Upgrading Python from $CURRENT_VERSION to $LATEST_STABLE..."
    
    # Try to install the latest stable version
    if pyenv install -s "$LATEST_STABLE" 2>/dev/null; then
        echo "✓ Python $LATEST_STABLE installed successfully"
        INSTALLED_VERSION="$LATEST_STABLE"
    else
        echo "Failed to install $LATEST_STABLE, trying to find latest patch version of $LATEST_MAJOR_MINOR..."
        
        # Try to install latest patch version of the major.minor version
        LATEST_PATCH=$(pyenv install --list 2>/dev/null | \
            grep -E "^\s+${LATEST_MAJOR_MINOR}\.[0-9]+$" | \
            grep -vE "(a|b|rc|dev)" | \
            sed 's/^[[:space:]]*//' | \
            sort -V | \
            tail -1)
        
        if [ -n "$LATEST_PATCH" ]; then
            if pyenv install -s "$LATEST_PATCH" 2>/dev/null; then
                echo "✓ Python $LATEST_PATCH installed successfully"
                INSTALLED_VERSION="$LATEST_PATCH"
            else
                echo "✗ Failed to install Python $LATEST_PATCH"
                echo "Attempting to use minimum required version: $MIN_REQUIRED_VERSION"
                # Try minimum required version as last resort
                MIN_VERSION_FULL="${MIN_REQUIRED_VERSION}.0"
                if pyenv install -s "$MIN_VERSION_FULL" 2>/dev/null; then
                    echo "✓ Python $MIN_VERSION_FULL installed successfully (minimum required)"
                    INSTALLED_VERSION="$MIN_VERSION_FULL"
                else
                    echo "✗ Failed to install Python. Please check pyenv installation."
                    return 1
                fi
            fi
        else
            echo "✗ Could not find a suitable Python version to install"
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
    NEW_VERSION=$(python3 --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || python3 --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
    NEW_MAJOR_MINOR=$(echo "$NEW_VERSION" | grep -oP '\d+\.\d+' | head -1)
    
    if [ "$(printf '%s\n' "$MIN_REQUIRED_VERSION" "$NEW_MAJOR_MINOR" | sort -V | head -n1)" = "$MIN_REQUIRED_VERSION" ]; then
        echo "✓ Python upgraded successfully to: $NEW_VERSION"
    else
        echo "⚠ Python version after upgrade: $NEW_VERSION (expected >= $MIN_REQUIRED_VERSION)"
        return 1
    fi
else
    echo "✓ Python version is already sufficient: $CURRENT_VERSION (>= $MIN_REQUIRED_VERSION)"
    
    # Still ensure pyenv shims are in PATH
    if command -v pyenv &> /dev/null; then
        export PATH="$(pyenv root)/shims:$PATH"
    fi
fi

# Display final Python version
echo "Final Python version: $(python3 --version)"
echo "Python path: $(which python3)"

echo "=== Python upgrade completed ==="

