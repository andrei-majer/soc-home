# SOC Lab Ansible

Infrastructure as Code for a home SOC lab — 5 managed Linux hosts + 2 Windows runbooks.

## Hosts

| Host | IP | Role | Mode |
|---|---|---|---|
| suricata-120 | 192.168.1.120 | IDS (Suricata + Snort + Grafana/Loki + Arkime + Velociraptor + fail2ban) | Full convergence (control node) |
| elk-133 | 192.168.1.133 | SIEM (Elasticsearch + Kibana + Logstash + Wazuh Manager + MISP) | Full convergence |
| opencti-135 | 192.168.1.135 | Threat intel (OpenCTI Docker Compose stack) | Full convergence |
| tpot-hive-130 | 192.168.1.130 | Honeypot HIVE | Backup/pull-only |
| tpot-sensor-125 | 192.168.1.125 | Honeypot Sensor | Backup/pull-only |

Windows hosts (.13 workstation, .15 hypervisor) are documented in runbooks, not managed by Ansible.

## Layout

\`\`\`
/opt/soc-ansible/
├── ansible.cfg
├── inventory/
│   ├── hosts.yml
│   ├── group_vars/
│   │   ├── all/{main.yml,vault.yml}
│   │   ├── debian.yml
│   │   └── tpot.yml
│   └── host_vars/<host>/vault.yml
├── roles/
│   ├── common/          # base packages, disk-alert, SSH, timezone
│   ├── suricata/        # IDS, Snort, fail2ban, Filebeat, iprep, MISP scripts, Arkime, Velociraptor, Grafana/Loki/Promtail/EveBox
│   ├── elk/             # Elasticsearch, Kibana, Logstash, Filebeat, index cleanup
│   ├── wazuh-manager/   # ossec.conf, rules, ntfy integration, TAXII, Wazuh dashboard
│   ├── misp/            # Apache vhost, PHP config, logrotate (config-only)
│   ├── opencti/         # Docker Compose stack, .env, backup
│   └── tpot/            # Backup/pull-only from T-Pot hosts
└── playbooks/
    └── site.yml         # Full convergence playbook
\`\`\`

## Usage

All commands run on the control node (192.168.1.120) from \`/opt/soc-ansible/\`.

\`\`\`bash
# Full convergence (all hosts)
ansible-playbook playbooks/site.yml

# Single host
ansible-playbook playbooks/site.yml --limit elk-133

# Check mode (dry run)
ansible-playbook playbooks/site.yml --check

# Single role
ansible-playbook playbooks/site.yml --limit suricata-120 --tags suricata
\`\`\`

## Secrets

Secrets are encrypted with Ansible Vault. The vault password is at \`~/.vault_pass\` (gitignored, permissions 600). Ansible reads it automatically via \`ansible.cfg\`.

To edit a vault file:
\`\`\`bash
ansible-vault edit inventory/host_vars/elk-133/vault.yml
ansible-vault view inventory/group_vars/all/vault.yml
\`\`\`

Vault files are scoped per host — see \`inventory/host_vars/<host>/vault.yml\`.

## Idempotency

\`site.yml\` is fully idempotent. A clean run on a healthy lab should report \`changed=0\` across all 5 hosts. T-Pot fetches always report \`ok\` (not changed) since they are read-only.

## Reference archive

\`files/originals/\` (gitignored) contains live config files pulled from each host. They are the reference for the Jinja2 templates and are used when rebuilding templates after a drift.

## Roles per host

| Host | Roles applied |
|---|---|
| suricata-120 | common, suricata |
| elk-133 | common, elk, wazuh-manager, misp |
| opencti-135 | common, opencti |
| tpot-hive-130 | tpot |
| tpot-sensor-125 | tpot |

T-Pot hosts skip \`common\` by design — T-Pot self-manages its base OS and fighting it causes drift.

## Phase plan

- **Phase 1 (done — v0.1.0):** Foundation + 7 core roles + site.yml
- **Phase 2 (pending):** OpenWrt router role (.1) via raw module
- **Phase 3 (pending):** Operational playbooks (health-check, rule-update, es-cleanup, cert-renew, backup, restart-services) + Windows runbooks (.13, .15, T-Pot rebuild, MISP rebuild)

See \`docs/superpowers/specs/2026-04-11-soc-ansible-iac-design.md\` for the full design spec.
