# SOC Lab Bootstrap

Provisions the 6-VM SOC lab on a fresh VirtualBox host via Packer + Vagrant + Ansible.

## Quick start

```powershell
# 1. Read prerequisites
notepad docs\prerequisites.md
notepad docs\secrets-checklist.md

# 2. Populate secrets/ (see secrets-checklist.md)

# 3. Build image + bring up lab (DR mode = default)
.\deploy.ps1 -Mode dr -Phase all
```

For testing on a constrained host (e.g. alongside the live lab):

```powershell
.\deploy.ps1 -Mode dr -Hosts suricata-120,elk-133 -Profile minimal
```

## Phases

| Phase | What it does | Approx duration |
|---|---|---|
| `image` | Packer builds Debian 12 golden box | ~15 min |
| `vms` | Vagrant brings up the 6 VMs (or subset via `-Hosts`) | ~10 min |
| `converge` | Runs `ansible-playbook site.yml` against the new VMs | ~20-40 min |
| `restore` | Restores MISP/OpenCTI/Wazuh/etc state from secrets/data-backup/ | Phase 2 - no-op in 1B |

## Modes

| Mode | Network | Use for |
|---|---|---|
| `dr` (default) | bridged, 192.168.1.x | drop-in replacement for broken .15 |
| `isolated` | internal VBox net, 192.168.99.x | parallel testing copy (Phase 2 - not yet implemented) |

## Flags

- `-Mode dr|isolated` (isolated is Phase 2)
- `-Phase image|vms|converge|restore|all`
- `-Hosts <comma-list>` - subset of VMs to bring up
- `-Profile full|minimal` - minimal caps RAM/CPU for testing
- `-BridgedNic '<name>'` - skip autodetect
- `-OverrideMtu <N>` - skip MTU check
- `-ForceImage` - rebuild .box even if source hash unchanged
- `-ForceWifiBridge` - allow Wi-Fi NIC as bridge (unreliable)
- `-OverwriteExisting` - allow restore over a populated lab
- `-SkipRestore` - skip restore phase even when `-Phase all`
- `-Force` - skip interactive confirmations

## Known issues

**SSH-over-NAT-port-forward intermittent on .13 (build host).**
Multiple Packer builds on .13 (Windows 11 + VBox 7.2.6r172322 + Debian 12.9.0)
hit "Timeout waiting for SSH" at 30-60 min - the Debian installer completes
but Packer can't reach the VM's sshd via the NAT port-forward to 127.0.0.1.
Build #2 (2026-06-02) succeeded once in ~16 min; builds #3 and #4 each timed
out. Same root cause blocks `vagrant ssh` / raw `ssh` after `vagrant up`:
TCP handshake completes, banner never arrives.

**Tested 2026-06-02: not Tailscale, not OneDrive, not ssh.socket.**
Investigated each candidate on .13:
- Tailscale tunnel down (`tailscale down`) → still hangs
- OneDrive output dir moved outside `OneDrive/` → build succeeds (#6), but
  `vagrant up` afterwards still hangs at banner
- Packer image rebuilt with `ssh.socket` masked + `ssh.service` forced +
  UseDNS/GSSAPI off → still hangs
- Raw TCP probe to `127.0.0.1:2222` shows TCP handshake completes (Established +
  CloseWait in `Get-NetTCPConnection`) but no bytes ever transit

**Root cause on .13 is the VBox NAT engine's loopback handling.** Build #6
succeeded — Packer's own SSH-via-NAT worked end-to-end (used a high random
port). But `vagrant up` afterwards (using port 2222 by default) hits the
banner timeout. Several candidates remain:
- Npcap loopback adapter (visible in `Get-NetAdapter`) intercepts 127.0.0.1
- Hyper-V virtual switch routes loopback differently
- Defender real-time scan hits some VBox NAT process file
- VBox kernel driver state corrupted after several failed builds (needs reboot)

**Current design (committed in this branch) avoids the runtime path that was
failing:**

- Packer bakes `/usr/local/sbin/soc-first-boot.sh` + a systemd unit that runs
  it once on first boot. Script reads SMBIOS Type 11 OEM strings (via
  `dmidecode -t 11`) to configure hostname, eth1 static IP, and root's
  authorized_keys.
- Vagrantfile sets `config.vm.communicator = :none` (skips Vagrant SSH
  entirely) and injects per-VM hostname / IP / mode / deploy SSH key as
  SMBIOS OEM strings via `setextradata DmiOEMVendorEx0/1`.
- `deploy.ps1` `vms` phase no longer calls `vagrant provision`.

This bypasses Vagrant's SSH-over-NAT step — but **Packer's build step still
uses NAT-forwarded SSH**, so the build itself remains intermittent on .13.

**Workarounds for the build:**
- Run Packer on a host without Tailscale (test on .15 if .15 doesn't have it,
  or stop Tailscale on .13 with `tailscale down` then retry)
- Switch Packer's NIC to bridged instead of NAT (VM gets DHCP IP on real LAN
  during build; needs `ssh_host` discovery, more invasive)
- Stop Windows Defender real-time scanning during build (security tradeoff)

**Status:** Image-build phase works occasionally (build #2). Once a build
succeeds, the new DMI-OEM-strings approach should let the full pipeline work
- but end-to-end validation pending a successful image build.

## See also

- Design spec: `../docs/superpowers/specs/2026-06-02-soc-lab-bootstrap-design.md`
- Phase 1A plan (backups, complete): `../docs/superpowers/plans/2026-06-02-soc-bootstrap-phase1a-backups.md`
- Phase 1B plan (this): `../docs/superpowers/plans/2026-06-02-soc-bootstrap-phase1b-dr-bootstrap.md`
