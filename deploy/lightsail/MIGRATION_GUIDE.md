# Migration Guide: Fixing Email URL Issues

This guide explains how to fix the URL generation issues in Frappe where email links include incorrect ports or internal IP addresses.

## Problem

When Frappe sends emails (user registration, password reset, etc.), the URLs are malformed:
- **Wrong:** `https://www.dev-hrms.sahdiagnostics.com:8000/api/method/frappe.www.login.login_via_key?key=...`
- **Correct:** `https://www.dev-hrms.sahdiagnostics.com/api/method/frappe.www.login.login_via_key?key=...`

Or:
- **Wrong:** `http://35_179_41_158:8000/update-password?key=...`
- **Correct:** `https://www.dev-hrms.sahdiagnostics.com/update-password?key=...`

## Root Cause

Frappe's `host_name` configuration was not set correctly. Frappe uses this setting to generate all URLs in emails and API responses.

## Solution

### Step 1: Update AWS Secrets Manager

1. Open AWS Console → Secrets Manager
2. Find your deployment secret (the one referenced in `AWS_DEPLOY_SECRET_ID`)
3. Click "Retrieve secret value" → "Edit"
4. Add or update these fields in the JSON:

```json
{
  "SITE_NAME": "dev-hrms.sahdiagnostics.com",
  "SITE_URL": "https://www.dev-hrms.sahdiagnostics.com",
  ... (keep other existing fields)
}
```

**Important:**
- `SITE_NAME`: Your domain name (can also be IP with underscores like `35_179_41_158`)
- `SITE_URL`: **Must** be the full public URL with HTTPS protocol and **no port number**

5. Save the secret

### Step 2: Redeploy

Option A: **Push a new commit** (recommended)
```bash
git add .
git commit -m "Update deployment configuration"
git push origin main
```

Option B: **Trigger workflow manually**
1. Go to GitHub → Actions → "Deploy to AWS Lightsail"
2. Click "Run workflow" → "Run workflow"

### Step 3: Verify the Fix

After deployment completes:

1. SSH into your Lightsail instance:
   ```bash
   ssh -i your-key.pem ubuntu@<your-lightsail-ip>
   ```

2. Check the Frappe configuration:
   ```bash
   cd /opt/frappe-hrms
   sudo docker compose -f docker/docker-compose.yml exec frappe \
     bench --site dev-hrms.sahdiagnostics.com get-config host_name
   ```

3. It should return: `https://www.dev-hrms.sahdiagnostics.com`

4. If not correct, manually update it:
   ```bash
   sudo docker compose -f docker/docker-compose.yml exec frappe \
     bench --site dev-hrms.sahdiagnostics.com set-config host_name "https://www.dev-hrms.sahdiagnostics.com"
   ```

5. Clear the cache:
   ```bash
   sudo docker compose -f docker/docker-compose.yml exec frappe \
     bench --site dev-hrms.sahdiagnostics.com clear-cache
   ```

### Step 4: Test Email URLs

1. Log in to your Frappe instance
2. Create a test user or use the "Forgot Password" feature
3. Check the email - the URLs should now be correct

## Quick Fix (Without Redeploying)

If you need an immediate fix without redeploying:

```bash
# SSH into your instance
ssh -i your-key.pem ubuntu@<your-lightsail-ip>

# Navigate to project directory
cd /opt/frappe-hrms

# Update the site URL configuration
sudo docker compose -f docker/docker-compose.yml exec frappe \
  bench --site <YOUR_SITE_NAME> set-config host_name "https://www.dev-hrms.sahdiagnostics.com"

# Clear cache
sudo docker compose -f docker/docker-compose.yml exec frappe \
  bench --site <YOUR_SITE_NAME> clear-cache
```

Replace `<YOUR_SITE_NAME>` with your actual site name (e.g., `dev-hrms.sahdiagnostics.com` or `35_179_41_158`).

## Understanding the Changes

The deployment system now:

1. **Reads `SITE_URL` from AWS Secrets Manager** - This is the public URL users will use
2. **Passes it to Frappe during initialization** - Sets the `host_name` config
3. **Updates it on every deployment** - Ensures consistency

This ensures that:
- Email links use the correct domain (not internal IP)
- Port numbers are not included in URLs (nginx handles the proxy)
- HTTPS is used in all generated URLs

## Additional Configuration

If you're behind a load balancer or using a custom domain:

1. Ensure nginx is configured to set proper headers:
   ```nginx
   proxy_set_header X-Forwarded-Proto $scheme;
   proxy_set_header X-Forwarded-Host $host;
   ```

2. This is already included in the deployment workflow's nginx configuration.

## Need Help?

If URLs are still incorrect after following these steps:

1. Check nginx is running: `sudo systemctl status nginx`
2. Check nginx configuration: `sudo nginx -t`
3. Check Frappe logs: `sudo docker compose -f /opt/frappe-hrms/docker/docker-compose.yml logs frappe`
4. Verify the environment file: `cat /opt/frappe-hrms/deploy/lightsail/.env.remote`

