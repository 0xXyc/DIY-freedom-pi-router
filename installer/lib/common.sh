#!/usr/bin/env bash
# shared helpers for freedom-pi installer

set -o pipefail

# color output
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'
  C_CYAN=$'\033[0;36m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

log_info()    { printf "%s[*]%s %s\n" "$C_CYAN" "$C_RESET" "$*"; }
log_ok()      { printf "%s[+]%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
log_warn()    { printf "%s[!]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
log_err()     { printf "%s[-]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
log_section() { printf "\n%s===%s %s%s%s\n" "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }

die() { log_err "$*"; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
}

require_pi5() {
  local model
  model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "")"
  case "$model" in
    *"Raspberry Pi 5"*) log_ok "detected: $model" ;;
    *) die "this installer is Pi 5 only. detected: ${model:-unknown}" ;;
  esac
}

require_rpios() {
  [ -f /etc/os-release ] || die "no /etc/os-release, unknown OS"
  . /etc/os-release
  case "$ID" in
    debian|raspbian) log_ok "OS: $PRETTY_NAME" ;;
    *) die "expected Raspberry Pi OS (Debian/Raspbian), got: $ID" ;;
  esac
}

prompt_default() {
  # $1=varname $2=prompt $3=default
  local varname="$1" promptstr="$2" default="$3" reply
  printf "%s%s%s [%s]: " "$C_BOLD" "$promptstr" "$C_RESET" "$default"
  read -r reply
  [ -z "$reply" ] && reply="$default"
  printf -v "$varname" '%s' "$reply"
}

prompt_required() {
  # $1=varname $2=prompt
  local varname="$1" promptstr="$2" reply
  while :; do
    printf "%s%s%s: " "$C_BOLD" "$promptstr" "$C_RESET"
    read -r reply
    [ -n "$reply" ] && break
    log_warn "cannot be empty"
  done
  printf -v "$varname" '%s' "$reply"
}

prompt_password() {
  # $1=varname $2=prompt
  local varname="$1" promptstr="$2" reply confirm
  while :; do
    printf "%s%s%s: " "$C_BOLD" "$promptstr" "$C_RESET"
    read -r -s reply; echo
    [ ${#reply} -lt 8 ] && { log_warn "at least 8 characters"; continue; }
    printf "%sconfirm:%s " "$C_BOLD" "$C_RESET"
    read -r -s confirm; echo
    [ "$reply" = "$confirm" ] && break
    log_warn "did not match"
  done
  printf -v "$varname" '%s' "$reply"
}

prompt_yes_no() {
  # $1=prompt $2=default(y|n). returns 0=yes 1=no
  local promptstr="$1" default="${2:-n}" reply
  local hint="[y/N]"
  [ "$default" = "y" ] && hint="[Y/n]"
  printf "%s%s%s %s " "$C_BOLD" "$promptstr" "$C_RESET" "$hint"
  read -r reply
  reply="${reply:-$default}"
  case "${reply,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

# substitute {{VAR}} placeholders in a file
# use: substitute_vars SRC DST VAR1=val1 VAR2=val2 ...
substitute_vars() {
  local src="$1" dst="$2"; shift 2
  local tmp
  tmp="$(mktemp)"
  cp "$src" "$tmp"
  local pair var val
  for pair in "$@"; do
    var="${pair%%=*}"
    val="${pair#*=}"
    # escape forward slashes, pipes, ampersands for sed
    val="${val//\\/\\\\}"
    val="${val//|/\\|}"
    val="${val//&/\\&}"
    sed -i "s|{{${var}}}|${val}|g" "$tmp"
  done
  mv "$tmp" "$dst"
}

# enumerate USB ethernet candidates (excluding built-in eth0)
# prints "name mac" per line
list_usb_ethernet() {
  local iface mac
  for iface in /sys/class/net/*/; do
    iface="$(basename "$iface")"
    # skip loopback, wifi, built-in integrated onboard
    case "$iface" in
      lo|wlan*|wl*) continue ;;
    esac
    # USB adapters appear under /sys/class/net/<iface>/device/ with usb subpath
    if [ -e "/sys/class/net/$iface/device" ]; then
      local devpath
      devpath="$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || echo "")"
      case "$devpath" in
        *usb*)
          mac="$(cat "/sys/class/net/$iface/address")"
          echo "$iface $mac"
          ;;
      esac
    fi
  done
}

# enumerate all wireless interfaces
# prints "name mac" per line
list_wifi() {
  local iface mac
  for iface in /sys/class/net/wl*; do
    [ -e "$iface" ] || continue
    iface="$(basename "$iface")"
    mac="$(cat "/sys/class/net/$iface/address")"
    echo "$iface $mac"
  done
}

# get MAC of built-in WiFi (2c:cf:67 or d8:3a:dd prefix)
detect_builtin_wifi_mac() {
  local line mac
  while IFS= read -r line; do
    mac="$(echo "$line" | awk '{print $2}')"
    case "$mac" in
      2c:cf:67:*|d8:3a:dd:*) echo "$mac"; return 0 ;;
    esac
  done < <(list_wifi)
  return 1
}

is_builtin_wifi_mac() {
  case "$1" in
    2c:cf:67:*|d8:3a:dd:*) return 0 ;;
    *) return 1 ;;
  esac
}
