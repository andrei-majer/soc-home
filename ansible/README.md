# SOC Lab Ansible

Infrastructure as Code for a home SOC lab — 8 hosts: 4 Debian VMs, 2 T-Pot honeypots, the OpenWrt router, and the Ubuntu hypervisor. The `.13` Windows workstation is runbook-only.

See the [top-level README](../README.md) for the full project overview, architecture diagram, and feature list.

## Where this runs, and how to deploy it

The control node `.20` runs Ansible from **`/opt/soc-home/ansible`** — a full clone of this
repository, tracking `origin` = the self-hosted Forgejo on `.15:2222`.

> **History:** until 2026-08-20 `.20` held a *separate* repo at `/opt/soc-ansible` with **no git
> remote**, a different branch name (`master`) and a different tree root. The two drifted apart —
> 44 files differed in both directions, and a file-level reconciliation paired one side's tasks with
> the other side's defaults, breaking every `elk-21` converge with an undefined variable. That repo is
> retained read-only at `/opt/soc-ansible.retired-20260820`; do not edit it.

**Deploy loop** — edit here, then:

```bash
git push origin main && git push forgejo main      # both remotes, always
ssh s "cd /opt/soc-home && git pull --ff-only"     # deploy to the control node
ssh s "cd /opt/soc-home/ansible && ansible-playbook playbooks/site.yml --limit <host> --check --diff"
```

Read the check hunks before converging for real — that habit caught a template that shipped a
fail2ban filter into `/etc/logrotate.d/`, and a botched variable substitution that rendered
`root@192.168.1.120`.

**Fallback** (works even if Forgejo is down): `.20` also accepts a direct push, since
`/opt/soc-home` has `receive.denyCurrentBranch=updateInstead`, which updates its working tree on
receive:

```bash
git -c core.sshCommand="ssh -i ~/.ssh/openwrt -o IdentitiesOnly=yes" push soc20 main
```

The key override is required: this repo pins `core.sshCommand` to the Forgejo key, which `.20`
does not accept.

**Line endings:** `.gitattributes` forces `eol=lf` in the working tree. Do not reintroduce CRLF —
templates here render shell scripts, and a CRLF render produces `#!/bin/bash` on the target. A
CRLF copy of `sinkhole.py` was live on `.24` until 2026-08-20; it only worked because the systemd
unit calls the interpreter explicitly.

## Hosts

| Host | IP | Role | Mode |
|---|---|---|---|
| suricata-20 | 192.168.1.20 | IDS / NSM (Suricata + Zeek + Snort 3 + Grafana/Loki/Promtail + EveBox + Arkime + Velociraptor + fail2ban) + control node + `soc-contain` | Full convergence (control node, `local`) |
| elk-21 | 192.168.1.21 | SIEM (Elasticsearch + Kibana + Logstash + Wazuh Manager + MISP) | Full convergence |
| opencti-22 | 192.168.1.22 | Threat intel (OpenCTI Docker Compose stack) | Full convergence |
| tpot-hive-23 | 192.168.1.23 | Honeypot HIVE (combined collector+sensor) | Backup/pull-only (SSH :64295) |
| fileserver-24 | 192.168.1.24 | Internal canary `fs1` (OpenCanary + Samba decoys + sinkhole.py) | Full convergence |
| tpot-sensor-25 | 192.168.1.25 | Honeypot sensor, ships to HIVE | Backup/pull-only (SSH :64295) |
| router-1 | 192.168.1.1 | OpenWrt edge router (AdGuard Home + Unbound + BanIP + soc-watchdog) | Backup/pull-only (`raw` + `scp`, no Python) |
| hypervisor-15 | 192.168.1.15 | Ubuntu 24.04 VirtualBox host — host-side units only (see `roles/hypervisor`) | Full convergence (`become`, SSH as `andrei`) |

LAN addresses were renumbered on 2026-07-15: physical hosts live in `.10–.19`, SOC VMs in `.20–.25`. The `tpot-sensor-25` host was retired 2026-06-07 and re-activated 2026-07-31 on a fresh IP (was `.125`) to join that band.

The `.13` Windows workstation is documented in runbooks, **not** managed by Ansible. The `.15` hypervisor (migrated from Windows 11 to Ubuntu 24.04 on 2026-06-08) was runbook-only until `roles/hypervisor` gained a `site.yml` play on 2026-08-01; its OS-level rebuild is still runbook territory.

## Layout

```
/opt/soc-ansible/
├── ansible.cfg
├── .ansible-lint           # production profile + documented skip_list
├── inventory/
│   ├── hosts.yml           # 8 active hosts in 5 groups (debian, canary, tpot, openwrt, hypervisor)
│   ├── group_vars/
│   │   ├── all/{main.yml, vault.yml}
│   │   ├── debian.yml
│   │   ├── tpot.yml
│   │   └── openwrt.yml
│   └── host_vars/<host>/{vars.yml|main.yml, vault.yml}
├── roles/
│   ├── common/          # base packages, disk-alert (self-remediating), SSH keys, timezone, journald cap
│   ├── suricata/        # Suricata + Zeek + Snort 3 + fail2ban + Filebeat + iprep + MISP scripts + Arkime + Velociraptor + Grafana/Loki/Promtail + EveBox
│   ├── elk/             # Elasticsearch, Kibana, Logstash, Filebeat, index cleanup
│   ├── wazuh-manager/   # ossec.conf, rules, Telegram integration, TAXII, Wazuh dashboard + vendor patches
│   ├── misp/            # Apache vhost, PHP config, logrotate (config-only)
│   ├── opencti/         # Docker Compose stack, .env, backup, on-demand savestate
│   ├── canary/          # OpenCanary + Samba decoys + sinkhole.py + rsyslog routing
│   ├── soc-contain/     # SOAR-lite containment receiver (dry-run-default) on 192.168.1.20:8765
│   ├── hypervisor/      # .15 host stack — docker-prune, disk-alert, soc-sleep/wake, ups-loki, NIC hang fix, PXE
│   ├── backups/         # service-native backup wrappers (.20/.21/.22)
│   ├── tpot/            # Backup/pull-only from T-Pot hosts
│   └── openwrt/         # Backup/pull-only via raw + scp; soc-watchdog deploy
└── playbooks/
    ├── site.yml         # Full convergence playbook
    └── ops/             # Day-2 ops (health-check, ti-health, rule-update, es-cleanup, cert-renew, backup, restart-services, state-collect)
```

## Usage

All commands run on the control node (192.168.1.20) from `/opt/soc-ansible/`.

```bash
# Full convergence (all hosts)
ansible-playbook playbooks/site.yml

# Single host
ansible-playbook playbooks/site.yml --limit elk-21

# Check mode (dry run)
ansible-playbook playbooks/site.yml --check

# Single role
ansible-playbook playbooks/site.yml --limit suricata-20 --tags suricata
```

## Secrets

Secrets are encrypted with Ansible Vault. The vault password is at `~/.vault_pass` (gitignored, permissions 600). Ansible reads it automatically via `ansible.cfg`.

To edit a vault file:
```bash
ansible-vault edit inventory/host_vars/elk-21/vault.yml
ansible-vault view inventory/group_vars/all/vault.yml
```

Vault files are scoped per host plus a shared `group_vars/all/vault.yml` — see `inventory/host_vars/<host>/vault.yml`. The canary host (`fileserver-24`) carries no secrets and has no vault file.

## Idempotency

`site.yml` is idempotent. A clean run on a healthy lab should report approximately `changed=0` across all hosts. T-Pot and OpenWrt fetches always report `ok` (not changed) since they are read-only.

## Reference archive

`files/originals/` (gitignored) contains live config files pulled from each host. They are the reference for the Jinja2 templates and are used when rebuilding templates after a drift.

## Roles per host

| Host | Roles applied |
|---|---|
| suricata-20 | common, suricata, backups, soc-contain (+ canary cutover) |
| elk-21 | common, elk, wazuh-manager, misp, backups |
| opencti-22 | common, opencti, backups |
| tpot-hive-23 | tpot |
| fileserver-24 | common, canary |
| tpot-sensor-25 | tpot |
| router-1 | openwrt |
| hypervisor-15 | hypervisor |

T-Pot and OpenWrt hosts skip `common` by design — T-Pot self-manages its base OS (fighting it causes drift) and the OpenWrt router has no Python.

## Phase plan

- **Phase 1 (done):** Foundation + core roles + `site.yml`
- **Phase 2 (done):** OpenWrt router role (`.1`) via `raw` + `scp`
- **Phase 3 (done):** Operational playbooks (health-check, ti-health, rule-update, es-cleanup, cert-renew, backup, restart-services, state-collect) + runbooks (`.13`, `.15`, T-Pot rebuild, MISP rebuild, canary rebuild, OpenWrt restore)

Subsequent work added the `canary`, `soc-contain`, `backups`, and `hypervisor` roles. The `tpot-sensor-125` host was retired 2026-06-07 and later re-activated as `tpot-sensor-25` on 2026-07-31.
