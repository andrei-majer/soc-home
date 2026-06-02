# Secrets Checklist

Place the following files in `bootstrap/secrets/` before running `deploy.ps1`. The directory is gitignored - secrets never enter the repo.

## Required for Phase 1B (DR mode VM provisioning)

| File | Purpose | Source |
|---|---|---|
| `vault_pass.txt` | Ansible Vault password | `OneDrive/Claude/backup/soc-ansible/vault_pass-<latest>.txt` |
| `id_ed25519` | SSH private key - deploy host -> all 6 VMs | `OneDrive/Claude/backup/soc-ansible/id_ed25519` (or generate fresh + rotate) |
| `id_ed25519.pub` | matching public key (installed in each VM's `/root/.ssh/authorized_keys` by Vagrant) | matching pair of above |

## Required for Phase 2 (restore phase)

| Dir | Purpose |
|---|---|
| `data-backup/misp/` | MISP DB dump + files tarball (latest from `OneDrive/Claude/backup/soc-data/misp/`) |
| `data-backup/opencti/` | OpenCTI volume tarball |
| `data-backup/wazuh/` | Wazuh certs + client.keys tarball |
| `data-backup/kibana/` | Kibana saved-objects NDJSON |
| `data-backup/velociraptor/` | Velociraptor server config + clients/ tarball |
| `data-backup/grafana/` | Grafana sqlite |

These are produced by the Phase 1A backup pipeline (already running monthly on the live lab).

## Verification

After populating:

```powershell
.\deploy.ps1 -Phase image  # runs preflight which checks all required files
```

The image phase only requires the Phase 1B secrets (vault_pass.txt + ssh keypair). Data-backup files become required when Phase 2 restore ships.

## Generating a fresh ssh keypair

If you don't want to reuse the .120 control-node key:

```powershell
ssh-keygen -t ed25519 -f bootstrap\secrets\id_ed25519 -N '""' -C 'soc-bootstrap-<date>'
```

Note: a fresh key won't be in `client.keys` / `authorized_keys` files restored from Phase 2 backups - external agents would need re-enrollment. Easier to reuse the existing one.
