#!/usr/bin/env bash
# Script to install and configure Prometheus Node Exporter

set -e

# Default variables
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.10.2}"
NODE_EXPORTER_USER="adminuser"
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"
NODE_EXPORTER_BIN="/usr/local/bin/node_exporter"
NODE_EXPORTER_SERVICE="/etc/systemd/system/node_exporter.service"
DOWNLOAD_DIR="/tmp/node_exporter_install"
ARCH="$(uname -m)"

# Normalize architecture
case "${ARCH}" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="armv7" ;;
    *)
        echo "Unsupported architecture: ${ARCH}"
        exit 1
        ;;
esac

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (or using sudo)."
  exit 1
fi

echo "Starting Node Exporter v${NODE_EXPORTER_VERSION} installation..."

# 1. Create node_exporter user if not exists
if ! id "${NODE_EXPORTER_USER}" &>/dev/null; then
    echo "Creating system user: ${NODE_EXPORTER_USER}..."
    useradd --no-create-home --shell /bin/false "${NODE_EXPORTER_USER}"
fi

# 2. Download and install binary
TARBALL="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${TARBALL}"

echo "Downloading ${DOWNLOAD_URL}..."
mkdir -p "${DOWNLOAD_DIR}"
curl -fsSL "${DOWNLOAD_URL}" -o "${DOWNLOAD_DIR}/${TARBALL}"

echo "Extracting archive..."
tar -xzf "${DOWNLOAD_DIR}/${TARBALL}" -C "${DOWNLOAD_DIR}"

echo "Installing binary to ${NODE_EXPORTER_BIN}..."
cp "${DOWNLOAD_DIR}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" "${NODE_EXPORTER_BIN}"
chown "${NODE_EXPORTER_USER}:${NODE_EXPORTER_USER}" "${NODE_EXPORTER_BIN}"
chmod 755 "${NODE_EXPORTER_BIN}"

# 3. Cleanup
rm -rf "${DOWNLOAD_DIR}"

# 4. Create systemd service
echo "Creating systemd service at ${NODE_EXPORTER_SERVICE}..."
cat > "${NODE_EXPORTER_SERVICE}" <<EOF
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=${NODE_EXPORTER_USER}
Group=${NODE_EXPORTER_USER}
Type=simple
ExecStart=${NODE_EXPORTER_BIN} --web.listen-address=:${NODE_EXPORTER_PORT}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

# 5. Enable and start service
echo "Enabling and starting node_exporter.service..."
systemctl daemon-reload
systemctl enable node_exporter
systemctl restart node_exporter

echo ""
echo "==================================================================="
echo "Node Exporter v${NODE_EXPORTER_VERSION} installation completed!"
echo "Listening on port: ${NODE_EXPORTER_PORT}"
echo "Metrics endpoint: http://localhost:${NODE_EXPORTER_PORT}/metrics"
echo ""
echo "To check the service status, run:"
echo "  sudo systemctl status node_exporter"
echo ""
echo "To view logs, run:"
echo "  sudo journalctl -u node_exporter -f"
echo "==================================================================="
