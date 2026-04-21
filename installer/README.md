# freedom-pi installer

Automated version of the full README setup. Turns a fresh Raspberry Pi OS Lite install into a working router with Pi-hole, hostapd, and firewall in two phases (interactive prompt + reboot + automatic finish).

## Requirements

- Raspberry Pi 5 (any RAM size)
- Fresh Raspberry Pi OS Lite (64-bit), SSH enabled, user set up via Raspberry Pi Imager
- UGREEN 2.5 GbE USB ethernet adapter plugged into a blue USB 3.0 port
- Panda PAU0F AXE3000 (or compatible) USB WiFi stick plugged into the other blue USB 3.0 port (optional, falls back to built-in WiFi)
- Internet access on the Pi (either via built-in ethernet to your existing network, or USB ethernet)

## How to run

On your Mac:

```bash
scp -r installer freedom@<pi>:~/
ssh freedom@<pi>
```

On the Pi:

```bash
sudo ~/installer/install.sh
```

Follow the prompts. Default values work for most setups.

## What happens

### Phase 1 (interactive, about 5 minutes)

1. Asks for SSID, WiFi password, country code, subnets, Pi-hole admin password
2. Detects USB adapters and WiFi radios
3. Confirms which MAC belongs to which device
4. Installs `dhcpcd5`, `hostapd`, `iptables-persistent`, `curl`
5. Disables NetworkManager, enables dhcpcd
6. Writes `.link` files to pin interface names (`eth1` UGREEN, `wlan0` Panda, `wlan_onboard` built-in WiFi)
7. Writes dhcpcd static IPs
8. Writes sysctl tuning (`99-router.conf`)
9. Writes iptables rules and saves them
10. Sets WiFi country code
11. Writes `hostapd.conf` (Panda or built-in variant)
12. Installs the phase 2 oneshot
13. Updates initramfs (so `.link` files take effect)
14. Reboots

### Phase 2 (automatic, about 5 minutes)

Runs once on first boot after phase 1, via a systemd oneshot service.

1. Waits for `wlan0` to come up with its static IP
2. Installs Pi-hole unattended (with pre-seeded `setupVars.conf`)
3. Sets the Pi-hole admin password
4. Patches `/etc/pihole/pihole.toml`:
   - `listeningMode` goes from `"LOCAL"` to `"ALL"`
   - `[dhcp]` block: `active = true`, start/end/router set to WiFi subnet
   - `dnsmasq_lines` set to serve wired LAN DHCP on `eth0`
5. Restarts `pihole-FTL`
6. Disables and removes its own systemd unit (self-destruct)

Logs go to `/var/log/freedom-pi-phase2.log`.

## File layout

```
installer/
├── install.sh                         # phase 1 entry point
├── lib/
│   └── common.sh                      # shared bash helpers
├── configs/
│   ├── 99-router.conf                 # sysctl
│   ├── dhcpcd.conf.append             # {{LAN_GATEWAY}}, {{WIFI_GATEWAY}}
│   ├── 10-eth1.link                   # {{UGREEN_MAC}}
│   ├── 20-wlan0.link                  # {{PANDA_MAC}}
│   ├── 20-wlan-onboard.link           # {{BUILTIN_WIFI_MAC}}
│   ├── hostapd-panda.conf             # {{SSID}}, {{COUNTRY_CODE}}, {{WPA_PASSPHRASE}}
│   ├── hostapd-builtin.conf           # built-in Pi WiFi variant
│   ├── hostapd-default                # /etc/default/hostapd
│   ├── unblock-rfkill.conf            # hostapd systemd drop-in
│   └── rules.v4                       # iptables rules
└── phase2/
    ├── phase2.sh                      # runs once on first boot after reboot
    └── freedom-pi-phase2.service      # systemd oneshot unit
```

## Troubleshooting

### Phase 1 failed

Re-run `sudo ~/installer/install.sh`. It's mostly idempotent. The dhcpcd.conf append guards against double-writing. Other config files get overwritten, which is fine.

### Phase 2 failed or didn't run

Check the log:

```bash
sudo cat /var/log/freedom-pi-phase2.log
sudo journalctl -u freedom-pi-phase2
```

Run manually:

```bash
sudo /etc/freedom-pi/phase2.sh
```

### Want to start over

Flash a fresh SD card. The installer touches too much system state for a clean rollback.

## Known gotchas

- NetworkManager gets disabled mid-install, which may drop your SSH session briefly. Reconnect and re-run if needed.
- Pi-hole's install script downloads a lot. Make sure WAN (eth1 via modem, or wired LAN via existing network) is plugged in before phase 2.
- If your ISP router uses `192.168.1.x` already, change the LAN subnet prompt to something like `192.168.10` to avoid collision.
