#!/usr/bin/env bash
# Script to install and configure process-exporter

set -e

# Default variables
PROCESS_EXPORTER_VERSION="${PROCESS_EXPORTER_VERSION:-0.8.7}"
PROCESS_EXPORTER_USER="adminuser"
PROCESS_EXPORTER_PORT="${PROCESS_EXPORTER_PORT:-9256}"
PROCESS_EXPORTER_BIN="/usr/local/bin/process-exporter"
PROCESS_EXPORTER_CONFIG="/etc/process-exporter/config.yml"
PROCESS_EXPORTER_SERVICE="/etc/systemd/system/process-exporter.service"
DOWNLOAD_DIR="/tmp/process_exporter_install"
ARCH="$(uname -m)"

# Normalize architecture
case "${ARCH}" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="armv7" ;;
    armv6l)  ARCH="armv6" ;;
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

echo "Starting process-exporter v${PROCESS_EXPORTER_VERSION} installation..."

# 1. Create user if not exists
if ! id "${PROCESS_EXPORTER_USER}" &>/dev/null; then
    echo "Creating system user: ${PROCESS_EXPORTER_USER}..."
    useradd --no-create-home --shell /bin/false "${PROCESS_EXPORTER_USER}"
fi

# 2. Download and install binary
TARBALL="process-exporter-${PROCESS_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/ncabatoff/process-exporter/releases/download/v${PROCESS_EXPORTER_VERSION}/${TARBALL}"

echo "Downloading ${DOWNLOAD_URL}..."
mkdir -p "${DOWNLOAD_DIR}"
curl -fsSL "${DOWNLOAD_URL}" -o "${DOWNLOAD_DIR}/${TARBALL}"

echo "Extracting archive..."
tar -xzf "${DOWNLOAD_DIR}/${TARBALL}" -C "${DOWNLOAD_DIR}"

echo "Installing binary to ${PROCESS_EXPORTER_BIN}..."
cp "${DOWNLOAD_DIR}/process-exporter-${PROCESS_EXPORTER_VERSION}.linux-${ARCH}/process-exporter" "${PROCESS_EXPORTER_BIN}"
chown "${PROCESS_EXPORTER_USER}:${PROCESS_EXPORTER_USER}" "${PROCESS_EXPORTER_BIN}"
chmod 755 "${PROCESS_EXPORTER_BIN}"

# 3. Cleanup
rm -rf "${DOWNLOAD_DIR}"

# 4. Create config file
echo "Creating config file at ${PROCESS_EXPORTER_CONFIG}..."
mkdir -p "$(dirname "${PROCESS_EXPORTER_CONFIG}")"
cat > "${PROCESS_EXPORTER_CONFIG}" <<'EOF'
process_names:
  - name: "{{.Comm}}"
    cmdline:
      - '.+'
EOF
chown -R "${PROCESS_EXPORTER_USER}:${PROCESS_EXPORTER_USER}" "$(dirname "${PROCESS_EXPORTER_CONFIG}")"

# 5. Create systemd service
echo "Creating systemd service at ${PROCESS_EXPORTER_SERVICE}..."
cat > "${PROCESS_EXPORTER_SERVICE}" <<EOF
[Unit]
Description=Prometheus Process Exporter
After=network.target

[Service]
User=${PROCESS_EXPORTER_USER}
Group=${PROCESS_EXPORTER_USER}
Type=simple
ExecStart=${PROCESS_EXPORTER_BIN} \
  -config.path=${PROCESS_EXPORTER_CONFIG} \
  -web.listen-address=0.0.0.0:${PROCESS_EXPORTER_PORT}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/proc

[Install]
WantedBy=multi-user.target
EOF

# 6. Enable and start service
echo "Enabling and starting process-exporter.service..."
systemctl daemon-reload
systemctl enable process-exporter
systemctl restart process-exporter

echo ""
echo "==================================================================="
echo "process-exporter v${PROCESS_EXPORTER_VERSION} installation completed!"
echo "Listening on port: ${PROCESS_EXPORTER_PORT}"
echo "Metrics endpoint: http://localhost:${PROCESS_EXPORTER_PORT}/metrics"
echo "Config file:      ${PROCESS_EXPORTER_CONFIG}"
echo ""
echo "To check the service status, run:"
echo "  sudo systemctl status process-exporter"
echo ""
echo "To view logs, run:"
echo "  sudo journalctl -u process-exporter -f"
echo "==================================================================="
