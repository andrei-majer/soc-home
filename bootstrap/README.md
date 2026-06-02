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

**SSH banner exchange timeout via NAT port-forward (Phase 1B end-to-end).**
After `packer build` produces a `.box` and `vagrant box add` registers it,
`vagrant up` boots the VM successfully but `vagrant ssh` and raw `ssh` to the
NAT-forwarded port both hang at "Connection timed out during banner exchange".
TCP handshake completes; sshd never sends `SSH-2.0` line. Reproduced on Windows
11 + VBox 7.2.6 + Debian 12.9.0 (build 2026-06-02). Investigation continues
in the followups list below.

This blocks Vagrant's `vm.provision` shell step (which installs the deploy SSH
key + configures `eth1` with static IP). Workarounds being explored:

- Disable `ssh.socket` + force `ssh.service` in the Packer provisioner (the
  intuitive fix; Packer build then hit its own 30 min SSH wait and never got
  to apply the fix — likely a separate NAT-NIC issue)
- Set NIC type explicitly to `virtio` via `--nictype1 virtio` in Packer's
  `vboxmanage` block
- Bake the deploy SSH key directly into the Packer image (no Vagrant
  provisioner needed for ssh) and switch eth1 config to systemd-networkd
  with templating via a small first-boot script

The Packer image itself builds correctly (~16 min, 600 MB `.box`). The deploy.ps1
preflight + image phase work end-to-end. Only the `vms`+`converge` phases are
blocked until SSH-over-NAT is reliable.

## See also

- Design spec: `../docs/superpowers/specs/2026-06-02-soc-lab-bootstrap-design.md`
- Phase 1A plan (backups, complete): `../docs/superpowers/plans/2026-06-02-soc-bootstrap-phase1a-backups.md`
- Phase 1B plan (this): `../docs/superpowers/plans/2026-06-02-soc-bootstrap-phase1b-dr-bootstrap.md`
