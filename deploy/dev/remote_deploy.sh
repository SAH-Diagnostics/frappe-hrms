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

install_with_retry() {
  local pkg="$1"
  local max_attempts=10
  local attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    # Check for lock files before trying
    if sudo lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || sudo lsof /var/lib/apt/lists/lock >/dev/null 2>&1; then
        echo "Apt lock held by another process. Waiting (attempt $attempt/$max_attempts)..."
        sleep 10
    else
        if sudo apt-get install -y "$pkg"; then
          return 0
        fi
        echo "Apt install failed. Retrying in 10s..."
        sleep 10
    fi
    attempt=$((attempt + 1))
  done
  
  echo "Failed to install $pkg after $max_attempts attempts."
  return 1
}

# Update package list safely
echo "Updating package lists..."
# Retry update as well
for i in {1..5}; do
    if sudo apt-get update; then
        break
    fi
    echo "apt-get update failed, retrying in 10s..."
    sleep 10
done

# Install git if not present
if ! command -v git &> /dev/null; then
  echo "Installing git..."
  install_with_retry git
fi

# Clone or pull the repository
if [ -d "$REMOTE_PATH/.git" ]; then
  echo "=== Repository exists, pulling latest changes ==="
  cd "$REMOTE_PATH"
  sudo chown -R "$REMOTE_USER":"$REMOTE_USER" .
  # A hard reset to the remote branch is sufficient; no need for an extra pull.
  git fetch origin
  git reset --hard origin/main
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
  install_with_retry docker.io
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

# Install Docker Compose if not present
if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
  echo "Docker Compose not found, installing..."
  
  # Try to install docker-compose-plugin from apt first (if Docker repo is configured)
  if ! install_with_retry docker-compose-plugin 2>/dev/null; then
    echo "⚠ docker-compose-plugin not available via apt, installing standalone docker-compose binary..."
    
    # Install curl if not present (needed to download docker-compose)
    if ! command -v curl >/dev/null 2>&1; then
      echo "Installing curl..."
      install_with_retry curl
    fi
    
    # Install standalone docker-compose binary (v2.x)
    DOCKER_COMPOSE_VERSION="v2.24.0"
    DOCKER_COMPOSE_URL="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64"
    
    if sudo curl -L "$DOCKER_COMPOSE_URL" -o /usr/local/bin/docker-compose 2>/dev/null; then
      sudo chmod +x /usr/local/bin/docker-compose
      echo "✓ Installed standalone docker-compose binary (v${DOCKER_COMPOSE_VERSION})"
    else
      echo "⚠ Failed to download docker-compose binary, trying legacy python package..."
      # Fallback to legacy docker-compose (if available in repos)
      install_with_retry docker-compose || {
        echo "✗ Failed to install docker-compose. Deployment may fail."
      }
    fi
  fi
elif docker compose version >/dev/null 2>&1; then
  echo "✓ Docker Compose plugin is already available"
elif command -v docker-compose >/dev/null 2>&1; then
  echo "✓ Legacy docker-compose is already available"
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

if [ -f "$BACKUP_SCRIPT" ] && [ -x "$BACKUP_SCRIPT" ]; then
  # Try to detect the running frappe container using docker compose metadata
  FRAPPE_CANDIDATE="$(sudo docker ps --filter 'label=com.docker.compose.service=frappe' --format '{{.Names}}' | head -n1 || true)"
  if [ -n "$FRAPPE_CANDIDATE" ]; then
    echo "Backup script found and frappe container '$FRAPPE_CANDIDATE' is running, triggering backup..."
    if sudo "$BACKUP_SCRIPT" >> /var/log/frappe-files-sync.log 2>&1; then
      echo "✓ Pre-deployment backup completed successfully"
    else
      BACKUP_EXIT_CODE=$?
      echo "⚠ Pre-deployment backup failed with exit code $BACKUP_EXIT_CODE"
      echo "Continuing with deployment anyway..."
      echo "Check /var/log/frappe-files-sync.log for details"
    fi
  else
    echo "⚠ No running frappe container detected, skipping pre-deployment backup"
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

echo "=== Cleaning up old Docker images (free up space) ==="
# Prune before pull to ensure space exists
sudo docker system prune -af || true

echo "=== Building and starting containers ==="
# Build locally on the server using the Dockerfile we added
compose_cmd -f "$COMPOSE_FILE" --env-file deploy/dev/.env.remote build
compose_cmd -f "$COMPOSE_FILE" --env-file deploy/dev/.env.remote up -d

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
  install_with_retry nginx
fi

if ! command -v certbot &> /dev/null; then
  echo "Installing certbot..."
  install_with_retry certbot
  install_with_retry python3-certbot-nginx
fi

sudo mkdir -p /var/www/certbot
sudo chown www-data:www-data /var/www/certbot

# Extract SITE_NAME from env file for domain configuration
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
# Replace both dev-hrms and www.dev-hrms placeholders with actual domains
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
  CERT_EMAIL="${CERTBOT_EMAIL:-admin@sahdiagnostics.com}"

  sudo certbot certonly --webroot \
    -w /var/www/certbot \
    -d "$DOMAIN" \
    -d "$WWW_DOMAIN" \
    --non-interactive \
    --agree-tos \
    --email "$CERT_EMAIL" \
    --keep-until-expiring || {
    echo "⚠ Certbot webroot method failed, trying standalone method..."
    sudo systemctl stop nginx
    sudo certbot certonly --standalone \
      -d "$DOMAIN" \
      -d "$WWW_DOMAIN" \
      --non-interactive \
      --agree-tos \
      --email "$CERT_EMAIL" || true
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
echo "=== AWS CLI Verification ==="
# Check AWS CLI availability since we moved it to Dockerfile
FRAPPE_CONTAINER=$(compose_cmd -f "$COMPOSE_FILE" ps -q frappe 2>/dev/null || echo "")
if [ -n "$FRAPPE_CONTAINER" ]; then
    if sudo docker exec "$FRAPPE_CONTAINER" bash -c "command -v aws >/dev/null 2>&1"; then
         echo "✓ AWS CLI is available inside the container"
         sudo docker exec "$FRAPPE_CONTAINER" aws --version
    else
         echo "✗ Error: AWS CLI is NOT available inside the container despite Dockerfile update."
    fi
fi

echo "=== Checking if volume has data before configuring cron jobs ==="
VOLUME_HAS_DATA=false
FRAPPE_CONTAINER=$(compose_cmd -f "$COMPOSE_FILE" ps -q frappe 2>/dev/null || echo "")

if [ -n "$FRAPPE_CONTAINER" ]; then
  CONTAINER_STATUS=$(sudo docker inspect -f '{{.State.Status}}' "$FRAPPE_CONTAINER" 2>/dev/null || echo "unknown")
  if [ "$CONTAINER_STATUS" = "running" ]; then
    # Check if there are any site files in the volume
    SITE_COUNT=$(sudo docker exec "$FRAPPE_CONTAINER" bash -c "find /home/frappe/frappe-bench/sites -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l" 2>/dev/null || echo "0")
    if [ "$SITE_COUNT" -gt 0 ]; then
      # Check if any site has actual files (not just empty directories)
      FILE_COUNT=$(sudo docker exec "$FRAPPE_CONTAINER" bash -c "find /home/frappe/frappe-bench/sites -type f 2>/dev/null | wc -l" 2>/dev/null || echo "0")
      if [ "$FILE_COUNT" -gt 0 ]; then
        VOLUME_HAS_DATA=true
        echo "✓ Volume contains data: Found $FILE_COUNT files across $SITE_COUNT site(s)"
      else
        echo "⚠ Volume exists but contains no files yet (fresh deployment)"
      fi
    else
      echo "⚠ No sites found in volume (fresh deployment)"
    fi
  else
    echo "⚠ Frappe container is not running, cannot check volume contents"
    echo "  Container status: $CONTAINER_STATUS"
    echo "  Will skip cron job setup for now"
  fi
else
  echo "⚠ Frappe container not found, cannot check volume contents"
  echo "  Will skip cron job setup for now"
fi

if [ "$VOLUME_HAS_DATA" = true ]; then
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
else
  echo "=== Skipping cron job setup ==="
  echo "  Volume does not contain data yet (fresh deployment)"
  echo "  Cron jobs will be configured on the next deployment after data is present"
  
  # Still ensure the script is executable for future use
  if [ -f "$REMOTE_PATH/scripts/sync-files-to-s3.sh" ]; then
    sudo chmod +x "$REMOTE_PATH/scripts/sync-files-to-s3.sh"
    echo "✓ Backup script is executable (ready for future cron setup)"
  fi
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

echo "=== Deployment completed successfully ==="
if [ -n "$DEPLOY_HOST" ]; then
  echo "=== Frappe HRMS should be accessible at http://$DEPLOY_HOST ==="
fi
