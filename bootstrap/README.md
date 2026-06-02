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

**Suspected: Tailscale on .13 interferes with VBox NAT loopback.**
`Tailscale Tunnel` adapter present + active on .13 (MTU 65535). Tailscale's
TUN driver hooks the Windows network stack and can intercept connections to
127.0.0.1. Vagrant + Packer both use 127.0.0.1:<NAT-forward-port> for SSH.
Build #2 succeeded because... unclear (Tailscale was running then too).
Possibly a Defender scan or system load racing with the SSH banner emit.

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
