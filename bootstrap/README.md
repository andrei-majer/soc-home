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

## See also

- Design spec: `../docs/superpowers/specs/2026-06-02-soc-lab-bootstrap-design.md`
- Phase 1A plan (backups, complete): `../docs/superpowers/plans/2026-06-02-soc-bootstrap-phase1a-backups.md`
- Phase 1B plan (this): `../docs/superpowers/plans/2026-06-02-soc-bootstrap-phase1b-dr-bootstrap.md`
