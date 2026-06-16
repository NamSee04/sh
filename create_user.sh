#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root." >&2
    exit 1
fi

read -rp "Username: " USERNAME
read -rp "SSH public key: " SSH_KEY

if [[ -z "$USERNAME" || -z "$SSH_KEY" ]]; then
    echo "Username and SSH key are required." >&2
    exit 1
fi

# Create user if it doesn't exist
if id "$USERNAME" &>/dev/null; then
    echo "User '$USERNAME' already exists."
else
    useradd -m -s /bin/bash "$USERNAME"
    echo "Created user '$USERNAME'."
fi

# Add to sudo group (sudo/wheel depending on distro)
if getent group sudo &>/dev/null; then
    usermod -aG sudo "$USERNAME"
elif getent group wheel &>/dev/null; then
    usermod -aG wheel "$USERNAME"
fi

# Passwordless sudo
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
chmod 0440 "/etc/sudoers.d/$USERNAME"
visudo -cf "/etc/sudoers.d/$USERNAME"

# Set up SSH key
USER_HOME=$(eval echo "~$USERNAME")
mkdir -p "$USER_HOME/.ssh"
echo "$SSH_KEY" >> "$USER_HOME/.ssh/authorized_keys"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"

echo "Done. '$USERNAME' has passwordless sudo and SSH key access."
