# Lightsail Deployment Notes

This folder documents everything the new `build-deploy.yml` workflow needs in order to build the Docker images and deploy them to the Lightsail instance.

## 1. Prerequisites on Lightsail
- Ubuntu (or similar) instance with `docker`, `docker compose` plugin, `tar`, and `nginx` already installed.
- Lightsail Postgres database provisioned. Note the **endpoint**, **port**, **database name**, **username**, and **password** from the AWS console.
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
Create a JSON secret (console → Secrets Manager → “Store a new secret”) containing the following keys. The workflow downloads this JSON and never echoes it in logs.

```json
{
  "lightsail_host": "ssh.example.amazonaws.com",
  "lightsail_port": "22",
  "lightsail_user": "ubuntu",
  "remote_project_path": "/opt/frappe-hrms",
  "docker_compose_file": "docker/docker-compose.yml",
  "lightsail_private_key_b64": "<base64 encoded private key>",
  "env_file_content": "POSTGRES_HOST=...\nPOSTGRES_DB=...\nPOSTGRES_USER=...\nPOSTGRES_PASSWORD=...\nSITE_NAME=hrms.example.com\n"
}
```

### Field notes
- `lightsail_private_key_b64`: Base64 encode the private key that corresponds to the public key installed on the instance.
  - macOS/Linux: `base64 -w0 LightsailDefaultKeyPair.pem`
  - PowerShell: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("LightsailDefaultKeyPair.pem"))`
- `env_file_content`: Raw contents that will become `deploy/lightsail/.env.remote` on both the runner and the Lightsail box. Add any environment variables your containers expect (e.g., Postgres DSN, Redis URL, `SITES`, `FRAPPE_SITE_NAME`, etc.). The workflow automatically writes this string to disk before packaging the repository.
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
4. **Postgres credentials**
   - Lightsail console → Databases → select DB → use the connection details card.
   - Feed those values into `env_file_content` (`POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, etc.).
5. **Additional app settings**
   - Add per-site values to the env block (e.g., `HRMS_SITE=hrms.example.com`, `ADMIN_PASSWORD=<generated>`).

## 5. What the workflow does
1. Runs on every push to `main` or when a PR to `main` is merged.
2. Builds the containers using `docker/docker-compose.yml`.
3. Pulls the deployment data from Secrets Manager.
4. Creates `.env.remote` with your Postgres / app settings, packages the repo, and copies it to Lightsail via SCP.
5. SSHes into Lightsail, unpacks to `remote_project_path`, and runs `docker compose up -d --build` with the env file.
6. Cleans dangling Docker artifacts via `docker system prune -f`.

## 6. Validating the setup
- Run `aws secretsmanager get-secret-value --secret-id <id>` locally to confirm the JSON parses and the base64 key decodes.
- Test SSH connectivity from your workstation using the decoded key: `ssh -i lightsail.pem ubuntu@HOST`.
- On the instance, confirm `docker compose version` prints at least `v2.5`.
- Perform a dry-run: temporarily change the workflow trigger to `workflow_dispatch` and run it manually to verify permissions and firewall rules.

If you need additional inputs (for example, Docker Hub credentials, Slack hooks, etc.) add them either as GitHub secrets or as new keys in the AWS secret and extend the parsing step inside the workflow.

