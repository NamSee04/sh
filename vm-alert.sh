#!/usr/bin/env bash
# Script to install vmalert based on official docs
# https://docs.victoriametrics.com/victoriametrics/vmalert/

set -e

# Default variables
VM_VERSION="${VM_VERSION:-v1.138.0}"
VM_USER="adminuser"
VM_GROUP="adminuser"
VMALERT_BIN="/usr/local/bin/vmalert"
VMALERT_CONFIG_DIR="/etc/vmalert"
VMALERT_RULES_DIR="/etc/vmalert/rules"
VMALERT_RULES_FILE="${VMALERT_RULES_DIR}/rules.yml"
VMALERT_PORT="${VMALERT_PORT:-8880}"
VMALERT_EVALUATION_INTERVAL="${VMALERT_EVALUATION_INTERVAL:-1m}"

# Connection endpoints — adjust these to match your environment
DATASOURCE_URL="${DATASOURCE_URL:-http://localhost:8428}"
REMOTE_WRITE_URL="${REMOTE_WRITE_URL:-http://localhost:8428}"
REMOTE_READ_URL="${REMOTE_READ_URL:-http://localhost:8428}"
NOTIFIER_URL="${NOTIFIER_URL:-http://localhost:9093}"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (or using sudo)."
  exit 1
fi

echo "Starting vmalert ${VM_VERSION} installation..."

# 1. Detect architecture
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

# 2. Create user and group
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
            --comment "VictoriaMetrics System User" \
            "${VM_USER}"
fi

# 3. Download and install binary
TMP_DIR=$(mktemp -d)
echo "Downloading vmutils release ${VM_VERSION} (${ARCH}) to ${TMP_DIR}..."
cd "${TMP_DIR}"

VM_TARBALL="vmutils-linux-${ARCH}-${VM_VERSION}.tar.gz"
VM_URL="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${VM_VERSION}/${VM_TARBALL}"

curl -L -O -f "${VM_URL}"
tar -xzf "${VM_TARBALL}"

echo "Installing vmalert binary to ${VMALERT_BIN}..."
mv vmalert-prod "${VMALERT_BIN}"
chown "${VM_USER}:${VM_GROUP}" "${VMALERT_BIN}"
chmod 755 "${VMALERT_BIN}"

cd - >/dev/null
rm -rf "${TMP_DIR}"

# 4. Create config and rules directories
echo "Creating config directory at ${VMALERT_CONFIG_DIR}..."
mkdir -p "${VMALERT_RULES_DIR}"
chown -R "${VM_USER}:${VM_GROUP}" "${VMALERT_CONFIG_DIR}"
chmod 755 "${VMALERT_CONFIG_DIR}"

# 5. Deploy rules file (only if it does not already exist)
if [ ! -f "${VMALERT_RULES_FILE}" ]; then
    echo "Deploying default rules file to ${VMALERT_RULES_FILE}..."
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${SCRIPT_DIR}/vmalert-rules.yml" ]; then
        cp "${SCRIPT_DIR}/vmalert-rules.yml" "${VMALERT_RULES_FILE}"
    else
        # Create a minimal placeholder so vmalert can start
        cat > "${VMALERT_RULES_FILE}" <<'RULES'
groups: []
RULES
    fi
    chown "${VM_USER}:${VM_GROUP}" "${VMALERT_RULES_FILE}"
    chmod 640 "${VMALERT_RULES_FILE}"
else
    echo "Rules file already exists at ${VMALERT_RULES_FILE}, skipping."
fi

# 6. Create systemd service
SERVICE_FILE="/etc/systemd/system/vmalert.service"
echo "Creating systemd unit file at ${SERVICE_FILE}..."

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=VictoriaMetrics vmalert
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${VM_USER}
Group=${VM_GROUP}
LimitNOFILE=65536

ExecStart=${VMALERT_BIN} \\
  -rule=${VMALERT_RULES_DIR}/*.yml \\
  -datasource.url=${DATASOURCE_URL} \\
  -remoteWrite.url=${REMOTE_WRITE_URL} \\
  -remoteRead.url=${REMOTE_READ_URL} \\
  -notifier.url=${NOTIFIER_URL} \\
  -evaluationInterval=${VMALERT_EVALUATION_INTERVAL} \\
  -httpListenAddr=:${VMALERT_PORT} \\
  -configCheckInterval=1m \\
  -rule.evalDelay=30s

SyslogIdentifier=vmalert
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

# 7. Reload systemd and start service
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling and starting vmalert.service..."
systemctl enable vmalert
systemctl restart vmalert

echo ""
echo "==================================================================="
echo "vmalert ${VM_VERSION} installation completed!"
echo ""
echo "Configuration:"
echo "  Rules directory : ${VMALERT_RULES_DIR}"
echo "  Datasource URL  : ${DATASOURCE_URL}"
echo "  Remote Write URL: ${REMOTE_WRITE_URL}"
echo "  Remote Read URL : ${REMOTE_READ_URL}"
echo "  Notifier URL    : ${NOTIFIER_URL}"
echo "  Web UI          : http://localhost:${VMALERT_PORT}"
echo ""
echo "To check the service status:"
echo "  sudo systemctl status vmalert"
echo ""
echo "To view logs:"
echo "  sudo journalctl -u vmalert -f"
echo ""
echo "Hot reload (after editing rules):"
echo "  curl -X GET http://localhost:${VMALERT_PORT}/-/reload"
echo "==================================================================="
