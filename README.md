<div align="center">

# 🛡️ soc-home

### A Home SOC Lab — Detection, Threat Intel, and Honeypots, Driven by Ansible

**Six-host SOC lab managed as code — Suricata + Snort 3 IDS, ELK + Wazuh + MISP SIEM, OpenCTI threat intel, T-Pot honeypots, and an OpenWrt edge router**

[![Ansible](https://img.shields.io/badge/Ansible-2.15%2B-EE0000.svg?logo=ansible)](https://www.ansible.com/)
[![Debian 12](https://img.shields.io/badge/Debian-12-A81D33.svg?logo=debian)](https://www.debian.org/)
[![Suricata 7](https://img.shields.io/badge/Suricata-7.0-2C5BB4.svg)](https://suricata.io/)
[![Wazuh 4.14](https://img.shields.io/badge/Wazuh-4.14-3578E5.svg)](https://wazuh.com/)
[![ansible-lint](https://img.shields.io/badge/ansible--lint-production-brightgreen.svg)](https://ansible-lint.readthedocs.io/)

</div>

---

## 🔍 The Problem

A working home SOC isn't one box — it's an IDS, a SIEM, a threat intel platform, honeypots, and an edge router, all wired together with vendor-specific quirks at every layer. Managing it by SSH-ing into each host doesn't scale: configs drift, manual tweaks get forgotten, and a hardware failure means rebuilding from memory.

## 💡 The Solution

`soc-home` captures the **entire lab as code** — every Suricata YAML, every Wazuh rule, every Logstash pipeline, every fail2ban jail, every cron entry — across six hosts, in one repository.

A single `ansible-playbook site.yml` brings the lab from a fresh Debian 12 install back to its known-good state. Day-2 ops (health checks, rule updates, ES cleanup, backups, service restarts) are one-line playbooks. Secrets stay encrypted with `ansible-vault`. Drift is detectable with `--check`. Disaster recovery for the Windows hosts (workstation + hypervisor) lives in runbooks alongside the code.

> **Scope.** This repo configures and operates the lab. It does **not** install T-Pot, OpenCTI, MISP, or the Snort 3 source build — those are one-shot installers run by hand and then captured by Ansible. Rebuild procedures for each are in `ansible/docs/runbooks/`.

---

## ⚡ Core Features

- **🏗️ Full IaC for 6 Hosts** — One `site.yml` converges Suricata, ELK, OpenCTI, T-Pot HIVE + Sensor, and the OpenWrt router from bare OS to production state
- **🚨 Detection Stack** — Suricata 7 + Snort 3 + ET Open + MISP rule pulls + Filebeat → Logstash → Elasticsearch
- **📊 SIEM & Visualization** — Elasticsearch, Kibana, Wazuh Manager + Dashboard, Grafana with 6 prebuilt dashboards (Suricata, Snort, MISP IOC, Network Overview, SIEM, SOC Ansible state), Loki + Promtail for log aggregation, EveBox + Arkime for alert triage and PCAP review
- **🧠 Threat Intelligence** — OpenCTI 6.x via Docker Compose, MISP 2.5 with auto-pulled IOC rules into Suricata + Snort, Wazuh ↔ OpenCTI TAXII bridge, MalwareBazaar feed
- **🍯 Honeypots** — T-Pot HIVE (.130) + Sensor (.125), 39 + 32 containers, backup-only (T-Pot self-manages, Ansible never pushes)
- **🛜 OpenWrt Edge Router** — `.1` managed via `raw` + `scp` (no Python on target), AdGuardHome → Unbound, banIP fed from Suricata IOC list
- **🛠️ Day-2 Ops Playbooks** — health-check, rule-update, es-cleanup (incl. Wazuh archive compression), cert-renew, backup, restart-services, state-collect
- **🔐 Vault-Encrypted Secrets** — Per-host `vault.yml` files (AES256), single password unlocks all via `ansible.cfg`
- **📓 Windows Runbooks** — `.13` workstation and `.15` hypervisor rebuild procedures live next to the code (Ansible can't run on Windows in this lab)
- **♻️ Bare-Metal Backup Scripts** — Pre-Ansible config-only tarball + restore for `.120` and `.133`, kept for full-host disaster recovery
- **💾 Documented Backup Strategy** — Three independent backup tracks (bare-metal tarballs, Ansible repo bundles, service-native), restore procedures and snapshot manifest in `backup/README.md`

---

## 🏛️ Architecture

```
                         ┌──────────────────────┐
                         │  OpenWrt R7800 (.1)  │
                         │  PPPoE · AdGuardHome │
                         │  Unbound · banIP     │
                         └──────────┬───────────┘
                                    │
                              LAN 192.168.1.0/24
                                    │
        ┌───────────────┬───────────┼────────────┬────────────┐
        │               │           │            │            │
   ┌────▼─────┐   ┌─────▼──────┐  ┌─▼──────┐ ┌───▼───┐  ┌─────▼──────┐
   │ .120     │   │ .133       │  │ .135   │ │ .130  │  │ .125       │
   │ Suricata │   │ ELK +      │  │OpenCTI │ │ T-Pot │  │ T-Pot      │
   │ Snort 3  │   │ Wazuh +    │  │ 6.x    │ │ HIVE  │  │ Sensor     │
   │ Grafana  │   │ MISP 2.5   │  │ Docker │ │ 39 ct │  │ 32 ct      │
   │ EveBox   │   │            │  │        │ │       │  │            │
   │ Arkime   │   │            │  │        │ │       │  │            │
   │ Veloci   │   │            │  │        │ │       │  │            │
   └────┬─────┘   └─────┬──────┘  └────┬───┘ └───────┘  └────────────┘
        │               │              │
        │  Filebeat     │  Wazuh agent │  TAXII
        │  ─────────────►              │  ─────────────►
        │               │              │
        │     ┌─────────▼──────┐       │
        │     │ Elasticsearch  │       │
        │     │ Kibana 5601    │       │
        │     │ Wazuh-DB :1514 │       │
        │     └────────────────┘       │
        │                              │
        │  MISP IOC pull               │
        ◄──────────────────────────────┘
        │
   ┌────▼─────────────────────┐
   │ Ansible control node     │
   │ /opt/soc-ansible (.120)  │
   │ ansible_connection=local │
   └──────────────────────────┘
```

The control node runs **on** `.120` (`ansible_connection: local`) — there is no separate management host. Every play either runs locally on `.120` or SSHes to one of the 5 managed hosts.

---

## 🚀 Quick Start

### 1. Clone

```bash
git clone https://github.com/andrei-majer/soc-home.git
cd soc-home/ansible
```

### 2. Provide a vault password

Ansible Vault is configured in `ansible.cfg` to read its password from `~/.vault_pass` (mode 600, gitignored). Create it:

```bash
echo 'your-vault-password' > ~/.vault_pass
chmod 600 ~/.vault_pass
```

The vault password unlocks all 7 `vault.yml` files. Without it, every play that touches a templated secret will fail.

### 3. Inventory & SSH keys

The control node (`.120`) needs an SSH private key that authorizes `root` on every managed host:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.1.133
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.1.135
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 64295 root@192.168.1.130
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 64295 root@192.168.1.125
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.1.1   # OpenWrt
```

T-Pot hosts use SSH on port **64295** (root, key auth — same key as `.120`).

### 4. Dry run

```bash
ansible-playbook playbooks/site.yml --check
```

A clean lab reports **0 changed, 0 failed** across all 6 hosts. Any `changed` items are drift since the last convergence.

### 5. Converge

```bash
ansible-playbook playbooks/site.yml
```

<details>
<summary><b>Prerequisites</b></summary>

- **Control node:** Debian 12 + `ansible-core ≥ 2.15`, `git`, `python3-passlib`, an SSH private key
- **Managed Linux hosts:** Debian 12 (5 of 6) — fresh install, root SSH key auth
- **Router:** OpenWrt 24.10+ (no Python — uses `raw` + `scp`)
- **T-Pot hosts:** install T-Pot first, then add the control node's pubkey to `/root/.ssh/authorized_keys` on port 64295
- **Hardware:** Anything that can run 5 Linux VMs comfortably. The reference lab uses a single Windows 11 hypervisor (i7-9700K / 64 GB / VirtualBox)

</details>

<details>
<summary><b>What if I'm rebuilding from bare metal?</b></summary>

Two paths depending on what failed:

| Failure | Path |
|---|---|
| `.120` lost (control node + IDS) | Reinstall Debian 12 → restore `~/.vault_pass` and SSH key → `git clone` this repo to `/opt/soc-ansible` → `ansible-playbook playbooks/site.yml --limit suricata-120` |
| `.133` lost (ELK + Wazuh + MISP) | Follow `ansible/docs/runbooks/misp-rebuild.md` for MISP, then `ansible-playbook playbooks/site.yml --limit elk-133`. ES indices and MISP event data are **not** in this repo — restore from your own backup target |
| T-Pot host lost | Follow `ansible/docs/runbooks/tpot-rebuild.md` (T-Pot installer is one-shot — Ansible role is backup-only) |
| Hypervisor or workstation lost | Follow `ansible/docs/runbooks/windows-15.md` or `windows-13.md` |
| `.120` *and* control node lost together | Use the pre-Ansible scripts in `scripts/` to restore `.120` to a runnable state, then converge with Ansible |

</details>

---

## 🖥️ Host Inventory

| Host | IP | OS | Roles applied | Connection |
|---|---|---|---|---|
| **suricata-120** | 192.168.1.120 | Debian 12 | `common`, `suricata` | `local` (control node) |
| **elk-133** | 192.168.1.133 | Debian 12 | `common`, `elk`, `wazuh-manager`, `misp` | SSH (key) |
| **opencti-135** | 192.168.1.135 | Debian 13 | `common`, `opencti` | SSH (key) |
| **tpot-hive-130** | 192.168.1.130 | Debian (T-Pot) | `tpot` (backup-only) | SSH :64295 |
| **tpot-sensor-125** | 192.168.1.125 | Debian (T-Pot) | `tpot` (backup-only) | SSH :64295 |
| **router-1** | 192.168.1.1 | OpenWrt 24.10 | `openwrt` (raw + scp) | SSH (no Python) |

Windows hosts (`.13` workstation, `.15` hypervisor) are documented in runbooks, not managed by Ansible.

---

## 📖 Usage

All commands run on the control node (`.120`) from `/opt/soc-ansible/`.

### Daily / weekly ops

```bash
# Morning health check (every host, every service, ES status, T-Pot containers, router)
ansible-playbook playbooks/ops/health-check.yml

# Drift detection — show what's changed since the last convergence
ansible-playbook playbooks/site.yml --check

# Pull fresh rules (Suricata + Snort + iprep + MISP)
ansible-playbook playbooks/ops/rule-update.yml

# ES disk filling — delete expired indices + compress old Wazuh archives
ansible-playbook playbooks/ops/es-cleanup.yml

# Before OS updates
ansible-playbook playbooks/ops/backup.yml

# After updates — restart everything in dependency order
ansible-playbook playbooks/ops/restart-services.yml -e confirm=yes

# Renew TLS certs (Let's Encrypt for the router's UI)
ansible-playbook playbooks/ops/cert-renew.yml

# Snapshot lab state into a JSON dashboard (Grafana panel)
ansible-playbook playbooks/ops/state-collect.yml
```

### Targeting

```bash
# One host
ansible-playbook playbooks/site.yml --limit elk-133

# One role
ansible-playbook playbooks/site.yml --limit suricata-120 --tags suricata

# Specific subset of rule updates
ansible-playbook playbooks/ops/rule-update.yml --tags suricata,iprep
```

### Editing secrets

```bash
# Edit a per-host vault file
ansible-vault edit inventory/host_vars/elk-133/vault.yml

# View without unlocking the editor
ansible-vault view inventory/group_vars/all/vault.yml

# Re-key after rotating the vault password
ansible-vault rekey inventory/host_vars/*/vault.yml
```

---

## 🧰 `scripts/` — Bare-Metal Backup & Restore

Pre-Ansible tooling for full-host disaster recovery of `.120` and `.133`. Kept around because they capture **everything** (binaries, configs, dashboards, sqlite DBs) into a single tarball — useful when you've lost the control node and need to bring `.120` back to a runnable state before Ansible can converge it.

| Script | Run on | Purpose |
|---|---|---|
| `backup-suricata-s.sh` | `.120` | Collects Suricata, Snort 3, fail2ban, Grafana, Loki/Promtail, EveBox, Velociraptor, Arkime, Filebeat, Wazuh agent configs + binaries |
| `restore-suricata-s.sh` | Fresh `.120` | Installs packages, extracts configs, enables services, runs `suricata-update`, optional Snort 3 binary restore or source build |
| `backup-elk-e.sh` | `.133` | Collects ES, Kibana (incl. saved objects), Logstash, Wazuh Manager + Dashboard, MISP, Apache, MariaDB structure |
| `read-hwinfo.ps1` | `.15` (Windows) | Reads HWiNFO64 shared memory to dump per-rail power consumption |

> ⚠️ **Credentials in `scripts/` and its README are placeholders** (`CHANGEME`, `REDACTED`). Set your own values before running. See `scripts/README.md` for full backup/restore walkthroughs.

---

## 🗂️ Stack

| Layer | Technology |
|---|---|
| **IDS** | [Suricata 7](https://suricata.io/) · [Snort 3](https://www.snort.org/) · [Emerging Threats Open](https://rules.emergingthreats.net/) · MISP IOC pull |
| **SIEM** | [Elasticsearch 8](https://www.elastic.co/) · [Kibana](https://www.elastic.co/kibana/) · [Logstash](https://www.elastic.co/logstash/) · [Wazuh 4.14](https://wazuh.com/) |
| **Threat Intel** | [OpenCTI 6.x](https://www.opencti.io/) · [MISP 2.5](https://www.misp-project.org/) · MalwareBazaar |
| **Honeypots** | [T-Pot 24.x](https://github.com/telekom-security/tpotce) (HIVE + Sensor, ~70 containers) |
| **Visualization** | [Grafana](https://grafana.com/) · [Loki](https://grafana.com/oss/loki/) · [Promtail](https://grafana.com/docs/loki/latest/clients/promtail/) · [EveBox](https://evebox.org/) · [Arkime](https://arkime.com/) |
| **Endpoint** | [Velociraptor](https://docs.velociraptor.app/) · [Filebeat](https://www.elastic.co/beats/filebeat) · [Wazuh agent](https://wazuh.com/) |
| **Edge** | [OpenWrt 24.10](https://openwrt.org/) · [AdGuardHome](https://github.com/AdguardTeam/AdGuardHome) · [Unbound](https://nlnetlabs.nl/projects/unbound/) · [banIP](https://github.com/openwrt/packages/tree/master/net/banip) |
| **Active Response** | `fail2ban` · custom `suricata-enforcer.py` · `sinkhole.py` |
| **IaC** | [Ansible](https://www.ansible.com/) · [ansible-vault](https://docs.ansible.com/ansible/latest/vault_guide/index.html) · [ansible-lint](https://ansible-lint.readthedocs.io/) (`production` profile, 0 failures) |

---

## 📁 Project Structure

```
soc-home/
├── README.md
├── LICENSE
├── ansible/
│   ├── ansible.cfg               # stdout=yaml, host_key_checking=False
│   ├── .ansible-lint             # production profile
│   ├── README.md
│   ├── inventory/
│   │   ├── hosts.yml             # 6 hosts in 3 groups (debian, tpot, openwrt)
│   │   ├── group_vars/
│   │   │   ├── all/{main.yml, vault.yml}
│   │   │   ├── debian.yml
│   │   │   ├── tpot.yml
│   │   │   └── openwrt.yml
│   │   └── host_vars/
│   │       ├── elk-133/vault.yml
│   │       ├── opencti-135/vault.yml
│   │       ├── router-1/vault.yml
│   │       ├── suricata-120/vault.yml
│   │       ├── tpot-hive-130/vault.yml
│   │       └── tpot-sensor-125/vault.yml
│   ├── roles/
│   │   ├── common/               # base packages, disk-alert, SSH keys, timezone
│   │   ├── suricata/             # IDS + Snort 3 + fail2ban + Filebeat + iprep + MISP scripts
│   │   │                         # + Arkime + Velociraptor + Grafana/Loki/Promtail + EveBox
│   │   ├── elk/                  # Elasticsearch, Kibana, Logstash, Filebeat, index cleanup
│   │   ├── wazuh-manager/        # ossec.conf, rules, ntfy, TAXII, dashboard + vendor patches
│   │   ├── misp/                 # Apache vhost, PHP, logrotate (config-only)
│   │   ├── opencti/              # Docker Compose stack, .env, backup
│   │   ├── tpot/                 # Backup/pull-only via fetch
│   │   └── openwrt/              # Backup/pull-only via raw + scp
│   ├── playbooks/
│   │   ├── site.yml              # Full convergence
│   │   └── ops/
│   │       ├── health-check.yml
│   │       ├── rule-update.yml   # tags: suricata, snort, iprep, misp
│   │       ├── es-cleanup.yml    # also compresses Wazuh archives
│   │       ├── cert-renew.yml
│   │       ├── backup.yml
│   │       ├── restart-services.yml   # requires -e confirm=yes
│   │       └── state-collect.yml
│   └── docs/
│       └── runbooks/
│           ├── windows-13.md     # workstation rebuild
│           ├── windows-15.md     # hypervisor rebuild
│           ├── tpot-rebuild.md   # T-Pot HIVE/Sensor rebuild
│           └── misp-rebuild.md   # MISP from-scratch rebuild
├── scripts/
│   ├── README.md
│   ├── backup-suricata-s.sh
│   ├── restore-suricata-s.sh
│   ├── backup-elk-e.sh
│   └── read-hwinfo.ps1
└── backup/
    └── README.md                 # Backup strategy, snapshot manifest, restore procedures
                                  # (no tarballs committed — see secret-handling rules)
```

---

## 🔐 Secrets & Vault

- **All sensitive values live in `inventory/host_vars/<host>/vault.yml` and `inventory/group_vars/all/vault.yml`**, encrypted with `ansible-vault` (AES256). The vault password is **not** in this repo.
- The vault password is read from `~/.vault_pass` (mode 600, gitignored) via `ansible.cfg`. Lose it and you lose every secret.
- Vault variable convention: `vault_<service>_<purpose>` — e.g. `vault_misp_api_key`, `vault_wazuh_api_password`.
- All 7 vault files are AES256 encrypted; you can verify with `head -1 inventory/host_vars/<host>/vault.yml` (should print `$ANSIBLE_VAULT;1.1;AES256`).
- **`scripts/`** intentionally uses `CHANGEME` / `REDACTED` placeholders — don't run them as-is in production without setting your own values first.

---

## 🩺 Health Check

`playbooks/ops/health-check.yml` is the morning ritual. It walks every host, checks every relevant systemd unit, and prints one summary table:

```
================= SOC LAB HEALTH SUMMARY =================
--- .120 suricata services ---
suricata             active
snort3               active
fail2ban             active
filebeat             active
loki                 active
promtail             active
grafana-server       active
evebox               active
velociraptor         active
disk: 71%

--- .133 elk services ---
elasticsearch        active
kibana               active
logstash             active
filebeat             active
wazuh-manager        active
wazuh-dashboard      active
apache2              active
misp-workers         active
ES health: green
Wazuh agents: 3
disk: 81%

--- .135 opencti ---
opencti svc:  active
compose ps lines: 14
disk: 70%

--- T-Pot hosts ---
tpot-hive-130: tpot svc=active containers=39
tpot-sensor-125: tpot svc=active containers=32

--- Router ---
uhttpd:      running
AdGuardHome: running
uptime:      38 days
==========================================================
```

If anything is `inactive`, `red`, or above the disk-alert threshold, the table tells you exactly which host and which service to look at next.

---

## ✅ Idempotency

`ansible-playbook playbooks/site.yml` reports **0 changed, 0 failed** on all 6 hosts when the lab is healthy — 127 tasks across 6 plays. Any `changed` items are drift since the last convergence and should be investigated.

`ansible-lint` passes the **`production` profile** (strictest) across all 29 Ansible files.

---

## 🤖 AI Acknowledgment

This repository was developed with assistance from **Claude (Anthropic)** for role design, playbook authoring, lint cleanup, and documentation. All Ansible code was reviewed, tested, and converged against the live lab by the author before commit.

---

## 📄 License

See [`LICENSE`](LICENSE).

---

<div align="center">

© 2026 Andrei Majer

[![GitHub](https://img.shields.io/badge/GitHub-andrei--majer-181717?logo=github)](https://github.com/andrei-majer/soc-home) [![LinkedIn](https://img.shields.io/badge/LinkedIn-Andrei%20Majer-0A66C2?logo=linkedin)](https://www.linkedin.com/in/andreimajer/)

</div>
