#!/usr/bin/env bash
# Script to install oauth2-proxy
# https://oauth2-proxy.github.io/oauth2-proxy/
#
# Version: oauth2-proxy v7.15.0 (built with go1.25.8)

set -e

# Default variables
OAUTH2_PROXY_VERSION="${OAUTH2_PROXY_VERSION:-v7.15.0}"
OAUTH2_PROXY_USER="oauth2-proxy"
OAUTH2_PROXY_GROUP="oauth2-proxy"
OAUTH2_PROXY_BIN="/usr/local/bin/oauth2-proxy"
OAUTH2_PROXY_CONFIG_DIR="/etc/oauth2-proxy"
OAUTH2_PROXY_CONFIG="${OAUTH2_PROXY_CONFIG_DIR}/oauth2-proxy.cfg"
OAUTH2_PROXY_LOG_DIR="/var/log/oauth2-proxy"

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  armv7l)  ARCH="arm" ;;
  *)
    echo "Unsupported architecture: ${ARCH}"
    exit 1
    ;;
esac

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

DOWNLOAD_URL="https://github.com/oauth2-proxy/oauth2-proxy/releases/download/${OAUTH2_PROXY_VERSION}/oauth2-proxy-${OAUTH2_PROXY_VERSION}.${OS}-${ARCH}.tar.gz"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (or using sudo)."
  exit 1
fi

echo "Starting oauth2-proxy installation version ${OAUTH2_PROXY_VERSION}..."

# 1. Create User and Group
if ! getent group "${OAUTH2_PROXY_GROUP}" >/dev/null; then
    echo "Creating group ${OAUTH2_PROXY_GROUP}..."
    groupadd --system "${OAUTH2_PROXY_GROUP}"
fi

if ! getent passwd "${OAUTH2_PROXY_USER}" >/dev/null; then
    echo "Creating user ${OAUTH2_PROXY_USER}..."
    useradd --system \
        --gid "${OAUTH2_PROXY_GROUP}" \
        --no-create-home \
        --shell /sbin/nologin \
        "${OAUTH2_PROXY_USER}"
fi

# 2. Download and install binary
echo "Downloading oauth2-proxy ${OAUTH2_PROXY_VERSION} for ${OS}/${ARCH}..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

curl -fsSL "${DOWNLOAD_URL}" -o "${TMP_DIR}/oauth2-proxy.tar.gz"

tar -xzf "${TMP_DIR}/oauth2-proxy.tar.gz" -C "${TMP_DIR}"

BINARY_PATH="$(find "${TMP_DIR}" -name "oauth2-proxy" -type f | head -n1)"
if [ -z "${BINARY_PATH}" ]; then
    echo "oauth2-proxy binary not found in archive."
    exit 1
fi

install -o root -g root -m 0755 "${BINARY_PATH}" "${OAUTH2_PROXY_BIN}"
echo "oauth2-proxy installed at ${OAUTH2_PROXY_BIN}"

# 3. Create directories
echo "Creating config and log directories..."
mkdir -p "${OAUTH2_PROXY_CONFIG_DIR}"
mkdir -p "${OAUTH2_PROXY_LOG_DIR}"
chown "${OAUTH2_PROXY_USER}:${OAUTH2_PROXY_GROUP}" "${OAUTH2_PROXY_LOG_DIR}"
chmod 750 "${OAUTH2_PROXY_LOG_DIR}"

# 4. Create default config (edit values as needed)
if [ ! -f "${OAUTH2_PROXY_CONFIG}" ]; then
    echo "Creating default config at ${OAUTH2_PROXY_CONFIG}..."
    cat > "${OAUTH2_PROXY_CONFIG}" <<'EOF'
## OAuth2 Proxy Configuration
## https://oauth2-proxy.github.io/oauth2-proxy/configuration/overview

# Provider settings
provider = "oidc"
# oidc_issuer_url = "https://accounts.google.com"
# client_id = "YOUR_CLIENT_ID"
# client_secret = "YOUR_CLIENT_SECRET"

# Upstream to proxy to
# upstreams = ["http://localhost:8080/"]

# Cookie settings
cookie_secret = "CHANGE_ME_16_OR_32_BYTES_BASE64"
cookie_secure = true
cookie_httponly = true
# cookie_domain = ".example.com"

# Listener
http_address = "0.0.0.0:4180"

# Email domain restriction (use "*" to allow all)
# email_domains = ["example.com"]

# Skip authentication for health check endpoint
skip_provider_button = false

# Logging
# logging_filename = "/var/log/oauth2-proxy/oauth2-proxy.log"
EOF
    chown "root:${OAUTH2_PROXY_GROUP}" "${OAUTH2_PROXY_CONFIG}"
    chmod 640 "${OAUTH2_PROXY_CONFIG}"
fi

# 5. Create systemd service
echo "Creating systemd service..."
cat > /etc/systemd/system/oauth2-proxy.service <<EOF
[Unit]
Description=oauth2-proxy
Documentation=https://oauth2-proxy.github.io/oauth2-proxy/
After=network.target

[Service]
Type=simple
User=${OAUTH2_PROXY_USER}
Group=${OAUTH2_PROXY_GROUP}
ExecStart=${OAUTH2_PROXY_BIN} --config=${OAUTH2_PROXY_CONFIG}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${OAUTH2_PROXY_LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF

# 6. Enable and start service
echo "Enabling and starting oauth2-proxy service..."
systemctl daemon-reload
systemctl enable oauth2-proxy
systemctl restart oauth2-proxy

echo ""
echo "oauth2-proxy installation complete!"
echo ""
echo "Version: $(${OAUTH2_PROXY_BIN} --version 2>&1 || true)"
echo ""
echo "IMPORTANT: Edit the config file before starting:"
echo "  ${OAUTH2_PROXY_CONFIG}"
echo ""
echo "Service management:"
echo "  systemctl status oauth2-proxy"
echo "  systemctl restart oauth2-proxy"
echo "  journalctl -u oauth2-proxy -f"
