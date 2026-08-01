<div align="center">

# 🛡️ soc-home

### A Home SOC Lab — Detection, Threat Intel, Deception, and Response, Driven by Ansible

**Eight-host SOC lab managed as code — Suricata + Zeek + Snort 3 IDS, ELK + Wazuh + MISP SIEM, OpenCTI threat intel with TAXII → Wazuh feedback, T-Pot HIVE + Sensor external and OpenCanary internal honeypots, an OpenWrt edge router with privacy-preserving DNS and reputation-feed blocking, and the VirtualBox hypervisor's own host stack**

📺 **[High-level visual overview →](overview.html)** *(open locally, or via [htmlpreview.github.io](https://htmlpreview.github.io/?https://github.com/andrei-majer/soc-home/blob/main/overview.html))*

🗺️ **[Architecture diagram →](soc-diagram.html)** — topology, detection pipeline, threat-intel flow & automated containment *(open locally, or via [htmlpreview.github.io](https://htmlpreview.github.io/?https://github.com/andrei-majer/soc-home/blob/main/soc-diagram.html))*

🔐 **[soc-contain arming guide →](soc-contain-arming.html)** — taking the containment fabric + Velociraptor L2 quarantine live: the observed round-trip, policy & guardrails, kill-switch, IPsec break-glass *(open locally, or via [htmlpreview.github.io](https://htmlpreview.github.io/?https://github.com/andrei-majer/soc-home/blob/main/soc-contain-arming.html))*

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

`soc-home` captures the **entire lab as code** — every Suricata YAML, every Zeek redef, every Wazuh rule, every Logstash pipeline, every fail2ban jail, every cron entry — across eight hosts, in one repository.

A single `ansible-playbook site.yml` brings the lab from a fresh Debian 12 install back to its known-good state. Day-2 ops (health checks, rule updates, ES cleanup, backups, service restarts) are one-line playbooks. Secrets stay encrypted with `ansible-vault`. Drift is detectable with `--check`. Disaster recovery for the Windows workstation — the one host Ansible doesn't manage — lives in runbooks alongside the code.

> **Scope.** This repo configures and operates the lab. It does **not** install T-Pot, OpenCTI, MISP, or the Snort 3 source build — those are one-shot installers run by hand and then captured by Ansible. Rebuild procedures for each are in `ansible/docs/runbooks/`.

---

## ⚡ Core Features

- **🏗️ Full IaC for 8 Hosts** — One `site.yml` converges Suricata + Zeek, ELK, OpenCTI, both T-Pot honeypots, the internal canary, the OpenWrt router, and the hypervisor's host stack from bare OS to production state
- **🚨 Network Detection** — Suricata 7 (~329k rules as of last check) + Zeek 8 protocol analyser on a shared SPAN port + Snort 3, with Filebeat → Logstash → Elasticsearch shipping and a 38-panel Grafana NSM dashboard for Zeek
- **🛡️ Host Detection** — Wazuh 4.14.5 across **7 currently enrolled agents** (IDS host, Windows workstation + WSL, HIVE honeypot, T-Pot sensor, canary, Ubuntu hypervisor) reporting to the manager on the ELK host, with FIM, SCA, CVE scanning cross-referenced against CISA KEV
- **📊 SIEM & Visualization** — Elasticsearch + Kibana (21-panel Cyber Defense Center + 33-panel SIEM Workbench), Grafana + Loki + Promtail for real-time log tailing, EveBox + Arkime for alert triage and PCAP review
- **🧠 Threat Intelligence** — MISP 2.5 with 8 OSINT feeds and bidirectional Suricata sync, OpenCTI 6.9 above with 5 active connectors (MISP, MITRE ATT&CK, URLhaus, ThreatFox, CISA KEV), TAXII server pushing live IOCs into Wazuh CDB rules every 30 min
- **🍯 External Honeypots** — T-Pot HIVE (`.23`) running 11 keep-list honeypot services across ~39 containers as a combined collector+sensor, plus a separate Sensor (`.25`, re-activated 2026-07-31) shipping to it; both backup-only (T-Pot self-manages, Ansible never pushes); ewsposter community sharing
- **🪤 Internal Canary** — `fileserver-24` (`fs1`): OpenCanary banners across 8 protocols, real Samba serving fake `HR`/`Backups`/`IT` shares with plausible filenames, sinkhole.py on 14 C2/exotic ports; custom Wazuh rules 1003xx with per-(rule, source) hourly dedup
- **🤖 SOAR-Lite Containment** — `soc-contain` on `.20`: a stdlib-Python containment receiver (`192.168.1.20:8765`) fed by Wazuh active-response. **Tiered** (T0 auto-contain / T1 human-approval), **guardrailed** (never acts on the SOC infra hosts), **reversible** (channel/DNS/router bans auto-release at TTL via a reaper; host-isolation stays manual), with a **dry-run → armed lifecycle** and an instant file-based kill-switch. Actuators: router ban-set, DNS sinkhole, Velociraptor collection, **Velociraptor host-firewall quarantine (host-level IPsec L2 lockdown — stops same-subnet lateral movement a gateway block can't reach on the flat LAN; composed with router-isolate for a compromised managed host)**, Tailscale quarantine, Telegram. **Full service source** (stdlib-only Python, TDD): **[`andrei-majer/soc-contain`](https://github.com/andrei-majer/soc-contain)**
- **🛜 OpenWrt Edge Router** — `.1` managed via `raw` + `scp` (no Python on target); **AdGuard Home** blocks ~47k ad/tracker/malware domains (as of last check), **Unbound** provides full DNSSEC recursion (no third-party DNS forwarding), DoT/DoQ/DoH endpoints exposed, DNS bypass firewalled at WAN; **BanIP** holds ~47k active entries (as of last check) from **Hagezi**, Spamhaus DROP, DShield, threat, threatview — independent reputation feeds, with SIEM-detected offenders added in via fail2ban
- **🔔 Telegram Alerting** — every Wazuh integration alert reaches a private Telegram bot with per-(rule, source) hourly dedup at the integration script. Migrated off self-hosted ntfy on 2026-06-29; the ntfy server was purged on 2026-08-01 and the rollback path retired with it
- **🐕 Out-of-VM Watchdog** — `soc-watchdog` on the router pings the hypervisor + IDS host every 5 min and alerts on outage — the only monitoring path that survives full hypervisor loss
- **🛠️ Day-2 Ops Playbooks** — health-check, ti-health, rule-update, es-cleanup (incl. Wazuh archive compression), cert-renew, backup, restart-services, state-collect
- **🛟 Disaster Recovery Hardening** — Self-remediating disk-alert (journal vacuum + Wazuh archive gzip at 92%, Telegram push), journald capped cluster-wide, freshness FAIL gates on `eve.json` and `conn.log`, hypervisor pre-flight in health-check — all added in response to a real disk-full outage
- **🚀 Bootstrap Pipeline** — Packer + Vagrant + `deploy.ps1` for rebuilding the Windows workstation from base ISO (see `bootstrap/`)
- **🔐 Vault-Encrypted Secrets** — Per-host `vault.yml` files (AES256), single password unlocks all via `ansible.cfg`
- **📓 Host Runbooks** — rebuild procedures for the `.13` Windows workstation (not Ansible-managed) and the `.15` Ubuntu hypervisor's OS-level install live next to the code
- **♻️ Bare-Metal Backup Scripts** — Pre-Ansible config-only tarball + restore for `.20` and `.21`, kept for full-host disaster recovery
- **💾 Documented Backup Strategy** — Three independent backup tracks (bare-metal tarballs, Ansible repo bundles, service-native), restore procedures and snapshot manifest in `backup/README.md`

---

## 🏛️ Architecture

```
                    ┌──────────────────────────────┐
                    │     OpenWrt R7800 (.1)       │
                    │  PPPoE WAN · AdGuard Home    │
                    │  Unbound (DNSSEC recursive)  │
                    │  BanIP ~47k · Hagezi + DROP  │
                    │  soc-watchdog · Telegram     │
                    └──────────────┬───────────────┘
                                   │
                            LAN 192.168.1.0/24
                     (physical .10–.19 · SOC VMs .20–.25)
                                   │
   ┌──────────┬──────────┬─────────┼──────────┬──────────┐
   │          │          │         │          │          │
┌──▼────┐ ┌───▼────┐ ┌───▼────┐ ┌──▼───┐ ┌────▼─────┐ ┌──▼───┐
│ .20   │ │ .21    │ │ .22    │ │ .23  │ │ .24      │ │ .13  │
│Suricat│ │ ELK +  │ │OpenCTI │ │T-Pot │ │ Canary   │ │ Win  │
│ Zeek  │ │Wazuh + │ │ 6.9.28 │ │ HIVE │ │ fs1      │ │workst│
│Snort3 │ │MISP 2.5│ │ Docker │ │39 ct │ │OpenCanary│ │Sysmon│
│Grafana│ │EveBox  │ │5 conntr│ │  ▲   │ │ + SMB    │ │Wazuh │
│ Loki  │ │        │ │ TAXII  │ │  │   │ │ sinkhole │ │Velo  │
│Arkime │ │        │ │ server │ │ .25  │ │          │ │      │
│Veloci │ │        │ │        │ │sensor│ │          │ │      │
│fail2b │ │        │ │        │ │      │ │          │ │      │
└──┬────┘ └───┬────┘ └───┬────┘ └──┬───┘ └────┬─────┘ └──┬───┘
   │          ▲          │         │          │          │
   │ Filebeat │          │ TAXII   │ Wazuh agents (7 enrolled)
   │ Promtail │          │  every  │                              │
   │   eve+   │          │ 30 min  │◀──────────────────────────────
   │  zeek+   │          │         │
   │  notice  │   ┌──────▼─────┐   │
   │  ────────►   │ Wazuh CDB  │   │
   │          │   │opencti-ioc │   │
   │      ┌───▼───┴───┐        │   │
   │      │Elasticsrch│        │   │
   │      │Kibana 5601│        │   │
   │      │Wazuh:1514 │        │   │
   │      └───────────┘        │   │
   │          │                │   │
   │ Suricata │ MISP feeds (8) │   │  MISP connector (5 min sync)
   │ sightings│ → Suricata IOC │   │  ────────────────────────────►
   │ → MISP   │   rules (6h)   │   │
   ◄──────────┴────────────────┘   │
   │                                │
   │  fail2ban → SSH → router BanIP set
   ▼  (3 alerts in 5 min → 1h ban at network edge)

   ┌──────────────────────────┐
   │ Ansible control node     │
   │ /opt/soc-ansible (.20)   │
   │ ansible_connection=local │
   └──────────────────────────┘
```

The control node runs **on** `.20` (`ansible_connection: local`) — there is no separate management host. Every play either runs locally on `.20` or SSHes to one of the 7 other managed hosts. Only the Windows workstation (`.13`) is outside Ansible (runbooks instead).

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

The vault password unlocks all 8 `vault.yml` files. Without it, every play that touches a templated secret will fail.

### 3. Inventory & SSH keys

The control node (`.20`) needs an SSH private key that authorizes `root` on every managed host:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.1.21
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.1.22
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.1.24   # internal canary
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 64295 root@192.168.1.23   # T-Pot HIVE
ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 64295 root@192.168.1.25   # T-Pot Sensor
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.1.1    # OpenWrt
ssh-copy-id -i ~/.ssh/id_ed25519.pub andrei@192.168.1.15 # hypervisor (become via vault)
```

Both T-Pot hosts use SSH on port **64295** (root, key auth — same key as `.20`).

### 4. Dry run

```bash
ansible-playbook playbooks/site.yml --check
```

A clean lab should report approximately **0 changed, 0 failed** across all 8 hosts. Any `changed` items are drift since the last convergence.

### 5. Converge

```bash
ansible-playbook playbooks/site.yml
```

<details>
<summary><b>Prerequisites</b></summary>

- **Control node:** Debian 12 + `ansible-core ≥ 2.15`, `git`, `python3-passlib`, an SSH private key
- **Managed Linux hosts:** Debian 12 (`.20`, `.21`) or Debian 13 (`.22`, `.24`) — fresh install, root SSH key auth
- **Router:** OpenWrt 24.10+ (no Python — uses `raw` + `scp`)
- **T-Pot hosts:** install T-Pot first, then add the control node's pubkey to `/root/.ssh/authorized_keys` on port 64295
- **Hardware:** Anything that can run 6 Linux VMs comfortably. The reference lab uses a single Ubuntu 24.04 hypervisor (i7-9700K / 64 GB / VirtualBox)

</details>

<details>
<summary><b>What if I'm rebuilding from bare metal?</b></summary>

Two paths depending on what failed:

| Failure | Path |
|---|---|
| `.20` lost (control node + IDS) | Reinstall Debian 12 → restore `~/.vault_pass` and SSH key → `git clone` this repo to `/opt/soc-ansible` → `ansible-playbook playbooks/site.yml --limit suricata-20`. If you also need `.20` runnable *before* Ansible can converge it, use the pre-Ansible tarball scripts in `scripts/` first |
| `.21` lost (ELK + Wazuh + MISP) | Follow `ansible/docs/runbooks/misp-rebuild.md` for MISP, then `ansible-playbook playbooks/site.yml --limit elk-21`. ES indices and MISP event data are **not** in this repo — restore from your own backup target |
| T-Pot host lost | Follow `ansible/docs/runbooks/tpot-rebuild.md` (T-Pot installer is one-shot — Ansible role is backup-only) |
| Canary `.24` lost | Follow `ansible/docs/runbooks/canary-24-rebuild.md` — fresh Debian 13 minimal + apt purge `dhcpcd-base` + install `rsyslog` and `systemd-timesyncd`, then `ansible-playbook playbooks/site.yml --limit fileserver-24` |
| Hypervisor or workstation lost | Follow `ansible/docs/runbooks/hypervisor-15.md` (Ubuntu OS-level install) then `ansible-playbook playbooks/site.yml --limit hypervisor-15` for the host stack; or `windows-13.md` / the `bootstrap/` Packer + Vagrant + `deploy.ps1` pipeline for `.13` |

</details>

---

## 🖥️ Host Inventory

| Host | IP | OS | Roles applied | Connection |
|---|---|---|---|---|
| **suricata-20** | 192.168.1.20 | Debian 12 | `common`, `suricata` (incl. Zeek, Snort 3, Filebeat, Grafana, Loki, Promtail, EveBox, Arkime, Velociraptor, fail2ban), `backups`, `soc-contain` (tiered, reversible SOAR-lite containment receiver on `192.168.1.20:8765`) | `local` (control node) |
| **elk-21** | 192.168.1.21 | Debian 12 | `common`, `elk`, `wazuh-manager`, `misp`, `backups` | SSH (key) |
| **opencti-22** | 192.168.1.22 | Debian 13 | `common`, `opencti` (on-demand savestate), `backups` | SSH (key) |
| **tpot-hive-23** | 192.168.1.23 | Debian (T-Pot) | `tpot` (backup-only) | SSH :64295 |
| **fileserver-24** | 192.168.1.24 | Debian 13 | `common`, `canary` (OpenCanary + Samba + sinkhole.py) | SSH (key) |
| **tpot-sensor-25** | 192.168.1.25 | Debian (T-Pot) | `tpot` (backup-only) | SSH :64295 |
| **router-1** | 192.168.1.1 | OpenWrt 24.10 | `openwrt` (raw + scp) | SSH (no Python) |
| **hypervisor-15** | 192.168.1.15 | Ubuntu 24.04 | `hypervisor` (docker-prune, disk-alert, soc-sleep/wake, ups-loki, e1000e NIC-hang fix, PXE netboot) | SSH as `andrei` + `become` |

> LAN addresses were renumbered on 2026-07-15 — physical hosts to `.10–.19`, SOC VMs to `.20–.25`. The `tpot-sensor` host was retired 2026-06-07 and re-activated 2026-07-31 as `.25` (was `.125`).

The `.13` Windows workstation is documented in runbooks, not managed by Ansible. The `.15` hypervisor's OS-level install is also runbook territory; `roles/hypervisor` covers only its host-side units.

---

## 📖 Usage

All commands run on the control node (`.20`) from `/opt/soc-ansible/`.

### Daily / weekly ops

```bash
# Morning health check (every host, every service, ES status, T-Pot containers, canary, router)
ansible-playbook playbooks/ops/health-check.yml

# Threat-intel pipeline check — OpenCTI connectors, RabbitMQ, MISP workers, IOC freshness
ansible-playbook playbooks/ops/ti-health.yml

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
ansible-playbook playbooks/site.yml --limit elk-21

# One role
ansible-playbook playbooks/site.yml --limit suricata-20 --tags suricata

# Specific subset of rule updates
ansible-playbook playbooks/ops/rule-update.yml --tags suricata,iprep
```

### Editing secrets

```bash
# Edit a per-host vault file
ansible-vault edit inventory/host_vars/elk-21/vault.yml

# View without unlocking the editor
ansible-vault view inventory/group_vars/all/vault.yml

# Re-key after rotating the vault password
ansible-vault rekey inventory/host_vars/*/vault.yml
```

---

## 🧰 `scripts/` — Bare-Metal Backup & Restore

Pre-Ansible tooling for full-host disaster recovery of `.20` and `.21`. Kept around because they capture **everything** (binaries, configs, dashboards, sqlite DBs) into a single tarball — useful when you've lost the control node and need to bring `.20` back to a runnable state before Ansible can converge it.

| Script | Run on | Purpose |
|---|---|---|
| `backup-suricata-s.sh` | `.20` | Collects Suricata, Snort 3, fail2ban, Grafana, Loki/Promtail, EveBox, Velociraptor, Arkime, Filebeat, Wazuh agent configs + binaries |
| `restore-suricata-s.sh` | Fresh `.20` | Installs packages, extracts configs, enables services, runs `suricata-update`, optional Snort 3 binary restore or source build |
| `backup-elk-e.sh` | `.21` | Collects ES, Kibana (incl. saved objects), Logstash, Wazuh Manager + Dashboard, MISP, Apache, MariaDB structure |

> ⚠️ **Credentials in `scripts/` and its README are placeholders** (`CHANGEME`, `REDACTED`). Set your own values before running. See `scripts/README.md` for full backup/restore walkthroughs.

---

## 🗂️ Stack

| Layer | Technology |
|---|---|
| **Network IDS / NSM** | [Suricata 7](https://suricata.io/) (~329k rules) · [Zeek 8](https://zeek.org/) (protocol logs, NXDOMAIN-burst DGA detection) · [Snort 3](https://www.snort.org/) · [Emerging Threats Open](https://rules.emergingthreats.net/) · MISP IOC pull |
| **SIEM** | [Elasticsearch 8](https://www.elastic.co/) · [Kibana](https://www.elastic.co/kibana/) · [Logstash](https://www.elastic.co/logstash/) · [Wazuh 4.14](https://wazuh.com/) (6 agents) |
| **Threat Intel** | [OpenCTI 6.9](https://www.opencti.io/) with 5 connectors ([MISP](https://www.misp-project.org/), [MITRE ATT&CK](https://attack.mitre.org/), [URLhaus](https://urlhaus.abuse.ch/), [ThreatFox](https://threatfox.abuse.ch/), [CISA KEV](https://www.cisa.gov/known-exploited-vulnerabilities-catalog)) · [MISP 2.5](https://www.misp-project.org/) with 8 OSINT feeds · TAXII 2.1 → Wazuh CDB |
| **External Honeypots** | [T-Pot 24.x](https://github.com/telekom-security/tpotce) HIVE (combined collector+sensor, 11 keep-list honeypot services across ~39 containers) |
| **Internal Canary** | [OpenCanary](https://github.com/thinkst/opencanary) (8 banner protocols) · real Samba with fake shares · custom `sinkhole.py` on 14 C2 ports |
| **Visualization** | [Grafana](https://grafana.com/) (Suricata, Snort, 38-panel Zeek NSM dashboard) · [Loki](https://grafana.com/oss/loki/) · [Promtail](https://grafana.com/docs/loki/latest/clients/promtail/) · [EveBox 0.24](https://evebox.org/) · [Arkime 5.8](https://arkime.com/) |
| **Endpoint** | [Velociraptor 0.75](https://docs.velociraptor.app/) · [Filebeat](https://www.elastic.co/beats/filebeat) · [Wazuh agent](https://wazuh.com/) · Sysmon (Windows) |
| **Edge** | [OpenWrt 24.10](https://openwrt.org/) · [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) (~47k blocked domains) · [Unbound](https://nlnetlabs.nl/projects/unbound/) (DNSSEC recursive) · [BanIP](https://github.com/openwrt/packages/tree/master/net/banip) (~47k entries from Hagezi, Spamhaus DROP, DShield, threat, threatview) |
| **Alerting** | Telegram bot · `custom-telegram` Wazuh integration with per-(rule, source) hourly dedup · router-side `soc-watchdog` for out-of-VM alerting. (Migrated off self-hosted [ntfy](https://ntfy.sh/) 2026-06-29; server purged 2026-08-01) |
| **Active Response** | `fail2ban` (3-strike → SSH → router BanIP) · custom `suricata-enforcer.py` · `sinkhole.py` on canary `.24` |
| **Bootstrap** | [Packer](https://www.packer.io/) · [Vagrant](https://www.vagrantup.com/) · `deploy.ps1` (see `bootstrap/`) |
| **IaC** | [Ansible](https://www.ansible.com/) · [ansible-vault](https://docs.ansible.com/ansible/latest/vault_guide/index.html) · [ansible-lint](https://ansible-lint.readthedocs.io/) (passes the `production` profile with a documented `skip_list`) |

---

## 📁 Project Structure

```
soc-home/
├── README.md
├── overview.html                 # Single-file dark-console visual overview (this is what
│                                 #   "📺 Visual Overview" at the top of the README links to)
├── soc-diagram.html              # Mermaid architecture diagram — topology, detection
│                                 #   pipeline, threat-intel flow, automated containment
├── soc-contain-arming.html       # soc-contain arming guide — round-trip, guardrails,
│                                 #   kill-switch, IPsec break-glass
├── LICENSE
├── ansible/
│   ├── ansible.cfg               # stdout=yaml, host_key_checking=False
│   ├── .ansible-lint             # production profile
│   ├── README.md
│   ├── files/
│   │   └── tailscale-acl.jsonc   # tailnet ACL, applied via API from .20
│   ├── inventory/
│   │   ├── hosts.yml             # 8 hosts in 5 groups (debian, canary, tpot, openwrt, hypervisor)
│   │   ├── group_vars/
│   │   │   ├── all/{main.yml, vault.yml}
│   │   │   ├── debian.yml
│   │   │   ├── tpot.yml
│   │   │   └── openwrt.yml
│   │   └── host_vars/
│   │       ├── elk-21/{vars.yml, vault.yml}
│   │       ├── fileserver-24/main.yml       # canary host — no secrets, no vault.yml
│   │       ├── hypervisor-15/{main.yml, vault.yml}   # vault holds the sudo/become pass
│   │       ├── opencti-22/{vars.yml, vault.yml}
│   │       ├── router-1/vault.yml
│   │       ├── suricata-20/{vars.yml, vault.yml}
│   │       ├── tpot-hive-23/vault.yml
│   │       └── tpot-sensor-25/vault.yml
│   ├── roles/
│   │   ├── common/               # base packages, disk-alert (self-remediating), SSH keys,
│   │   │                         #   timezone, journald cap (200 MB)
│   │   ├── suricata/             # Suricata + Zeek + Snort 3 + fail2ban + Filebeat + iprep
│   │   │                         #   + MISP scripts + Arkime + Velociraptor
│   │   │                         #   + Grafana/Loki/Promtail + EveBox
│   │   ├── elk/                  # Elasticsearch, Kibana, Logstash, Filebeat, index cleanup
│   │   ├── wazuh-manager/        # ossec.conf, rules, Telegram, TAXII, dashboard + patches
│   │   ├── misp/                 # Apache vhost, PHP, logrotate (config-only)
│   │   ├── opencti/              # Docker Compose stack, .env, backup, on-demand savestate
│   │   ├── canary/               # OpenCanary + Samba decoys + sinkhole.py + rsyslog routing
│   │   ├── soc-contain/          # SOAR-lite containment receiver (tiered, reversible) on
│   │   │                         #   192.168.1.20:8765, fed by Wazuh active-response
│   │   ├── hypervisor/           # .15 host stack — docker-prune, disk-alert, soc-sleep/wake,
│   │   │                         #   ups-loki, e1000e NIC-hang fix, PXE netboot framework
│   │   ├── backups/              # service-native backup wrappers (.20/.21/.22)
│   │   ├── tpot/                 # Backup/pull-only via fetch
│   │   └── openwrt/              # Backup/pull-only via raw + scp; soc-watchdog deploy
│   ├── playbooks/
│   │   ├── site.yml              # Full convergence
│   │   └── ops/
│   │       ├── health-check.yml  # incl. hypervisor pre-flight, eve.json/conn.log
│   │       │                     #   freshness FAIL gates, canary services, agent drift
│   │       ├── ti-health.yml     # OpenCTI connectors, RabbitMQ, MISP workers, IOC freshness
│   │       ├── rule-update.yml   # tags: suricata, snort, iprep, misp
│   │       ├── es-cleanup.yml    # also compresses Wazuh archives, reclaim-first ordering
│   │       ├── cert-renew.yml
│   │       ├── backup.yml
│   │       ├── restart-services.yml   # requires -e confirm=yes
│   │       └── state-collect.yml
│   └── docs/
│       ├── plans/                      # historical implementation plans (pre-renumber IPs)
│       ├── specs/                      # historical design specs (pre-renumber IPs)
│       ├── archive/                    # superseded material — see its README before using
│       └── runbooks/
│           ├── windows-13.md           # .13 Windows workstation rebuild
│           ├── hypervisor-15.md        # .15 Ubuntu hypervisor rebuild
│           ├── tpot-rebuild.md         # T-Pot HIVE + Sensor rebuild
│           ├── misp-rebuild.md         # MISP from-scratch rebuild
│           ├── canary-24-rebuild.md    # internal canary (.24) rebuild
│           ├── ssd-monitoring-15.md    # .15 SMART + mdadm monitoring
│           ├── ups-loki-collectors.md  # NUT → Loki collectors on .15 / .1 / .13
│           ├── velociraptor-ca-rotation.md
│           └── restore-xndrei.go.ro.md # OpenWrt router (.1) restore
├── bootstrap/                    # Packer + Vagrant + deploy.ps1 for rebuilding .13
│                                 #   workstation from base ISO (Phase 1B)
├── scripts/                      # Reference copies + pre-Ansible tooling. Where a file also
│   │                             #   exists under ansible/roles/*/files/, the ROLE copy is
│   │                             #   what gets deployed.
│   ├── README.md
│   ├── backup-suricata-s.sh
│   ├── restore-suricata-s.sh
│   ├── backup-elk-e.sh
│   ├── soc-backup-sync.{ps1,md}  # .13 OneDrive backup sync
│   ├── hypervisor-15/            # .15 host units (see roles/hypervisor)
│   ├── netboot-15/               # PXE assets + fetch notes (see roles/hypervisor)
│   ├── opencti/                  # on-demand savestate/wake helpers for .22
│   ├── wol-relay/                # token-authed WOL CGI on the router
│   └── ups-monitoring/           # NUT UPS monitoring + Grafana dashboards;
│                                 #   hypervisor suspends-to-RAM on power loss
└── backup/
    └── README.md                 # Backup strategy, snapshot manifest, restore procedures
                                  # (no tarballs committed — see secret-handling rules)
```

---

## 🔐 Secrets & Vault

- **All sensitive values live in `inventory/host_vars/<host>/vault.yml` and `inventory/group_vars/all/vault.yml`**, encrypted with `ansible-vault` (AES256). The vault password is **not** in this repo.
- The vault password is read from `~/.vault_pass` (mode 600, gitignored) via `ansible.cfg`. Lose it and you lose every secret.
- Vault variable convention: `vault_<service>_<purpose>` — e.g. `vault_misp_api_key`, `vault_wazuh_api_password`.
- All 8 vault files are AES256 encrypted; you can verify with `head -1 inventory/host_vars/<host>/vault.yml` (should print `$ANSIBLE_VAULT;1.1;AES256`).
- **`scripts/`** intentionally uses `CHANGEME` / `REDACTED` placeholders — don't run them as-is in production without setting your own values first.

---

## 🩺 Health Check

`playbooks/ops/health-check.yml` is the morning ritual. It walks every host, checks every relevant systemd unit, and prints one summary table:

```
================= SOC LAB HEALTH SUMMARY =================
--- .20 suricata services ---
suricata             active   (rules loaded: 329156)
zeek                 running  (conn.log 2s ago [OK])
snort3               active
fail2ban             active
filebeat             active
loki                 active
promtail             active
grafana-server       active
evebox               active
velociraptor         active
eve.json             3s ago [OK]
disk: 71% [OK]

--- .21 elk services ---
elasticsearch        active
kibana               active
logstash             active
filebeat             active
wazuh-manager        active
wazuh-dashboard      active
mariadb              active
apache2              active
misp-workers         active
ES health: green
Wazuh agents: 7
MISP rules age: 2h
disk: 81% [WARN]

--- .22 opencti ---
opencti svc:  active
compose ps lines: 14
restart count (10m): 0
disk: 70% [OK]

--- .24 canary ---
opencanary           active
sinkhole             active
smbd                 active
wazuh-agent          active
listening ports:     22 [OK]
disk: 14% [OK]

--- T-Pot ---
tpot-hive-23:    tpot svc=active wazuh-agent=active containers=39
tpot-sensor-25:  tpot svc=active wazuh-agent=active containers=13

--- Router ---
uhttpd:       running
AdGuardHome:  running
Unbound:      running
BanIP:        47567 entries
disk:         43% [OK]
uptime:       38 days
==========================================================
```

If anything is `inactive`, `red`, or above the disk-alert threshold, the table tells you exactly which host and which service to look at next.

---

## ✅ Idempotency

`ansible-playbook playbooks/site.yml` reports approximately **0 changed, 0 failed** on all 8 hosts when the lab is healthy. Any `changed` items are drift since the last convergence and should be investigated.

`ansible-lint` passes the **`production` profile** (strictest) across all Ansible files (34+ as of last check) with a documented `skip_list` in `.ansible-lint`.

---

## 🤖 AI Acknowledgment

This repository was developed with assistance from **Claude (Anthropic)** for role design, playbook authoring, lint cleanup, and documentation. All Ansible code was reviewed, tested, and converged against the live lab by the author before commit.

---

## 📄 License

See [`LICENSE`](LICENSE).

---

<div align="center">

© 2026 Andrei Majer

[![GitHub](https://img.shields.io/badge/GitHub-andrei--majer-181717?logo=github)](https://github.com/andrei-majer/soc-home) [![LinkedIn](https://img.shields.io/badge/LinkedIn-Andrei%20Majer-0A66C2?logo=linkedin)](https://www.linkedin.com/in/andrei-majer/)

</div>
