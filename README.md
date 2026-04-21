<p align="center">
  <img src="assets/swiz-logo-horizontal.png" alt="Swiz Security" width="560" />
</p>

# Raspberry Pi 5 Router with Pi-hole

Turn a Pi 5 into your actual home router. USB ethernet on the WAN side, built-in ethernet on the LAN side, USB WiFi broadcasting your own network. Pi-hole runs on top, blocking ads and trackers on every device.

One command sets the whole thing up on a fresh Raspberry Pi OS Lite SD card.

## Don't wanna read? Run this

On a fresh Raspberry Pi OS Lite install with SSH on and the UGREEN plugged in:

```bash
bash <(curl -sSL https://protocol.swizsecurity.com/freedom/bootstrap.sh)
```

That pulls the installer from this repo and runs it. Two phases, one reboot in the middle, about 10 minutes total. Answer the prompts (SSID, passwords, subnets) and it's off.

Installer docs, what each phase does, and how to recover if something breaks: [installer/README.md](installer/README.md).

## Hardware

### What you need

- Raspberry Pi 5 (any RAM, 8 GB is plenty)
- microSD card, 32 GB or bigger, class 10 or A2
- Official 27W USB-C power supply (cheap knockoffs make the Pi throttle)
- Two ethernet cables, cat5e or better
- One USB ethernet adapter for the WAN side (plugs into your modem)
- Keyboard and monitor for first boot, OR an ethernet connection to your existing network

### What I actually run

My ISP does 927/927 Mbps so I don't need anything fancy on the LAN side. Built-in gigabit is plenty.

- **WAN (internet side):** UGREEN 2.5 GbE USB-A 3.0, Realtek RTL8156BG. About $25. Plugs into a blue USB 3.0 port, becomes `eth1`.
- **LAN (home side):** Pi 5's built-in ethernet port. Free, already on the Pi. Becomes `eth0`.
- **WiFi broadcast:** Panda PAU0F AXE3000 USB 3.0, MediaTek MT7921AU. About $30. Way better than the Pi's built-in WiFi.

Real speeds on my box: 931 Mbps wired, 540 to 600 Mbps on WiFi 6 clients. ~$55 total on top of the Pi.

### Skip these

- **TP-Link UE306 or anything with an RTL8153 chip.** Looks great at $10, terrible Linux driver, caps around 300 Mbps because it negotiates half duplex.
- **WiFi 6 USB sticks under $30.** Most are receive-only, no AP mode. hostapd won't work.
- **Realtek RTL8812AU WiFi sticks.** Out-of-tree driver that breaks on every kernel update.
- **Cheap cat5 cables.** Old cat5 forces gigabit links into half duplex. Use cat5e or cat6.

## What the installer does

### Phase 1 (about 5 min, you answer prompts)

1. Asks for SSID, WiFi password, country, subnets, Pi-hole admin password
2. Finds your USB ethernet and WiFi radios by MAC, confirms which is which
3. `apt install`s the packages (dhcpcd5, hostapd, iptables-persistent, curl)
4. Kills NetworkManager, switches to dhcpcd
5. Writes `.link` files to lock interface names
6. Writes dhcpcd static IPs, sysctl tuning, iptables rules, hostapd config
7. Stages the phase 2 oneshot and reboots

### Phase 2 (about 5 min, hands off)

Runs automatically on first boot after phase 1.

1. Waits for the WiFi AP to come up
2. Waits for WAN DHCP and DNS to actually work (otherwise curl dies)
3. Installs Pi-hole unattended
4. Sets the admin password
5. Patches `pihole.toml`: listeningMode ALL, DHCP block for WiFi, dnsmasq_lines for wired LAN
6. Restarts pihole-FTL
7. Self-destructs its own systemd unit

Logs land in `/var/log/freedom-pi-phase2.log`. Full breakdown in [installer/README.md](installer/README.md).

## Plug it inline when you're done

The installer configures the Pi to BE a router, but doesn't rewire your house. Do that part once phase 2 is finished:

1. Unplug the cable from your ISP modem to your switch (that cable is what's bypassing the Pi).
2. Plug the ISP modem into the UGREEN USB adapter on the Pi (WAN side, `eth1`).
3. Plug the Pi's built-in ethernet port (LAN side, `eth0`) into your switch.
4. Each computer on the switch grabs a new IP from the Pi within ~10 seconds. If one is stubborn, unplug and replug its cable.

Verify you're actually inline:

```bash
ip -br addr | grep -E 'eth|wlan'
```

- `eth1` should have the ISP-assigned IP (like `10.x.x.x/22`)
- `eth0` should only have your static `192.168.1.1/24`, no ISP IP on it

If `eth0` has two IPs, the modem-to-switch bypass cable is still plugged in somewhere. Find it and unplug it.

## Client-side gotchas

Nothing the installer can fix on your other devices. Heads up for when you're troubleshooting.

- **iCloud Private Relay hides DNS failures on iPhones.** If Pi-hole is broken, Safari still loads because Apple tunnels its own DNS. Phone looks fine, Pi-hole sees zero queries. Turn Private Relay off in Settings to confirm.
- **macOS caches manual DNS.** If any interface has manual DNS set in System Settings, it overrides DHCP. Clear with `sudo networksetup -setdnsservers "Interface Name" "Empty"`. Check with `scutil --dns | grep -A 3 "resolver #1"`, should point at your LAN gateway, not `1.1.1.1`.
- **Windows hangs onto old DHCP leases.** After going inline, run `ipconfig /release` then `ipconfig /renew` in an admin PowerShell.

## What this unlocks

Every packet from every device on your network now flows through Pi-hole. From here:

- Pump up the blocklists in the Pi-hole admin
- Turn on DNS over HTTPS upstream so your ISP can't read your queries
- `tcpdump` any specific device from the Pi
- Add Suricata or Snort if you want IDS/IPS
- Plug IoT junk into the wired LAN and actually see what it phones home to
