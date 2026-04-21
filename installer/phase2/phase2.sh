#!/usr/bin/env bash
# freedom-pi installer, phase 2
# runs once on first boot after phase 1, via freedom-pi-phase2.service
# installs Pi-hole unattended and patches its config

set -e

STATE_DIR="/etc/freedom-pi"
STATE_FILE="$STATE_DIR/install.conf"
LOG="/var/log/freedom-pi-phase2.log"

log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

die() { log "ERROR: $*"; exit 1; }

[ -f "$STATE_FILE" ] || die "missing $STATE_FILE"
# shellcheck source=/dev/null
. "$STATE_FILE"

log "=== freedom-pi phase 2 starting ==="

#
# 1. wait for wlan0 to be up with IP
#
log "waiting for wlan0 to come up..."
for i in $(seq 1 60); do
  if ip -br addr show wlan0 2>/dev/null | grep -q "${WIFI_GATEWAY}"; then
    log "wlan0 up with ${WIFI_GATEWAY}"
    break
  fi
  sleep 1
done
ip -br addr show wlan0 | grep -q "${WIFI_GATEWAY}" || die "wlan0 never got ${WIFI_GATEWAY}"

#
# 1b. wait for WAN + DNS before attempting to download Pi-hole
#
log "waiting for WAN IP on eth1..."
for i in $(seq 1 60); do
  wan_ip=$(ip -br addr show eth1 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
  case "$wan_ip" in
    ""|169.254.*) sleep 1; continue ;;
    *) log "eth1 up with $wan_ip"; break ;;
  esac
done

log "waiting for DNS to resolve install.pi-hole.net..."
for i in $(seq 1 60); do
  if getent hosts install.pi-hole.net >/dev/null 2>&1; then
    log "DNS OK"
    break
  fi
  sleep 1
done
getent hosts install.pi-hole.net >/dev/null 2>&1 || die "DNS never resolved install.pi-hole.net. check eth1 DHCP."

#
# 2. pre-seed Pi-hole unattended values (v6 reads setupVars.conf on fresh install)
#
log "pre-seeding /etc/pihole/setupVars.conf"
install -d -m 755 /etc/pihole
cat > /etc/pihole/setupVars.conf << EOF
PIHOLE_INTERFACE=wlan0
IPV4_ADDRESS=${WIFI_GATEWAY}/24
PIHOLE_DNS_1=1.1.1.1
PIHOLE_DNS_2=8.8.8.8
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
BLOCKING_ENABLED=true
DNSMASQ_LISTENING=local
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSSEC=false
REV_SERVER=false
EOF

#
# 3. install Pi-hole unattended
#
log "installing Pi-hole (unattended)..."
export PIHOLE_SKIP_OS_CHECK=true
curl -sSL https://install.pi-hole.net -o /tmp/pihole-installer.sh
bash /tmp/pihole-installer.sh --unattended
rm -f /tmp/pihole-installer.sh
log "Pi-hole install complete"

#
# 4. set admin password
#
log "setting Pi-hole admin password"
pihole setpassword "$PIHOLE_ADMIN_PW"

#
# 5. patch pihole.toml
#   - listeningMode: LOCAL -> ALL
#   - [dhcp] block: active=true, start/end/router set
#   - dnsmasq_lines: replace with our wired DHCP config
#
log "patching /etc/pihole/pihole.toml"
TOML=/etc/pihole/pihole.toml
[ -f "$TOML" ] || die "$TOML not found after Pi-hole install"
cp "$TOML" "${TOML}.pre-freedom-pi.bak"

python3 << PYEOF
import re
import sys

path = "$TOML"
wifi_start = "$WIFI_DHCP_START"
wifi_end = "$WIFI_DHCP_END"
wifi_router = "$WIFI_GATEWAY"
lan_start = "$LAN_DHCP_START"
lan_end = "$LAN_DHCP_END"
lan_router = "$LAN_GATEWAY"

with open(path) as f:
    content = f.read()

# 5a. listeningMode: LOCAL -> ALL
content = re.sub(
    r'(^\s*listeningMode\s*=\s*)"LOCAL"',
    r'\1"ALL" ### freedom-pi',
    content,
    count=1,
    flags=re.MULTILINE
)

# 5b. [dhcp] block scalars. only patch lines inside [dhcp]...[next section]
def patch_dhcp_block(text):
    m = re.search(r'^\[dhcp\]\s*$', text, flags=re.MULTILINE)
    if not m:
        sys.stderr.write("no [dhcp] section found\n")
        return text
    start = m.end()
    nxt = re.search(r'^\[[^\]]+\]\s*$', text[start:], flags=re.MULTILINE)
    end = start + nxt.start() if nxt else len(text)
    block = text[start:end]
    block = re.sub(r'(^\s*active\s*=\s*)false', r'\1true ### freedom-pi', block, count=1, flags=re.MULTILINE)
    block = re.sub(r'(^\s*start\s*=\s*)""', rf'\1"{wifi_start}" ### freedom-pi', block, count=1, flags=re.MULTILINE)
    block = re.sub(r'(^\s*end\s*=\s*)""', rf'\1"{wifi_end}" ### freedom-pi', block, count=1, flags=re.MULTILINE)
    block = re.sub(r'(^\s*router\s*=\s*)""', rf'\1"{wifi_router}" ### freedom-pi', block, count=1, flags=re.MULTILINE)
    return text[:start] + block + text[end:]

content = patch_dhcp_block(content)

# 5c. dnsmasq_lines: replace the (usually empty) array with our wired DHCP config
new_block = (
    '  dnsmasq_lines = [\n'
    '    "interface=eth0",\n'
    '    "interface=wlan0",\n'
    f'    "dhcp-range=set:eth0lan,{lan_start},{lan_end},24h",\n'
    f'    "dhcp-option=tag:eth0lan,option:router,{lan_router}",\n'
    f'    "dhcp-option=tag:eth0lan,option:dns-server,{lan_router}"\n'
    '  ] ### freedom-pi'
)
content, n = re.subn(
    r'^\s*dnsmasq_lines\s*=\s*\[[^\]]*\][^\n]*',
    new_block,
    content,
    count=1,
    flags=re.MULTILINE | re.DOTALL
)
if n == 0:
    sys.stderr.write("warning: dnsmasq_lines pattern did not match\n")

with open(path, "w") as f:
    f.write(content)

print("pihole.toml patched")
PYEOF

log "pihole.toml patched"

#
# 6. restart pihole-FTL to pick up new config
#
log "restarting pihole-FTL"
systemctl restart pihole-FTL
sleep 3
if ! systemctl is-active --quiet pihole-FTL; then
  die "pihole-FTL failed to start after patching. check: journalctl -u pihole-FTL"
fi

#
# 7. disable and clean up this oneshot
#
log "disabling phase 2 oneshot (self-destruct)"
systemctl disable freedom-pi-phase2.service
rm -f /etc/systemd/system/freedom-pi-phase2.service
systemctl daemon-reload

# leave STATE_FILE on disk for post-install inspection, but strip secrets
if [ -f "$STATE_FILE" ]; then
  sed -i 's/^PIHOLE_ADMIN_PW=.*$/PIHOLE_ADMIN_PW=<redacted>/' "$STATE_FILE"
fi

log "=== freedom-pi phase 2 complete ==="
log "admin UI: http://${WIFI_GATEWAY}/admin"
log "logs:     $LOG"
