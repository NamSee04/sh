#!/usr/bin/env bash
# Script to install VictoriaMetrics vmauth based on official docs
# https://docs.victoriametrics.com/victoriametrics/vmauth/
#
# Configuration:
#   - Only select (read) requests are allowed; remote write is disabled
#   - TLS enabled with self-signed certs from /etc/self-sign-cert
#   - Basic Auth for select requests
#   - Backend TLS verification disabled (self-signed backend certs)

set -e

# Default variables
VM_VERSION="${VM_VERSION:-v1.138.0}"
VM_USER="adminuser"
VM_GROUP="adminuser"
VM_BIN="/usr/local/bin/vmauth"
VM_CONFIG_DIR="/etc/vmauth"
VM_AUTH_CONFIG="${VM_CONFIG_DIR}/config.yml"

TLS_CERT_DIR="/etc/self-sign-cert"
TLS_CERT_FILE="${TLS_CERT_DIR}/server.crt"
TLS_KEY_FILE="${TLS_CERT_DIR}/server.key"

VMAUTH_LISTEN_ADDR="${VMAUTH_LISTEN_ADDR:-0.0.0.0:8427}"

# Backend VictoriaMetrics address (single-node)
VM_BACKEND="${VM_BACKEND:-http://localhost:8428}"

# Basic Auth credentials for select user
SELECT_USERNAME="${SELECT_USERNAME:-selectuser}"
SELECT_PASSWORD="${SELECT_PASSWORD:-selectpassword}"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (or using sudo)."
  exit 1
fi

echo "Starting vmauth installation version ${VM_VERSION}..."

# 1. Create User and Group
if ! getent group "${VM_GROUP}" >/dev/null; then
    echo "Creating group ${VM_GROUP}..."
    groupadd --system "${VM_GROUP}"
fi

if ! getent passwd "${VM_USER}" >/dev/null; then
    echo "Creating user ${VM_USER}..."
    useradd --system \
            --gid "${VM_GROUP}" \
            --no-create-home \
            --shell /sbin/nologin \
            --comment "VictoriaMetrics vmauth System User" \
            "${VM_USER}"
fi

# 2. Verify TLS certificates exist
echo "Checking TLS certificates at ${TLS_CERT_DIR}..."
if [ ! -f "${TLS_CERT_FILE}" ]; then
    echo "ERROR: TLS certificate not found at ${TLS_CERT_FILE}"
    echo "Please place your self-signed certificate there before running this script."
    exit 1
fi
if [ ! -f "${TLS_KEY_FILE}" ]; then
    echo "ERROR: TLS key not found at ${TLS_KEY_FILE}"
    echo "Please place your self-signed key there before running this script."
    exit 1
fi

# 3. Download and Install Binaries
TMP_DIR=$(mktemp -d)
echo "Downloading vmutils release to ${TMP_DIR}..."
cd "${TMP_DIR}"

VMUTILS_TARBALL="vmutils-linux-amd64-${VM_VERSION}.tar.gz"
VMUTILS_URL="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${VM_VERSION}/${VMUTILS_TARBALL}"

curl -L -O -f "${VMUTILS_URL}"
tar -xzf "${VMUTILS_TARBALL}"

# Move vmauth binary to destination
mv vmauth-prod "${VM_BIN}"
chown "${VM_USER}:${VM_GROUP}" "${VM_BIN}"
chmod 755 "${VM_BIN}"

cd - >/dev/null
rm -rf "${TMP_DIR}"

# 4. Create vmauth config directory
echo "Creating vmauth config directory at ${VM_CONFIG_DIR}..."
mkdir -p "${VM_CONFIG_DIR}"

# 5. Create auth config (select only, no remote write)
echo "Writing vmauth auth config to ${VM_AUTH_CONFIG}..."

cat > "${VM_AUTH_CONFIG}" <<EOF
users:
  # Basic Auth user for select (read) queries only
  - username: "${SELECT_USERNAME}"
    password: "${SELECT_PASSWORD}"
    url_map:
      # Allow select/read API endpoints (remote write paths are intentionally excluded)
      - src_paths:
          # Core query endpoints
          - "/api/v1/query"
          - "/api/v1/query_range"
          - "/api/v1/query_exemplars"
          - "/api/v1/series"
          # Label endpoints
          - "/api/v1/labels"
          - "/api/v1/label/.+/values"
          # Metadata / status
          - "/api/v1/metadata"
          - "/api/v1/status/.*"
          - "/api/v1/rules"
          - "/api/v1/alerts"
          # Export endpoints
          - "/api/v1/export"
          - "/api/v1/export/csv"
          - "/api/v1/export/native"
          # VictoriaMetrics extensions (used by Grafana VM plugin)
          - "/api/v1/format_query"
          - "/api/v1/parse_query"
          # Prometheus-prefixed equivalents
          - "/prometheus/api/v1/query"
          - "/prometheus/api/v1/query_range"
          - "/prometheus/api/v1/query_exemplars"
          - "/prometheus/api/v1/series"
          - "/prometheus/api/v1/labels"
          - "/prometheus/api/v1/label/.+/values"
          - "/prometheus/api/v1/metadata"
          - "/prometheus/api/v1/status/.*"
          - "/prometheus/api/v1/rules"
          - "/prometheus/api/v1/alerts"
          # UI
          - "/vmui/.*"
          # Health / readiness checks (required for Grafana connection test)
          - "/health"
          - "/-/healthy"
          - "/-/ready"
        url_prefix: "${VM_BACKEND}"
EOF

chown "${VM_USER}:${VM_GROUP}" "${VM_AUTH_CONFIG}"
chmod 640 "${VM_AUTH_CONFIG}"

# 6. Create Systemd Service File
SERVICE_FILE="/etc/systemd/system/vmauth.service"
echo "Creating systemd unit file at ${SERVICE_FILE}..."

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=VictoriaMetrics vmauth - auth proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${VM_USER}
Group=${VM_GROUP}
LimitNOFILE=2097152

ExecStart=${VM_BIN} \\
  -auth.config=${VM_AUTH_CONFIG} \\
  -httpListenAddr=${VMAUTH_LISTEN_ADDR} \\
  -tls \\
  -tlsCertFile=${TLS_CERT_FILE} \\
  -tlsKeyFile=${TLS_KEY_FILE} \\
  -backend.tlsInsecureSkipVerify

SyslogIdentifier=vmauth
Restart=always
RestartSec=10s

# Hardening measures
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

# 7. Reload, Enable, and Start vmauth Service
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling and starting vmauth.service..."
systemctl enable vmauth
systemctl restart vmauth

echo ""
echo "==================================================================="
echo "vmauth ${VM_VERSION} installation completed successfully!"
echo ""
echo "  Listen address : ${VMAUTH_LISTEN_ADDR} (TLS enabled)"
echo "  TLS cert       : ${TLS_CERT_FILE}"
echo "  TLS key        : ${TLS_KEY_FILE}"
echo "  Auth config    : ${VM_AUTH_CONFIG}"
echo "  Backend        : ${VM_BACKEND}"
echo "  Backend TLS    : insecure skip verify (strict SSL OFF)"
echo ""
echo "  Select user    : ${SELECT_USERNAME}"
echo "  Select password: ${SELECT_PASSWORD}"
echo ""
echo "  Remote write   : DISABLED (only select/read endpoints allowed)"
echo ""
echo "To check the service status, run:"
echo "  sudo systemctl status vmauth"
echo ""
echo "To view logs, run:"
echo "  sudo journalctl -u vmauth -f"
echo ""
echo "Example query (select):"
echo "  curl -k -u '${SELECT_USERNAME}:${SELECT_PASSWORD}' 'https://localhost:8427/api/v1/query?query=up'"
echo "==================================================================="
