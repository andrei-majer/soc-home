# SOC Lab Ansible

Infrastructure as Code for a home SOC lab — 6 managed hosts (5 Debian + 1 OpenWrt router) plus 2 runbook-only hosts (`.13` Windows workstation, `.15` Ubuntu hypervisor).

See the [top-level README](../README.md) for the full project overview, architecture diagram, and feature list.

## Hosts

| Host | IP | Role | Mode |
|---|---|---|---|
| suricata-120 | 192.168.1.120 | IDS / NSM (Suricata + Zeek + Snort 3 + Grafana/Loki/Promtail + EveBox + Arkime + Velociraptor + fail2ban + ntfy) + control node + `soc-contain` | Full convergence (control node, `local`) |
| elk-133 | 192.168.1.133 | SIEM (Elasticsearch + Kibana + Logstash + Wazuh Manager + MISP) | Full convergence |
| opencti-135 | 192.168.1.135 | Threat intel (OpenCTI Docker Compose stack) | Full convergence |
| fileserver-140 | 192.168.1.140 | Internal canary `fs1` (OpenCanary + Samba decoys + sinkhole.py) | Full convergence |
| tpot-hive-130 | 192.168.1.130 | Honeypot HIVE (combined collector+sensor) | Backup/pull-only (SSH :64295) |
| router-1 | 192.168.1.1 | OpenWrt edge router (AdGuard Home + Unbound + BanIP + soc-watchdog) | Backup/pull-only (`raw` + `scp`, no Python) |

The former `tpot-sensor-125` (192.168.1.125) was retired 2026-06-07 — it is commented out in `inventory/hosts.yml`; HIVE covers the honeypot role and the `.140` canary provides the second LAN-source signal.

The `.13` Windows workstation and `.15` Ubuntu hypervisor (migrated from Windows 11 to Ubuntu 24.04 on 2026-06-08) are documented in runbooks, **not** managed by Ansible.

## Layout

```
/opt/soc-ansible/
├── ansible.cfg
├── .ansible-lint           # production profile + documented skip_list
├── inventory/
│   ├── hosts.yml           # 6 active hosts in 5 groups (debian, canary, tpot, openwrt, hypervisor)
│   ├── group_vars/
│   │   ├── all/{main.yml, vault.yml}
│   │   ├── debian.yml
│   │   ├── tpot.yml
│   │   └── openwrt.yml
│   └── host_vars/<host>/{vars.yml|main.yml, vault.yml}
├── roles/
│   ├── common/          # base packages, disk-alert (self-remediating), SSH keys, timezone, journald cap
│   ├── suricata/        # Suricata + Zeek + Snort 3 + fail2ban + Filebeat + iprep + MISP scripts + Arkime + Velociraptor + ntfy + Grafana/Loki/Promtail + EveBox
│   ├── elk/             # Elasticsearch, Kibana, Logstash, Filebeat, index cleanup
│   ├── wazuh-manager/   # ossec.conf, rules, ntfy integration, TAXII, Wazuh dashboard + vendor patches
│   ├── misp/            # Apache vhost, PHP config, logrotate (config-only)
│   ├── opencti/         # Docker Compose stack, .env, backup, on-demand savestate
│   ├── canary/          # OpenCanary + Samba decoys + sinkhole.py + rsyslog routing
│   ├── soc-contain/     # SOAR-lite containment receiver (dry-run-default) on 192.168.1.120:8765
│   ├── backups/         # service-native backup wrappers (.120/.133/.135)
│   ├── tpot/            # Backup/pull-only from T-Pot host
│   └── openwrt/         # Backup/pull-only via raw + scp; soc-watchdog deploy
└── playbooks/
    ├── site.yml         # Full convergence playbook
    └── ops/             # Day-2 ops (health-check, ti-health, rule-update, es-cleanup, cert-renew, backup, restart-services, state-collect)
```

## Usage

All commands run on the control node (192.168.1.120) from `/opt/soc-ansible/`.

```bash
# Full convergence (all hosts)
ansible-playbook playbooks/site.yml

# Single host
ansible-playbook playbooks/site.yml --limit elk-133

# Check mode (dry run)
ansible-playbook playbooks/site.yml --check

# Single role
ansible-playbook playbooks/site.yml --limit suricata-120 --tags suricata
```

## Secrets

Secrets are encrypted with Ansible Vault. The vault password is at `~/.vault_pass` (gitignored, permissions 600). Ansible reads it automatically via `ansible.cfg`.

To edit a vault file:
```bash
ansible-vault edit inventory/host_vars/elk-133/vault.yml
ansible-vault view inventory/group_vars/all/vault.yml
```

Vault files are scoped per host plus a shared `group_vars/all/vault.yml` — see `inventory/host_vars/<host>/vault.yml`. The canary host (`fileserver-140`) carries no secrets and has no vault file.

## Idempotency

`site.yml` is idempotent. A clean run on a healthy lab should report approximately `changed=0` across all hosts. T-Pot and OpenWrt fetches always report `ok` (not changed) since they are read-only.

## Reference archive

`files/originals/` (gitignored) contains live config files pulled from each host. They are the reference for the Jinja2 templates and are used when rebuilding templates after a drift.

## Roles per host

| Host | Roles applied |
|---|---|
| suricata-120 | common, suricata, backups, soc-contain (+ canary cutover) |
| elk-133 | common, elk, wazuh-manager, misp, backups |
| opencti-135 | common, opencti, backups |
| fileserver-140 | common, canary |
| tpot-hive-130 | tpot |
| router-1 | openwrt |

T-Pot and OpenWrt hosts skip `common` by design — T-Pot self-manages its base OS (fighting it causes drift) and the OpenWrt router has no Python.

## Phase plan

- **Phase 1 (done):** Foundation + core roles + `site.yml`
- **Phase 2 (done):** OpenWrt router role (`.1`) via `raw` + `scp`
- **Phase 3 (done):** Operational playbooks (health-check, ti-health, rule-update, es-cleanup, cert-renew, backup, restart-services, state-collect) + runbooks (`.13`, `.15`, T-Pot rebuild, MISP rebuild, canary `.140` rebuild, OpenWrt restore)

Subsequent work added the `canary`, `soc-contain`, and `backups` roles and retired the `tpot-sensor-125` host.
