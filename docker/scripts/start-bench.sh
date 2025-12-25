#!/bin/bash
# Start bench processes manually (without bench start command)

set -e

BENCH_DIR="${BENCH_DIR:-/home/frappe/frappe-bench}"
SITE_NAME="${SITE_NAME:-hrms.localhost}"

echo "=== Starting bench processes ==="

cd "$BENCH_DIR"

# Set site environment variable
export FRAPPE_SITE="$SITE_NAME"

# Start processes based on Procfile if it exists
if [ -f "$BENCH_DIR/Procfile" ]; then
    echo "Starting processes from Procfile..."
    
    # Read Procfile and start processes
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        
        # Extract process name and command
        process_name=$(echo "$line" | cut -d: -f1)
        command=$(echo "$line" | cut -d: -f2- | xargs)
        
        # Skip disabled processes (commented out in Procfile)
        [[ "$process_name" =~ ^#.*$ ]] && continue
        
        echo "Starting $process_name..."
        
        # Start process in background
        cd "$BENCH_DIR"
        eval "$command" > "$BENCH_DIR/logs/$process_name.log" 2>&1 &
        echo $! > "$BENCH_DIR/logs/$process_name.pid"
    done < "$BENCH_DIR/Procfile"
else
    # Fallback: start gunicorn directly
    echo "Procfile not found, starting gunicorn directly..."
    cd "$BENCH_DIR"
    "$BENCH_DIR/env/bin/gunicorn" \
        frappe.app:application \
        --bind 0.0.0.0:8000 \
        --workers 4 \
        --timeout 120 \
        --log-level info \
        --access-logfile "$BENCH_DIR/logs/web.log" \
        --error-logfile "$BENCH_DIR/logs/web.error.log" \
        > "$BENCH_DIR/logs/gunicorn.log" 2>&1 &
    echo $! > "$BENCH_DIR/logs/gunicorn.pid"
fi

echo "✓ Bench processes started"
echo "Logs are available in $BENCH_DIR/logs/"

# Keep script running
wait

