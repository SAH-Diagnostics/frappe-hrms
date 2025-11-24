# Deployment URL Fix - Summary of Changes

## Overview

Fixed URL generation issues in Frappe where email notifications contained incorrect URLs with port numbers or internal IP addresses.

## Problems Addressed

1. **Port number in URLs**: Email links included `:8000` port (e.g., `https://www.dev-hrms.sahdiagnostics.com:8000/api/...`)
2. **Internal IP in URLs**: Password reset links used internal IP format (e.g., `http://35_179_41_158:8000/update-password?key=...`)

## Root Cause

Frappe's `host_name` configuration was not being set, causing it to use default internal URLs based on the container's environment rather than the public-facing URL.

## Changes Made

### 1. Updated `deploy/lightsail/prepare_context.py`

**Lines 88-109**: Enhanced site configuration logic
- Added support for `SITE_NAME` environment variable from AWS Secrets Manager
- Added support for `SITE_URL` environment variable (critical for correct URL generation)
- `SITE_URL` is now passed to the deployment environment

**Key additions:**
```python
# Add the public site URL (used for email links and API redirects)
if "SITE_URL" in secret:
    env_parts.append(f"SITE_URL={secret['SITE_URL']}")
```

### 2. Updated `docker/docker-compose.yml`

**Lines 37-38**: Added SITE_URL environment variable
```yaml
# Public URL for the site (used in emails and API redirects)
- SITE_URL=${SITE_URL:-http://hrms.localhost:8000}
```

This ensures the Frappe container receives the public URL configuration.

### 3. Updated `docker/init.sh`

**Three key changes:**

a. **Line 16**: Added SITE_URL variable with default
```bash
SITE_URL="${SITE_URL:-http://hrms.localhost:8000}"
```

b. **Lines 22-34**: Enhanced site configuration update logic
```bash
# Always update the public site URL for email links and API redirects
echo "Updating site URL to: $SITE_URL"
bench set-config host_name "$SITE_URL" --site "$SITE_NAME"
```
This ensures existing sites get their URL updated on every deployment.

c. **Lines 80-82**: Added site URL configuration during site creation
```bash
# Set the public site URL for email links and API redirects
echo "Setting site URL to: $SITE_URL"
bench --site "$SITE_NAME" set-config host_name "$SITE_URL"
```
This ensures new sites are created with the correct URL from the start.

### 4. Updated `deploy/lightsail/README.md`

**Comprehensive documentation updates:**
- Clarified that Frappe requires MariaDB/MySQL (not PostgreSQL)
- Added `SITE_NAME` and `SITE_URL` to the example AWS Secrets Manager payload
- Added detailed field notes explaining the importance of `SITE_URL`
- Updated all references from "Postgres" to "MariaDB/MySQL"
- Added troubleshooting section for URL-related issues
- Added validation commands to verify the configuration

**Example AWS Secret format:**
```json
{
  "lightsail_host": "ssh.example.amazonaws.com",
  "lightsail_port": "22",
  "lightsail_user": "ubuntu",
  "remote_project_path": "/opt/frappe-hrms",
  "docker_compose_file": "docker/docker-compose.yml",
  "lightsail_private_key_b64": "<base64 encoded private key>",
  "DATABASE_ENDPOINT": "db.example.amazonaws.com",
  "DATABASE_PORT": "3306",
  "DATABASE_NAME": "frappe_db",
  "DATABASE_USERNAME": "dbadmin",
  "DATABASE_PASSWORD": "your_secure_password",
  "SITE_NAME": "dev-hrms.sahdiagnostics.com",
  "SITE_URL": "https://www.dev-hrms.sahdiagnostics.com"
}
```

### 5. Created `deploy/lightsail/MIGRATION_GUIDE.md`

**New file with step-by-step migration instructions:**
- Explains the problem and root cause
- Provides clear steps to update AWS Secrets Manager
- Includes verification commands
- Offers both redeployment and quick-fix options
- Contains troubleshooting guidance

## Required Actions

### For New Deployments

1. Add these fields to your AWS Secrets Manager secret:
   ```json
   {
     "SITE_NAME": "dev-hrms.sahdiagnostics.com",
     "SITE_URL": "https://www.dev-hrms.sahdiagnostics.com"
   }
   ```

2. Deploy normally - the workflow will configure everything correctly

### For Existing Deployments

**Option 1: Redeploy (Recommended)**
1. Update AWS Secrets Manager secret with `SITE_NAME` and `SITE_URL`
2. Push a commit or trigger the workflow manually
3. The init script will automatically update the Frappe configuration

**Option 2: Manual Quick Fix**
```bash
ssh -i your-key.pem ubuntu@<lightsail-ip>
cd /opt/frappe-hrms
sudo docker compose -f docker/docker-compose.yml exec frappe \
  bench --site <SITE_NAME> set-config host_name "https://www.dev-hrms.sahdiagnostics.com"
sudo docker compose -f docker/docker-compose.yml exec frappe \
  bench --site <SITE_NAME> clear-cache
```

## Verification

After deployment, verify the configuration:

```bash
# Check the host_name configuration
sudo docker compose -f /opt/frappe-hrms/docker/docker-compose.yml exec frappe \
  bench --site <SITE_NAME> get-config host_name

# Expected output: https://www.dev-hrms.sahdiagnostics.com
```

## Technical Details

### How Frappe Generates URLs

Frappe uses the `host_name` configuration from `site_config.json` to generate URLs in:
- Email notifications (user registration, password reset, etc.)
- API responses with links
- System-generated redirects

Without this configuration, Frappe falls back to using:
- The internal container hostname
- The port it's listening on (8000)
- HTTP instead of HTTPS

### The Nginx Reverse Proxy

Nginx is preconfigured on the Lightsail instance to:
- Listen on port 80/443 (with SSL/TLS via certbot)
- Proxy requests to Frappe on port 8000
- Set proper proxy headers (`X-Forwarded-Proto`, `X-Forwarded-Host`, etc.)

A reference configuration is available in `deploy/lightsail/nginx.conf` for manual setup if needed.

This is why the `SITE_URL` should **not** include `:8000` - users access via nginx on port 80/443, not directly to Frappe.

## Benefits

✅ Email links now use the correct public URL
✅ No port numbers in generated URLs
✅ HTTPS URLs are generated correctly
✅ Password reset links work properly
✅ User registration emails are functional
✅ Consistent URL generation across all Frappe features

## Files Modified

1. `.github/workflows/deploy.yml` - Removed nginx configuration (now preconfigured on instance)
2. `deploy/lightsail/prepare_context.py` - Enhanced to read and pass SITE_URL
3. `docker/docker-compose.yml` - Added SITE_URL environment variable
4. `docker/init.sh` - Configures Frappe's host_name setting
5. `deploy/lightsail/README.md` - Updated documentation with nginx prerequisites
6. `deploy/lightsail/MIGRATION_GUIDE.md` - Created migration guide

## Testing

After implementing these changes:

1. Create a new user or use "Forgot Password"
2. Check the email - URLs should not include `:8000` and should use the correct domain
3. Test the links - they should work directly without manual editing

## References

- Frappe Documentation: [Site Configuration](https://frappeframework.com/docs/user/en/bench/reference/configuration)
- Related Frappe configuration: `host_name` in `site_config.json`

