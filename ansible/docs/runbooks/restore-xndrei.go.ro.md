# Runbook: Router Restore (xndrei.go.ro)

Procedure for rebuilding the Netgear R7800 gateway from a full wipe.

| Field | Value |
|---|---|
| Hardware | Netgear Nighthawk X4S R7800 |
| Firmware | OpenWrt 24.10.5 r29087, target `ipq806x/generic`, image `netgear_r7800` |
| LAN IP | 192.168.1.1 |
| Hostname | `xndrei.go.ro` |
| Backup source | `.20:/opt/soc-ansible/backups/openwrt/router-1/` |

## Backup contents

| File | Restores |
|---|---|
| `uci-export.txt` | All OpenWrt config: network, firewall, DHCP, wireless, unbound, banip, NFS |
| `packages.txt` | Full installed package list |
| `crontab.txt` | Root crontab |
| `AdGuardHome.yaml` | AGH blocklists, rewrites, upstream DNS, users |
| `nginx-xndrei.conf` | nginx virtual host for xndrei.go.ro |
| `acme-renew.sh` | Let's Encrypt renewal script |
| `wol-cgi` | WOL relay CGI binary |

Run `ansible-playbook playbooks/site.yml --limit router-1` before a planned rebuild to freshen these.

---

## Phase 1 — Flash + first boot

1. Download OpenWrt 24.10.5 `sysupgrade` image for `ipq806x/generic/netgear_r7800`.
2. Flash via LuCI (System → Backup/Flash Firmware) or:
   ```sh
   sysupgrade -n /tmp/openwrt-24.10.5-ipq806x-generic-netgear_r7800-squashfs-sysupgrade.bin
   ```
   `-n` wipes config — correct, you are restoring from backup.
3. Router reboots to 192.168.1.1, root password blank.
4. Add SSH authorized keys:
   ```sh
   ssh root@192.168.1.1   # blank password on first login
   cat >> /etc/dropbear/authorized_keys << 'EOF'
   # xndre@147K (.13 workstation)
   ssh-ed25519 AAAA... xndre@147K
   # root@suricata (.20 control node)
   ssh-ed25519 AAAA... root@suricata
   # andrei@13xD+ (laptop)
   ssh-ed25519 AAAA... andrei@13xD+
   EOF
   ```
   Get the actual public keys from `.13:~/.ssh/id_ed25519.pub`, `.20:~/.ssh/id_ed25519.pub`, and the laptop.

---

## Phase 2 — UCI import (core config)

Copy backup files to the router, then import:

```sh
# From .20 control node:
scp /opt/soc-ansible/backups/openwrt/router-1/uci-export.txt root@192.168.1.1:/tmp/
scp /opt/soc-ansible/backups/openwrt/router-1/packages.txt root@192.168.1.1:/tmp/
scp /opt/soc-ansible/backups/openwrt/router-1/crontab.txt root@192.168.1.1:/tmp/

ssh root@192.168.1.1
uci import < /tmp/uci-export.txt
uci commit
reboot
```

After reboot: LAN, firewall, DHCP, both WiFi SSIDs, IoT VLAN, Unbound UCI settings (including `unbound_control=1`, `ttl_neg_max=30`), and banip feeds are all restored.

---

## Phase 3 — Packages

```sh
ssh root@192.168.1.1   # now using key auth
opkg update

# Extract non-base packages from the backup list and install:
grep -E 'AdGuardHome|tailscale|banip|unbound-control|unbound-control-setup|unbound-daemon|unbound-anchor|unbound-host|netdata|acme|nmap|nlbwmon|rpcbind|nfs|kmod-fs-nfs' \
  /tmp/packages.txt | awk '{print $1}' | xargs opkg install
```

> **Tailscale:** opkg installs `1.80.3-r1`. Upgrade the binary immediately after:
> ```sh
> tailscale update
> ```
> Target binary version: `1.96.4`.

---

## Phase 4 — AdGuardHome

AdGuardHome is not in opkg — manual install required.

```sh
# Download linux_arm build v0.107.73 from GitHub releases (or later):
cd /tmp
curl -LO https://github.com/AdguardTeam/AdGuardHome/releases/download/v0.107.73/AdGuardHome_linux_arm.tar.gz
tar -xzf AdGuardHome_linux_arm.tar.gz
cp AdGuardHome/AdGuardHome /opt/AdGuardHome/AdGuardHome
chmod +x /opt/AdGuardHome/AdGuardHome
```

Restore config and register the service:

```sh
# Copy backup config:
scp /opt/soc-ansible/backups/openwrt/router-1/AdGuardHome.yaml root@192.168.1.1:/etc/AdGuardHome/AdGuardHome.yaml

# On the router:
/opt/AdGuardHome/AdGuardHome -s install
/etc/init.d/AdGuardHome restart
```

AGH binds to `:53` (DNS) and `192.168.1.1:1080` (DoH). Verify:
```sh
/opt/AdGuardHome/AdGuardHome --version
nslookup google.com 127.0.0.1
```

---

## Phase 5 — nginx + WOL relay CGI

```sh
# From .20:
scp /opt/soc-ansible/backups/openwrt/router-1/nginx-xndrei.conf root@192.168.1.1:/etc/nginx/conf.d/xndrei.conf
scp /opt/soc-ansible/backups/openwrt/router-1/wol-cgi root@192.168.1.1:/usr/share/wol-relay/cgi-bin/wol

# On the router:
chmod +x /usr/share/wol-relay/cgi-bin/wol
/etc/init.d/nginx restart
```

---

## Phase 6 — Crontab

```sh
crontab /tmp/crontab.txt
crontab -l   # verify
```

Expected entries:
```
* * * * * echo 'nameserver 127.0.0.1' > /etc/resolv.conf
0 0 * * * /usr/local/bin/acme-renew.sh
0 4 * * 1 opkg update && opkg list-upgradable | logger -t opkg-check
```

---

## Phase 7 — TLS certificate (Let's Encrypt)

```sh
# From .20:
scp /opt/soc-ansible/backups/openwrt/router-1/acme-renew.sh root@192.168.1.1:/usr/local/bin/acme-renew.sh

# On the router:
chmod +x /usr/local/bin/acme-renew.sh

# Configure ACME (account + domain):
uci set acme.@acme[0]=acme
uci set acme.@acme[0].account_email='xndrei@xs.ro'
uci add_list acme.@acme[0].domains='xndrei.go.ro'
uci set acme.@acme[0].enabled='1'
uci commit acme

# Issue certificate (stops uhttpd ~30s for HTTP-01 challenge on WAN port 80):
/usr/local/bin/acme-renew.sh
```

> WAN port 80 must be reachable from the internet. The script handles opening/closing it.
> Cert is issued to `/etc/acme/xndrei.go.ro_ecc/` and symlinked to `/etc/ssl/acme/`.

---

## Phase 8 — Tailscale

```sh
# Get an auth key from https://login.tailscale.com/admin/settings/keys
tailscale up \
  --advertise-routes=192.168.1.0/24 \
  --advertise-exit-node \
  --authkey tskey-auth-...

# Approve subnet routes and exit node in the Tailscale admin console.
tailscale status   # verify peers
```

Tailscale account: `cr231521.fh@` (tag may still show old username in admin UI).

---

## Phase 9 — unbound-control keys

The keys in `/etc/unbound/` are not backed up — regenerate:

```sh
unbound-control-setup -d /etc/unbound
/etc/init.d/unbound restart
unbound-control status   # should show version + "is running"
```

---

## Phase 10 — Verification

```sh
# DNS stack
nslookup google.com 127.0.0.1          # AGH → Unbound → recursive
unbound-control status                  # control socket working

# TLS
curl -sk https://xndrei.go.ro | head -5

# WOL relay
curl -sk "https://xndrei.go.ro/wol?token=<WOL_TOKEN>&mac=..." | head -5

# Tailscale
tailscale status

# AdGuardHome
curl -s http://192.168.1.1:1080/control/status

# BanIP
banip -q status

# NFS
showmount -e localhost
```

Full Ansible health check from `.20` once SSH keys are in place:
```sh
ansible-playbook playbooks/ops/health-check.yml --limit router-1
```
