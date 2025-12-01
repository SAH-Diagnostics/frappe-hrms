#!/bin/bash

# Diagnostic script for Frappe HRMS deployment
# Run this script on the Lightsail instance to diagnose connection issues

set -e

echo "=========================================="
echo "Frappe HRMS Deployment Diagnostics"
echo "=========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print status
print_status() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $2"
    else
        echo -e "${RED}✗${NC} $2"
    fi
}

# 1. Check Docker
echo "=== Docker Status ==="
if command -v docker &> /dev/null; then
    print_status 0 "Docker is installed"
    docker --version
else
    print_status 1 "Docker is NOT installed"
fi
echo ""

# 2. Check Docker Compose
echo "=== Docker Compose Status ==="
if command -v docker-compose &> /dev/null || docker compose version &> /dev/null; then
    print_status 0 "Docker Compose is installed"
    docker compose version || docker-compose --version
else
    print_status 1 "Docker Compose is NOT installed"
fi
echo ""

# 3. Check Nginx
echo "=== Nginx Status ==="
if command -v nginx &> /dev/null; then
    print_status 0 "Nginx is installed"
    nginx -v
    
    # Check if nginx is running
    if sudo systemctl is-active --quiet nginx; then
        print_status 0 "Nginx service is running"
    else
        print_status 1 "Nginx service is NOT running"
        echo "  Try: sudo systemctl start nginx"
    fi
    
    # Check nginx config
    if sudo nginx -t &> /dev/null; then
        print_status 0 "Nginx configuration is valid"
    else
        print_status 1 "Nginx configuration has errors"
        echo "  Run: sudo nginx -t"
    fi
else
    print_status 1 "Nginx is NOT installed"
    echo "  Install with: sudo apt-get install -y nginx"
fi
echo ""

# 4. Check listening ports
echo "=== Port Status ==="
if sudo ss -tlnp | grep -q ':80 '; then
    print_status 0 "Port 80 is listening"
    sudo ss -tlnp | grep ':80 '
else
    print_status 1 "Port 80 is NOT listening"
fi

if sudo ss -tlnp | grep -q ':443 '; then
    print_status 0 "Port 443 is listening"
    sudo ss -tlnp | grep ':443 '
else
    print_status 1 "Port 443 is NOT listening (HTTPS not configured)"
fi

if sudo ss -tlnp | grep -q ':8000 '; then
    print_status 0 "Port 8000 is listening (Frappe container)"
    sudo ss -tlnp | grep ':8000 '
else
    print_status 1 "Port 8000 is NOT listening (Frappe container may not be running)"
fi
echo ""

# 5. Check Docker containers
echo "=== Docker Container Status ==="
COMPOSE_FILE="/opt/frappe-hrms/docker/docker-compose.yml"
if [ -f "$COMPOSE_FILE" ]; then
    cd /opt/frappe-hrms
    if sudo docker compose -f "$COMPOSE_FILE" ps | grep -q "frappe"; then
        print_status 0 "Frappe container exists"
        sudo docker compose -f "$COMPOSE_FILE" ps
    else
        print_status 1 "Frappe container is NOT running"
        echo "  Check with: sudo docker compose -f $COMPOSE_FILE ps -a"
    fi
else
    print_status 1 "Docker compose file not found at $COMPOSE_FILE"
fi
echo ""

# 6. Test Frappe container connectivity
echo "=== Frappe Container Connectivity ==="
if curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8000 | grep -qE "200|302|301|401"; then
    print_status 0 "Frappe container is responding on port 8000"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8000)
    echo "  HTTP Status Code: $HTTP_CODE"
else
    print_status 1 "Frappe container is NOT responding on port 8000"
    echo "  Check container logs: sudo docker compose -f $COMPOSE_FILE logs frappe"
fi
echo ""

# 7. Check Nginx configuration
echo "=== Nginx Configuration ==="
NGINX_CONFIG="/etc/nginx/sites-available/frappe-hrms"
if [ -f "$NGINX_CONFIG" ]; then
    print_status 0 "Nginx config file exists"
    if [ -L "/etc/nginx/sites-enabled/frappe-hrms" ]; then
        print_status 0 "Nginx site is enabled"
    else
        print_status 1 "Nginx site is NOT enabled"
        echo "  Enable with: sudo ln -sf $NGINX_CONFIG /etc/nginx/sites-enabled/frappe-hrms"
    fi
    
    # Check if config proxies to correct upstream
    if grep -q "server 127.0.0.1:8000" "$NGINX_CONFIG"; then
        print_status 0 "Nginx config proxies to 127.0.0.1:8000"
    else
        print_status 1 "Nginx config does NOT proxy to 127.0.0.1:8000"
    fi
else
    print_status 1 "Nginx config file NOT found at $NGINX_CONFIG"
fi
echo ""

# 8. Check firewall (UFW)
echo "=== Firewall Status (UFW) ==="
if command -v ufw &> /dev/null; then
    UFW_STATUS=$(sudo ufw status | head -1)
    echo "  $UFW_STATUS"
    if echo "$UFW_STATUS" | grep -q "Status: active"; then
        if sudo ufw status | grep -q "80/tcp"; then
            print_status 0 "Port 80 is allowed in UFW"
        else
            print_status 1 "Port 80 is NOT allowed in UFW"
            echo "  Allow with: sudo ufw allow 80/tcp"
        fi
        
        if sudo ufw status | grep -q "443/tcp"; then
            print_status 0 "Port 443 is allowed in UFW"
        else
            print_status 1 "Port 443 is NOT allowed in UFW"
            echo "  Allow with: sudo ufw allow 443/tcp"
        fi
    fi
else
    echo "  UFW not installed (Lightsail firewall managed via AWS console)"
fi
echo ""

# 9. Check AWS Lightsail Firewall (reminder)
echo "=== AWS Lightsail Firewall Reminder ==="
echo -e "${YELLOW}⚠${NC}  AWS Lightsail firewall is managed via AWS Console"
echo "  Go to: AWS Lightsail → Your Instance → Networking → Firewall"
echo "  Ensure these rules exist:"
echo "    - HTTP (port 80) from Anywhere (0.0.0.0/0)"
echo "    - HTTPS (port 443) from Anywhere (0.0.0.0/0)"
echo "    - SSH (port 22) from your IP or Anywhere"
echo ""

# 10. Check recent nginx error logs
echo "=== Recent Nginx Errors ==="
if [ -f "/var/log/nginx/error.log" ]; then
    ERROR_COUNT=$(sudo tail -20 /var/log/nginx/error.log | wc -l)
    if [ "$ERROR_COUNT" -gt 0 ]; then
        echo "  Last 5 error log entries:"
        sudo tail -5 /var/log/nginx/error.log | sed 's/^/    /'
    else
        echo "  No recent errors in nginx error log"
    fi
else
    print_status 1 "Nginx error log not found"
fi
echo ""

# 11. Check Frappe container logs (last few lines)
echo "=== Recent Frappe Container Logs ==="
if [ -f "$COMPOSE_FILE" ]; then
    cd /opt/frappe-hrms
    echo "  Last 10 lines of frappe container logs:"
    sudo docker compose -f "$COMPOSE_FILE" logs --tail=10 frappe 2>/dev/null | sed 's/^/    /' || echo "    Could not retrieve logs"
else
    echo "  Docker compose file not found"
fi
echo ""

# Summary
echo "=========================================="
echo "Diagnostic Summary"
echo "=========================================="
echo ""
echo "If you see 'ERR_CONNECTION_REFUSED' in your browser:"
echo ""
echo "1. Check AWS Lightsail Firewall (most common issue):"
echo "   - Go to AWS Console → Lightsail → Instance → Networking"
echo "   - Ensure ports 80 and 443 are open from 0.0.0.0/0"
echo ""
echo "2. Verify Nginx is running:"
echo "   sudo systemctl status nginx"
echo "   sudo systemctl start nginx  # if not running"
echo ""
echo "3. Verify Frappe container is running:"
echo "   sudo docker compose -f $COMPOSE_FILE ps"
echo "   sudo docker compose -f $COMPOSE_FILE logs frappe"
echo ""
echo "4. Test local connectivity:"
echo "   curl -I http://127.0.0.1:8000  # Should return HTTP response"
echo "   curl -I http://localhost       # Should return HTTP response via nginx"
echo ""
echo "=========================================="

