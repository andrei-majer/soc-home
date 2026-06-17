# Runbook: Hypervisor (192.168.1.15)

Ubuntu 24.04 VirtualBox host running the SOC lab VMs. **NOT managed by Ansible** — this runbook plus `scripts/hypervisor-15/` are the source of truth. Migrated from a Windows 11 host on 2026-06-08.

## Host Overview

| Field | Value |
|---|---|
| Hostname | `9700k` |
| IP | `192.168.1.15/24` (static, gateway `.1`) |
| OS | Ubuntu 24.04.4 LTS (kernel 6.8.x) |
| Admin user | `andrei` — sudoer (not passwordless), member of `vboxusers`, key-only SSH |
| MAC (`eno1`) | `B4:2E:99:34:9C:6B` |
| Hardware | Intel i7-9700K (8c/8t), 64 GB RAM, NVIDIA RTX 2080 Ti |
| VirtualBox | 7.2.8 (Oracle apt repo) |
| Secure Boot | enabled — VBox kernel modules MOK-signed |
| Role | VirtualBox host for all SOC lab VMs |

## Access

```bash
# from .13 (workstation)
ssh -i ~/.ssh/openwrt andrei@192.168.1.15
# from .120 (Ansible control node)
ssh -i ~/.ssh/id_ed25519 andrei@192.168.1.15
```

- Key-only: `PasswordAuthentication` and `KbdInteractiveAuthentication` are disabled via `/etc/ssh/sshd_config.d/00-key-only.conf`. The `00-` prefix matters — it loads **before** cloud-init's `50-cloud-init.conf` (sshd is first-win), which would otherwise re-enable password auth.
- Sudo password is held by the operator, **not** in this repo.

## VBoxManage

In `PATH` at `/usr/bin/VBoxManage` — no full-path wrapper needed (unlike the old Windows host). VMs are registered under user **`andrei`**, so **run VBoxManage as `andrei`** (member of `vboxusers`); any other user sees an empty VM list.

```bash
VBoxManage list vms          # all registered
VBoxManage list runningvms   # currently running
```

## VM Inventory

| VM | IP | Role | Default state |
|---|---|---|---|
| Suricata | 192.168.1.120 | IDS + Ansible control node | on (24/7) |
| ELK | 192.168.1.133 | Elastic + Wazuh + MISP + Kibana | on |
| T-Pot Hive | 192.168.1.130 | Honeypot aggregator | on |
| OpenCanary | 192.168.1.140 | Internal canary (`fs1`) | on |
| OpenCTi | 192.168.1.135 | CTI platform | off — on-demand savestate (woken via `opencti-wake.ps1` on `.13`) |
| OpenClaw | — | non-SOC | off |
| T-Pot Sensor | 192.168.1.125 | retired 2026-06-07 | off |

The **4 SOC VMs** (Suricata, ELK, T-Pot Hive, OpenCanary) are the ones the nightly timers manage.

## Storage

| Device | Mount | Notes |
|---|---|---|
| `sda1` (100M vfat) | `/boot/efi` | |
| `sda3` (169G ext4) | `/` | OS, ~15% used |
| `sda2` (320G ext4, LABEL=`vms`) | `/mnt/vms` | all VMs at `/mnt/vms/Virtual Machines/<vm>/`; ~83% used — watch headroom |
| `sdb1` (233G LUKS2 → ext4 LABEL=`storage`) | `/mnt/storage` | encrypted at rest; auto-unlocks at boot via keyfile `/root/sdb.key` (`/etc/crypttab`). `/home` is a symlink into here, so all user homes inherit encryption. |

The `/mnt/vms` fstab entry is in `scripts/hypervisor-15/installed-configs/fstab-vms.snippet`.

## Networking

- **`eno1`** — Intel I219-V, static `192.168.1.15/24` (gateway `.1`) via `/etc/netplan/99-static-ip.yaml`; cloud-init network reconfig disabled with `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`.
- **`enp4s0`** — Realtek GbE, the **SPAN/mirror NIC**: no IP, bridged into the Suricata VM in promiscuous mode. It needs an explicit netplan stanza or it stays DOWN at boot and Suricata sees zero packets — see `scripts/hypervisor-15/README.md`.
- **`tailscale0`** — Tailscale interface.

Config snapshots for all of the above live in `scripts/hypervisor-15/installed-configs/`.

## Nightly sleep / wake

systemd timers replace the old Windows Task Scheduler jobs: ACPI-shutdown the 4 SOC VMs at **23:00** local and cold-boot them at **06:00** (host timezone `Europe/Bucharest`). OpenCTI is excluded (savestate mode). Units, scripts, install steps, and the cold-boot gotchas (`KillMode=process`, `vboxdrv` boot race) are all in **`scripts/hypervisor-15/`**.

```bash
systemctl list-timers soc-sleep.timer soc-wake.timer
sudo systemctl start soc-wake.service     # bring the SOC VMs up now
sudo systemctl start soc-sleep.service    # take them down now
```

Manual cold-start without the timer:

```bash
for vm in Suricata ELK "T-Pot Hive" OpenCanary; do
  VBoxManage startvm "$vm" --type headless
done
```

## Secure Boot / MOK

Secure Boot is **enabled**; the VBox kernel modules (`vboxdrv`, `vboxnetflt`, `vboxnetadp`) are signed with a local MOK key. DKMS re-signs them on kernel/VBox upgrades, but a brand-new key must be enrolled at the blue **MOK Manager** screen on the next boot. Generate-sign-enroll procedure: `scripts/hypervisor-15/installed-configs/README.md`.

```bash
lsmod | grep vbox      # expect vboxdrv, vboxnetflt, vboxnetadp
mokutil --sb-state     # expect "SecureBoot enabled"
```

## Power note

The Windows-era HVCI/VBS/WSL tuning is gone with the OS and **does not apply on Linux** — VirtualBox uses native VT-x directly. No Linux power tuning (TLP/governors) is configured yet, and the old RAPL/HWiNFO wattage figures no longer apply.

## Wake-on-LAN

Same hardware and MAC `B4:2E:99:34:9C:6B`. The host runs 24/7, but after a power **outage** it stays OFF (BIOS is set not to auto-power-on after AC loss).

```bash
# from the router
ssh root@192.168.1.1 "etherwake -i br-lan B4:2E:99:34:9C:6B"
```

## Rebuild from scratch (~30 min from this repo)

1. **Install Ubuntu 24.04**, create sudoer `andrei`, set the hostname.
2. **SSH hardening** — drop `00-key-only.conf` from `installed-configs/`, then `sudo sshd -t && sudo systemctl reload ssh`.
3. **Static IP** — drop `99-static-ip.yaml` + `99-disable-network-config.cfg`, add the `enp4s0` SPAN stanza (see `scripts/hypervisor-15/README.md`), `sudo netplan apply`.
4. **Timezone** — `sudo timedatectl set-timezone Europe/Bucharest`.
5. **VirtualBox 7.2** from the Oracle apt repo (+ Extension Pack). Under Secure Boot, generate, sign, and enroll a MOK (`installed-configs/README.md`), reboot through MOK Manager.
6. **VM disk** — append `fstab-vms.snippet` to `/etc/fstab`, `sudo mkdir -p /mnt/vms && sudo mount /mnt/vms`. If the encrypted disk was lost, re-create the LUKS2 `/mnt/storage` + auto-unlock keyfile.
7. **Re-register VMs** as `andrei` from `/mnt/vms/Virtual Machines/<vm>/<vm>.vbox` (`VBoxManage registervm ...`). `.vbox` files carried over from the Windows host use absolute Windows paths — rewrite them to relative, and remap each VM's bridged adapter to `eno1` (plus `enp4s0` for the Suricata SPAN adapter) before registering.
8. **Sleep/wake** — install the units per the `scripts/hypervisor-15/` README, then `sudo systemctl enable --now soc-sleep.timer soc-wake.timer`.
9. **Verify** — `sudo systemctl start soc-wake.service`, then `ping 192.168.1.120 192.168.1.133 192.168.1.130 192.168.1.140` all respond and `VBoxManage list runningvms` shows the 4 SOC VMs.

## See also

- `scripts/hypervisor-15/` — sleep/wake systemd units, installed-config snapshots, MOK procedure
- `windows-13.md` — the `.13` Windows workstation (still Windows)
