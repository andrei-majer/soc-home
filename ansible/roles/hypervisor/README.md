# `hypervisor` role — `.15` host stack

Brings the `.15` (Ubuntu 24.04) hypervisor **host** configuration under Ansible.
Runs against the `hypervisor` inventory group with `become: true`.

> **Context:** `.15` was previously runbook-only (the original "Play 7" in
> `playbooks/site.yml`). That worked until the 2026-07-02 encrypted-RAID1
> reinstall silently dropped the `ups-loki` collector — the `ups-hyper-15`
> Grafana dashboard went blank until it was manually restored. This role exists
> so host-side units survive a rebuild via `ansible-playbook`. It had no play in
> `site.yml` until 2026-08-01, so until then a converge never actually ran it.

## Scope

| Managed | Notes |
|---|---|
| `docker-prune.{sh,service,timer}` | Weekly prune of unused images/cache/stopped containers >7d; never volumes |
| `disk-alert.{sh,service,timer}` | Hourly Telegram alert when `/` or `/mnt/vms` ≥ 85% (reads token from `/etc/default/smartd-telegram`) |
| `soc-sleep`/`soc-wake` `{.sh,.service,.timer}` | Nightly ACPI shutdown (23:00) / cold-boot (06:00) of the SOC VMs. Suricata is excluded from `SOC_VMS` in both scripts — it hosts the Grafana mobile proxy and stays up 24/7 |
| `ups-loki-push.sh` + `ups-loki.{service,timer}` | UPS reading → Loki push every 30s. Codified 2026-07-27 after the script was found still pointing at the pre-renumber `.120` Loki address, failing silently behind a `\|\| true` |
| `suricata-vm-start.service` | Cold-starts the Suricata VM on host boot (`soc-wake.timer` skips it and no VBox autostart existed, so nothing brought it back after the 2026-07-29 RAM-upgrade reboot). Enabled but never started by the role — the VM is already running |
| `suricata-watchdog.sh` + `andrei` cron `*/5` | Checks `VBoxManage runningvms`, one Telegram alert then re-alerts every 3h while broken, recovery message on return |
| `eno1-disable-offload.service` | Disables `eno1` TSO/GSO/GRO at boot — mitigates the Intel I219-V `e1000e` **"Detected Hardware Unit Hang"** that dropped `.15` off the LAN on 2026-07-06 (829 hangs; OS stayed up, NIC dead). Also ensures `ethtool` is installed. |
| GRUB cmdline (`pcie_aspm=off`) | `GRUB_CMDLINE_LINUX_DEFAULT` via `hypervisor_grub_cmdline_default` (defaults). Belt-and-suspenders for the same NIC hang (disables PCIe ASPM). `update-grub` handler; **applies on next reboot**. |
| VM disk TRIM (`hypervisor_vm_trim`) | Enforces `--discard on --nonrotational on` on every VM disk so guest deletes actually reach the SSDs. Audit 2026-08-20 found it **off on all five substantial VMs**; only OpenCanary was correct. Without it a VDI only grows and the FTL treats the whole ever-written footprint as live, inflating erase counts (the suspected cause of the SU800 pair going 100%→95% lifetime in ~6 weeks on ~0.7 TB of host writes). **VBoxManage cannot set this on a running VM**, so the task applies to powered-off VMs only and *reports* the rest — it never stops a VM for you. Runs as `andrei` (root has its own empty VM registry). |
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
`ssd-smart-loki`, `lm-sensors`, and the NUT config (`ups.conf`/`upsmon`/
`upssched`/`ups-resilience` + `upsd.users` — the last needs `ansible-vault`).
Source copies live under `../../scripts/hypervisor-15/` and
`../../scripts/ups-monitoring/hypervisor-15/`; those trees are reference copies,
the role's own `files/` is what gets deployed.

## Run
```bash
ansible-playbook playbooks/site.yml --limit hypervisor-15 --check   # dry run
ansible-playbook playbooks/site.yml --limit hypervisor-15           # apply
```
