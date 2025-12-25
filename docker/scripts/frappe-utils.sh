#!/bin/bash
# Frappe utility functions for manual operations

# Source this file to use the utility functions

BENCH_DIR="${BENCH_DIR:-/home/frappe/frappe-bench}"
SITE_NAME="${SITE_NAME:-hrms.localhost}"

# Update common_site_config.json
update_common_config() {
    local key="$1"
    local value="$2"
    local config_file="$BENCH_DIR/sites/common_site_config.json"
    
    # Create file if it doesn't exist
    if [ ! -f "$config_file" ]; then
        echo "{}" > "$config_file"
    fi
    
    # Use Python to update JSON (more reliable than sed)
    "$BENCH_DIR/env/bin/python" -c "
import json
import sys
with open('$config_file', 'r') as f:
    config = json.load(f)
config['$key'] = $value if '$value' not in ['true', 'false', 'null'] and not isinstance($value, str) else '$value'
with open('$config_file', 'w') as f:
    json.dump(config, f, indent=2)
" 2>/dev/null || {
        # Fallback: use jq if available, or simple sed
        if command -v jq &> /dev/null; then
            jq ". + {\"$key\": $value}" "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"
        fi
    }
}

# Update site_config.json
update_site_config() {
    local site="$1"
    local key="$2"
    local value="$3"
    local config_file="$BENCH_DIR/sites/$site/site_config.json"
    
    if [ ! -f "$config_file" ]; then
        echo "Error: site_config.json not found for site $site"
        return 1
    fi
    
    "$BENCH_DIR/env/bin/python" -c "
import json
import sys
with open('$config_file', 'r') as f:
    config = json.load(f)
config['$key'] = $value if '$value' not in ['true', 'false', 'null'] and not isinstance($value, str) else '$value'
with open('$config_file', 'w') as f:
    json.dump(config, f, indent=2)
" 2>/dev/null
}

# Check if site exists
site_exists() {
    local site="$1"
    [ -f "$BENCH_DIR/sites/$site/site_config.json" ]
}

# Run Frappe Python command with site context
frappe_python() {
    local site="$1"
    shift
    local python_code="$@"
    
    cd "$BENCH_DIR"
    export FRAPPE_SITE="$site"
    "$BENCH_DIR/env/bin/python" -c "$python_code"
}

# Clear cache
clear_cache() {
    local site="$1"
    rm -rf "$BENCH_DIR/sites/$site/__pycache__" 2>/dev/null || true
    rm -rf "$BENCH_DIR/sites/.assets" 2>/dev/null || true
    find "$BENCH_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find "$BENCH_DIR" -type f -name "*.pyc" -delete 2>/dev/null || true
}

