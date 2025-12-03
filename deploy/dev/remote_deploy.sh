#!/usr/bin/env bash
set -e

# Arguments passed from GitHub Actions via SSH:
#   1: remote user
#   2: remote project path
#   3: docker compose file (relative to project path)
#   4: deploy host (public hostname/IP, for messages only)

REMOTE_USER="$1"
REMOTE_PATH="$2"
COMPOSE_FILE="$3"
DEPLOY_HOST="$4"

if [ -z "$REMOTE_USER" ] || [ -z "$REMOTE_PATH" ] || [ -z "$COMPOSE_FILE" ]; then
  echo "Remote deploy script missing required arguments."
  echo "Usage: remote_deploy.sh <remote_user> <remote_path> <compose_file> <deploy_host>"
  exit 1
fi

echo "=== Starting deployment ==="

# Install git if not present
if ! command -v git &> /dev/null; then
  echo "Installing git..."
  sudo apt-get update && sudo apt-get install -y git
fi

# Clone or pull the repository
if [ -d "$REMOTE_PATH/.git" ]; then
  echo "=== Repository exists, pulling latest changes ==="
  cd "$REMOTE_PATH"
  sudo chown -R "$REMOTE_USER":"$REMOTE_USER" .
  git fetch origin
  git reset --hard origin/main
  git pull origin main
else
  echo "=== Cloning repository ==="
  sudo rm -rf "$REMOTE_PATH"
  sudo mkdir -p "$REMOTE_PATH"
  sudo chown -R "$REMOTE_USER":"$REMOTE_USER" "$REMOTE_PATH"
  git clone https://github.com/SAH-Diagnostics/frappe-hrms.git "$REMOTE_PATH"
  cd "$REMOTE_PATH"
fi

echo "=== Setting up environment file ==="
mkdir -p deploy/dev
mv /tmp/frappe.env deploy/dev/.env.remote

echo "=== Ensuring Docker and Docker Compose are installed ==="
# Install Docker Engine if not present
if ! command -v docker &> /dev/null; then
  echo "Docker not found, installing..."
  sudo apt-get update
  sudo apt-get install -y docker.io
  sudo systemctl enable docker
  sudo systemctl start docker
else
  echo "✓ Docker is already installed"
fi

# Ensure current user can run docker without sudo (optional, best-effort)
if groups "$USER" | grep -q '\bdocker\b'; then
  echo "✓ User '$USER' is already in the docker group"
else
  echo "Adding user '$USER' to docker group (will take effect on next login)"
  sudo groupadd -f docker
  sudo usermod -aG docker "$USER" || true
fi

# Install Docker Compose plugin (docker compose) if not present
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose plugin not found, installing..."
  sudo apt-get update
  # docker-compose-plugin provides the 'docker compose' subcommand on Ubuntu
  sudo apt-get install -y docker-compose-plugin || {
    echo "⚠ Failed to install docker-compose-plugin via apt, trying legacy docker-compose..."
    sudo apt-get install -y docker-compose || true
  }
fi

# Final verification of docker and compose
if command -v docker &> /dev/null; then
  echo "✓ Docker version:"
  docker --version || sudo docker --version || true
else
  echo "✗ Docker is still not available; deployment may fail"
fi

if docker compose version >/dev/null 2>&1; then
  echo "✓ Docker Compose (plugin) is available"
  docker compose version || true
elif command -v docker-compose >/dev/null 2>&1; then
  echo "✓ Legacy docker-compose is available"
  docker-compose version || true
else
  echo "✗ Docker Compose is not available; docker compose commands may fail"
fi

echo "=== Running pre-deployment backup ==="
BACKUP_SCRIPT="$REMOTE_PATH/scripts/sync-files-to-s3.sh"
CONTAINER_NAME="docker-frappe-1"

if [ -f "$BACKUP_SCRIPT" ] && [ -x "$BACKUP_SCRIPT" ]; then
  if sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Backup script found and container is running, triggering backup..."
    if sudo "$BACKUP_SCRIPT" >> /var/log/frappe-files-sync.log 2>&1; then
      echo "✓ Pre-deployment backup completed successfully"
    else
      BACKUP_EXIT_CODE=$?
      echo "⚠ Pre-deployment backup failed with exit code $BACKUP_EXIT_CODE"
      echo "Continuing with deployment anyway..."
      echo "Check /var/log/frappe-files-sync.log for details"
    fi
  else
    echo "⚠ Container '$CONTAINER_NAME' is not running, skipping pre-deployment backup"
    echo "This is normal on first deployment or if containers were already stopped"
  fi
else
  echo "⚠ Backup script not found or not executable at $BACKUP_SCRIPT"
  echo "Skipping pre-deployment backup (this is normal on first deployment)"
fi

echo "=== Stopping existing containers ==="
compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    sudo docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    sudo docker-compose "$@"
  else
    echo "✗ Docker Compose is not available; command failed: compose_cmd $*"
    return 1
  fi
}

if [ -f "$COMPOSE_FILE" ]; then
  compose_cmd -f "$COMPOSE_FILE" --env-file deploy/dev/.env.remote down || true
fi

echo "=== Building and starting containers ==="
compose_cmd -f "$COMPOSE_FILE" --env-file deploy/dev/.env.remote pull || true
compose_cmd -f "$COMPOSE_FILE" --env-file deploy/dev/.env.remote up -d --build

echo "=== Waiting for services to be ready ==="
sleep 15

echo "=== Container status ==="
compose_cmd -f "$COMPOSE_FILE" ps -a

echo ""
echo "=== Checking frappe container startup logs ==="
FRAPPE_CONTAINER=$(compose_cmd -f "$COMPOSE_FILE" ps -q frappe 2>/dev/null || echo "")
if [ -n "$FRAPPE_CONTAINER" ]; then
  echo "Frappe container ID: $FRAPPE_CONTAINER"
  CONTAINER_STATUS=$(sudo docker inspect -f '{{.State.Status}}' "$FRAPPE_CONTAINER" 2>/dev/null || echo "unknown")
  echo "Container status: $CONTAINER_STATUS"
  if [ "$CONTAINER_STATUS" = "exited" ] || [ "$CONTAINER_STATUS" = "dead" ]; then
    EXIT_CODE=$(sudo docker inspect -f '{{.State.ExitCode}}' "$FRAPPE_CONTAINER" 2>/dev/null || echo "unknown")
    echo "⚠ Container exited with code: $EXIT_CODE"
    echo "Last 100 lines of logs:"
    sudo docker logs "$FRAPPE_CONTAINER" --tail 100 2>&1 || true
  elif [ "$CONTAINER_STATUS" = "running" ]; then
    echo "✓ Container is running"
    echo "Last 50 lines of logs:"
    sudo docker logs "$FRAPPE_CONTAINER" --tail 50 2>&1 || true
  fi
else
  echo "⚠ Frappe container not found"
fi

echo "=== Configuring nginx and SSL certificates ==="

if ! command -v nginx &> /dev/null; then
  echo "Installing nginx..."
  sudo apt-get update
  sudo apt-get install -y nginx
fi

if ! command -v certbot &> /dev/null; then
  echo "Installing certbot..."
  sudo apt-get update
  sudo apt-get install -y certbot python3-certbot-nginx
fi

sudo mkdir -p /var/www/certbot
sudo chown www-data:www-data /var/www/certbot

SITE_NAME=$(grep -E '^SITE_NAME=' deploy/dev/.env.remote | cut -d= -f2 | tr -d '\r' || echo "dev-hrms.sahdiagnostics.com")
DOMAIN="$SITE_NAME"
if [[ "$DOMAIN" == www.* ]]; then
  WWW_DOMAIN="$DOMAIN"
  BASE_DOMAIN="${DOMAIN#www.}"
else
  BASE_DOMAIN="$DOMAIN"
  WWW_DOMAIN="www.$DOMAIN"
fi
CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

echo "Using domain: $DOMAIN"
echo "Using www domain: $WWW_DOMAIN"

check_certificate_valid() {
  if [ ! -f "$CERT_PATH" ] && [ ! -L "$CERT_PATH" ]; then
    return 1
  fi
  if ! sudo test -r "$CERT_PATH" || ! sudo test -r "$KEY_PATH"; then
    return 1
  fi
  if sudo openssl x509 -checkend 2592000 -noout -in "$CERT_PATH" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

CERT_NEEDED=false
if check_certificate_valid; then
  echo "✓ SSL certificate exists and is valid"
  CERT_EXPIRY=$(sudo openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2)
  echo "  Certificate expires: $CERT_EXPIRY"
else
  echo "⚠ SSL certificate is missing, expired, or expiring soon"
  CERT_NEEDED=true
fi

echo "=== Deploying nginx configuration ==="
if [ ! -f "deploy/dev/nginx.conf" ]; then
  echo "✗ Error: deploy/dev/nginx.conf not found!"
  exit 1
fi

TEMP_NGINX="/tmp/nginx-frappe-hrms.conf"
sed "s/dev-hrms\.sahdiagnostics\.com/$DOMAIN/g; s/www\.dev-hrms\.sahdiagnostics\.com/$WWW_DOMAIN/g" deploy/dev/nginx.conf > "$TEMP_NGINX"

sudo cp "$TEMP_NGINX" /etc/nginx/sites-available/frappe-hrms
rm -f "$TEMP_NGINX"

sudo ln -sf /etc/nginx/sites-available/frappe-hrms /etc/nginx/sites-enabled/frappe-hrms
sudo rm -f /etc/nginx/sites-enabled/default

if ! sudo systemctl is-active --quiet nginx; then
  echo "Starting nginx for certificate validation..."
  if ! sudo systemctl start nginx; then
    echo "⚠ Failed to start nginx (likely due to missing SSL certificates); continuing to certificate setup."
  fi
else
  if sudo nginx -t; then
    sudo systemctl reload nginx
  else
    echo "⚠ Nginx config test failed, but continuing for certificate setup"
  fi
fi

if [ "$CERT_NEEDED" = true ]; then
  echo "=== Obtaining SSL certificate ==="
  sudo certbot certonly --webroot \
    -w /var/www/certbot \
    -d "$DOMAIN" \
    -d "$WWW_DOMAIN" \
    --non-interactive \
    --agree-tos \
    --email admin@sahdiagnostics.com \
    --keep-until-expiring || {
    echo "⚠ Certbot webroot method failed, trying standalone method..."
    sudo systemctl stop nginx
    sudo certbot certonly --standalone \
      -d "$DOMAIN" \
      -d "$WWW_DOMAIN" \
      --non-interactive \
      --agree-tos \
      --email admin@sahdiagnostics.com || true
    sudo systemctl start nginx || true
  }

  if check_certificate_valid; then
    echo "✓ SSL certificate obtained successfully"
    CERT_EXPIRY=$(sudo openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2)
    echo "  Certificate expires: $CERT_EXPIRY"
  else
    echo "✗ Error: Failed to obtain valid SSL certificate"
    echo "  Continuing with deployment without a valid certificate (likely DNS not pointing yet)"
  fi
else
  echo "=== Checking if certificate renewal is needed ==="
  if ! sudo openssl x509 -checkend 2592000 -noout -in "$CERT_PATH" 2>/dev/null; then
    echo "Certificate expires soon, attempting renewal..."
    sudo certbot renew --quiet --nginx || {
      echo "⚠ Certificate renewal failed, but existing certificate is still valid"
    }
  fi
fi

echo "=== Setting up automatic certificate renewal ==="
CRON_JOB="0 0,12 * * * /usr/bin/certbot renew --quiet --nginx && /usr/bin/systemctl reload nginx"
if ! sudo crontab -l 2>/dev/null | grep -q "certbot renew"; then
  (sudo crontab -l 2>/dev/null; echo "$CRON_JOB") | sudo crontab -
  echo "✓ Certbot renewal cron job added"
else
  echo "✓ Certbot renewal cron job already exists"
fi

echo "=== Final nginx configuration ==="
if sudo nginx -t; then
  echo "✓ Nginx configuration is valid"
  sudo systemctl reload nginx
else
  echo "✗ Nginx configuration test failed"
  echo "Showing nginx error details:"
  sudo nginx -t 2>&1 || true
  if check_certificate_valid; then
    echo "⚠ Nginx config is invalid even though a certificate exists; failing deployment."
    exit 1
  else
    echo "⚠ Skipping deployment failure because SSL is not yet fully configured (likely DNS / certificate issue)."
  fi
fi

sudo systemctl enable nginx

if [ ! -f /etc/nginx/sites-available/frappe-hrms ]; then
  echo "✗ Error: nginx config file was not created!"
  exit 1
fi
echo "✓ Nginx config file deployed from deploy/dev/nginx.conf"

if [ -L /etc/nginx/sites-enabled/frappe-hrms ]; then
  echo "✓ Nginx site enabled"
else
  echo "✗ Error: Failed to enable nginx site"
  exit 1
fi

echo "=== Nginx configured and reloaded ==="

echo "=== Verifying nginx status ==="
sudo systemctl status nginx --no-pager -l || true

echo ""
echo "=== Checking listening ports ==="
sudo ss -tlnp | grep -E ':80|:443' || echo "⚠ Warning: nginx may not be listening on ports 80/443"

echo ""
echo "=== Verifying frappe container connectivity ==="
if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8000 | grep -q "200\|302\|301"; then
  echo "✓ Frappe container is responding on port 8000"
else
  echo "⚠ Warning: Frappe container may not be responding on port 8000"
  echo "Checking docker container status:"
  compose_cmd -f "$COMPOSE_FILE" ps -a

  FRAPPE_CONTAINER=$(compose_cmd -f "$COMPOSE_FILE" ps -q frappe 2>/dev/null || echo "")
  if [ -n "$FRAPPE_CONTAINER" ]; then
    echo ""
    echo "=== Frappe container logs (last 50 lines) ==="
    sudo docker logs --tail 50 "$FRAPPE_CONTAINER" 2>&1 || true

    CONTAINER_STATUS=$(sudo docker inspect -f '{{.State.Status}}' "$FRAPPE_CONTAINER" 2>/dev/null || echo "unknown")
    echo ""
    echo "Container status: $CONTAINER_STATUS"

    if [ "$CONTAINER_STATUS" != "running" ]; then
      echo "⚠ Frappe container is not running. Exit code:"
      sudo docker inspect -f '{{.State.ExitCode}}' "$FRAPPE_CONTAINER" 2>/dev/null || echo "unknown"
    fi
  else
    echo "⚠ Frappe container not found"
  fi
fi

if command -v ufw &> /dev/null; then
  echo ""
  echo "=== Checking firewall status ==="
  sudo ufw status | head -10
fi

echo ""
echo "=== Ensuring AWS CLI is available inside frappe container for backups ==="
FRAPPE_CONTAINER=$(compose_cmd -f "$COMPOSE_FILE" ps -q frappe 2>/dev/null || echo "")
if [ -n "$FRAPPE_CONTAINER" ]; then
  CONTAINER_STATUS=$(sudo docker inspect -f '{{.State.Status}}' "$FRAPPE_CONTAINER" 2>/dev/null || echo "unknown")
  if [ "$CONTAINER_STATUS" = "running" ]; then
    if ! sudo docker exec "$FRAPPE_CONTAINER" bash -lc "command -v aws >/dev/null 2>&1"; then
      echo "Installing AWS CLI v2 in frappe container..."
      sudo docker exec "$FRAPPE_CONTAINER" bash -lc "
        set -e
        sudo apt-get update -qq
        sudo apt-get install -y -qq unzip curl
        cd /tmp
        curl -sS 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o awscliv2.zip
        unzip -q awscliv2.zip
        sudo ./aws/install
        rm -rf aws awscliv2.zip
        aws --version
        echo '✓ AWS CLI v2 installed successfully'
      " || {
        echo "⚠ Failed to install AWS CLI v2, trying pip installation as fallback..."
        sudo docker exec "$FRAPPE_CONTAINER" bash -lc "
          pip3 install --user awscli --quiet || sudo pip3 install awscli --quiet
          aws --version
          echo '✓ AWS CLI installed via pip'
        " || echo "⚠ Failed to install AWS CLI via pip as well"
      }
    else
      echo "✓ AWS CLI already available in frappe container"
      if sudo docker exec "$FRAPPE_CONTAINER" bash -lc "aws --version 2>&1" | grep -q "aws-cli"; then
        echo "✓ AWS CLI is working correctly"
      else
        echo "AWS CLI has issues, attempting to fix..."
        sudo docker exec "$FRAPPE_CONTAINER" bash -lc "pip3 install --user 'urllib3<2.0' --force-reinstall 2>/dev/null || true" || true
        if ! sudo docker exec "$FRAPPE_CONTAINER" bash -lc "aws --version 2>&1" | grep -q "aws-cli"; then
          echo "Reinstalling AWS CLI v2..."
          sudo docker exec "$FRAPPE_CONTAINER" bash -lc "
            sudo apt-get update -qq && sudo apt-get install -y -qq unzip curl
            cd /tmp
            curl -sS 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o awscliv2.zip
            unzip -q awscliv2.zip
            sudo ./aws/install
            rm -rf aws awscliv2.zip
            aws --version
          " || echo "⚠ Could not fix AWS CLI, backups may fail"
        fi
      fi
    fi
  else
    echo "⚠ Skipping AWS CLI installation - frappe container is not running"
  fi
else
  echo "⚠ Skipping AWS CLI installation - frappe container not found"
fi

echo "=== Ensuring file backup cron job is configured ==="
if [ -f "$REMOTE_PATH/scripts/sync-files-to-s3.sh" ]; then
  sudo chmod +x "$REMOTE_PATH/scripts/sync-files-to-s3.sh"
  echo "✓ Backup script is executable"
else
  echo "✗ Error: Backup script not found at $REMOTE_PATH/scripts/sync-files-to-s3.sh"
  exit 1
fi

BACKUP_ENV_FILE="$REMOTE_PATH/deploy/dev/.env.remote"
BACKUP_HOURS="24"
if [ -f "$BACKUP_ENV_FILE" ]; then
  VALUE=$(grep -E '^FILES_BACK_UP_HOURS=' "$BACKUP_ENV_FILE" | cut -d= -f2 | tr -d '\r')
  if [ -n "$VALUE" ]; then
    BACKUP_HOURS="$VALUE"
  fi
fi
echo "Backup interval: Every $BACKUP_HOURS hours"

CRON_SCHEDULE="0 */$BACKUP_HOURS * * *"
CRON_JOB="$CRON_SCHEDULE $REMOTE_PATH/scripts/sync-files-to-s3.sh >> /var/log/frappe-files-sync.log 2>&1"

(sudo crontab -l 2>/dev/null | grep -v 'sync-files-to-s3.sh' ; echo "$CRON_JOB") | sudo crontab -

if sudo crontab -l 2>/dev/null | grep -q "sync-files-to-s3.sh"; then
  echo "✓ Cron job created successfully"
  echo "Cron job details:"
  sudo crontab -l | grep "sync-files-to-s3.sh" | sed 's/^/  /'
else
  echo "✗ Error: Failed to create cron job"
  exit 1
fi

sudo touch /var/log/frappe-files-sync.log
sudo chmod 644 /var/log/frappe-files-sync.log
echo "✓ Log file configured: /var/log/frappe-files-sync.log"

echo "=== Testing backup script syntax ==="
if bash -n "$REMOTE_PATH/scripts/sync-files-to-s3.sh"; then
  echo "✓ Backup script syntax is valid"
else
  echo "✗ Error: Backup script has syntax errors"
  exit 1
fi

if check_certificate_valid; then
  CERT_EXPIRY=$(sudo openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2)
  echo ""
  echo "✅ HTTPS is ENABLED"
  echo "Site is accessible at: https://$DOMAIN"
  echo "Certificate expires: $CERT_EXPIRY"
  echo "HTTP traffic will be automatically redirected to HTTPS"
else
  echo ""
  echo "⚠️  HTTPS certificate is missing or invalid"
  echo "Site may be accessible at: http://$DOMAIN"
  echo "Certificate setup may have failed - check logs above"
fi

echo "=== Cleaning up old Docker images ==="
sudo docker system prune -f

echo "=== Deployment completed successfully ==="
if [ -n "$DEPLOY_HOST" ]; then
  echo "=== Frappe HRMS should be accessible at http://$DEPLOY_HOST ==="
fi


