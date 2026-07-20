# Runbook — Rebuild `.140` canary (`OpenCanary` VM / `fs1` host)

Rebuilds the internal trip-wire canary host from scratch. Cold rebuild ~30 min;
fast-path (OVA restore) ~5 min once an OVA backup exists.

**Naming:** VirtualBox VM name is `OpenCanary`. Guest OS hostname is `fs1`.
Ansible inventory name is `fileserver-24`. SMB netbiosname is `FS1`. Three
different names — pay attention to which one each step needs.

## Prereqs
- `.15` hypervisor up (use WoL from `.13` if .15 stayed off after AC loss). `.15` is now Ubuntu 24.04 — see `hypervisor-15.md` for access/VBoxManage/storage details.
- `.133` Wazuh manager reachable
- soc-ansible repo on `.120` clean
- Debian 13.x minimal ISO on `.15` at `/mnt/vms/iso/debian-13.x-amd64-netinst.iso` (fetch with `wget` from the host, or `scp` it over)

## Cold rebuild (no OVA available)

### 1. Create the VM on `.15`
SSH to the (now Ubuntu) hypervisor as `andrei` — key-only — and run bare
`VBoxManage` (on `PATH` at `/usr/bin/VBoxManage`; VMs are registered under
`andrei`, so it must run as `andrei`). From `.13`:
```bash
ssh -i ~/.ssh/openwrt andrei@192.168.1.15
```
Then on `.15` (paths use the `/mnt/vms` disk; bridged adapter is `eno1`):
```bash
VM="OpenCanary"
VMDIR="/mnt/vms/Virtual Machines/$VM"
ISO="/mnt/vms/iso/debian-13.4.0-amd64-netinst.iso"

VBoxManage createvm --name "$VM" --ostype Debian_64 --register
VBoxManage modifyvm "$VM" --cpus 1 --memory 768 --vram 16 --audio-driver none --usb on --usbohci on --vrde on --vrdeport 3391 --boot1 dvd --boot2 disk --boot3 none --boot4 none --nic1 bridged --nictype1 virtio --macaddress1 auto
VBoxManage modifyvm "$VM" --bridgeadapter1 eno1
VBoxManage createmedium disk --filename "$VMDIR/$VM.vdi" --size 4096 --variant Standard
VBoxManage storagectl "$VM" --name SATA --add sata --portcount 2
VBoxManage storageattach "$VM" --storagectl SATA --port 0 --device 0 --type hdd --medium "$VMDIR/$VM.vdi" --nonrotational on --discard on
VBoxManage storageattach "$VM" --storagectl SATA --port 1 --device 0 --type dvddrive --medium "$ISO"
VBoxManage startvm "$VM" --type headless
```

VRDE listens on `.15:3391`. Connect a remote desktop viewer to that port from
`.13` (no `mstsc` on the Linux host) — e.g. an RDP client pointed at
`192.168.1.15:3391`, or tunnel it back to `.13` and view locally:
```bash
ssh -i ~/.ssh/openwrt -L 3391:127.0.0.1:3391 andrei@192.168.1.15
# then point an RDP viewer on .13 at 127.0.0.1:3391
```

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
ssh -i ~/.ssh/openwrt root@192.168.1.120 'cd /opt/soc-ansible && ansible-playbook playbooks/site.yml --limit fileserver-24'
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

Push the OVA to `.15` and import it there (Ubuntu host, `andrei` user, bare
`VBoxManage`). From `.13` (PowerShell):
```powershell
$ova = Get-ChildItem C:\Users\xndre\OneDrive\Claude\backup\vms\OpenCanary-*.ova | Sort-Object Name -Descending | Select-Object -First 1
scp -i $env:USERPROFILE\.ssh\openwrt $ova.FullName "andrei@192.168.1.15:/mnt/vms/import/"
ssh -i $env:USERPROFILE\.ssh\openwrt andrei@192.168.1.15 "VBoxManage import '/mnt/vms/import/$($ova.Name)' --vsys 0 --vmname OpenCanary"
ssh -i $env:USERPROFILE\.ssh\openwrt andrei@192.168.1.15 "VBoxManage startvm OpenCanary --type headless"
```

Then run step 6 of the cold rebuild.

## Sleep policy reminder

On the now-Ubuntu `.15`, nightly sleep/wake is handled by systemd timers, not
the old Windows PowerShell scripts (see `hypervisor-15.md` → *Nightly sleep /
wake*). `OpenCanary` is one of the 4 SOC VMs the `soc-sleep.service` /
`soc-wake.service` units manage, so it is ACPI-shut at 23:00 and cold-booted at
06:00 along with Suricata, ELK, and T-Pot Hive. It is also cold-booted if `.15`
itself is restarted. The VM list lives in the sleep/wake units under
`scripts/hypervisor-15/`; if a future change touches it, keep `OpenCanary` in
both the sleep and wake sets.

## Recovery time
- Fast path (OVA): ~5 min
- Cold rebuild: ~30 min
