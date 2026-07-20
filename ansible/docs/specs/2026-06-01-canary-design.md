# Internal Canary on `.140` + T-Pot → Wazuh Pipe — Design Spec

**Date:** 2026-06-01
**Status:** Approved (brainstorming complete; awaiting implementation plan)
**Repo:** soc-ansible (`/opt/soc-ansible/` on .120 master / GitHub mirror `andrei-majer/soc-home` main)

## 1. Context

The lab has external honeypot coverage via T-Pot HIVE (`.130`, 39 containers) and SENSOR (`.125`, 32 containers), each feeding T-Pot's own ELK at `.130:64297`. There is **no internal trip-wire** that pages when one of the lab's own hosts (e.g. compromised `.13`) probes a fake service on the LAN.

`.120` does run a partial canary: `/usr/local/bin/sinkhole.py` on alias `enp0s3:0` (`.121`), systemd unit `sinkhole.service`, deployed 2026-04-03. It listens on 19 ports, writes JSON to `/var/log/sinkhole.json`, but:

- **No banner / protocol emulation** — `nmap -sV .121` returns nothing; fingerprintable as "not a real service" in one probe
- **Not in Ansible** — lost on `.120` rebuild, not in backups, undocumented in memory until recon for this spec
- **Not wired into Wazuh** — JSON lands on disk; no manager rule, no ntfy, no SIEM visibility

This spec covers:
1. A proper internal canary on a dedicated decoy VM (`.140 fileserver01`)
2. Migration of `sinkhole.py` off `.120` onto the new canary VM (clean cutover)
3. Piping T-Pot internal-source hits into the main Wazuh/ntfy pipeline so lateral movement caught by T-Pot also pages

## 2. Scope

### In scope

- Provision new VM `.140 fileserver01` on `.15`: Debian 12 minimal, 1 vCPU / 768 MB / 4 GB virtio disk, virtio NIC bridged to LAN, single IP `192.168.1.140/24`, VBox owner `Games`, excluded from `soc-sleep-savestate.ps1` so it stays 24/7
- Deploy OpenCanary on `.140` for 8 service ports with banners + credential capture: FTP, Telnet, HTTP, HTTPS, SMB (3 fake shares), MySQL, RDP, VNC
- Migrate `sinkhole.py` from `.120:.121` to `.140`: code unchanged; `PORTS` list trimmed to remove the 7 ports now owned by OpenCanary banners (21, 23, 80, 443, 445, 3389, 5900)
- Decommission `.121` alias + `sinkhole.service` from `.120` in the same change-set
- New Ansible role `roles/canary/` and new inventory host + `canary` group
- Wazuh agent install on `.140`, `.130`, `.125` (one-time manual; matches existing pattern where agent `ossec.conf` is not otherwise Ansible-managed — only `<localfile>` blocks are added via `blockinfile`)
- Manager rules `1003xx` (canary) and `1004xx` (T-Pot internal) on `.133`, tiered + dedup (Section 5)
- Active-response ntfy push for level 10/12 hits, per-source-IP hourly dedup
- SMB decoy content: 3 shares (HR, Backups, IT), ~30 plausibly-named empty/random-byte files. **No live canary tokens.**
- `playbooks/ops/health-check.yml` additions: new `canary` play, `wazuh-agent` added to T-Pot service loop, agent-count drift threshold updated 4 → 7
- Memory updates and runbooks (Section 9)

### Out of scope (explicit YAGNI)

- Canarytokens (fake AWS creds, beaconing docx) — separate beast, own spec if `.140` proves itself
- OpenCanary on `.13` Windows — defer; Windows OpenCanary is weak; if pursued it's a separate spec
- Real SSH MITM on `.140:22` — real `sshd` keeps `:22`. "Real sshd on `:2222` + OpenCanary SSH on `:22`" is a stronger deception model, deferred as v2 hardening (adds `ansible_port: 2222` inventory complexity)
- TLS interception on `.140:443` — OpenCanary serves self-signed
- Internal honey-accounts on `.13`/etc. — bigger scope, separate spec
- T-Pot non-JSON honeypots (Heralding CSV, RDPY/Mailoney/Citrixhoneypot text) — v1 is JSON-only; text decoders deferred

## 3. Architecture

### 3a. Host `.140 fileserver01`

- VirtualBox VM on `.15`, owner `Games` (matches existing pattern so Task Scheduler `SOC-Start*`/`SOC-Stop*` scripts see it via `VBoxManage` when run as `Games`)
- Debian 12 minimal, 1 vCPU / 768 MB / 4 GB virtio disk, virtio NIC, bridged to LAN
- Single IP `192.168.1.140/24`, hostname `fileserver01`
- Excluded from `soc-sleep-savestate.ps1` — 24/7 canary

### 3b. Processes (systemd on `.140`)

| Unit | Purpose |
|---|---|
| `ssh.service` | Real `sshd` on `:22` for Ansible/admin |
| `opencanary.service` | Python venv `/opt/opencanary-venv`, config `/etc/opencanaryd/opencanary.conf` |
| `sinkhole.service` | Relocated from `.120`, code unchanged |
| `wazuh-agent.service` | Enrolled to `.133:1514` |

### 3c. Port map (22 canary ports + real SSH)

| Port(s) | Listener | Banner / behavior |
|---|---|---|
| `22` | real `sshd` | Normal OpenSSH (admin/Ansible) |
| `21` | OpenCanary | FTP login banner, credential capture |
| `23` | OpenCanary | Telnet login banner, credential capture |
| `80` | OpenCanary | NAS-style HTML login page |
| `443` | OpenCanary | HTTPS self-signed, same NAS page |
| `445` | OpenCanary | SMB with HR/Backups/IT shares |
| `3306` | OpenCanary | MySQL greeting + credential capture |
| `3389` | OpenCanary | RDP cookie / X.224 |
| `5900` | OpenCanary | VNC handshake |
| `25, 465, 587` | sinkhole.py | Connect-and-close (SMTP) |
| `1080` | sinkhole.py | Connect-and-close (SOCKS) |
| `1337, 31337` | sinkhole.py | Connect-and-close (backdoor) |
| `4444, 4445, 4449` | sinkhole.py | Connect-and-close (Metasploit/C2) |
| `6667, 6697` | sinkhole.py | Connect-and-close (IRC) |
| `8443, 8888` | sinkhole.py | Connect-and-close (alt-HTTP/S) |
| `9001` | sinkhole.py | Connect-and-close (Tor) |

`sinkhole.py` `PORTS` list drops: 21, 23, 80, 443, 445, 3389, 5900.

### 3d. Data flow (canary)

```
attacker (any source)
       |
       v
  .140 : port  ->  OpenCanary  or  sinkhole.py
                          |
              +-----------+-----------+
              v                       v
  /var/tmp/opencanary.log    /var/log/sinkhole.json
              |                       |
              +-----------+-----------+
                          v
              wazuh-agent (.140) -> .133:1514
                          v
              manager rules 1003xx
                (tier by port, dedup by src_ip/hour)
                          v
              active-response -> ntfy push
```

### 3e. T-Pot tap (no T-Pot modification)

- Wazuh agent on `.130` and `.125`, separate from T-Pot's own pipeline
- Localfile tail of 6 JSON honeypot logs per host
- Manager rules `1004xx` filter on `src_ip` matching `^192\.168\.1\.` — only LAN-source hits trigger. External internet noise stays silent in T-Pot's own Kibana on `.130:64297`, unchanged.

## 4. Components

### 4a. Ansible role `roles/canary/`

```
roles/canary/
├── defaults/main.yml          ports, share names, log paths, sinkhole PORTS list
├── files/
│   ├── sinkhole.py            migrated from .120 (PORTS list trimmed)
│   ├── sinkhole.service       systemd unit (relocated)
│   ├── opencanary.service     systemd unit
│   └── share-decoys/{HR,Backups,IT}/   ~30 decoy files (empty xlsx/pdf/docx, random-byte .bak/.tar.gz, plausible text)
├── handlers/main.yml          Restart opencanary, Restart sinkhole, Restart wazuh-agent
├── tasks/main.yml             venv + opencanary install, config deploy, smb decoy tree, sinkhole + units, enable/start, wait_for ports, .120 cleanup block (state: absent)
└── templates/opencanary.conf.j2   OpenCanary JSON config
```

### 4b. Inventory

- Add `fileserver-24` to `inventory/hosts.yml` under both `debian` group and new `canary` group
- New `inventory/host_vars/fileserver-24/main.yml` with `ansible_host: 192.168.1.140`
- No new `vault.yml` — canary has no secrets of its own; the ntfy topic var lives in `.133`'s vault scope where the manager runs

### 4c. Site playbook

- `playbooks/site.yml` gains a play targeting `canary` group → `common` + `canary` roles
- T-Pot agent localfile tap: **extend the existing `tpot` role** with a tagged `wazuh-agent` section (not a separate role — keeps the host-to-role mapping one-to-one and matches how the Zeek tap was folded into the `suricata` role). The tap section is a single `blockinfile` task; the rest of the `tpot` role remains backup-only as today.

### 4d. `.120` cutover

`canary` role contains an `ansible.builtin.file: state: absent` task block, gated on `inventory_hostname == 'suricata-20'`, that removes:

- `/etc/network/interfaces.d/sinkhole`
- `/etc/systemd/system/sinkhole.service` (after `systemd: state: stopped, enabled: no`)
- `/usr/local/bin/sinkhole.py`

Idempotent. Reversible from git.

## 5. Wazuh wiring

### 5a. Agent-side localfile blocks

`.140` — two blocks via `blockinfile`:
```xml
<localfile>
  <location>/var/tmp/opencanary.log</location>
  <log_format>json</log_format>
</localfile>
<localfile>
  <location>/var/log/sinkhole.json</location>
  <log_format>json</log_format>
</localfile>
```

`.130` + `.125` — six blocks per host (JSON-emitting honeypots only):
```xml
<localfile><location>/data/cowrie/log/cowrie.json</location>          <log_format>json</log_format></localfile>
<localfile><location>/data/dionaea/log/dionaea.json</location>        <log_format>json</log_format></localfile>
<localfile><location>/data/adbhoney/log/adbhoney.json</location>      <log_format>json</log_format></localfile>
<localfile><location>/data/tanner/log/tanner_report.json</location>   <log_format>json</log_format></localfile>
<localfile><location>/data/sentrypeer/log/sentrypeer.json</location>  <log_format>json</log_format></localfile>
<localfile><location>/data/conpot/log/conpot.json</location>          <log_format>json</log_format></localfile>
```

All wrapped in one `blockinfile` marker per host. Notifies `Restart wazuh-agent` handler.

### 5b. Manager rules — `roles/wazuh-manager/files/local_rules.xml`

Built-in JSON decoder, no custom decoder (same pattern as Zeek `1002xx`). Field names below come from OpenCanary docs; **exact decode paths confirmed empirically via `wazuh-logtest` against a captured sample before commit** — adjust pcre2 paths if needed.

**`1003xx` — canary**:
```xml
<group name="canary,internal_tripwire,">

  <rule id="100300" level="3">
    <decoded_as>json</decoded_as>
    <field name="logdata.local_host">192.168.1.140</field>
    <description>Canary hit on .140 (base)</description>
  </rule>

  <rule id="100301" level="10">
    <if_sid>100300</if_sid>
    <field name="logdata.src_host" type="pcre2">^192\.168\.1\.</field>
    <field name="logdata.dst_port" type="pcre2">^(21|23|80|443)$</field>
    <description>Canary banner-port hit from LAN (lateral movement signal)</description>
    <group>canary_banner,</group>
  </rule>

  <rule id="100302" level="12">
    <if_sid>100300</if_sid>
    <field name="logdata.src_host" type="pcre2">^192\.168\.1\.</field>
    <field name="logdata.dst_port" type="pcre2">^(445|3306|3389|5900|4444|4445|4449|6667|6697|9001|1337|31337)$</field>
    <description>Canary critical-port hit from LAN</description>
    <group>canary_critical,</group>
  </rule>

  <rule id="100303" level="12">
    <if_sid>100300</if_sid>
    <field name="logdata.USERNAME" type="pcre2">.+</field>
    <description>Canary credential attempt captured</description>
    <group>canary_creds,</group>
    <!-- intentionally NOT deduplicated — each unique credential pair is intel; repeats from
         same source still page so we don't miss password-spray progression -->
  </rule>

  <rule id="100304" level="3" frequency="2" timeframe="3600" ignore="3600">
    <if_matched_sid>100301</if_matched_sid>
    <same_field>logdata.src_host</same_field>
    <description>Canary hit repeat from same source (dedup, hourly)</description>
  </rule>

  <rule id="100305" level="3" frequency="2" timeframe="3600" ignore="3600">
    <if_matched_sid>100302</if_matched_sid>
    <same_field>logdata.src_host</same_field>
    <description>Canary critical-port repeat from same source (dedup, hourly)</description>
  </rule>

</group>
```

**`1004xx` — T-Pot internal**:
```xml
<group name="tpot,internal_tripwire,">

  <rule id="100400" level="3">
    <decoded_as>json</decoded_as>
    <match>cowrie|dionaea|adbhoney|tanner|sentrypeer|conpot</match>
    <description>T-Pot honeypot hit (base)</description>
  </rule>

  <rule id="100401" level="10">
    <if_sid>100400</if_sid>
    <field name="src_ip" type="pcre2">^192\.168\.1\.</field>
    <description>T-Pot hit from internal LAN (lateral movement signal)</description>
  </rule>

  <rule id="100402" level="12">
    <if_sid>100401</if_sid>
    <field name="dst_port" type="pcre2">^(445|3306|3389|5900)$</field>
    <description>T-Pot critical-port hit from LAN</description>
  </rule>

  <rule id="100403" level="3" frequency="2" timeframe="3600" ignore="3600">
    <if_matched_sid>100401</if_matched_sid>
    <same_field>src_ip</same_field>
    <description>T-Pot hit repeat from same source (dedup, hourly)</description>
  </rule>

</group>
```

### 5c. Active-response ntfy

```xml
<command>
  <name>ntfy-canary</name>
  <executable>ntfy-alert.sh</executable>
  <expect />
</command>
<active-response>
  <command>ntfy-canary</command>
  <location>server</location>
  <rules_group>canary_critical,canary_creds,canary_banner,tpot</rules_group>
</active-response>
```

`/var/ossec/active-response/bin/ntfy-alert.sh`:
- Parses Wazuh alert JSON from stdin (`{"timestamp":...,"rule":{"level":X,"id":Y,"description":Z},"data":{...}}`)
- Formats title: `[CANARY/.140] 192.168.1.X -> :445 SMB` (or `[T-Pot/.130] ...`)
- `POST https://ntfy.xndrei.go.ro/<topic>` with `Priority: urgent` for lvl 12, `Priority: high` for lvl 10
- Reads topic from `/etc/ntfy/topic` (deployed by wazuh-manager role from vault var, matches existing ntfy active-response pattern)

### 5d. Why this catches both — vs T-Pot's own UI

T-Pot's Kibana on `.130:64297` keeps receiving every hit (including all external internet noise on `.125`) — unchanged. The new path forwards only LAN-source hits to `.133`/Wazuh/ntfy — that's the lateral-movement subset. No double-counting, no flood on the SOC pipeline.

## 6. Health-check additions (`playbooks/ops/health-check.yml`)

New play targeting `canary` group:
```yaml
- name: Health check — canary (.140)
  hosts: canary
  gather_facts: true
  tasks:
    - name: Check systemd services (.140)
      ansible.builtin.command: "systemctl is-active {{ item }}"
      loop: [opencanary, sinkhole, wazuh-agent]
      register: svc_24
      failed_when: false
      changed_when: false
    - name: Canary listening port count (.140)
      ansible.builtin.shell: ss -tln '! ( sport = :22 )' | grep -c LISTEN
      register: ports_24
      failed_when: false
      changed_when: false
    - name: OpenCanary log exists (.140)
      ansible.builtin.stat: { path: /var/tmp/opencanary.log }
      register: ocan_log_24
    - name: Sinkhole log exists (.140)
      ansible.builtin.stat: { path: /var/log/sinkhole.json }
      register: sink_log_24
    - name: Disk pct (.140)        # standard df pattern
    - name: Disk detail (.140)
```

T-Pot existing play gains `wazuh-agent` in its service loop:
```yaml
loop: [tpot, wazuh-agent]
```

Summary table gains `.140 canary` section ([OK]/[FAIL] per service, port count vs expected 22, log-file existence). Wazuh agent-count drift assert (existing) updates threshold 4 → 7.

New fail asserts (same structure as existing tiered fail tasks):
- `Fail if canary services down` — any inactive of opencanary/sinkhole/wazuh-agent on `.140`
- `Fail if canary port count drifted` — `ports_24 < 22`
- `Fail if canary log files missing` — neither stat exists (means OpenCanary or sinkhole never wrote anything; OpenCanary writes initialization line on startup)

Display thresholds use the same WARN-in-summary / FAIL-in-assert pattern. Templating uses inline ternary or `{% endif +%}` (see `feedback/jinja-trim-blocks-fix.md`).

## 7. Disaster recovery + runbooks

### `.140` full rebuild

1. VBoxManage create on `.15` (Debian 12 minimal ISO already staged on `.15` from existing VM builds; `.15` now runs Ubuntu 24.04 — see runbooks/hypervisor-15.md)
2. One-time manual install: hostname `fileserver01`, static IP `.140`, openwrt pubkey to `/root/.ssh/authorized_keys`, create/run the VM as the `.15` admin user (`andrei`)
3. Manual Wazuh agent install + enroll to `.133` (matches existing convention — agent install out-of-band)
4. `ansible-playbook playbooks/site.yml --limit canary` → role reproduces everything (OpenCanary venv, sinkhole files, share decoys, systemd units, localfile blocks)
5. Verify via `playbooks/ops/health-check.yml`

Runbook: new `docs/runbooks/canary-140-rebuild.md`.

### T-Pot Wazuh agent loss (e.g. after T-Pot upgrade)

1. Re-install Wazuh agent on `.130` and/or `.125`, re-enroll to `.133`
2. `ansible-playbook playbooks/site.yml --limit tpot` → restores localfile `blockinfile` blocks
3. Verify via `health-check.yml` (agent count returns to 7)

Runbook: extend existing `docs/runbooks/tpot-rebuild.md` with "Wazuh agent (post-rebuild step)" section.

### `.120` cutover rollback

`state: absent` tasks are reversible from git — `git revert` the cutover commit, re-converge `.120`. Data-loss window: any hits to `.121` between cutover and rollback (acceptable; testable on a quiet hour).

### Backup coverage

- Ansible-managed config: existing soc-ansible OneDrive bundle covers everything (no new step)
- VM image: one-time VBox export of `.140` after first successful run → `C:\Users\xndre\OneDrive\Claude\backup\vms\fileserver01-YYYYMMDD.ova` (~500 MB compressed; skipped on incremental refreshes since config is reproducible)
- OpenCanary/sinkhole logs: already in Wazuh archives on `.133`; no separate backup

### Sleep policy

`soc-sleep-savestate.ps1` gets a one-line skip: `if ($vm -eq 'fileserver01') { continue }` — 24/7 canary. Documented in `docs/runbooks/canary-140-rebuild.md` so a future power-script refactor doesn't silently re-enable nightly shutdown.

## 8. Verification plan (post-deploy)

| From | Command | Expected | Confirms |
|---|---|---|---|
| `.120` | `nmap -sV 192.168.1.140` | Banners on 8 ports, RST on others | OpenCanary banner emulation live |
| `.13` | `smbclient -L \\\\fileserver01 -N` | HR/Backups/IT shares visible | SMB decoy + ntfy lvl 12 |
| `.13` | `curl http://fileserver01/` | NAS login page | HTTP decoy + ntfy lvl 10 |
| `.13` | `nmap -p 4444 192.168.1.140` | Connect logged | sinkhole.py + ntfy lvl 12 |
| `.13` | `nmap -p 22 192.168.1.130` | T-Pot Cowrie SSH banner | T-Pot tap + ntfy lvl 12 |
| any | second hit from same `.13` in same hour | No second ntfy | Dedup working |
| `.120` | `ansible-playbook playbooks/ops/health-check.yml` | All canary checks `[OK]`, agent count = 7 | Health-check integration |

## 9. Memory updates (post-deploy)

- New `soc-lab/canary.md` — host inventory, ports, OpenCanary config, sinkhole PORTS list, rule IDs (`1003xx`/`1004xx`), alert path, ntfy script location
- Update `soc-lab/infrastructure.md` — add `.140 fileserver01` to host list; add to MEMORY.md Core Facts active-projects line
- Update `soc-lab/ansible.md` — Latest commit pointer + add `canary` to roles list in repo layout
- Update `soc-lab/tpot.md` — Wazuh agent + localfile pattern + which honeypots are tapped
- New `feedback/recon-list-systemd-services.md` — "during host recon, list `/etc/systemd/system/*.service` directly; do NOT trust `grep keyword` — it missed the existing `sinkhole.service` for ~2 months and almost led to a duplicate canary deployment"

## 10. Implementation notes

- **OpenCanary install** via pip in venv (`/opt/opencanary-venv`). Debian 12 ships Python 3.11.2 — sufficient. Thinkst's .deb not used; venv is more portable / explicit.
- **Wazuh manager field-name confirmation:** OpenCanary's JSON field paths (`logdata.local_host`, `logdata.src_host`, `logdata.dst_port`, `logdata.USERNAME`) come from docs but exact decoded paths are empirical. Before committing manager rules: capture a sample line from `/var/tmp/opencanary.log` after a test hit, run `printf '<json>' | /var/ossec/bin/wazuh-logtest -q` on `.133`, adjust the pcre2 `field name=` paths if the decoder produces different keys. Same approach used for Zeek `1002xx`.
- **Cutover ordering:** decommission `.121`/`sinkhole.service` on `.120` ONLY AFTER `.140` is verified live (nmap from `.13` hits `.140`, ntfy fires) — avoids a coverage gap.
- **`--tags` gotcha:** per `[[ansible]]` and `[[zeek]]` history, `--tags <role>` often only triggers fact-gathering when role tasks aren't individually tagged. Default to untagged `--limit <host>` runs for this role. Document in role README.
- **ansible-lint:** must pass at `production` profile (existing repo standard).
- **Jinja in health-check summary:** if conditionals are added to display lines, use inline ternary or `{% endif +%}` per `feedback/jinja-trim-blocks-fix.md` to avoid the `trim_blocks` newline-eating.
