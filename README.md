# soc-home

My home SOC lab — Ansible IaC + bare-metal backup/restore scripts.

## Layout

```
soc-home/
├── ansible/   # Ansible IaC for the lab control node (.120) and managed hosts
└── scripts/   # Bash/PowerShell helpers — Suricata/ELK config backup & restore, hardware sensors
```

## `ansible/`

Day-2 ops + disaster recovery for the lab. Six managed hosts across `debian`, `tpot`, and `openwrt`
groups. See [`ansible/README.md`](ansible/README.md) for full details.

Highlights:

- `playbooks/site.yml` — full convergence (idempotent, 0 changed on a healthy lab)
- `playbooks/ops/` — health-check, rule-update, es-cleanup, cert-renew, backup, restart-services
- `roles/` — common, suricata (+ Snort 3, Loki, Promtail, Grafana, EveBox, Velociraptor, Arkime),
  elk, wazuh-manager, misp, opencti, tpot (backup-only), openwrt
- `docs/runbooks/` — Windows hosts (.13, .15) and rebuild procedures for T-Pot and MISP

Secrets are kept in per-host `inventory/host_vars/<host>/vault.yml`, encrypted with
`ansible-vault` (AES256). The vault password is **not** in this repo.

## `scripts/`

Pre-Ansible bare-metal backup/restore tooling, kept around for full-host disaster recovery
of `.120` (Suricata + Snort 3) and `.133` (ELK + Wazuh + MISP). See
[`scripts/README.md`](scripts/README.md) for usage.

> **Heads-up:** the scripts and their README contain **placeholder credentials**
> (`CHANGEME`, `REDACTED`). Replace them with your own values before running.

## License

See `LICENSE`.
