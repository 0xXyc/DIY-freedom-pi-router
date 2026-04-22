# freedom-pi installer

Automated version of the big README. Takes a fresh Raspberry Pi OS Lite install and turns it into a working router with Pi-hole, WiFi AP, and firewall. Two phases, one reboot in the middle, rest is hands off.

## What you need

- Raspberry Pi 5 (any RAM)
- Fresh Raspberry Pi OS Lite (64-bit) with SSH on and a user set up via the Pi Imager
- UGREEN 2.5 GbE USB ethernet plugged into a blue USB 3.0 port
- Panda PAU0F AXE3000 USB WiFi (or keep the Pi built-in, installer handles both)
- Internet on the Pi during install (WAN cable to your modem, or the built-in ethernet plugged into your existing network)

## Run it

On your Mac:

```bash
scp -r installer freedompi@<pi-ip>:~/
ssh freedompi@<pi-ip>
```

On the Pi:

```bash
sudo ~/installer/install.sh
```

Follow the prompts. Defaults work for most setups.

## If your SSH drops, use tmux

Phase 1 kills NetworkManager partway through, which can blip your SSH session. If you're SSH'd in over WiFi, it drops and never comes back until after the Pi reboots. The install dies with it.

Wrap the install in tmux so it keeps running even if your SSH dies:

```bash
sudo apt install -y tmux          # if not already installed
tmux new -s inst                  # new session called "inst"
sudo ~/installer/install.sh       # run inside tmux
```

If the SSH session drops, reconnect and reattach:

```bash
ssh freedompi@<pi-ip>
tmux attach -t inst
```

You're back exactly where you left off, prompts and all.

Other useful bits:

- `Ctrl-b d` detaches from the session without killing it (so you can SSH out and come back later)
- `tmux ls` lists all sessions
- `tmux kill-session -t inst` cleans up when you're done

If you SSH in over a wired path (UGREEN plugged into a LAN port upstream, DHCP'd IP in the 192.168.x range), tmux is less critical because eth1 keeps its DHCP lease across the NetworkManager kill. Over WiFi, tmux is your safety net.

## What it does

### Phase 1 (about 5 min, you answer prompts)

1. Asks for SSID, WiFi password, country, subnets, Pi-hole admin password
2. Finds your USB ethernet and WiFi radios by MAC
3. `apt install` the packages (dhcpcd5, hostapd, iptables-persistent, curl, fail2ban, unattended-upgrades)
4. Kills NetworkManager, turns on dhcpcd
5. Writes `.link` files to lock interface names (`eth1` UGREEN, `wlan0` Panda, `wlan_onboard` for built-in WiFi if you have a Panda)
6. Writes dhcpcd static IPs
7. Writes sysctl tuning and kernel hardening (rp_filter anti-spoof, SYN cookies, no ICMP redirects, etc.)
8. Writes iptables v4 + v6 rules and saves them
9. Sets your WiFi country code
10. Writes hostapd config (Panda or built-in variant)
11. Host hardening: SSH drop-in (`PermitRootLogin no`, `MaxAuthTries 3`, key-only auth if `authorized_keys` exists), enables fail2ban sshd jail, enables unattended-upgrades
12. Stages the phase 2 oneshot
13. `update-initramfs` so the `.link` files kick in
14. Reboots

### Phase 2 (about 5 min, hands off)

Runs once automatically on first boot. Installs Pi-hole, patches its config, then deletes itself.

1. Waits for `wlan0` to come up at its static IP
2. Waits for `eth1` DHCP lease and for DNS to actually resolve (otherwise curl dies with "could not resolve host")
3. Installs Pi-hole unattended
4. Sets the admin password
5. Patches `/etc/pihole/pihole.toml`:
   - `listeningMode` from `LOCAL` to `ALL`
   - `[dhcp]` block active with your WiFi DHCP range
   - `dnsmasq_lines` set to serve wired LAN DHCP on `eth0`
6. Restarts `pihole-FTL`
7. Disables and removes its own systemd unit (self-destruct)

Phase 2 logs to `/var/log/freedom-pi-phase2.log`.

## File layout

```
installer/
├── install.sh                     # phase 1 entry
├── lib/
│   └── common.sh                  # helpers (prompts, MAC detection, templating)
├── configs/
│   ├── 99-router.conf             # sysctl
│   ├── dhcpcd.conf.append         # {{LAN_GATEWAY}}, {{WIFI_GATEWAY}}
│   ├── 10-eth1.link               # {{UGREEN_MAC}}
│   ├── 20-wlan0.link              # {{PANDA_MAC}}
│   ├── 20-wlan-onboard.link       # {{BUILTIN_WIFI_MAC}}
│   ├── hostapd-panda.conf         # {{SSID}}, {{COUNTRY_CODE}}, {{WPA_PASSPHRASE}}
│   ├── hostapd-builtin.conf       # built-in Pi WiFi variant
│   ├── hostapd-default            # /etc/default/hostapd
│   ├── unblock-rfkill.conf        # hostapd systemd drop-in (fixes USB WiFi soft block)
│   ├── rules.v4                   # iptables v4 rules (LAN+WiFi whitelist, WAN closed)
│   ├── rules.v6                   # iptables v6 rules (default-deny, ICMPv6 + DHCPv6 only)
│   ├── sshd_freedom-pi.conf       # sshd drop-in (PermitRootLogin no, MaxAuthTries 3)
│   └── 20auto-upgrades            # enables unattended-upgrades
└── phase2/
    ├── phase2.sh                  # runs on first boot
    └── freedom-pi-phase2.service  # oneshot unit, self-destructs
```

## When things break

### Phase 1 died partway

Just re-run it:

```bash
sudo ~/installer/install.sh
```

Mostly idempotent. The dhcpcd.conf append is guarded against double writes. Other configs get overwritten cleanly.

### Phase 2 didn't finish

Check the log first:

```bash
sudo cat /var/log/freedom-pi-phase2.log
sudo journalctl -u freedom-pi-phase2 --no-pager
```

If it bailed on DNS or network, wait a minute and re-run manually:

```bash
sudo systemctl reset-failed freedom-pi-phase2
sudo systemctl start freedom-pi-phase2
```

If it's still busted, run it by hand to see the live output:

```bash
sudo bash -x /etc/freedom-pi/phase2.sh
```

### You want to start over

Reflash the SD card. The installer changes too many system files for a clean uninstall.

## Stuff to know before running

- When NetworkManager gets killed, any SSH over WiFi drops. Use wired SSH (eth1 via your existing switch) so your session survives.
- Pi-hole's installer pulls a lot of stuff. Phase 2 bails if WAN isn't up, so make sure your modem cable is plugged in to `eth1` before you reboot out of phase 1.
- If your current home network already uses `192.168.1.x`, don't use that as the LAN subnet prompt or you'll get a collision. Use `192.168.10` or `192.168.50`.
- Admin password goes into `/etc/freedom-pi/install.conf` briefly between phase 1 and phase 2, escaped with `printf %q`. Phase 2 redacts it after use. File is `chmod 600 root:root`.
