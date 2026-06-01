# Runbook — Rebuild `.140` canary (`OpenCanary` VM / `fs1` host)

Rebuilds the internal trip-wire canary host from scratch. Cold rebuild ~30 min;
fast-path (OVA restore) ~5 min once an OVA backup exists.

**Naming:** VirtualBox VM name is `OpenCanary`. Guest OS hostname is `fs1`.
Ansible inventory name is `fileserver-140`. SMB netbiosname is `FS1`. Three
different names — pay attention to which one each step needs.

## Prereqs
- `.15` hypervisor up (use WoL from `.13` if .15 stayed off after AC loss)
- `.133` Wazuh manager reachable
- soc-ansible repo on `.120` clean
- Debian 13.x minimal ISO at `C:\Users\Games\Downloads\debian-13.x-amd64-netinst.iso`

## Cold rebuild (no OVA available)

### 1. Create the VM on `.15`
SSH as `Games@.15` and run:
```powershell
$VBOX='C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
& $VBOX createvm --name OpenCanary --ostype Debian_64 --register
& $VBOX modifyvm OpenCanary --cpus 1 --memory 768 --vram 16 --audio-driver none --usb on --usbohci on --vrde on --vrdeport 3391 --boot1 dvd --boot2 disk --boot3 none --boot4 none --nic1 bridged --nictype1 virtio --macaddress1 auto
& $VBOX modifyvm OpenCanary --bridgeadapter1 'Intel(R) Ethernet Connection (7) I219-V'
& $VBOX createmedium disk --filename 'C:\Users\Games\VirtualBox VMs\OpenCanary\OpenCanary.vdi' --size 4096 --variant Standard
& $VBOX storagectl OpenCanary --name SATA --add sata --portcount 2
& $VBOX storageattach OpenCanary --storagectl SATA --port 0 --device 0 --type hdd --medium 'C:\Users\Games\VirtualBox VMs\OpenCanary\OpenCanary.vdi' --nonrotational on --discard on
& $VBOX storageattach OpenCanary --storagectl SATA --port 1 --device 0 --type dvddrive --medium 'C:\Users\Games\Downloads\debian-13.4.0-amd64-netinst.iso'
& $VBOX startvm OpenCanary --type headless
```

VRDE listens on `.15:3391`. From `.13`: `mstsc /v:192.168.1.15:3391`.

### 2. Debian install (VRDE console, ~10 min)
- Hostname: **`fs1`**, no domain
- Strong root password (save), skip user creation
- Partitioning: guided, entire disk, all in one partition (no LVM)
- Software selection: **only** `SSH server` + `standard system utilities`
- GRUB to `/dev/sda`

After first boot, log in as root via VRDE and:
```bash
# Static IP (replace dhcp block in /etc/network/interfaces)
cat > /etc/network/interfaces <<EOF
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback
allow-hotplug enp0s3
iface enp0s3 inet static
    address 192.168.1.140
    gateway 192.168.1.1
    dns-nameservers 192.168.1.1
EOF

# Debian 13 ships dhcpcd which parallel-claims an extra IP via DHCP — purge it
apt-get purge -y dhcpcd-base
pkill -9 -f dhcpcd 2>/dev/null
ip addr del 192.168.1.<dhcp-leased-ip>/24 dev enp0s3 2>/dev/null
systemctl restart networking

# Debian 13 minimal doesn't ship rsyslog or systemd-timesyncd — needed for canary
apt-get update
apt-get install -y curl ca-certificates rsync rsyslog systemd-timesyncd
systemctl enable --now systemd-timesyncd
```

### 3. SSH keys
From `.13`:
```powershell
# .120 control-node pubkey (Ansible)
$pub120 = ssh -i $env:USERPROFILE\.ssh\openwrt root@192.168.1.120 'cat /root/.ssh/id_ed25519.pub'
ssh root@192.168.1.140 "echo '$pub120' >> /root/.ssh/authorized_keys"

# openwrt key (admin from .13)
$openwrt = Get-Content $env:USERPROFILE\.ssh\openwrt.pub
ssh root@192.168.1.140 "echo '$openwrt' >> /root/.ssh/authorized_keys"
ssh root@192.168.1.140 'chmod 600 /root/.ssh/authorized_keys'
```

### 4. Install Wazuh agent (manual one-time, matches existing convention)
```bash
ssh -i ~/.ssh/openwrt root@192.168.1.140 << 'EOF'
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
apt-get update
WAZUH_MANAGER='192.168.1.133' apt-get install -y wazuh-agent=4.14.5-1
echo "wazuh-agent hold" | dpkg --set-selections
systemctl enable --now wazuh-agent
EOF
```

### 5. Converge IaC
```bash
ssh -i ~/.ssh/openwrt root@192.168.1.120 'cd /opt/soc-ansible && ansible-playbook playbooks/site.yml --limit fileserver-140'
```

Idempotent re-run should show `changed=0`. If samba `full_audit` errors with `Could not find opname X` after a samba major upgrade, the operation names may have changed again — see the `success = all` line in `roles/canary/templates/smb.conf.j2`.

### 6. Verify
```bash
ssh -i ~/.ssh/openwrt root@192.168.1.120 'cd /opt/soc-ansible && ansible-playbook playbooks/ops/health-check.yml'
```

Expected: canary section all `[OK]`, **22+ listening ports** (8 OpenCanary + 14 sinkhole, excluding sshd:22), both log files present.

End-to-end alert test from `.13`:
```bash
smbclient -L 192.168.1.140 -N           # should list HR, Backups, IT
smbclient //192.168.1.140/HR -N -c 'ls' # 2nd hit within 1h fires ntfy rule 100312
```

## Fast path — OVA restore (when OVA backup exists)

`C:\Users\xndre\OneDrive\Claude\backup\vms\OpenCanary-YYYYMMDD.ova` (not
currently created — first OVA capture is a TODO for the user). When available:

```powershell
$ova = Get-ChildItem C:\Users\xndre\OneDrive\Claude\backup\vms\OpenCanary-*.ova | Sort-Object Name -Descending | Select-Object -First 1
scp -i $env:USERPROFILE\.ssh\openwrt $ova.FullName "Games@192.168.1.15:C:/Users/Games/Desktop/"
ssh -i $env:USERPROFILE\.ssh\openwrt Games@192.168.1.15 "powershell -Command \"& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' import 'C:\Users\Games\Desktop\$($ova.Name)' --vsys 0 --vmname OpenCanary\""
ssh -i $env:USERPROFILE\.ssh\openwrt Games@192.168.1.15 "powershell -Command \"& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' startvm OpenCanary --type headless\""
```

Then run step 6 of the cold rebuild.

## Sleep policy reminder

`C:\scripts\soc-sleep-savestate.ps1` does NOT include `OpenCanary` in its
`$vms` array — keeps it 24/7. `C:\scripts\soc-start-savestate.ps1` DOES
include it so the VM cold-boots if `.15` is restarted. If a future power-script
refactor touches these, preserve both behaviours.

## Recovery time
- Fast path (OVA): ~5 min
- Cold rebuild: ~30 min
