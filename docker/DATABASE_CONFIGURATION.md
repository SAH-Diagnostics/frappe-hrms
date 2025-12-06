# Database Configuration Guide

This document explains how the updated Docker configuration handles local and remote database connections while keeping them completely separate.

## Overview

The configuration supports two database modes:
1. **Local Development**: Uses MariaDB container (default)
2. **Production/AWS**: Uses external RDS database

**Important**: Local and remote databases are kept completely separate - no automatic migration occurs.

## Configuration Files

### `docker-compose.yml`
- Defines MariaDB service for local development
- Passes database environment variables to frappe service
- Supports both `DB_*` and `RDS_*` variable names for compatibility

### `init.sh`
- Automatically detects which database to use based on environment variables
- Prevents overwriting existing data
- Handles both fresh installations and existing benches

## Environment Variables

### For Local Development (Default)
No environment variables needed - uses local MariaDB container automatically.

### For External RDS
Set these environment variables (via `.env` file or deployment):

```env
# Primary variables (preferred)
DB_HOST=your-rds-endpoint.region.rds.amazonaws.com
DB_PORT=3306
DB_USER=admin
DB_PASSWORD=your-secure-password
ADMIN_PASSWORD=your-admin-password

# Alternative RDS variables (for compatibility)
RDS_HOSTNAME=your-rds-endpoint.region.rds.amazonaws.com
RDS_PORT=3306
RDS_USERNAME=admin
RDS_PASSWORD=your-secure-password

# Safety flag (set to true when deploying to existing RDS)
EXISTING_SITE=true
```

## Scenarios Handled

### ✅ Scenario 1: Fresh Installation - Local Database
**Setup**: No environment variables set
**Behavior**:
- Creates new bench
- Connects to local MariaDB container
- Creates new site `hrms.localhost`
- Installs HRMS app
- Starts bench

**Command**:
```bash
docker-compose up -d
```

### ✅ Scenario 2: Fresh Installation - External RDS
**Setup**: `DB_HOST` environment variable set
**Behavior**:
- Creates new bench
- Connects to external RDS
- Verifies database connectivity
- Creates new site `hrms.localhost` in RDS
- Installs HRMS app
- Starts bench

**Command**:
```bash
# With .env file containing DB_HOST, etc.
docker-compose --env-file .env up -d
```

### ✅ Scenario 3: Existing Bench - Local Database
**Setup**: Bench exists, no environment variables
**Behavior**:
- Detects existing bench
- Uses existing database configuration (local MariaDB)
- Verifies site exists
- Starts bench (no data changes)

**Result**: ✅ **Safe** - Existing data preserved

### ✅ Scenario 4: Existing Bench - External RDS (Same RDS)
**Setup**: Bench exists, `DB_HOST` points to same RDS
**Behavior**:
- Detects existing bench
- Updates database host configuration
- Verifies site exists in RDS
- Starts bench (no data changes)

**Result**: ✅ **Safe** - Existing RDS data preserved

### ✅ Scenario 5: Existing Bench - Switching to Different RDS
**Setup**: Bench exists, `DB_HOST` points to different RDS
**Behavior**:
- Detects existing bench
- Updates database host configuration
- Checks if site exists in new RDS
- **Fails safely** if site doesn't exist (prevents accidental data loss)

**Result**: ✅ **Safe** - Fails with clear error message

### ✅ Scenario 6: Fresh Bench - Existing RDS with Data
**Setup**: No bench, `DB_HOST` set, RDS already has site data
**Behavior**:
- Creates new bench
- Connects to external RDS
- Detects existing site in database
- **Requires `EXISTING_SITE=true`** to proceed
- Uses existing site data (no overwrite)

**Result**: ✅ **Safe** - Requires explicit flag to use existing data

### ✅ Scenario 7: Fresh Bench - Existing RDS without Site
**Setup**: No bench, `DB_HOST` set, RDS empty or has other data
**Behavior**:
- Creates new bench
- Connects to external RDS
- Verifies connectivity
- Creates new site (no conflict)

**Result**: ✅ **Safe** - Creates new site in empty/new database

## Safety Features

### 1. Site Existence Check
Before starting, the script verifies the site exists in the configured database:
```bash
bench --site hrms.localhost list-apps
```
If site doesn't exist, script fails with clear error message.

### 2. EXISTING_SITE Flag
When deploying to RDS that already has data:
- Set `EXISTING_SITE=true` to use existing site
- Without this flag, script will fail if site exists (prevents accidental overwrites)

### 3. Database Separation
- Local MariaDB and remote RDS are completely separate
- No automatic migration between them
- Each maintains its own data independently

### 4. Connection Verification
- Tests database connectivity before creating sites
- Provides clear error messages if connection fails

## Usage Examples

### Local Development
```bash
# Start with local MariaDB (default)
docker-compose up -d

# View logs
docker-compose logs -f frappe
```

### AWS Deployment with RDS
```bash
# Create .env file
cat > .env << EOF
DB_HOST=my-rds.region.rds.amazonaws.com
DB_PORT=3306
DB_USER=admin
DB_PASSWORD=secure-password
ADMIN_PASSWORD=admin-password
EXISTING_SITE=true
EOF

# Deploy
docker-compose --env-file .env up -d
```

### Switching Between Databases
**Important**: To switch from local to RDS (or vice versa), you need to:
1. **Backup existing data** (if you want to preserve it)
2. **Remove the bench directory** to start fresh, OR
3. **Manually migrate data** using bench backup/restore commands

The script will **NOT** automatically migrate data between databases to keep them separate.

## Troubleshooting

### Error: "Site does not exist in database"
**Cause**: Bench exists but site is missing from database
**Solution**: 
- Remove bench directory to reinitialize: `docker-compose down -v` (removes volumes)
- Or manually create site: `bench new-site hrms.localhost`

### Error: "Site exists but EXISTING_SITE not set to 'true'"
**Cause**: Database already has site data, but safety flag not set
**Solution**: Set `EXISTING_SITE=true` in environment variables

### Error: "Cannot connect to database"
**Cause**: Network or credential issues
**Solution**:
- Verify RDS security group allows connections from Docker host
- Check database credentials
- Verify RDS endpoint and port are correct

### Error: "Bench exists but site is missing"
**Cause**: Bench directory exists but site was deleted from database
**Solution**: Remove bench directory to reinitialize, or restore from backup

## Best Practices

1. **Always backup before major changes**:
   ```bash
   bench --site hrms.localhost backup
   ```

2. **Use EXISTING_SITE=true for production deployments** to existing RDS

3. **Keep local and production databases separate** - don't mix them

4. **Use environment files** (`.env`) for sensitive credentials

5. **Test database connectivity** before deploying to production

6. **Monitor logs** during first deployment:
   ```bash
   docker-compose logs -f frappe
   ```

