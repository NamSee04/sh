#!/usr/bin/env bash
# Script to install Alertmanager with Telegram notifications
# Matches the vmalert notifier config:
#   -notifier.url=https://<host>:9093  (TLS + basic auth)

set -e

# ---------------------------------------------------------------------------
# Variables — override via environment before running
# ---------------------------------------------------------------------------
AM_VERSION="${AM_VERSION:-0.28.1}"
AM_USER="adminuser"
AM_GROUP="adminuser"
AM_BIN="/usr/local/bin/alertmanager"
AM_TOOL_BIN="/usr/local/bin/amtool"
AM_CONFIG_DIR="/etc/alertmanager"
AM_CONFIG_FILE="${AM_CONFIG_DIR}/alertmanager.yml"
AM_WEB_CONFIG_FILE="${AM_CONFIG_DIR}/web.yml"
AM_DATA_DIR="/var/lib/alertmanager"
AM_PORT="${AM_PORT:-9093}"

# TLS — must match the cert used by vmalert's -notifier.url
TLS_CERT_FILE="${TLS_CERT_FILE:-/etc/self-signed-cert/namsee002.crt}"
TLS_KEY_FILE="${TLS_KEY_FILE:-/etc/self-signed-cert/namsee002.key}"

# Basic auth — must match vmalert's -notifier.basicAuth.*
AM_AUTH_USERNAME="${AM_AUTH_USERNAME:-}"
AM_AUTH_PASSWORD="${AM_AUTH_PASSWORD:-}"

# Telegram
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"   # e.g. 123456:ABC-DEF...
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"       # e.g. -1001234567890

# ---------------------------------------------------------------------------

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (or using sudo)."
  exit 1
fi

# Validate required Telegram values
if [ -z "${TELEGRAM_BOT_TOKEN}" ] || [ -z "${TELEGRAM_CHAT_ID}" ]; then
  echo "ERROR: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set."
  echo ""
  echo "  How to get them:"
  echo "  1. Create a bot via @BotFather on Telegram → copy the token."
  echo "  2. Add the bot to your group / channel."
  echo "  3. Get the chat ID:"
  echo "       curl \"https://api.telegram.org/bot<TOKEN>/getUpdates\""
  echo "     The chat id is the 'id' field inside 'chat' of a message."
  echo ""
  echo "  Then re-run:"
  echo "    sudo TELEGRAM_BOT_TOKEN='<token>' TELEGRAM_CHAT_ID='<id>' bash alertmanager.sh"
  exit 1
fi

echo "Starting Alertmanager ${AM_VERSION} installation..."

# ---------------------------------------------------------------------------
# 1. Detect architecture
# ---------------------------------------------------------------------------
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="armv7" ;;
    *)
        echo "Unsupported architecture: ${ARCH}"
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# 2. Create system user and group
# ---------------------------------------------------------------------------
if ! getent group "${AM_GROUP}" >/dev/null; then
    echo "Creating group ${AM_GROUP}..."
    groupadd --system "${AM_GROUP}"
fi

if ! getent passwd "${AM_USER}" >/dev/null; then
    echo "Creating user ${AM_USER}..."
    useradd --system \
            --gid "${AM_GROUP}" \
            --no-create-home \
            --shell /sbin/nologin \
            --comment "Alertmanager System User" \
            "${AM_USER}"
fi

# ---------------------------------------------------------------------------
# 3. Download and install binaries
# ---------------------------------------------------------------------------
TMP_DIR=$(mktemp -d)
echo "Downloading Alertmanager ${AM_VERSION} (${ARCH}) to ${TMP_DIR}..."
cd "${TMP_DIR}"

AM_TARBALL="alertmanager-${AM_VERSION}.linux-${ARCH}.tar.gz"
AM_URL="https://github.com/prometheus/alertmanager/releases/download/v${AM_VERSION}/${AM_TARBALL}"

curl -L -O -f "${AM_URL}"
tar -xzf "${AM_TARBALL}"

EXTRACTED_DIR="alertmanager-${AM_VERSION}.linux-${ARCH}"

echo "Installing alertmanager binary to ${AM_BIN}..."
install -o root -g root -m 755 "${EXTRACTED_DIR}/alertmanager" "${AM_BIN}"

echo "Installing amtool binary to ${AM_TOOL_BIN}..."
install -o root -g root -m 755 "${EXTRACTED_DIR}/amtool" "${AM_TOOL_BIN}"

cd - >/dev/null
rm -rf "${TMP_DIR}"

# ---------------------------------------------------------------------------
# 4. Create directories
# ---------------------------------------------------------------------------
echo "Creating config directory at ${AM_CONFIG_DIR}..."
mkdir -p "${AM_CONFIG_DIR}"
chown -R "${AM_USER}:${AM_GROUP}" "${AM_CONFIG_DIR}"
chmod 750 "${AM_CONFIG_DIR}"

echo "Creating data directory at ${AM_DATA_DIR}..."
mkdir -p "${AM_DATA_DIR}"
chown -R "${AM_USER}:${AM_GROUP}" "${AM_DATA_DIR}"
chmod 750 "${AM_DATA_DIR}"

# ---------------------------------------------------------------------------
# 5. Generate bcrypt hash of the basic-auth password
#    (required by Prometheus/Alertmanager web config)
# ---------------------------------------------------------------------------
echo "Generating bcrypt hash for basic-auth password..."
if command -v python3 >/dev/null 2>&1 && python3 -c "import bcrypt" 2>/dev/null; then
    HASHED_PASSWORD=$(python3 -c \
        "import bcrypt, sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(rounds=12)).decode())" \
        "${AM_AUTH_PASSWORD}")
elif command -v htpasswd >/dev/null 2>&1; then
    HASHED_PASSWORD=$(htpasswd -bnBC 12 "" "${AM_AUTH_PASSWORD}" | tr -d ':\n')
else
    echo "Neither python3-bcrypt nor htpasswd is available."
    echo "Installing apache2-utils for htpasswd..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y apache2-utils
    elif command -v yum >/dev/null 2>&1; then
        yum install -y httpd-tools
    fi
    HASHED_PASSWORD=$(htpasswd -bnBC 12 "" "${AM_AUTH_PASSWORD}" | tr -d ':\n')
fi

# ---------------------------------------------------------------------------
# 6. Write web config (TLS + basic auth)
# ---------------------------------------------------------------------------
echo "Writing web config to ${AM_WEB_CONFIG_FILE}..."
cat > "${AM_WEB_CONFIG_FILE}" <<EOF
# Alertmanager TLS + basic-auth web config
# https://prometheus.io/docs/alerting/latest/https/

tls_server_config:
  cert_file: ${TLS_CERT_FILE}
  key_file:  ${TLS_KEY_FILE}

basic_auth_users:
  ${AM_AUTH_USERNAME}: "${HASHED_PASSWORD}"
EOF
chown "${AM_USER}:${AM_GROUP}" "${AM_WEB_CONFIG_FILE}"
chmod 640 "${AM_WEB_CONFIG_FILE}"

# ---------------------------------------------------------------------------
# 7. Write alertmanager.yml
# ---------------------------------------------------------------------------
echo "Writing alertmanager config to ${AM_CONFIG_FILE}..."
cat > "${AM_CONFIG_FILE}" <<EOF
global:
  resolve_timeout: 5m

# ---------------------------------------------------------------------------
# Routing tree
# ---------------------------------------------------------------------------
route:
  group_by: ['alertname', 'instance', 'severity']
  group_wait:      30s   # wait for more alerts in the same group before sending
  group_interval:  5m    # how long to wait before sending a new notification for a group
  repeat_interval: 4h    # resend if still firing after this duration
  receiver: telegram

  # Optional: send critical alerts faster
  routes:
    - matchers:
        - severity = "critical"
      group_wait:     10s
      repeat_interval: 1h
      receiver: telegram

# ---------------------------------------------------------------------------
# Receivers
# ---------------------------------------------------------------------------
receivers:
  - name: telegram
    telegram_configs:
      - bot_token: "${TELEGRAM_BOT_TOKEN}"
        chat_id: ${TELEGRAM_CHAT_ID}
        parse_mode: HTML
        message: |
          {{ if eq .Status "firing" }}🔥{{ else }}✅{{ end }} <b>{{ .Status | toUpper }} — {{ .CommonLabels.alertname }}</b>

          {{ range .Alerts }}
          <b>Instance:</b> {{ .Labels.instance }}
          <b>Severity:</b> {{ .Labels.severity }}
          <b>Summary:</b> {{ .Annotations.summary }}
          <b>Description:</b> {{ .Annotations.description }}
          <b>Started:</b> {{ .StartsAt.Format "2006-01-02 15:04:05 UTC" }}
          {{ if .EndsAt }}
          <b>Resolved at:</b> {{ .EndsAt.Format "2006-01-02 15:04:05 UTC" }}
          {{ end }}
          {{ end }}
        send_resolved: true

# ---------------------------------------------------------------------------
# Inhibition rules — suppress lower-severity alerts when a higher one fires
# ---------------------------------------------------------------------------
inhibit_rules:
  - source_matchers:
      - severity = "critical"
    target_matchers:
      - severity = "warning"
    equal: ['alertname', 'instance']
EOF
chown "${AM_USER}:${AM_GROUP}" "${AM_CONFIG_FILE}"
chmod 640 "${AM_CONFIG_FILE}"

# ---------------------------------------------------------------------------
# 8. Validate config
# ---------------------------------------------------------------------------
echo "Validating alertmanager config..."
if "${AM_BIN}" --config.file="${AM_CONFIG_FILE}" 2>&1 | grep -q "no errors found\|successfully loaded"; then
    echo "Config validation passed."
elif amtool check-config "${AM_CONFIG_FILE}" 2>/dev/null; then
    echo "Config validation passed (amtool)."
else
    echo "WARNING: Could not validate config automatically — check manually with:"
    echo "  amtool check-config ${AM_CONFIG_FILE}"
fi

# ---------------------------------------------------------------------------
# 9. Create systemd service
# ---------------------------------------------------------------------------
SERVICE_FILE="/etc/systemd/system/alertmanager.service"
echo "Creating systemd unit file at ${SERVICE_FILE}..."

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Alertmanager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${AM_USER}
Group=${AM_GROUP}
LimitNOFILE=65536

ExecStart=${AM_BIN} \\
  --config.file=${AM_CONFIG_FILE} \\
  --storage.path=${AM_DATA_DIR} \\
  --web.listen-address=:${AM_PORT} \\
  --web.config.file=${AM_WEB_CONFIG_FILE} \\
  --cluster.listen-address="" \\
  --log.level=info

ExecReload=/bin/kill -HUP \$MAINPID

SyslogIdentifier=alertmanager
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

# ---------------------------------------------------------------------------
# 10. Reload systemd and start service
# ---------------------------------------------------------------------------
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling and starting alertmanager.service..."
systemctl enable alertmanager
systemctl restart alertmanager

echo ""
echo "==================================================================="
echo "Alertmanager ${AM_VERSION} installation completed!"
echo ""
echo "Configuration:"
echo "  Config file   : ${AM_CONFIG_FILE}"
echo "  Web config    : ${AM_WEB_CONFIG_FILE}"
echo "  Data directory: ${AM_DATA_DIR}"
echo "  Listen address: https://$(hostname -I | awk '{print $1}'):${AM_PORT}"
echo "  Basic auth    : ${AM_AUTH_USERNAME} / (as configured)"
echo "  Telegram chat : ${TELEGRAM_CHAT_ID}"
echo ""
echo "To check service status:"
echo "  sudo systemctl status alertmanager"
echo ""
echo "To view logs:"
echo "  sudo journalctl -u alertmanager -f"
echo ""
echo "To reload config without restart:"
echo "  sudo systemctl kill -s HUP alertmanager"
echo "  # or:"
echo "  curl -X POST https://${AM_AUTH_USERNAME}:${AM_AUTH_PASSWORD}@localhost:${AM_PORT}/-/reload -k"
echo ""
echo "To test Telegram alert (fire a test silence then delete it):"
echo "  amtool --alertmanager.url=https://localhost:${AM_PORT} \\"
echo "         --alertmanager.username=${AM_AUTH_USERNAME} \\"
echo "         --alertmanager.password='${AM_AUTH_PASSWORD}' \\"
echo "         --tls.insecure-skip-verify \\"
echo "         alert add alertname=TestAlert severity=warning instance=test"
echo "==================================================================="
