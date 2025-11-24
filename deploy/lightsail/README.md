# Lightsail Deployment Notes

This folder documents everything the new `build-deploy.yml` workflow needs in order to build the Docker images and deploy them to the Lightsail instance.

## 1. Prerequisites on Lightsail
- Ubuntu (or similar) instance with `docker`, `docker compose` plugin, and `tar` already installed.
- **Nginx with SSL/TLS (certbot) preconfigured** - The nginx reverse proxy and SSL certificates should be set up beforehand to proxy requests from port 80/443 to the Frappe container on port 8000.
- Lightsail MariaDB/MySQL database provisioned. **Note:** Frappe requires MariaDB or MySQL, not PostgreSQL. Note the **endpoint**, **port**, **database name**, **username**, and **password** from the AWS console.
- A system user (e.g., `ubuntu` or `frappe`) with passwordless `sudo` for Docker commands and SSH key–based access enabled.
- Target project directory, e.g., `/opt/frappe-hrms`, writable by the SSH user.

## 2. GitHub Secrets that must be set
| Secret | Description |
| --- | --- |
| `AWS_ACCESS_KEY_ID` | Access key with permissions for Secrets Manager + Lightsail (read-only is enough) |
| `AWS_SECRET_ACCESS_KEY` | Matching secret key |
| `AWS_REGION` | Region where both the Lightsail resources and secret live |
| `AWS_DEPLOY_SECRET_ID` | Name or full ARN of the Secrets Manager secret that stores the deployment payload described below |

> Optional: keep long-lived values such as `REMOTE_PROJECT_PATH` in GitHub repository **variables** if you do not want them versioned inside the AWS secret.

## 3. AWS Secrets Manager payload
Create a JSON secret (console → Secrets Manager → "Store a new secret") containing the following keys. The workflow downloads this JSON and never echoes it in logs.

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

**Important:** The `SITE_URL` field is critical for generating correct URLs in email notifications and API redirects. It should be the full public URL (including protocol) where users will access your Frappe instance.

### Field notes
- `lightsail_private_key_b64`: Base64 encode the private key that corresponds to the public key installed on the instance.
  - macOS/Linux: `base64 -w0 LightsailDefaultKeyPair.pem`
  - PowerShell: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("LightsailDefaultKeyPair.pem"))`
- `DATABASE_*` fields: Connection details for your MariaDB/MySQL database. These are automatically converted to `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, and `DB_PASSWORD` environment variables.
- `SITE_NAME`: Internal Frappe site identifier (e.g., `dev-hrms.sahdiagnostics.com` or `35_179_41_158` for IP-based access). This is used as the site folder name in Frappe.
- `SITE_URL`: **Critical** - The full public URL where users access your site (e.g., `https://www.dev-hrms.sahdiagnostics.com`). This is used by Frappe to generate URLs in email notifications, password reset links, and API redirects. **Do not include port numbers** unless your users actually need to access via a specific port.
- `env_file_content`: (Optional) Raw contents that will become `deploy/lightsail/.env.remote`. If you provide `DATABASE_*` fields, this is auto-generated. You can still provide this to add custom environment variables.
- You can extend the JSON with additional keys if you want to parse more data later (for example, `slack_webhook`). The parsing step will simply ignore unknown keys.

## 4. Getting the parameters
1. **Lightsail host / port / user**
   - Open the Lightsail console → Instances → select instance → Networking tab for the public IP or DNS name.
   - Port is `22` unless you manually changed the SSH daemon config.
   - User is usually `ubuntu` (Ubuntu), `ec2-user` (Amazon Linux), or a custom sudo-capable user you added.
2. **SSH key**
   - Download the Lightsail default key pair or upload your own under the “Account” → “SSH keys” section.
   - Base64 encode the `.pem` before storing it in the secret as shown above.
3. **Remote project path**
   - Pick/create a directory, e.g., `/opt/frappe-hrms`. Ensure it exists and is owned by the SSH user: `sudo mkdir -p /opt/frappe-hrms && sudo chown ubuntu:ubuntu /opt/frappe-hrms`.
4. **MariaDB/MySQL credentials**
   - Lightsail console → Databases → select DB → use the connection details card.
   - **Important:** Ensure you provision a MariaDB or MySQL database, not PostgreSQL. Frappe requires MariaDB/MySQL.
   - Add these values as `DATABASE_ENDPOINT`, `DATABASE_PORT`, `DATABASE_NAME`, `DATABASE_USERNAME`, and `DATABASE_PASSWORD` in the AWS secret.
5. **Site configuration**
   - `SITE_NAME`: Can be your domain (e.g., `dev-hrms.sahdiagnostics.com`) or IP with underscores (e.g., `35_179_41_158`).
   - `SITE_URL`: **Must** be the full public URL with protocol (e.g., `https://www.dev-hrms.sahdiagnostics.com`). This ensures email links and API redirects work correctly.

## 5. What the workflow does
1. Runs on every push to `main` or when manually triggered via `workflow_dispatch`.
2. Retrieves deployment configuration from AWS Secrets Manager.
3. Prepares the environment file with database credentials, site name, and site URL.
4. Clones or updates the repository on the Lightsail instance.
5. Deploys using `docker compose up -d --build` with the prepared environment file.
6. Cleans dangling Docker artifacts via `docker system prune -f`.

**Note:** The workflow assumes nginx is already configured on the instance to reverse proxy to Frappe on port 8000. A reference nginx configuration is available in `deploy/lightsail/nginx.conf` for manual setup if needed.

## 6. Validating the setup
- Run `aws secretsmanager get-secret-value --secret-id <id>` locally to confirm the JSON parses and the base64 key decodes.
- Test SSH connectivity from your workstation using the decoded key: `ssh -i lightsail.pem ubuntu@HOST`.
- On the instance, confirm `docker compose version` prints at least `v2.5`.
- Verify nginx is properly configured and running: `sudo systemctl status nginx`
- Perform a dry-run: use `workflow_dispatch` trigger to run the workflow manually and verify permissions and firewall rules.
- After deployment, check that the site URL is configured correctly by logging into Frappe and checking System Settings or running:
  ```bash
  sudo docker compose -f /opt/frappe-hrms/docker/docker-compose.yml exec frappe bench --site <SITE_NAME> get-config host_name
  ```
  This should return your `SITE_URL` value (e.g., `https://www.dev-hrms.sahdiagnostics.com`).

## 7. Troubleshooting

### Email links include port number (e.g., :8000)
This happens when `SITE_URL` is not configured correctly. Ensure:
1. `SITE_URL` is set in your AWS Secrets Manager secret
2. `SITE_URL` includes the protocol but **no port number** (e.g., `https://www.dev-hrms.sahdiagnostics.com`)
3. After updating the secret, redeploy or manually update the site config:
   ```bash
   sudo docker compose -f /opt/frappe-hrms/docker/docker-compose.yml exec frappe \
     bench --site <SITE_NAME> set-config host_name "https://www.dev-hrms.sahdiagnostics.com"
   ```

### Email links use internal IP address
This also indicates `SITE_URL` is not set. Follow the steps above.

If you need additional inputs (for example, Docker Hub credentials, Slack hooks, etc.) add them either as GitHub secrets or as new keys in the AWS secret and extend the parsing step inside the workflow.

