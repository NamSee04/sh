#!/usr/bin/env bash
# Script to install and configure Nginx

set -e

# Default variables
NGINX_USER="nginx"
NGINX_GROUP="nginx"
NGINX_CONF_DIR="/etc/nginx"
NGINX_LOG_DIR="/var/log/nginx"
NGINX_DATA_DIR="/var/www/html"
NGINX_PORT="${NGINX_PORT:-80}"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (or using sudo)."
  exit 1
fi

echo "Starting Nginx installation..."

# 1. Detect package manager and install Nginx
if command -v apt-get >/dev/null 2>&1; then
    echo "Detected apt-based system. Installing Nginx..."
    apt-get update -y
    apt-get install -y nginx
elif command -v yum >/dev/null 2>&1; then
    echo "Detected yum-based system. Installing Nginx..."
    yum install -y epel-release
    yum install -y nginx
elif command -v dnf >/dev/null 2>&1; then
    echo "Detected dnf-based system. Installing Nginx..."
    dnf install -y nginx
else
    echo "Unsupported package manager. Please install Nginx manually."
    exit 1
fi

# 2. Setup web root directory
echo "Configuring web root at ${NGINX_DATA_DIR}..."
mkdir -p "${NGINX_DATA_DIR}"
chown -R "${NGINX_USER}:${NGINX_GROUP}" "${NGINX_DATA_DIR}" 2>/dev/null || \
chown -R www-data:www-data "${NGINX_DATA_DIR}" 2>/dev/null || true
chmod 755 "${NGINX_DATA_DIR}"

# 3. Create a default index.html if not present
if [ ! -f "${NGINX_DATA_DIR}/index.html" ]; then
    cat > "${NGINX_DATA_DIR}/index.html" <<EOF
<!DOCTYPE html>
<html>
<head><title>Welcome to Nginx</title></head>
<body>
  <h1>Nginx is running!</h1>
</body>
</html>
EOF
fi

# 4. Write Nginx site configuration
SITE_CONF="${NGINX_CONF_DIR}/conf.d/default.conf"
echo "Writing Nginx config to ${SITE_CONF}..."

mkdir -p "${NGINX_CONF_DIR}/conf.d"
cat > "${SITE_CONF}" <<EOF
server {
    listen ${NGINX_PORT};
    server_name _;

    root ${NGINX_DATA_DIR};
    index index.html index.htm;

    access_log ${NGINX_LOG_DIR}/access.log;
    error_log  ${NGINX_LOG_DIR}/error.log;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

# 5. Validate configuration
echo "Validating Nginx configuration..."
nginx -t

# 6. Enable and start Nginx service
echo "Enabling and starting nginx.service..."
systemctl daemon-reload
systemctl enable nginx
systemctl restart nginx

echo ""
echo "==================================================================="
echo "Nginx installation completed successfully!"
echo "Web root: ${NGINX_DATA_DIR}"
echo "Listening on port: ${NGINX_PORT}"
echo ""
echo "To check the service status, run:"
echo "  sudo systemctl status nginx"
echo ""
echo "To view logs, run:"
echo "  sudo journalctl -u nginx -f"
echo "  sudo tail -f ${NGINX_LOG_DIR}/access.log"
echo "==================================================================="
