#!/usr/bin/env bash
# Script to install VictoriaMetrics Single-node based on official docs and ansible playbook defaults
# https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/

set -e

# Default variables
VM_VERSION="${VM_VERSION:-v1.138.0}"
VM_USER="adminuser"
VM_GROUP="adminuser"
VM_DATA_DIR="/var/lib/victoria-metrics/"
VM_BIN="/usr/local/bin/victoriametrics"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (or using sudo)."
  exit 1
fi

echo "Starting VictoriaMetrics (vmsingle) installation version ${VM_VERSION}..."

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
            --home-dir "${VM_DATA_DIR}" \
            --shell /sbin/nologin \
            --comment "VictoriaMetrics System User" \
            "${VM_USER}"
fi

# 2. Setup Data Directory
echo "Configuring data directory at ${VM_DATA_DIR}..."
mkdir -p "${VM_DATA_DIR}"
chown -R "${VM_USER}:${VM_GROUP}" "${VM_DATA_DIR}"
chmod 755 "${VM_DATA_DIR}"

# 3. Download and Install Binaries
TMP_DIR=$(mktemp -d)
echo "Downloading VictoriaMetrics release to ${TMP_DIR}..."
cd "${TMP_DIR}"

VM_TARBALL="victoria-metrics-linux-amd64-${VM_VERSION}.tar.gz"
VM_URL="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${VM_VERSION}/${VM_TARBALL}"

curl -L -O -f "${VM_URL}"
tar -xzf "${VM_TARBALL}"

# Move binary to destination
# The released single-node binary is usually named 'victoria-metrics-prod'
mv victoria-metrics-prod "${VM_BIN}"
chown "${VM_USER}:${VM_GROUP}" "${VM_BIN}"
chmod 755 "${VM_BIN}"

cd - >/dev/null
rm -rf "${TMP_DIR}"

# 4. Create Systemd Service File
SERVICE_FILE="/etc/systemd/system/victoriametrics.service"
echo "Creating systemd unit file at ${SERVICE_FILE}..."

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=VictoriaMetrics single-node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${VM_USER}
Group=${VM_GROUP}
# Recommended max open files limit for VictoriaMetrics
LimitNOFILE=2097152

ExecStart=${VM_BIN} \\
  -storageDataPath=${VM_DATA_DIR} \\
  -retentionPeriod=12 \\
  -selfScrapeInterval=30s \\
  -maxConcurrentInserts=32 \\
  -search.maxUniqueTimeseries=900000

SyslogIdentifier=victoriametrics
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

# 5. Reload, Enable, and Start VictoriaMetrics Service
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling and starting victoriametrics.service..."
systemctl enable victoriametrics
systemctl restart victoriametrics

echo ""
echo "==================================================================="
echo "VictoriaMetrics ${VM_VERSION} installation completed successfully!"
echo "Data directory: ${VM_DATA_DIR}"
echo "Configured retention: 12 months"
echo ""
echo "To check the service status, run:"
echo "  sudo systemctl status victoriametrics"
echo ""
echo "To view system logs, run:"
echo "  sudo journalctl -u victoriametrics -f"
echo "==================================================================="
