#!/usr/bin/env bash
# freedom-pi installer, phase 1
# run on a fresh Raspberry Pi OS Lite (64-bit) install with sudo

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

CONFIGS_DIR="$SCRIPT_DIR/configs"
PHASE2_DIR="$SCRIPT_DIR/phase2"
STATE_DIR="/etc/freedom-pi"
STATE_FILE="$STATE_DIR/install.conf"

banner() {
  cat << 'EOF'

  +---------------------------------------+
  |   freedom-pi router installer         |
  |   Pi 5 + Pi-hole + hostapd            |
  +---------------------------------------+

EOF
}

#
# sanity
#
banner
require_root
require_pi5
require_rpios

#
# gather answers
#
log_section "configuration"

prompt_default    SSID              "WiFi network name (SSID)"          "Freedom"
prompt_password   WPA_PASSPHRASE    "WiFi password (min 8 chars)"
prompt_default    COUNTRY_CODE      "WiFi country code (2 letters)"     "US"
prompt_default    LAN_SUBNET        "Wired LAN subnet (x.x.x)"          "192.168.1"
prompt_default    WIFI_SUBNET       "WiFi subnet (x.x.x)"               "192.168.2"
prompt_password   PIHOLE_ADMIN_PW   "Pi-hole admin password (min 8)"

LAN_GATEWAY="${LAN_SUBNET}.1"
WIFI_GATEWAY="${WIFI_SUBNET}.1"
LAN_DHCP_START="${LAN_SUBNET}.100"
LAN_DHCP_END="${LAN_SUBNET}.200"
WIFI_DHCP_START="${WIFI_SUBNET}.100"
WIFI_DHCP_END="${WIFI_SUBNET}.200"

cat << EOF

${C_BOLD}review:${C_RESET}
  SSID:             $SSID
  country:          $COUNTRY_CODE
  LAN gateway:      $LAN_GATEWAY
  LAN DHCP range:   $LAN_DHCP_START - $LAN_DHCP_END
  WiFi gateway:     $WIFI_GATEWAY
  WiFi DHCP range:  $WIFI_DHCP_START - $WIFI_DHCP_END

EOF
prompt_yes_no "proceed?" y || die "aborted"

#
# MAC discovery
#
log_section "interface detection"

log_info "USB ethernet adapters found:"
mapfile -t USB_ETH < <(list_usb_ethernet)
if [ ${#USB_ETH[@]} -eq 0 ]; then
  die "no USB ethernet adapter detected. plug in the UGREEN and re-run."
fi
i=1
for line in "${USB_ETH[@]}"; do
  printf "  %d) %s\n" "$i" "$line"
  i=$((i+1))
done

if [ ${#USB_ETH[@]} -eq 1 ]; then
  UGREEN_IFACE="$(echo "${USB_ETH[0]}" | awk '{print $1}')"
  UGREEN_MAC="$(echo "${USB_ETH[0]}" | awk '{print $2}')"
  log_ok "picked as UGREEN WAN: $UGREEN_IFACE ($UGREEN_MAC)"
else
  prompt_default PICK "which number is your UGREEN (WAN)" "1"
  sel="${USB_ETH[$((PICK-1))]}"
  UGREEN_IFACE="$(echo "$sel" | awk '{print $1}')"
  UGREEN_MAC="$(echo "$sel" | awk '{print $2}')"
fi

log_info "WiFi radios found:"
mapfile -t WIFI_DEVS < <(list_wifi)
i=1
for line in "${WIFI_DEVS[@]}"; do
  mac="$(echo "$line" | awk '{print $2}')"
  tag=""
  is_builtin_wifi_mac "$mac" && tag=" (looks like Pi built-in)"
  printf "  %d) %s%s\n" "$i" "$line" "$tag"
  i=$((i+1))
done

USE_PANDA=1
if prompt_yes_no "using a Panda PAU0F (or other USB WiFi stick) for the AP?" y; then
  USE_PANDA=1
  # auto-detect panda = the one that's NOT a built-in mac prefix
  PANDA_MAC=""
  BUILTIN_WIFI_MAC=""
  for line in "${WIFI_DEVS[@]}"; do
    mac="$(echo "$line" | awk '{print $2}')"
    if is_builtin_wifi_mac "$mac"; then
      BUILTIN_WIFI_MAC="$mac"
    else
      PANDA_MAC="$mac"
    fi
  done
  if [ -z "$PANDA_MAC" ]; then
    die "could not find a non-built-in WiFi MAC. plug in the Panda and re-run."
  fi
  if [ -z "$BUILTIN_WIFI_MAC" ]; then
    log_warn "no built-in WiFi detected (2c:cf:67 or d8:3a:dd prefix). skipping wlan-onboard rename."
  fi
  log_ok "Panda WiFi MAC:    $PANDA_MAC"
  [ -n "$BUILTIN_WIFI_MAC" ] && log_ok "built-in WiFi MAC: $BUILTIN_WIFI_MAC"
else
  USE_PANDA=0
  log_ok "using Pi built-in WiFi for AP"
fi

prompt_yes_no "looks right?" y || die "aborted"

#
# install packages
#
log_section "apt install"
export DEBIAN_FRONTEND=noninteractive
apt update
apt full-upgrade -y
# preseed iptables-persistent to skip the save-current-rules prompt
echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
apt install -y dhcpcd5 hostapd iptables-persistent curl ca-certificates \
  fail2ban unattended-upgrades

#
# swap NetworkManager for dhcpcd
#
log_section "network stack"
systemctl disable --now NetworkManager 2>/dev/null || true
systemctl enable --now dhcpcd

#
# .link files for predictable interface names
#
log_section "pinning interface names"
install -d /etc/systemd/network
substitute_vars "$CONFIGS_DIR/10-eth1.link" /etc/systemd/network/10-eth1.link \
  "UGREEN_MAC=$UGREEN_MAC"
log_ok "pinned UGREEN -> eth1 ($UGREEN_MAC)"

if [ "$USE_PANDA" -eq 1 ]; then
  substitute_vars "$CONFIGS_DIR/20-wlan0.link" /etc/systemd/network/20-wlan0.link \
    "PANDA_MAC=$PANDA_MAC"
  log_ok "pinned Panda -> wlan0 ($PANDA_MAC)"
  if [ -n "$BUILTIN_WIFI_MAC" ]; then
    substitute_vars "$CONFIGS_DIR/20-wlan-onboard.link" /etc/systemd/network/20-wlan-onboard.link \
      "BUILTIN_WIFI_MAC=$BUILTIN_WIFI_MAC"
    log_ok "pinned built-in WiFi -> wlan_onboard"
  fi
fi

#
# dhcpcd static IPs
#
log_section "dhcpcd static IPs"
if ! grep -q "freedom-pi router config" /etc/dhcpcd.conf; then
  substitute_vars "$CONFIGS_DIR/dhcpcd.conf.append" /tmp/dhcpcd.append \
    "LAN_GATEWAY=$LAN_GATEWAY" \
    "WIFI_GATEWAY=$WIFI_GATEWAY"
  cat /tmp/dhcpcd.append >> /etc/dhcpcd.conf
  rm -f /tmp/dhcpcd.append
  log_ok "added static IPs to dhcpcd.conf"
else
  log_warn "dhcpcd.conf already has freedom-pi block, skipping"
fi

#
# sysctl (forwarding + buffers)
#
log_section "IP forwarding and sysctl tuning"
install -m 644 "$CONFIGS_DIR/99-router.conf" /etc/sysctl.d/99-router.conf
sysctl --system > /dev/null
[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || die "ip_forward did not apply"
log_ok "IP forwarding on"

#
# iptables and NAT (v4 and v6)
#
log_section "firewall and NAT"
install -d /etc/iptables
install -m 644 "$CONFIGS_DIR/rules.v4" /etc/iptables/rules.v4
install -m 644 "$CONFIGS_DIR/rules.v6" /etc/iptables/rules.v6
# apply now too (so we can verify before reboot)
iptables-restore  < /etc/iptables/rules.v4
ip6tables-restore < /etc/iptables/rules.v6
log_ok "v4 + v6 firewall rules loaded and saved"

#
# WiFi country code
#
log_section "WiFi country code"
raspi-config nonint do_wifi_country "$COUNTRY_CODE" || log_warn "raspi-config failed, continuing"

#
# hostapd
#
log_section "hostapd (WiFi AP)"
install -d /etc/hostapd
if [ "$USE_PANDA" -eq 1 ]; then
  HOSTAPD_SRC="$CONFIGS_DIR/hostapd-panda.conf"
else
  HOSTAPD_SRC="$CONFIGS_DIR/hostapd-builtin.conf"
fi
substitute_vars "$HOSTAPD_SRC" /etc/hostapd/hostapd.conf \
  "SSID=$SSID" \
  "COUNTRY_CODE=$COUNTRY_CODE" \
  "WPA_PASSPHRASE=$WPA_PASSPHRASE"
chmod 600 /etc/hostapd/hostapd.conf
log_ok "hostapd.conf written"

install -m 644 "$CONFIGS_DIR/hostapd-default" /etc/default/hostapd

install -d /etc/systemd/system/hostapd.service.d
install -m 644 "$CONFIGS_DIR/unblock-rfkill.conf" /etc/systemd/system/hostapd.service.d/unblock-rfkill.conf

systemctl daemon-reload
systemctl unmask hostapd
systemctl enable hostapd
log_ok "hostapd enabled"

#
# host hardening: SSH, fail2ban, auto security updates
#
log_section "host hardening"

# SSH drop-in. If the current user has no authorized_keys file, skip
# the PasswordAuthentication=no line so we don't lock them out.
SSHD_DROPIN_SRC="$CONFIGS_DIR/sshd_freedom-pi.conf"
SSHD_DROPIN_DST="/etc/ssh/sshd_config.d/99-freedom-pi.conf"
install -d /etc/ssh/sshd_config.d

# Who ran sudo? Fall back to root if someone ran this directly as root.
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
HAS_KEYS=0
if [ -n "$REAL_HOME" ] && [ -s "$REAL_HOME/.ssh/authorized_keys" ]; then
  HAS_KEYS=1
fi

install -m 644 "$SSHD_DROPIN_SRC" "$SSHD_DROPIN_DST"
if [ "$HAS_KEYS" -eq 0 ]; then
  log_warn "no authorized_keys for '$REAL_USER'. leaving password auth on so you don't get locked out."
  sed -i 's/^PasswordAuthentication.*/# PasswordAuthentication no  # skipped: no authorized_keys/' "$SSHD_DROPIN_DST"
else
  log_ok  "key found for '$REAL_USER', enforcing key-only auth"
fi

# Sanity check before restarting. If the drop-in has a typo, back it out
# instead of restarting sshd with a broken config.
if sshd -t; then
  systemctl restart ssh
  log_ok "sshd hardened (PermitRootLogin=no, MaxAuthTries=3)"
else
  log_err "sshd -t failed, removing the drop-in"
  rm -f "$SSHD_DROPIN_DST"
fi

# fail2ban ships with a working sshd jail out of the box on Debian.
systemctl enable --now fail2ban
log_ok "fail2ban enabled (sshd jail)"

# Auto security patches.
install -m 644 "$CONFIGS_DIR/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now unattended-upgrades
log_ok "unattended-upgrades enabled"

#
# stash state for phase 2
#
log_section "staging phase 2"
install -d -m 700 "$STATE_DIR"
# use printf %q so any special chars in the admin password (", $, \, !, etc.)
# are properly escaped. sourcing this file back into bash is safe.
{
  echo "# freedom-pi install state, consumed by phase 2 on next boot"
  printf 'WIFI_GATEWAY=%q\n'      "$WIFI_GATEWAY"
  printf 'WIFI_DHCP_START=%q\n'   "$WIFI_DHCP_START"
  printf 'WIFI_DHCP_END=%q\n'     "$WIFI_DHCP_END"
  printf 'LAN_GATEWAY=%q\n'       "$LAN_GATEWAY"
  printf 'LAN_DHCP_START=%q\n'    "$LAN_DHCP_START"
  printf 'LAN_DHCP_END=%q\n'      "$LAN_DHCP_END"
  printf 'PIHOLE_ADMIN_PW=%q\n'   "$PIHOLE_ADMIN_PW"
} > "$STATE_FILE"
chmod 600 "$STATE_FILE"

# drop phase 2 script + systemd oneshot in place
install -m 755 "$PHASE2_DIR/phase2.sh" "$STATE_DIR/phase2.sh"
install -m 644 "$PHASE2_DIR/freedom-pi-phase2.service" /etc/systemd/system/freedom-pi-phase2.service
systemctl daemon-reload
systemctl enable freedom-pi-phase2.service
log_ok "phase 2 oneshot installed"

#
# bake .link files into initramfs
#
log_section "updating initramfs"
update-initramfs -u
log_ok "initramfs updated"

#
# done phase 1
#
log_section "phase 1 complete"
cat << EOF

next up: the Pi will reboot and phase 2 runs automatically. phase 2 starts
hostapd, installs Pi-hole, and patches its config. takes about 5 minutes.

${C_YELLOW}${C_BOLD}heads up on SSH:${C_RESET}
  WAN SSH is off. After the reboot you reach the Pi over LAN or WiFi:
    LAN (eth0):   ssh $REAL_USER@${LAN_GATEWAY}
    WiFi:         ssh $REAL_USER@${WIFI_GATEWAY}
  If you were SSH'd in via eth1 plugged into your existing switch, move
  your cable to eth0 (built-in port) or join WiFi after the reboot.
  Also: root SSH is off, MaxAuthTries is 3, fail2ban is watching.

after phase 2, SSH back in and check:
  systemctl is-active hostapd pihole-FTL dhcpcd fail2ban unattended-upgrades
  ip addr show wlan0     # should show ${WIFI_GATEWAY}
  ip addr show eth0      # should show ${LAN_GATEWAY}
  sudo fail2ban-client status sshd
  sudo ip6tables -S      # v6 firewall active

EOF

if prompt_yes_no "reboot now?" y; then
  log_info "rebooting in 5 seconds..."
  sleep 5
  systemctl reboot
else
  log_warn "reboot manually when ready (sudo reboot) to trigger phase 2"
fi
