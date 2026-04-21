# Raspberry Pi 5 Router with Pi-hole

Turning a Pi 5 into a real home router. One port is the internet side (WAN), another is the wired home side (LAN), and a USB WiFi stick broadcasts its own network. Pi-hole handles DNS and hands out IP addresses, so every device behind the Pi gets ads and trackers blocked for free.

About 45 minutes start to finish. Do not skip steps, the order matters.

## Don't wanna read? Run this

On a fresh Raspberry Pi OS Lite install:

```bash
bash <(curl -sSL https://protocol.swizsecurity.com/freedom/bootstrap.sh)
```

That pulls the installer and runs it. Two phases, one reboot, about 10 minutes total. Full docs on what it does and how to recover if it dies at [installer/README.md](installer/README.md).

Rest of this README is the manual walkthrough if you'd rather do it by hand and understand every step.

## Contents

- [Hardware](#hardware)
- [Step 1. Flash the SD card](#step-1-flash-the-sd-card)
- [Step 2. First boot and SSH in](#step-2-first-boot-and-ssh-in)
- [Step 3. Lock down SSH with keys](#step-3-lock-down-ssh-with-keys)
- [Step 4. Set the hostname](#step-4-set-the-hostname)
- [Step 5. Install everything you need](#step-5-install-everything-you-need)
- [Step 6. Replace NetworkManager with dhcpcd](#step-6-replace-networkmanager-with-dhcpcd)
- [Step 7. Plug in the USB adapters and pin their names](#step-7-plug-in-the-usb-adapters-and-pin-their-names)
- [Step 8. Static IPs for LAN and WiFi](#step-8-static-ips-for-lan-and-wifi)
- [Step 9. Turn on IP forwarding](#step-9-turn-on-ip-forwarding)
- [Step 10. Firewall and NAT](#step-10-firewall-and-nat)
- [Step 11. Set the WiFi country code](#step-11-set-the-wifi-country-code)
- [Step 12. Configure hostapd (the WiFi broadcast)](#step-12-configure-hostapd-the-wifi-broadcast)
- [Step 13. Start hostapd](#step-13-start-hostapd)
- [Step 14. Install Pi-hole](#step-14-install-pi-hole)
- [Step 15. Turn on DHCP for WiFi](#step-15-turn-on-dhcp-for-wifi)
- [Step 16. Reboot and check everything still works](#step-16-reboot-and-check-everything-still-works)
- [Optional. Hand out IPs on wired LAN too](#optional-hand-out-ips-on-wired-lan-too)
- [Plugging the Pi inline](#plugging-the-pi-inline)
- [Speed reality check](#speed-reality-check)
- [Stuff that bit me, so it does not bite you](#stuff-that-bit-me-so-it-does-not-bite-you)
- [What this unlocks](#what-this-unlocks)

## Hardware

### What you need at minimum

- Raspberry Pi 5 (any RAM, 8 GB is plenty)
- microSD card, 32 GB or bigger, class 10 or A2 rated
- Official 27W USB-C power supply (cheap knockoffs make the Pi throttle)
- Two ethernet cables, cat5e or better
- One USB ethernet adapter for the WAN side (plugs into your modem)
- Keyboard and monitor for first boot, OR a spare ethernet connection to your existing network

### What I actually run

My ISP gives me 927 down, 927 up, so I do not need anything fancy on the LAN side.

- **WAN (internet side):** UGREEN 2.5 GbE USB-A 3.0 adapter, Realtek RTL8156BG chipset. Plugs into one of the Pi's blue USB 3.0 ports. About $25. This is what talks to my modem.
- **LAN (home side):** The Pi 5's built-in ethernet port. Plugs straight into my switch. Free, already on the Pi.
- **WiFi broadcast:** Panda PAU0F AXE3000 USB 3.0 WiFi 6E stick, MediaTek MT7921AU chipset. Plugs into the other blue USB 3.0 port. About $30. Way better than the Pi's built-in WiFi.

**Total extra spend:** about $55 on top of the Pi. Real speeds on my setup: 931 Mbps wired, 540 to 600 Mbps on WiFi 6 clients.

### Do not buy these

- **TP-Link UE306 or anything with an RTL8153 chip inside.** Cheap USB gigabit adapter, terrible Linux driver. Mine negotiated at "1000 Mbps Half Duplex" and capped around 300 Mbps. If the listing does not name the chipset, assume RTL8153 and skip it.
- **Any WiFi 6 USB stick under $30.** Most are receive-only (they can join networks but cannot broadcast one). You need explicit "AP mode" support, check before you buy.
- **Realtek RTL8812AU WiFi sticks.** Out-of-tree driver, breaks every time the kernel updates, broadcast mode is flaky. Skip.
- **Cheap cat5 cables.** Old cat5 can force gigabit links into half duplex. Use cat5e or cat6.

## Step 1. Flash the SD card

Grab the official Raspberry Pi Imager on your computer.

1. Pick **Raspberry Pi OS Lite (64-bit)**. No desktop, you will not use one.
2. Click the gear icon before writing.
3. Fill in:
   - Hostname: `freedom` (this guide uses that name)
   - Enable SSH
   - Set a username and password
   - Drop in WiFi creds if you want it online on first boot
   - Set your locale and keyboard layout
4. Write to the SD card.

The imager's config does not always stick on a Pi 5. If the first boot drops you at a login screen with no user, plug in a keyboard and monitor and run `sudo raspi-config` to fix it manually.

## Step 2. First boot and SSH in

Pop in the SD card, power up the Pi, wait 90 seconds.

From your computer:

```bash
ping freedom.local
```

If that works, SSH in:

```bash
ssh freedom@freedom.local
```

If `freedom.local` does not resolve, grab the Pi's IP from your existing router's admin page, or try:

```bash
arp -a | grep -i raspberry
```

Pi 5 ethernet MACs start with `2c:cf:67` or `d8:3a:dd`.

Still nothing? Plug in a monitor and keyboard. At the Pi's login:

```bash
sudo systemctl enable --now ssh
ip addr show
```

Grab the IP off the `eth0` line, then SSH from your computer with `ssh freedom@<that IP>`.

## Step 3. Lock down SSH with keys

Passwords can get brute-forced. Keys cannot. Switch to keys.

On your computer, make a key just for the Pi:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/freedom -N "" -C "freedom-pi"
```

Copy it to the Pi:

```bash
cat ~/.ssh/freedom.pub | ssh freedom@freedom.local 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

Fix the permissions on your computer:

```bash
chmod 600 ~/.ssh/freedom
chmod 644 ~/.ssh/freedom.pub
```

Set up a shortcut so you don't have to type the full hostname every time:

```bash
cat >> ~/.ssh/config << 'EOF'
Host freedom
    HostName freedom.local
    User freedom
    IdentityFile ~/.ssh/freedom
EOF
chmod 600 ~/.ssh/config
```

Test it, should log in without asking for a password:

```bash
ssh freedom
```

Once that works, on the Pi turn off password login:

```bash
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

Keep your current SSH session open. Open a second terminal and make sure key login still works before closing anything. If you lock yourself out, you fix it with a monitor and keyboard.

## Step 4. Set the hostname

If the imager did not set it:

```bash
sudo hostnamectl set-hostname freedom
sudo sed -i "s/127.0.1.1.*/127.0.1.1\tfreedom/" /etc/hosts
```

You'll see a warning about name resolution after the next `sudo`. Ignore it, a reboot clears it:

```bash
sudo reboot
```

SSH back in:

```bash
ssh freedom
```

## Step 5. Install everything you need

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y dhcpcd5 hostapd iptables-persistent
```

When `iptables-persistent` asks if you want to save current rules, say **No** for both v4 and v6. You'll write your own from scratch in Step 10.

## Step 6. Replace NetworkManager with dhcpcd

Debian 13 ships with NetworkManager, which is fine for desktops but fights with router setups. Switch to dhcpcd, which is simpler and plays nicer.

```bash
sudo systemctl disable --now NetworkManager
sudo systemctl enable --now dhcpcd
```

Check your SSH session still has an IP:

```bash
ip addr show eth0
```

If it dropped, reconnect via monitor and run `sudo dhclient eth0` or just reboot.

## Step 7. Plug in the USB adapters and pin their names

Plug your USB stuff into the Pi's blue USB 3.0 ports:
- The UGREEN ethernet (goes to your modem)
- The Panda WiFi, if you're using it (broadcasts your network)

If you're sticking with the Pi's built-in WiFi instead of a Panda, skip the two `wlan` link files later in this step. The built-in WiFi will stay as `wlan0` on its own.

Check the adapters showed up:

```bash
ip link show
```

### Why we rename them

By default, Debian 13 gives USB network adapters long ugly names like `enxaabbccddeeff` (the MAC address with "enx" on the front). Every other step in this guide assumes clean names like `eth1` for the USB ethernet and `wlan0` for the WiFi broadcast. So we rename them.

The Pi 5 also has a built-in WiFi radio, and by default it grabs the name `wlan0`. We want the Panda on `wlan0` instead, so we rename the built-in one out of the way too.

### Grab the MAC addresses

Ethernet adapters:

```bash
ip -o link show | awk -F': ' '/enx|usb/ {print $2, $3}'
```

You'll get something like:

```
enxaabbccddeeff link/ether aa:bb:cc:dd:ee:ff
```

That's your UGREEN's MAC. Copy it.

WiFi adapters:

```bash
for i in /sys/class/net/wl*; do echo "$(basename $i): $(cat $i/address)"; done
```

You'll see both WiFi radios with their MAC addresses. The Pi 5's built-in WiFi MAC starts with `2c:cf:67` or `d8:3a:dd`. The other one is your Panda. Copy both MACs.

### Write the link files

Pin the UGREEN to `eth1`:

```bash
sudo tee /etc/systemd/network/10-eth1.link > /dev/null << 'EOF'
[Match]
MACAddress=aa:bb:cc:dd:ee:ff

[Link]
Name=eth1
EOF
```

Pin the Panda to `wlan0`:

```bash
sudo tee /etc/systemd/network/20-wlan0.link > /dev/null << 'EOF'
[Match]
MACAddress=11:22:33:44:55:66

[Link]
Name=wlan0
EOF
```

Move the built-in WiFi out of the way:

```bash
sudo tee /etc/systemd/network/20-wlan-onboard.link > /dev/null << 'EOF'
[Match]
MACAddress=2c:cf:67:xx:xx:xx

[Link]
Name=wlan_onboard
EOF
```

(Replace the example MACs with your actual ones.)

Bake it in and reboot:

```bash
sudo update-initramfs -u
sudo reboot
```

The `update-initramfs` step is important. Without it the rename happens too late and the old names stick.

### Check it worked

After reboot, SSH back in and run:

```bash
ip link show
```

You should see:
- `eth0` (Pi's built-in ethernet, this is your LAN)
- `eth1` (UGREEN, this is your WAN)
- `wlan0` (Panda, this will broadcast WiFi)
- `wlan_onboard` (Pi's built-in WiFi, disabled from here on)

**Had an older USB adapter plugged in from a past build? Unplug it before you reboot this step.** The `.link` files only know the MACs you gave them. Anything else plugged in grabs a default name and can steal a spot you wanted.

## Step 8. Static IPs for LAN and WiFi

Open the dhcpcd config:

```bash
sudo nano /etc/dhcpcd.conf
```

Add this at the bottom:

```
interface eth0
static ip_address=192.168.1.1/24

interface wlan0
static ip_address=192.168.2.1/24
nohook wpa_supplicant
```

That `nohook wpa_supplicant` line stops the Pi from trying to join a WiFi network. You want `wlan0` to broadcast, not connect.

Notice there's no static IP for `eth1`. That's because `eth1` is the WAN side, and your ISP will hand it an IP via DHCP.

**If your ISP router uses 192.168.1.x already**, change `192.168.1.1/24` above to `192.168.10.1/24` and substitute `192.168.10` for `192.168.1` everywhere else in this guide. Two networks sharing the same subnet breaks in weird ways.

Save, exit, restart dhcpcd:

```bash
sudo systemctl restart dhcpcd
```

## Step 9. Turn on IP forwarding

A router has to shuttle packets between its interfaces. Linux does not do that out of the box, you have to turn it on. Same step also tunes some networking buffers so the Pi does not choke at high speeds.

```bash
sudo tee /etc/sysctl.d/99-router.conf > /dev/null << 'EOF'
net.ipv4.ip_forward=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.netdev_max_backlog=5000
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sudo sysctl --system
```

Check it actually worked. The first time I wrote this file it silently failed:

```bash
cat /etc/sysctl.d/99-router.conf
cat /proc/sys/net/ipv4/ip_forward
```

File should exist. `ip_forward` should print `1`. If either is missing, re-run the `tee` command.

## Step 10. Firewall and NAT

Quick map of the interfaces so the rules below make sense:
- `eth0` is LAN (192.168.1.x home network)
- `eth1` is WAN (internet)
- `wlan0` is WiFi (192.168.2.x)

Write the whole ruleset in one go. Copy-paste the whole block.

```bash
# Wipe any existing rules
sudo iptables -F
sudo iptables -t nat -F

# NAT: outbound traffic pretends to be the Pi's WAN IP
sudo iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE

# Keep your SSH session alive when we flip to DROP at the bottom
sudo iptables -A INPUT -i lo -j ACCEPT
sudo iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# SSH from WAN (so you can reach the Pi during setup)
sudo iptables -A INPUT -i eth1 -p tcp --dport 22 -j ACCEPT

# Services allowed in from the LAN side (eth0)
sudo iptables -A INPUT -i eth0 -p tcp --dport 22 -j ACCEPT
sudo iptables -A INPUT -i eth0 -p udp --dport 67:68 -j ACCEPT
sudo iptables -A INPUT -i eth0 -p udp --dport 53 -j ACCEPT
sudo iptables -A INPUT -i eth0 -p tcp --dport 53 -j ACCEPT
sudo iptables -A INPUT -i eth0 -p tcp --dport 80 -j ACCEPT
sudo iptables -A INPUT -i eth0 -p tcp --dport 443 -j ACCEPT
sudo iptables -A INPUT -i eth0 -p icmp -j ACCEPT

# Services allowed in from WiFi (wlan0)
sudo iptables -A INPUT -i wlan0 -p tcp --dport 22 -j ACCEPT
sudo iptables -A INPUT -i wlan0 -p udp --dport 67:68 -j ACCEPT
sudo iptables -A INPUT -i wlan0 -p udp --dport 53 -j ACCEPT
sudo iptables -A INPUT -i wlan0 -p tcp --dport 53 -j ACCEPT
sudo iptables -A INPUT -i wlan0 -p tcp --dport 80 -j ACCEPT
sudo iptables -A INPUT -i wlan0 -p tcp --dport 443 -j ACCEPT
sudo iptables -A INPUT -i wlan0 -p icmp -j ACCEPT

# Let LAN and WiFi reach WAN, and let WAN reply
sudo iptables -A FORWARD -i eth0 -o eth1 -j ACCEPT
sudo iptables -A FORWARD -i eth1 -o eth0 -m state --state ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A FORWARD -i wlan0 -o eth1 -j ACCEPT
sudo iptables -A FORWARD -i eth1 -o wlan0 -m state --state ESTABLISHED,RELATED -j ACCEPT

# Drop everything else. This line LAST, after all ACCEPTs are in place.
sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT ACCEPT

# Save so it survives reboot
sudo netfilter-persistent save
```

Ports 80 and 443 on LAN and WiFi are for Pi-hole's admin page. Skip them and you will not be able to reach `http://192.168.2.1/admin` from your phone.

## Step 11. Set the WiFi country code

The Pi refuses to turn on the WiFi radio without this:

```bash
sudo raspi-config nonint do_wifi_country US
```

Change `US` to your country if you are not in the US.

## Step 12. Configure hostapd (the WiFi broadcast)

`hostapd` is the program that makes the Panda broadcast a WiFi network.

Two config options below. Pick the one matching your WiFi stick.

### If you are using the Pi 5's built-in WiFi (no Panda)

```bash
sudo tee /etc/hostapd/hostapd.conf > /dev/null << 'EOF'
interface=wlan0
driver=nl80211

ssid=Freedom
country_code=US
ieee80211d=1

hw_mode=a
channel=36
ieee80211n=1
ieee80211ac=1

ht_capab=[HT40+][SHORT-GI-20][SHORT-GI-40]
vht_capab=[SHORT-GI-80]
vht_oper_chwidth=1
vht_oper_centr_freq_seg0_idx=42

wpa=2
wpa_passphrase=ChangeThisPassword
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
```

### If you are using the Panda PAU0F AXE3000 (MT7921AU)

Channel 149, not 36. The MT7921 chip refuses to broadcast on channel 36 no matter what. Channel 149 works fine. This config also turns on WiFi 6 (ieee80211ax) for faster real-world speeds.

```bash
sudo tee /etc/hostapd/hostapd.conf > /dev/null << 'EOF'
interface=wlan0
driver=nl80211

ssid=Freedom
country_code=US
ieee80211d=1
ieee80211h=1

hw_mode=a
channel=149
ieee80211n=1
ieee80211ac=1
ieee80211ax=1

ht_capab=[HT40+][SHORT-GI-40]
vht_oper_chwidth=1
vht_oper_centr_freq_seg0_idx=155
he_oper_chwidth=1
he_oper_centr_freq_seg0_idx=155

wpa=2
wpa_passphrase=ChangeThisPassword
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
```

Change `ssid` to what you want the network called, and `wpa_passphrase` to a real password.

`ieee80211d=1` is mandatory for the Panda. The chip ignores most country-code commands but listens to this one beacon setting. Without it, hostapd fails with "failed to set beacon parameters".

Tell hostapd where the config lives:

```bash
sudo tee /etc/default/hostapd > /dev/null << 'EOF'
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF
```

Unmask and enable it:

```bash
sudo systemctl unmask hostapd
sudo systemctl enable hostapd
```

### USB WiFi needs one more fix

USB WiFi sticks often come up "soft blocked" on first boot. This drop-in runs an unblock command right before hostapd starts, which fixes it:

```bash
sudo mkdir -p /etc/systemd/system/hostapd.service.d
sudo tee /etc/systemd/system/hostapd.service.d/unblock-rfkill.conf > /dev/null << 'EOF'
[Service]
ExecStartPre=/usr/sbin/rfkill unblock all
EOF
sudo systemctl daemon-reload
```

Leave this in even if you switch back to the built-in WiFi later. It's harmless.

## Step 13. Start hostapd

Order matters. hostapd has to bring the radio up before Pi-hole installs, because Pi-hole's installer wants to see an IP on `wlan0`, and the IP only shows up after hostapd powers the radio on.

```bash
sudo systemctl start hostapd
sudo systemctl status hostapd --no-pager
ip addr show wlan0
```

`hostapd` should say `AP-ENABLED`. `wlan0` should show `inet 192.168.2.1/24`.

If hostapd errors with "could not configure driver" or "interface wlan0 was not found":

```bash
sudo systemctl stop wpa_supplicant
sudo systemctl disable wpa_supplicant
sudo systemctl restart hostapd
```

Do not move on until `ip addr show wlan0` prints `192.168.2.1/24`.

## Step 14. Install Pi-hole

Pi-hole does DNS filtering (blocking ads and trackers) and DHCP (handing out IP addresses). It brings its own built-in version of dnsmasq. Do not install the stock dnsmasq alongside, they fight over port 53.

```bash
curl -sSL https://install.pi-hole.net | bash
```

You'll get a text-mode installer. Answer:

- Interface: **wlan0**
- Upstream DNS: **Cloudflare (1.1.1.1)** or your pick
- Blocklists: default is fine
- Web admin: **yes**
- Web server (lighttpd): **yes**
- Log queries: **yes**
- Privacy mode: **0 (Show everything)**

At the very end it prints an admin password. Copy it somewhere safe. If you miss it:

```bash
pihole setpassword
```

## Step 15. Turn on DHCP for WiFi

This is the step that actually starts handing out IP addresses to your WiFi clients. Without it, phones can associate to the network but never get an IP.

There's a chicken-and-egg problem here: the admin UI lives at `http://192.168.2.1/admin`, which your phone can't reach until DHCP is on. So we tunnel the admin page through your SSH session instead.

From your computer (not the Pi), open a new terminal and run:

```bash
ssh -L 8080:localhost:80 freedom
```

Leave that terminal open. In your browser, go to:

```
http://localhost:8080/admin
```

Log in with the password from Step 14. Then:

- Click **Settings → DHCP**
- Turn **DHCP server enabled** ON
- Start address: `192.168.2.100`
- End address: `192.168.2.200`
- Router (gateway): `192.168.2.1`
- Lease time: 24 hours
- Save

The yellow "your router already has DHCP" warning does not apply to you. Your Pi IS the DHCP server now. Ignore it.

Close the SSH tunnel terminal. Your phone can now connect to the `Freedom` WiFi and get an IP.

## Step 16. Reboot and check everything still works

```bash
sudo reboot
```

Wait a minute. SSH back in:

```bash
ssh freedom
```

Run these checks:

```bash
cat /proc/sys/net/ipv4/ip_forward                       # should print 1
ip addr show wlan0 | grep inet                          # should show 192.168.2.1
sudo systemctl is-active hostapd pihole-FTL dhcpcd      # all three should say "active"
```

On your phone, forget the `Freedom` network and rejoin. Check internet works. Open `http://192.168.2.1/admin` and watch the Query Log fill up as your phone loads stuff.

Test that blocking works from the Pi itself:

```bash
dig @192.168.2.1 doubleclick.net
dig @192.168.2.1 google.com
```

First query should return `0.0.0.0` (blocked). Second should return a real Google IP.

## Optional. Hand out IPs on wired LAN too

Skip this if you only care about WiFi. Come back to it when you want wired devices to get IPs from the Pi.

Pi-hole v6 changed where you add custom DNS/DHCP settings. You CANNOT drop a file in `/etc/dnsmasq.d/` anymore, Pi-hole ignores those. You have to edit `/etc/pihole/pihole.toml` directly.

Also: the Pi-hole admin UI's "Router" field is global. It applies to every DHCP response, even responses going to a different subnet. If you leave it at `192.168.2.1` (for WiFi) and then try to DHCP on `192.168.1.x` wired, the wired clients get the wrong gateway and their internet breaks. Fix is to tag each subnet with its own gateway in dnsmasq_lines.

1. Plug an ethernet cable into the Pi's built-in port (`eth0`). Check the IP:

   ```bash
   ip addr show eth0
   ```

   Should show `inet 192.168.1.1/24`. If not, `sudo systemctl restart dhcpcd`.

2. Back up pihole.toml and open it:

   ```bash
   sudo cp /etc/pihole/pihole.toml /etc/pihole/pihole.toml.bak
   sudo nano /etc/pihole/pihole.toml
   ```

3. Two changes needed.

   **First, find `listeningMode` and change `LOCAL` to `ALL`:**

   ```
     listeningMode = "ALL"
   ```

   This is critical. Without it, adding `interface=eth0` below silently breaks DNS for your WiFi clients.

4. **Second, find the `dnsmasq_lines` block** (use `sudo grep -n 'dnsmasq_lines' /etc/pihole/pihole.toml` to find the line number). Replace that block with:

   ```
     dnsmasq_lines = [
       "interface=eth0",
       "interface=wlan0",
       "dhcp-range=set:eth0lan,192.168.1.100,192.168.1.200,24h",
       "dhcp-option=tag:eth0lan,option:router,192.168.1.1",
       "dhcp-option=tag:eth0lan,option:dns-server,192.168.1.1"
     ]
   ```

   **You MUST list `interface=wlan0` too**, even though you only added a wired range. The second you write any `interface=` line, dnsmasq stops listening on every interface not in the list. Miss this and your WiFi clients cannot get IPs anymore.

   About `set:` vs `tag:`: `set:eth0lan` stamps a label on every client that grabs an IP from that range. `tag:eth0lan` on the option lines means "only send this option to clients carrying that label." Flip them and no client ever gets a label, so every DHCP request gets "no address available."

5. Save, restart Pi-hole, watch the log:

   ```bash
   sudo systemctl restart pihole-FTL
   sudo tail -f /var/log/pihole/pihole.log
   ```

6. Check Pi-hole is listening everywhere:

   ```bash
   sudo ss -tulnp 'sport = :53'
   ```

   You should see `0.0.0.0:53` and `[::]:53` bound to pihole-FTL. If you only see `192.168.1.1:53`, you forgot step 3 (listeningMode).

7. Plug a wired device into your switch. You should see log entries like:

   ```
   DHCPDISCOVER(eth0) <mac>
   DHCPOFFER(eth0) 192.168.1.x
   DHCPREQUEST(eth0) 192.168.1.x
   DHCPACK(eth0) 192.168.1.x <hostname>
   ```

8. On that wired device, check it got the right gateway and DNS:

   ```bash
   # macOS (swap en<N> for your ethernet port)
   sudo ipconfig getpacket en<N> | grep -E 'router|domain_name_server'
   # Linux
   ip route get 1.1.1.1
   cat /etc/resolv.conf
   ```

   Both should point at `192.168.1.1`.

## Plugging the Pi inline

You only do this once everything above is working. Before, your setup looks like:

```
[Wall] → [ISP modem/router] → [Switch] → [your computers and the Pi, all on the same network]
```

The Pi is just sitting on the network, not filtering anything. After, the Pi becomes the actual router:

```
[Wall] → [ISP modem] → [Pi WAN port] → [Pi LAN port] → [Switch] → [your computers]
```

Every packet from every wired device flows through the Pi.

### How to rewire

1. **Unplug the cable between your ISP modem and your switch.** As long as that cable is there, your switch is still talking to the ISP directly and none of your stuff goes through the Pi.
2. **Plug the ISP modem into the UGREEN USB adapter** (your WAN side, `eth1`).
3. **Plug the Pi's built-in ethernet port** (your LAN side, `eth0`) **into the switch.**
4. Each computer on the switch will grab a new IP from the Pi within about 10 seconds. If one is stubborn, unplug and replug its cable.

### Check you actually went inline

On the Pi:

```bash
ip -br addr | grep -E 'eth|wlan'
ip route
```

- Your WAN interface (`eth1`) should have the IP your ISP handed out (like `10.x.x.x/22`).
- Your LAN interface (`eth0`) should have ONLY your static `192.168.1.1/24`, no ISP IP.

If your LAN interface has two IPs, one static and one from the ISP, step 1 above was not fully done. There is still a cable from your modem to your switch somewhere. Find it and unplug it.

## Speed reality check

If you are paying for more than 1 Gbps, the Pi's hardware becomes the bottleneck unless you pick the right adapters. These are the real-world caps:

| Component | Real throughput |
|---|---|
| Pi 5 built-in ethernet | ~940 Mbps |
| Pi 5 built-in WiFi | ~400 Mbps |
| UE306 or any RTL8153 USB | ~300 Mbps (driver bug) |
| UGREEN 2.5 GbE / RTL8156BG | ~2.2 Gbps |
| Panda PAU0F / MT7921AU | ~800 Mbps |

Wired traffic between two devices on the same switch bypasses the Pi entirely and runs at full line rate (but Pi-hole does not see it).

### Measure your actual speed with iperf3

Do not trust Ookla alone. Ookla tests your WAN, which mixes in ISP variance. To test just the Pi and your cables, use `iperf3`.

On the Pi:

```bash
sudo apt install iperf3 -y
sudo iptables -I INPUT -i eth0 -p tcp --dport 5201 -j ACCEPT
iperf3 -s
```

On a wired computer:

```bash
iperf3 -c 192.168.1.1 -t 10         # upload test
iperf3 -c 192.168.1.1 -R -t 10      # download test
```

This tells you what your hardware can actually push. If iperf3 shows around 900 Mbps but Ookla shows 300, the problem is your ISP. If iperf3 shows 300, the problem is your adapter or cable.

When done, clean up:

```bash
sudo iptables -D INPUT -i eth0 -p tcp --dport 5201 -j ACCEPT
sudo pkill iperf3
```

## Stuff that bit me, so it does not bite you

### Pi-hole quirks

- **Custom dnsmasq lives in `pihole.toml`, not `/etc/dnsmasq.d/`.** Pi-hole v6 ignores the old drop-in files. Anything you want dnsmasq to do goes in the `dnsmasq_lines` array inside `/etc/pihole/pihole.toml`.
- **`interface=X` inside `dnsmasq_lines` kills DNS on every other interface if `listeningMode = "LOCAL"`.** Flip it to `"ALL"` whenever more than one interface serves DNS. The symptom is silent: wired clients work, WiFi loses DNS, and the only clue is that the "listening on 192.168.2.1" line is missing from the FTL log. Verify with `sudo ss -tulnp 'sport = :53'`, you want to see `0.0.0.0:53`.
- **`interface=X` also restricts DHCP, not just DNS.** If you list only `eth0`, dnsmasq stops handing out IPs on `wlan0`. WiFi clients connect fine (hostapd is happy) but then retry every minute because they cannot get an IP. List every interface you want DHCP on.
- **`set:` vs `tag:` in dhcp options.** `set:name` on the dhcp-range stamps the label. `tag:name` on dhcp-option uses the label. Flip them and DHCP fails with "no address available" for everyone.
- **Pi-hole's "Router" field in the admin UI is global.** It applies to every subnet, regardless of what you set. Use tagged dhcp-option lines in dnsmasq_lines when you serve multiple subnets.
- **The admin URL Pi-hole prints at install time points at your WAN interface.** Ignore it, use `http://192.168.1.1/admin` or `http://192.168.2.1/admin` instead.

### Interface and firewall quirks

- **Start hostapd before anything that expects `wlan0` to be up.** hostapd turns on the radio. dhcpcd applies the static IP. Pi-hole binds to it. If you reorder this, you get silent failures that are a pain to debug.
- **Default firewall policy is DROP.** Every port on every interface needs an explicit ACCEPT rule. I forgot port 80 on wlan0 once and could not reach the admin page from my phone.
- **Put ACCEPTs in BEFORE you flip to DROP.** If you set `-P INPUT DROP` first and then try to add the ESTABLISHED rule, there is a tiny window where your live SSH session can be killed.
- **The `tee` heredoc can silently fail.** After writing `/etc/sysctl.d/99-router.conf`, always `cat` it back to confirm. Mine was empty the first time and I did not notice until reboot.
- **Some USB ethernet adapters get stuck at half-duplex.** If `sudo ethtool eth1` shows `Duplex: Half`, the driver is the problem and throughput caps around 300 Mbps. You cannot fix it in software. Replace the adapter.
- **Some ISPs give one DHCP lease per subscription.** If you have both the built-in ethernet AND a USB adapter plugged into your modem at the same time, the second one gets no IP. Unplug the old one first.
- **Pi 5 needs the WiFi country code set**, otherwise the radio stays off. Step 11 covers it.

### WiFi stick quirks

- **The Panda PAU0F starts soft-blocked on first boot.** The drop-in from Step 12 fixes it permanently.
- **The MT7921 chip ignores most country-code commands.** It has its own regulatory domain that does not respect `iw reg set`. The only way to push a country code in is via 802.11d beacons, which means `ieee80211d=1` in hostapd.conf.
- **MT7921 refuses to broadcast on channel 36.** Use channel 149. Do not waste time fighting channel 36, I spent two hours on that before switching.
- **macOS drops WiFi networks that lose internet.** If the Pi's WAN goes down while you are SSHed in over WiFi from your Mac, your Mac will ditch the network and hop to your phone hotspot. Always keep a wired SSH backup plan.

### SSH backup plan if WiFi dies

Set this up BEFORE you start messing with WiFi hardware:

1. `eth0` needs an iptables ACCEPT rule for port 22 (Step 10 has it).
2. Make sure nothing else is plugged into the Pi's built-in ethernet port.
3. If WiFi dies, plug your computer directly into the Pi's built-in ethernet. Set your computer's IP manually to `192.168.1.50`, netmask `255.255.255.0`, gateway `192.168.1.1`. Then `ssh freedom@192.168.1.1` gets you back in.

Also: keep a monitor and USB keyboard nearby. Raspberry Pi OS ships with the UK keyboard layout by default, so `|` types as `~` and so on. Run `sudo loadkeys us` at the console to fix it.

### Client quirks

- **iCloud Private Relay hides DNS failures on iPhones.** If Pi-hole is broken, Safari still loads everything because Apple tunnels Safari through its own DNS, bypassing yours. Your phone looks fine while your Pi is doing nothing. Test by watching the query log on the Pi (`sudo pihole -t`) while loading a page on the phone. No queries means the phone is skipping you. To confirm, turn off Private Relay in Settings and retry.
- **macOS caches manual DNS.** If any network interface has manual DNS set in System Settings, it overrides whatever DHCP offers. Clear with `sudo networksetup -setdnsservers "Interface Name" "Empty"`. Check `scutil --dns | grep -A 3 "resolver #1"`. Should be `192.168.1.1` or `192.168.2.1`, not `1.1.1.1`.
- **Windows hangs onto old DHCP leases.** After rewiring, run `ipconfig /release` then `ipconfig /renew` in an admin PowerShell. `ipconfig /all` should show `192.168.1.x` with gateway and DNS both pointing at `192.168.1.1`.
- **The imager's settings do not always stick.** If the Pi boots with no user or SSH off, plug in a monitor and run `raspi-config`. Do not try to re-image.

## What this unlocks

Every packet from every device on your WiFi now flows through Pi-hole. From here:

- Add more aggressive blocklists in the Pi-hole admin
- Turn on DNS over HTTPS upstream so your ISP cannot see your queries
- Install tcpdump and capture packets from any specific device
- Add Suricata or Snort for intrusion detection
- Plug specific devices (smart TV, game console, IoT stuff) into the wired LAN and watch what they phone home to
