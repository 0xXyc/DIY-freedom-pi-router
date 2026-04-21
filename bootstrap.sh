#!/usr/bin/env bash
# freedom-pi bootstrap, fetches the installer and runs it
#
# usage (on a fresh Raspberry Pi OS Lite install):
#   bash <(curl -sSL https://protocol.swizsecurity.com/diy-pi-router/bootstrap.sh)
#
# or:
#   curl -sSL https://protocol.swizsecurity.com/diy-pi-router/bootstrap.sh -o /tmp/bootstrap.sh && bash /tmp/bootstrap.sh

set -euo pipefail

REPO_URL="https://github.com/0xXyc/DIY-freedom-pi-router/archive/refs/heads/main.tar.gz"
TMPDIR="$(mktemp -d -t freedom-pi-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

cat << 'EOF'

  +---------------------------------------+
  |   freedom-pi bootstrap                |
  |   Pi 5 router + Pi-hole installer     |
  +---------------------------------------+

EOF

if ! command -v curl >/dev/null; then
  echo "curl is required. install with: sudo apt install -y curl"
  exit 1
fi
if ! command -v tar >/dev/null; then
  echo "tar is required. install with: sudo apt install -y tar"
  exit 1
fi

echo "[*] downloading installer from GitHub..."
curl -fsSL "$REPO_URL" | tar -xz -C "$TMPDIR"

INSTALLER_DIR="$(find "$TMPDIR" -maxdepth 2 -type d -name installer | head -1)"
if [ -z "$INSTALLER_DIR" ] || [ ! -f "$INSTALLER_DIR/install.sh" ]; then
  echo "[-] installer not found in downloaded archive"
  exit 1
fi

echo "[*] launching installer..."
echo
sudo bash "$INSTALLER_DIR/install.sh"
