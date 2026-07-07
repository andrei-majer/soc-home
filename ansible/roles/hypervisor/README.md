# `hypervisor` role — `.15` host stack

Brings the `.15` (Ubuntu 24.04) hypervisor **host** configuration under Ansible.
Runs against the `hypervisor` inventory group with `become: true`.

> **Context:** `.15` was previously runbook-only (the removed "Play 7" in
> `playbooks/site.yml`). That worked until the 2026-07-02 encrypted-RAID1
> reinstall silently dropped the `ups-loki` collector — the `ups-hyper-15`
> Grafana dashboard went blank until it was manually restored. This role exists
> so host-side units survive a rebuild via `ansible-playbook`.

## Scope

| Managed | Notes |
|---|---|
| `docker-prune.{sh,service,timer}` | Weekly prune of unused images/cache/stopped containers >7d; never volumes |
| `disk-alert.{sh,service,timer}` | Hourly Telegram alert when `/` or `/mnt/vms` ≥ 85% (reads token from `/etc/default/smartd-telegram`) |
| `eno1-disable-offload.service` | Disables `eno1` TSO/GSO/GRO at boot — mitigates the Intel I219-V `e1000e` **"Detected Hardware Unit Hang"** that dropped `.15` off the LAN on 2026-07-06 (829 hangs; OS stayed up, NIC dead). Also ensures `ethtool` is installed. |
| GRUB cmdline (`pcie_aspm=off`) | `GRUB_CMDLINE_LINUX_DEFAULT` via `hypervisor_grub_cmdline_default` (defaults). Belt-and-suspenders for the same NIC hang (disables PCIe ASPM). `update-grub` handler; **applies on next reboot**. |
| PXE netboot framework (`dnsmasq-pxe.conf`, `pxe-*.service`, `pxe-netboot.target`, `pxe-clone`, `grub.cfg`) | On-demand UEFI Secure-Boot netboot server (Clonezilla + Ubuntu Server + Fedora). All units **disabled by default**; toggled via `pxe-clone start\|stop` (off = zero footprint). dnsmasq is **proxyDHCP-only** (`port=0`, never assigns IPs — `.1` stays the DHCP authority); stock `dnsmasq` is **masked**. Validated end-to-end 2026-07-07 via QEMU+OVMF. |

Idempotent — these are already deployed on `.15`; the role just codifies them.
(The GRUB cmdline line is *owned* by the role — add future kernel params to `hypervisor_grub_cmdline_default` in `defaults/main.yml`.)

## Not managed here
- The runtime `/etc/nut/ARMED` toggle — operator-controlled on purpose.
- The PXE boot **assets** (ISOs, `filesystem.squashfs`, signed shims/grubs, per-distro
  kernels/initrds under `/srv/tftp` and `/mnt/backup/netboot`) — large and manual;
  fetch per `scripts/netboot-15/README.md`. The role provisions only the framework.
  Note: Ubuntu/Fedora entries require Secure Boot **off** on the target (only the
  Debian-based Clonezilla path boots with Secure Boot on).

## Planned next passes
`ups-loki`, `ssd-smart-loki`, `soc-sleep`/`soc-wake`, `lm-sensors`, and the NUT
config (`ups.conf`/`upsmon`/`upssched`/`ups-resilience` + `upsd.users` — the last
needs `ansible-vault`). Source copies live under `../../scripts/hypervisor-15/`
and `../../scripts/ups-monitoring/hypervisor-15/`.

## Run
```bash
ansible-playbook playbooks/site.yml --limit hypervisor-15 --check   # dry run
ansible-playbook playbooks/site.yml --limit hypervisor-15           # apply
```
