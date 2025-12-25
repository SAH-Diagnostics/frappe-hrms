# Manual Bench Setup Scripts

This directory contains modular scripts that replace all `bench` commands with manual operations. The scripts are completely decoupled from bench CLI and use direct Python/Frappe API calls and file operations.

## Script Overview

### Core Scripts

1. **frappe-utils.sh** - Utility functions for Frappe operations
   - `update_common_config()` - Update common_site_config.json
   - `update_site_config()` - Update site_config.json
   - `site_exists()` - Check if site exists
   - `frappe_python()` - Run Python code with site context
   - `clear_cache()` - Clear Frappe cache

2. **setup-bench.sh** - Manual bench initialization
   - Creates bench directory structure
   - Clones Frappe repository
   - Creates and configures virtual environment
   - Installs Frappe in editable mode
   - Handles Python version compatibility (3.11 vs 3.12+)

3. **setup-database-config.sh** - Database and Redis configuration
   - Configures database host/port in common_site_config.json
   - Sets up Redis endpoints
   - Cleans up Procfile

4. **setup-apps.sh** - Get and install apps
   - Clones ERPNext and HRMS repositories
   - Installs app dependencies via pip
   - Installs Node.js dependencies for Frappe

5. **setup-site.sh** - Site creation and configuration
   - Tests database connection
   - Creates site directory structure
   - Creates site_config.json
   - Initializes database schema using Frappe Python API
   - Handles both new and existing sites
   - Supports external RDS and local MariaDB

6. **install-app-manual.sh** - Manual app installation
   - Installs apps into a site using Frappe Python API
   - Checks if app is already installed
   - Usage: `./install-app-manual.sh <app_name>`

7. **configure-site.sh** - Site settings configuration
   - Sets developer_mode
   - Enables scheduler via database update
   - Clears cache

8. **start-bench.sh** - Start bench processes
   - Reads Procfile and starts processes
   - Falls back to direct gunicorn if Procfile missing
   - Runs processes in background

## Main Entry Point

**init.sh** (in parent directory) - Minimal orchestrator script that:
1. Calls upgrade-python.sh (if exists)
2. Calls install-aws-cli.sh (if exists)
3. Calls all setup scripts in order
4. Installs bucket helper scripts
5. Starts bench

## Key Differences from Bench Commands

### Replaced Commands

| Bench Command | Manual Replacement |
|--------------|-------------------|
| `bench init` | `setup-bench.sh` - Manual directory creation, git clone, venv setup |
| `bench set-config --global` | Direct JSON file editing via Python |
| `bench set-config` (site) | Direct JSON file editing via Python |
| `bench get-app` | `setup-apps.sh` - Git clone + pip install |
| `bench new-site` | `setup-site.sh` - Manual site creation + Python API |
| `bench --site migrate` | Python: `frappe.init()` + `frappe.connect()` |
| `bench --site install-app` | `install-app-manual.sh` - Python: `frappe.installer.install_app()` |
| `bench --site enable-scheduler` | Database SQL update |
| `bench --site clear-cache` | File deletion (`clear_cache()` function) |
| `bench use` | Environment variable: `export FRAPPE_SITE=...` |
| `bench start` | `start-bench.sh` - Parse Procfile and start processes |

## Benefits

1. **No Bench Dependency**: Scripts work without bench CLI installed
2. **Modular**: Each step is a separate script, easy to debug and modify
3. **Transparent**: All operations are explicit and visible
4. **Flexible**: Easy to customize individual steps
5. **Maintainable**: Clear separation of concerns

## Usage

The scripts are automatically called by `init.sh`. To run individual scripts:

```bash
cd /home/frappe/frappe-bench
export BENCH_DIR=/home/frappe/frappe-bench
export SITE_NAME=hrms.localhost
bash docker/scripts/setup-bench.sh
bash docker/scripts/setup-apps.sh
# etc.
```

## Environment Variables

All scripts use these environment variables (with defaults):
- `BENCH_DIR` - Bench directory (default: `/home/frappe/frappe-bench`)
- `SITE_NAME` - Site name (default: `hrms.localhost`)
- `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` - Database config
- `ADMIN_PASSWORD` - Admin user password
- `FRAPPE_BRANCH` - Frappe branch (default: `develop` - latest)
- `SITE_URL` - Public site URL

## Notes

- All Python operations use the virtual environment at `$BENCH_DIR/env`
- Site configuration is stored in JSON files, edited directly
- Database operations use Frappe's Python API instead of bench commands
- Scripts are idempotent - safe to run multiple times

