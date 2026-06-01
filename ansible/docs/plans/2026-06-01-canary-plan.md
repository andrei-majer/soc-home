# Internal Canary on `.140` + T-Pot → Wazuh Pipe — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy an internal trip-wire canary on a new dedicated VM `.140 fileserver01` (OpenCanary banner emulation + relocated `sinkhole.py` for C2/exotic ports), pipe T-Pot internal-source hits into the main Wazuh/ntfy pipeline, and decommission the unmanaged `.121` alias + `sinkhole.service` from `.120` in the same change-set.

**Architecture:** New Ansible role `canary` deploys OpenCanary (Python venv, 8 banner ports: FTP/Telnet/HTTP/HTTPS/SMB/MySQL/RDP/VNC with 3 fake shares) and the relocated `sinkhole.py` (14 C2 ports with the 7 overlapping ports trimmed) on `.140`. Wazuh agent on `.140` ships both log files to `.133`; new manager rules `1003xx` tier alerts by port (lvl 10 banner, lvl 12 critical/cred) with hourly per-source-IP dedup. T-Pot tap extends the existing `tpot` role with a `blockinfile` adding 6 JSON honeypot localfiles to `/var/ossec/etc/ossec.conf` on `.130` and `.125`; new rules `1004xx` filter on `^192\.168\.1\.` source IPs so only LAN-source hits page (external internet noise stays in T-Pot's own Kibana on `.130:64297`). All wired into the existing `custom-ntfy` integration on `.133` by extending the integration's `<rule_id>` list. Cutover on `.120` removes `.121` alias + `sinkhole.service` files via `state: absent` after `.140` is verified live, gated to `inventory_hostname == 'suricata-120'`.

**Tech Stack:** Ansible (production lint profile), OpenCanary (pip in `/opt/opencanary-venv`), `sinkhole.py` (Python 3.11 asyncio), Wazuh agent/manager 4.14.5, ntfy.sh (`wazuh-Qzwhd0BgI6pQDaxb` topic), VirtualBox 7.2 on `.15`, Debian 12 minimal.

**Spec:** `/opt/soc-ansible/docs/specs/2026-06-01-canary-design.md` (commit `48d38f2`)

---

## Phase 1 — Provision `.140` VM

### Task 1.1: Create VirtualBox VM on `.15`

**Files:**
- Manual one-time (no files in repo): VBoxManage commands on `.15`

- [ ] **Step 1: SSH into `.15` as `Games`**

```powershell
ssh -i $env:USERPROFILE\.ssh\openwrt Games@192.168.1.15
```

- [ ] **Step 2: Create the VM via VBoxManage**

In the SSH session on `.15`, run (paths split for readability):

```bash
VBOX='C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
"$VBOX" createvm --name fileserver01 --ostype Debian_64 --register
"$VBOX" modifyvm fileserver01 \
  --cpus 1 --memory 768 --vram 16 \
  --nic1 bridged --bridgeadapter1 'Intel(R) Ethernet Connection I219-V' \
  --nictype1 virtio --macaddress1 auto \
  --boot1 dvd --boot2 disk --boot3 none --boot4 none \
  --audio-driver none --usb on --usbohci on --vrde on --vrdeport 3391
"$VBOX" createmedium disk --filename "%USERPROFILE%\VirtualBox VMs\fileserver01\fileserver01.vdi" --size 4096 --variant Standard
"$VBOX" storagectl fileserver01 --name SATA --add sata --portcount 2
"$VBOX" storageattach fileserver01 --storagectl SATA --port 0 --device 0 --type hdd --medium "%USERPROFILE%\VirtualBox VMs\fileserver01\fileserver01.vdi" --nonrotational on --discard on
"$VBOX" storageattach fileserver01 --storagectl SATA --port 1 --device 0 --type dvddrive --medium "%USERPROFILE%\Downloads\debian-12-netinst.iso"
```

If `debian-12-netinst.iso` is not in Downloads, fetch it first from `https://www.debian.org/CD/netinst/`. Bridge adapter name must match the L1 NIC (`Intel I219-V`) — verify with `"$VBOX" list bridgedifs | findstr Intel`.

- [ ] **Step 3: Verify VM is registered**

```bash
"$VBOX" list vms | grep fileserver01
```

Expected: `"fileserver01" {<uuid>}`

- [ ] **Step 4: Start the VM headless and connect VRDE for install**

```bash
"$VBOX" startvm fileserver01 --type headless
```

VRDE listens on `.15:3391`. From `.13`, connect via `mstsc /v:192.168.1.15:3391`.

- [ ] **Step 5: No commit (manual setup, not tracked in IaC)**

---

### Task 1.2: Install Debian 12 minimal on `.140`

**Files:** Manual (Debian installer GUI / curses over VRDE)

- [ ] **Step 1: Walk through Debian installer**

Settings:
- Language/locale/keyboard: en_US, default
- Hostname: `fileserver01`
- Domain: leave blank
- Root password: random strong (record in vault later)
- User: skip (root-only is fine for this single-purpose host)
- Partitioning: guided, use entire disk, all in one partition (no LVM, no encryption)
- Software selection: **uncheck everything except** `SSH server` and `standard system utilities`
- GRUB: install to `/dev/sda`

- [ ] **Step 2: Configure static IP**

Reboot. Log in as root via VRDE console. Edit `/etc/network/interfaces`:

```
auto enp0s3
iface enp0s3 inet static
    address 192.168.1.140/24
    gateway 192.168.1.1
    dns-nameservers 192.168.1.1
```

Then:
```bash
systemctl restart networking
ip addr show enp0s3 | grep 192.168.1.140
```

Expected output line: `inet 192.168.1.140/24 ...`

- [ ] **Step 3: Verify outbound reachability**

```bash
ping -c 2 192.168.1.1
ping -c 2 deb.debian.org
```

Both expected: 0% packet loss.

- [ ] **Step 4: Install minimal toolset**

```bash
apt-get update
apt-get install -y python3-venv python3-pip ca-certificates curl
```

- [ ] **Step 5: No commit (manual install, not tracked)**

---

### Task 1.3: Add `openwrt` pubkey to `.140` and verify SSH

**Files:** `~/.ssh/authorized_keys` on `.140` (manual)

- [ ] **Step 1: From `.120`, push the existing Ansible control pubkey to `.140`**

On `.120`:
```bash
cat ~/.ssh/id_ed25519.pub
```

Copy the output. From `.13` workstation:
```powershell
$pubkey = ssh -i $env:USERPROFILE\.ssh\openwrt root@192.168.1.120 'cat /root/.ssh/id_ed25519.pub'
ssh-copy-id  # not available on Windows — use:
ssh -o StrictHostKeyChecking=no root@192.168.1.140 "mkdir -p /root/.ssh && echo '$pubkey' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
```

(Initial SSH will prompt for the root password set in Task 1.2.)

Also add the `openwrt` (admin) key for direct admin access from `.13`:
```powershell
$openwrt = Get-Content $env:USERPROFILE\.ssh\openwrt.pub
ssh root@192.168.1.140 "echo '$openwrt' >> /root/.ssh/authorized_keys"
```

- [ ] **Step 2: Verify passwordless SSH from `.120`**

On `.120`:
```bash
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 root@192.168.1.140 'hostname; cat /etc/debian_version'
```

Expected: `fileserver01\n12.X`

- [ ] **Step 3: Verify passwordless SSH from `.13`**

```powershell
ssh -i $env:USERPROFILE\.ssh\openwrt root@192.168.1.140 'hostname'
```

Expected: `fileserver01`

- [ ] **Step 4: No commit (manual setup)**

---

### Task 1.4: Add `.140` to Ansible inventory and run `common` role

**Files:**
- Modify: `/opt/soc-ansible/inventory/hosts.yml`
- Create: `/opt/soc-ansible/inventory/host_vars/fileserver-140/main.yml`

- [ ] **Step 1: Read current inventory structure**

On `.120`:
```bash
cat /opt/soc-ansible/inventory/hosts.yml
```

Locate the `debian:` group. The plan's next step shows the diff that needs adding.

- [ ] **Step 2: Add `fileserver-140` to inventory under `debian` group and new `canary` group**

Edit `/opt/soc-ansible/inventory/hosts.yml`. Add to the existing `debian:` group's `hosts:` block:

```yaml
    fileserver-140:
      ansible_host: 192.168.1.140
```

Add a new top-level group at the bottom of the file:

```yaml
canary:
  hosts:
    fileserver-140:
```

- [ ] **Step 3: Create the host_vars directory and main.yml**

```bash
mkdir -p /opt/soc-ansible/inventory/host_vars/fileserver-140
cat > /opt/soc-ansible/inventory/host_vars/fileserver-140/main.yml <<'EOF'
---
# fileserver-140 — internal canary host (see docs/specs/2026-06-01-canary-design.md)
# No host-specific vars beyond ansible_host (inherited from inventory).
EOF
```

- [ ] **Step 4: Verify Ansible can reach the host**

```bash
cd /opt/soc-ansible
ansible fileserver-140 -m ping
```

Expected:
```
fileserver-140 | SUCCESS => {
    "ansible_facts": {"discovered_interpreter_python": "/usr/bin/python3"},
    "changed": false,
    "ping": "pong"
}
```

- [ ] **Step 5: Run the `common` role against `.140`**

```bash
ansible-playbook playbooks/site.yml --limit fileserver-140 --tags common
```

Expected: `ok=N changed=≤M failed=0`. The `common` role installs the base packages, journald cap, disk-alert script, SSH keys, timezone. Repeat run should show `changed=0` (idempotent).

- [ ] **Step 6: Lint and commit inventory**

```bash
cd /opt/soc-ansible
ansible-lint inventory/hosts.yml inventory/host_vars/fileserver-140/
git add inventory/hosts.yml inventory/host_vars/fileserver-140/
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'inventory: add fileserver-140 (.140) canary host

New VM on .15, Debian 12 minimal, 1 vCPU / 768MB / 4GB. Joins `debian` group
(inherits group_vars/debian.yml) and new `canary` group for the role play
added in a later commit. Common role converged 0 changed on repeat.'
```

Mirror push deferred to a later batch commit (see Task 10.x).

---

## Phase 2 — `canary` role: OpenCanary daemon

### Task 2.1: Scaffold `roles/canary/` structure

**Files:**
- Create: `/opt/soc-ansible/roles/canary/{defaults,files,handlers,tasks,templates}/`

- [ ] **Step 1: Create the role directory tree**

```bash
cd /opt/soc-ansible
mkdir -p roles/canary/{defaults,files/share-decoys/{HR,Backups,IT},handlers,tasks,templates}
```

- [ ] **Step 2: Create the role's README.md**

```bash
cat > roles/canary/README.md <<'EOF'
# canary

Internal trip-wire canary on `.140 fileserver01`. Runs OpenCanary (8 banner
ports + 3 fake SMB shares) and the relocated `sinkhole.py` (14 C2 ports).
Feeds `/var/tmp/opencanary.log` and `/var/log/sinkhole.json` into the local
Wazuh agent, which ships to `.133:1514`. Manager rules `1003xx` page ntfy on
LAN-source hits (lvl 10 banner, lvl 12 critical/cred), per-src-IP hourly dedup.

The role also contains a cutover task block (gated on
`inventory_hostname == 'suricata-120'`) that removes the legacy `.121` alias
+ `sinkhole.service` from .120. See `docs/specs/2026-06-01-canary-design.md`.

## --tags gotcha

The role's tasks are NOT individually tagged. `--tags canary` only fires
fact-gathering. Deploy untagged: `ansible-playbook playbooks/site.yml
--limit fileserver-140`.

## Deploy

    ansible-playbook playbooks/site.yml --limit canary

## Verify

    ansible-playbook playbooks/ops/health-check.yml --limit fileserver-140
EOF
```

- [ ] **Step 3: Lint the empty role**

```bash
cd /opt/soc-ansible
ansible-lint roles/canary/
```

Expected: `0 failure(s), 0 warning(s)` (an empty role is lint-clean).

- [ ] **Step 4: Commit scaffold**

```bash
git add roles/canary/
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'canary: scaffold role directory + README'
```

---

### Task 2.2: Write `defaults/main.yml` with role variables

**Files:**
- Create: `/opt/soc-ansible/roles/canary/defaults/main.yml`

- [ ] **Step 1: Write defaults**

```yaml
---
# OpenCanary
canary_opencanary_venv: /opt/opencanary-venv
canary_opencanary_user: opencanary
canary_opencanary_log: /var/tmp/opencanary.log
canary_opencanary_config: /etc/opencanaryd/opencanary.conf

# OpenCanary modules enabled (port = default for each module).
# SSH module deliberately NOT enabled — real sshd on :22 for Ansible/admin.
canary_modules:
  ftp:     {port: 21}
  telnet:  {port: 23}
  http:    {port: 80}
  https:   {port: 443}
  smb:     {port: 445}
  mysql:   {port: 3306}
  rdp:     {port: 3389}
  vnc:     {port: 5900}

# SMB fake shares (served from the decoy dir below)
canary_smb_share_dir: /srv/smb-decoys
canary_smb_shares: [HR, Backups, IT]

# sinkhole.py (relocated from .120)
canary_sinkhole_bin: /usr/local/bin/sinkhole.py
canary_sinkhole_log: /var/log/sinkhole.json
canary_sinkhole_ports:
  - 25
  - 465
  - 587
  - 1080
  - 1337
  - 31337
  - 4444
  - 4445
  - 4449
  - 6667
  - 6697
  - 8443
  - 8888
  - 9001

# Total expected listening ports (for health-check)
canary_expected_port_count: 22  # 8 OpenCanary + 14 sinkhole
```

Save as `/opt/soc-ansible/roles/canary/defaults/main.yml`.

- [ ] **Step 2: Lint**

```bash
cd /opt/soc-ansible
ansible-lint roles/canary/
```

Expected: `0 failure(s)`.

- [ ] **Step 3: Commit**

```bash
git add roles/canary/defaults/main.yml
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'canary: defaults/main.yml — modules, ports, share names'
```

---

### Task 2.3: Write the OpenCanary systemd unit and config template

**Files:**
- Create: `/opt/soc-ansible/roles/canary/files/opencanary.service`
- Create: `/opt/soc-ansible/roles/canary/templates/opencanary.conf.j2`

- [ ] **Step 1: Write the systemd unit**

```ini
[Unit]
Description=OpenCanary internal trip-wire
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/opt/opencanary-venv/bin/opencanaryd --dev --uid=root --gid=root
Restart=on-failure
RestartSec=10
StandardOutput=append:/var/tmp/opencanary.log
StandardError=append:/var/tmp/opencanary.log

[Install]
WantedBy=multi-user.target
```

Save as `/opt/soc-ansible/roles/canary/files/opencanary.service`.

(`--dev` runs in foreground without daemonizing — required for systemd `Type=simple`. `--uid/--gid=root` is needed because the SMB/HTTPS/RDP modules bind privileged ports.)

- [ ] **Step 2: Write the OpenCanary config template**

```jinja
{
    "device.node_id": "fileserver01-140",
    "ip.ignorelist": [],
    "logger": {
        "class": "PyLogger",
        "kwargs": {
            "handlers": {
                "file": {
                    "class": "logging.FileHandler",
                    "filename": "{{ canary_opencanary_log }}"
                }
            }
        }
    },

    "ftp.enabled": true,
    "ftp.port": {{ canary_modules.ftp.port }},
    "ftp.banner": "FTP server ready",

    "telnet.enabled": true,
    "telnet.port": {{ canary_modules.telnet.port }},
    "telnet.banner": "Welcome to fileserver01",

    "http.enabled": true,
    "http.port": {{ canary_modules.http.port }},
    "http.banner": "Apache/2.4.41 (Ubuntu)",
    "http.skin": "nasLogin",

    "https.enabled": true,
    "https.port": {{ canary_modules.https.port }},
    "https.skin": "nasLogin",

    "smb.enabled": true,
    "smb.port": {{ canary_modules.smb.port }},
    "smb.netbiosname": "FILESERVER01",
    "smb.serverstring": "fileserver01 backup share",
    "smb.domain": "WORKGROUP",
    "smb.filelist": [
{% for share in canary_smb_shares %}
        {
            "name": "{{ share }}",
            "type": "folder",
            "path": "{{ canary_smb_share_dir }}/{{ share }}"
        }{% if not loop.last %},{% endif %}
{% endfor %}
    ],

    "mysql.enabled": true,
    "mysql.port": {{ canary_modules.mysql.port }},
    "mysql.banner": "5.7.42-0ubuntu0.18.04.1",

    "rdp.enabled": true,
    "rdp.port": {{ canary_modules.rdp.port }},

    "vnc.enabled": true,
    "vnc.port": {{ canary_modules.vnc.port }},

    "ssh.enabled": false,

    "portscan.enabled": true,
    "portscan.synrate": 5,
    "portscan.nmaposrate": 5,
    "portscan.lorate": 3
}
```

Save as `/opt/soc-ansible/roles/canary/templates/opencanary.conf.j2`.

(Note: not every OpenCanary version supports every config key — the install task will run `opencanaryd --copyconfig` on first deploy to surface unknown keys, and the implementer trims any rejected keys.)

- [ ] **Step 3: Lint**

```bash
cd /opt/soc-ansible
ansible-lint roles/canary/
```

Expected: `0 failure(s)`. (Linting Jinja inside `.j2` is light, mostly checks for syntax-level errors.)

- [ ] **Step 4: Commit**

```bash
git add roles/canary/files/opencanary.service roles/canary/templates/opencanary.conf.j2
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'canary: opencanary systemd unit + config template (8 banner ports + 3 SMB shares)'
```

---

### Task 2.4: Write OpenCanary install + config tasks

**Files:**
- Create: `/opt/soc-ansible/roles/canary/handlers/main.yml`
- Create: `/opt/soc-ansible/roles/canary/tasks/main.yml` (initial draft — OpenCanary section only; sinkhole + cutover sections come in later tasks)

- [ ] **Step 1: Write handlers**

```yaml
---
- name: Restart opencanary
  ansible.builtin.systemd:
    name: opencanary
    state: restarted

- name: Restart sinkhole
  ansible.builtin.systemd:
    name: sinkhole
    state: restarted

- name: Restart wazuh-agent
  ansible.builtin.systemd:
    name: wazuh-agent
    state: restarted

- name: Reload systemd
  ansible.builtin.systemd:
    daemon_reload: true
```

Save as `/opt/soc-ansible/roles/canary/handlers/main.yml`.

- [ ] **Step 2: Write the main tasks file with OpenCanary install + config**

```yaml
---
# ============================================================================
# Cutover block — remove legacy sinkhole from .120 (see Task 8.x)
# Gated section appended later; lives at the BOTTOM of this file so .140
# tasks run unconditionally first.
# ============================================================================

# ============================================================================
# OpenCanary install + config (.140 only)
# ============================================================================

- name: Install OpenCanary system dependencies
  ansible.builtin.apt:
    name:
      - python3-venv
      - python3-pip
      - libssl-dev
      - libffi-dev
      - build-essential
      - samba   # provides smbpasswd which OpenCanary's SMB module needs
    state: present
    update_cache: true
  when: inventory_hostname in groups['canary']

- name: Create OpenCanary venv
  ansible.builtin.command: python3 -m venv {{ canary_opencanary_venv }}
  args:
    creates: "{{ canary_opencanary_venv }}/bin/python"
  when: inventory_hostname in groups['canary']

- name: Upgrade pip in OpenCanary venv
  ansible.builtin.pip:
    name: pip
    state: latest
    virtualenv: "{{ canary_opencanary_venv }}"
  when: inventory_hostname in groups['canary']

- name: Install OpenCanary into venv
  ansible.builtin.pip:
    name: opencanary
    state: present
    virtualenv: "{{ canary_opencanary_venv }}"
  when: inventory_hostname in groups['canary']

- name: Ensure /etc/opencanaryd exists
  ansible.builtin.file:
    path: /etc/opencanaryd
    state: directory
    mode: '0755'
  when: inventory_hostname in groups['canary']

- name: Deploy OpenCanary config
  ansible.builtin.template:
    src: opencanary.conf.j2
    dest: "{{ canary_opencanary_config }}"
    mode: '0644'
  notify: Restart opencanary
  when: inventory_hostname in groups['canary']

- name: Deploy OpenCanary systemd unit
  ansible.builtin.copy:
    src: opencanary.service
    dest: /etc/systemd/system/opencanary.service
    mode: '0644'
  notify:
    - Reload systemd
    - Restart opencanary
  when: inventory_hostname in groups['canary']

- name: Ensure OpenCanary log file exists with correct mode
  ansible.builtin.file:
    path: "{{ canary_opencanary_log }}"
    state: touch
    mode: '0640'
    modification_time: preserve
    access_time: preserve
  when: inventory_hostname in groups['canary']

- name: Enable and start opencanary.service
  ansible.builtin.systemd:
    name: opencanary
    enabled: true
    state: started
    daemon_reload: true
  when: inventory_hostname in groups['canary']

- name: Wait for OpenCanary to listen on key ports
  ansible.builtin.wait_for:
    host: 192.168.1.140
    port: "{{ item }}"
    timeout: 30
  loop: [21, 80, 445, 3306]
  when: inventory_hostname in groups['canary']
```

Save as `/opt/soc-ansible/roles/canary/tasks/main.yml`.

- [ ] **Step 3: Add canary play to site.yml**

Edit `/opt/soc-ansible/playbooks/site.yml`. Find the last play and add at the bottom:

```yaml
- name: Canary host (.140 fileserver01)
  hosts: canary
  become: true
  roles:
    - common
    - canary
```

- [ ] **Step 4: Lint**

```bash
cd /opt/soc-ansible
ansible-lint
```

Expected: `0 failure(s), 0 warning(s)` at production profile.

- [ ] **Step 5: Dry-run to inspect what will change**

```bash
cd /opt/soc-ansible
ansible-playbook playbooks/site.yml --limit fileserver-140 --check --diff
```

Expected: tasks listed as `changed` for apt, venv create, pip install, config deploy, unit deploy, systemd enable/start.

- [ ] **Step 6: Live converge**

```bash
ansible-playbook playbooks/site.yml --limit fileserver-140
```

Expected: `ok=N changed=M failed=0`. If OpenCanary's `--copyconfig` complains about unknown config keys during start, capture the error from `journalctl -u opencanary -n 50` on `.140`, trim the offending keys from `opencanary.conf.j2`, re-run.

- [ ] **Step 7: Verify listening ports**

```bash
ssh -i ~/.ssh/id_ed25519 root@192.168.1.140 'ss -tlnp | grep -E ":(21|23|80|443|445|3306|3389|5900) " | sort -k4'
```

Expected: 8 lines, all `0.0.0.0:<port>` or `*:<port>`, all owned by `opencanaryd`.

- [ ] **Step 8: Re-run for idempotence check**

```bash
ansible-playbook playbooks/site.yml --limit fileserver-140
```

Expected: `changed=0`.

- [ ] **Step 9: Commit**

```bash
git add roles/canary/handlers/main.yml roles/canary/tasks/main.yml playbooks/site.yml
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'canary: install + run opencanaryd on .140 (8 banner ports live)

Tasks gated on inventory_hostname in groups[canary] so the .120 cutover
block (added later) shares the same role file without cross-contamination.
Idempotent: 0 changed on re-run. Verified opencanaryd listening on 21/23/80/
443/445/3306/3389/5900.'
```

---

### Task 2.5: Generate SMB decoy file tree and deploy it

**Files:**
- Create: `/opt/soc-ansible/roles/canary/files/share-decoys/HR/*.{xlsx,docx,pdf,csv}`
- Create: `/opt/soc-ansible/roles/canary/files/share-decoys/Backups/*.{bak,tar.gz,sql.gz}`
- Create: `/opt/soc-ansible/roles/canary/files/share-decoys/IT/*.{pdf,txt,docx}`
- Modify: `/opt/soc-ansible/roles/canary/tasks/main.yml` (add decoy deploy task)

- [ ] **Step 1: Generate decoy files locally on `.120`**

```bash
cd /opt/soc-ansible/roles/canary/files/share-decoys

# HR — plausibly named, empty/tiny
for f in employee_records_2026.xlsx payroll_q1_2026.xlsx contracts_signed.pdf staff_directory.docx pto_balances.csv 'new_hires_2026.xlsx' performance_reviews_2025.pdf onboarding_checklist.docx contractor_rates.xlsx leave_policy_v3.pdf; do
  : > "HR/$f"
done

# Backups — random binary content (looks like real backups but is garbage)
for f in domain_controller_2026-04-01.bak file_share_2026-04-01.tar.gz mariadb_misp_2026-04-01.sql.gz exchange_mailboxes_2026-03-15.bak adsync_config_2026-03-01.tar.gz dns_zones_2026-04-01.tar.gz gpo_backup_2026-03-15.tar.gz nas_full_2026-04-01.bak certs_p12_2026-03-15.tar.gz scripts_archive_2026-04-01.tar.gz; do
  dd if=/dev/urandom of="Backups/$f" bs=1K count=$((RANDOM % 50 + 10)) status=none
done

# IT — credentials-flavored bait, no real values
for f in network_diagram.pdf vpn_config_notes.txt admin_passwords.txt wifi_keys.txt firewall_rules_export.txt server_inventory.xlsx sccm_creds.txt vmware_admin.txt switch_configs.txt printer_admin.txt; do
  case "$f" in
    *.txt) echo "see internal wiki" > "IT/$f" ;;
    *) : > "IT/$f" ;;
  esac
done

ls HR/ Backups/ IT/ | wc -l
```

Expected: `30` (or thereabouts).

- [ ] **Step 2: Add deploy task to `roles/canary/tasks/main.yml`**

Edit `/opt/soc-ansible/roles/canary/tasks/main.yml`. After the `Enable and start opencanary.service` task but BEFORE the `wait_for` task, insert:

```yaml
- name: Ensure SMB share root exists
  ansible.builtin.file:
    path: "{{ canary_smb_share_dir }}"
    state: directory
    mode: '0755'
  when: inventory_hostname in groups['canary']

- name: Deploy SMB decoy file tree
  ansible.posix.synchronize:
    src: share-decoys/
    dest: "{{ canary_smb_share_dir }}/"
    delete: true
    recursive: true
  delegate_to: "{{ inventory_hostname }}"
  notify: Restart opencanary
  when: inventory_hostname in groups['canary']
```

Note: `ansible.posix.synchronize` requires `rsync` on both ends. If not present on `.140`, install via the apt task in Step 2 of Task 2.4 (add `rsync` to the package list) and re-run.

Alternative if synchronize is fragile: use `ansible.builtin.copy` with directory recursion:

```yaml
- name: Deploy SMB decoy file tree (copy variant)
  ansible.builtin.copy:
    src: share-decoys/
    dest: "{{ canary_smb_share_dir }}/"
    mode: '0644'
    directory_mode: '0755'
  notify: Restart opencanary
  when: inventory_hostname in groups['canary']
```

- [ ] **Step 3: Lint**

```bash
cd /opt/soc-ansible
ansible-lint
```

Expected: `0 failure(s)`. (Suppress `risky-file-permissions` if it flags — decoys are world-readable on purpose for browsable shares.)

- [ ] **Step 4: Converge**

```bash
ansible-playbook playbooks/site.yml --limit fileserver-140
```

Expected: 30 files synced, `changed=N failed=0`.

- [ ] **Step 5: Verify SMB shares are visible**

From `.13`:
```powershell
# enable temporary anonymous SMB client (test only)
smbclient -L 192.168.1.140 -N
```

(If `smbclient` not installed: `apt install smbclient` on `.120` and run from there.)

Expected output should list `HR`, `Backups`, `IT` shares.

- [ ] **Step 6: Verify a share lists files**

From `.13` or `.120`:
```bash
smbclient //192.168.1.140/HR -N -c 'ls'
```

Expected: list of HR/* filenames.

- [ ] **Step 7: Idempotence re-run**

```bash
ansible-playbook playbooks/site.yml --limit fileserver-140
```

Expected: `changed=0`.

- [ ] **Step 8: Commit**

```bash
git add roles/canary/files/share-decoys/ roles/canary/tasks/main.yml
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'canary: SMB decoy file tree (HR/Backups/IT, ~30 files)

Plausibly-named empty xlsx/docx/pdf for HR, random-byte .bak/.tar.gz/.sql.gz
for Backups (looks like real backup output), and bait-y .txt/.pdf for IT
with no real credentials. Goal: invite enumeration, page on access.'
```

---

## Phase 3 — Sinkhole migration to `.140`

### Task 3.1: Copy `sinkhole.py` (trimmed) + systemd unit into the role and deploy

**Files:**
- Create: `/opt/soc-ansible/roles/canary/files/sinkhole.py`
- Create: `/opt/soc-ansible/roles/canary/files/sinkhole.service`
- Modify: `/opt/soc-ansible/roles/canary/tasks/main.yml` (sinkhole section)

- [ ] **Step 1: Copy current `sinkhole.py` from `.120` to the role and trim PORTS**

On `.120`:
```bash
scp -i ~/.ssh/id_ed25519 /usr/local/bin/sinkhole.py /opt/soc-ansible/roles/canary/files/sinkhole.py
```

Edit `/opt/soc-ansible/roles/canary/files/sinkhole.py` — replace the `PORTS` list with:

```python
PORTS = [
    25, 465, 587,        # SMTP, SMTPS, submission
    1080,                # SOCKS
    1337, 31337,         # classic backdoor
    4444, 4445, 4449,    # Metasploit / C2
    6667, 6697,          # IRC, IRC-TLS
    8443, 8888,          # alt HTTP/S
    9001,                # Tor
]
```

Also update the SINKHOLE_IP constant from `192.168.1.121` to `192.168.1.140`:
```python
SINKHOLE_IP = "192.168.1.140"
```

And update the module docstring:
```python
"""TCP sinkhole listener on 192.168.1.140 (C2/exotic port set).
Logs all inbound connections as JSON -> /var/log/sinkhole.json.
Companion to OpenCanary on the same host — sinkhole covers C2/exotic ports
OpenCanary doesn't ship; OpenCanary covers banner-emulated service ports.
"""
```

- [ ] **Step 2: Copy systemd unit from `.120` and update it**

```bash
scp -i ~/.ssh/id_ed25519 root@192.168.1.120:/etc/systemd/system/sinkhole.service /opt/soc-ansible/roles/canary/files/sinkhole.service
```

Inspect and edit the file. Expected final content:
```ini
[Unit]
Description=TCP Sinkhole Listener (C2/exotic ports)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/sinkhole.py
Restart=on-failure
RestartSec=10
SyslogIdentifier=sinkhole

[Install]
WantedBy=multi-user.target
```

(The original on `.120` says `Description=DNS Sinkhole Listener` — updated to `TCP Sinkhole Listener (C2/exotic ports)` to reflect what it actually does after the migration.)

- [ ] **Step 3: Add sinkhole deploy tasks to `roles/canary/tasks/main.yml`**

After the OpenCanary `wait_for` task and before the cutover section (which doesn't exist yet — append for now), insert:

```yaml
# ============================================================================
# sinkhole.py + systemd unit (relocated from .120)
# ============================================================================

- name: Deploy sinkhole.py
  ansible.builtin.copy:
    src: sinkhole.py
    dest: "{{ canary_sinkhole_bin }}"
    mode: '0755'
  notify: Restart sinkhole
  when: inventory_hostname in groups['canary']

- name: Deploy sinkhole.service systemd unit
  ansible.builtin.copy:
    src: sinkhole.service
    dest: /etc/systemd/system/sinkhole.service
    mode: '0644'
  notify:
    - Reload systemd
    - Restart sinkhole
  when: inventory_hostname in groups['canary']

- name: Ensure sinkhole log file exists with correct mode
  ansible.builtin.file:
    path: "{{ canary_sinkhole_log }}"
    state: touch
    mode: '0640'
    modification_time: preserve
    access_time: preserve
  when: inventory_hostname in groups['canary']

- name: Enable and start sinkhole.service
  ansible.builtin.systemd:
    name: sinkhole
    enabled: true
    state: started
    daemon_reload: true
  when: inventory_hostname in groups['canary']

- name: Wait for sinkhole to listen on canonical port (4444)
  ansible.builtin.wait_for:
    host: 192.168.1.140
    port: 4444
    timeout: 30
  when: inventory_hostname in groups['canary']
```

- [ ] **Step 4: Lint and converge**

```bash
cd /opt/soc-ansible
ansible-lint
ansible-playbook playbooks/site.yml --limit fileserver-140 --check --diff
ansible-playbook playbooks/site.yml --limit fileserver-140
```

Expected: `failed=0`, sinkhole.service started.

- [ ] **Step 5: Verify sinkhole listening**

```bash
ssh -i ~/.ssh/id_ed25519 root@192.168.1.140 'ss -tlnp | grep python3 | wc -l'
```

Expected: `14` (sinkhole.py owns 14 ports).

Combined OpenCanary + sinkhole = 8 + 14 = 22 listening canary ports. Confirm:
```bash
ssh -i ~/.ssh/id_ed25519 root@192.168.1.140 'ss -tln | grep -v ":22 " | grep -c LISTEN'
```

Expected: `22`.

- [ ] **Step 6: Test a sinkhole hit logs JSON**

From `.13`:
```powershell
$nc = New-Object System.Net.Sockets.TcpClient
$nc.Connect("192.168.1.140", 4444)
$nc.Close()
```

On `.140`:
```bash
tail -1 /var/log/sinkhole.json
```

Expected: `{"timestamp":"...", "event":"sinkhole_hit", "client_ip":"192.168.1.13", "client_port":N, "dst_port":4444}`

- [ ] **Step 7: Idempotence**

```bash
ansible-playbook playbooks/site.yml --limit fileserver-140
```

Expected: `changed=0`.

- [ ] **Step 8: Commit**

```bash
git add roles/canary/files/sinkhole.py roles/canary/files/sinkhole.service roles/canary/tasks/main.yml
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'canary: deploy sinkhole.py (trimmed for .140) + systemd unit

Relocated from .120:.121 (the live original stays running until cutover —
phase 8 — to avoid coverage gap). PORTS list dropped 21/23/80/443/445/3389/
5900 (now owned by OpenCanary with banners) — keeps 14 C2/exotic ports.
SINKHOLE_IP changed to 192.168.1.140. Description updated from DNS Sinkhole
to TCP Sinkhole. Verified 22 canary ports listening (8 OpenCanary +
14 sinkhole).'
```

---

## Phase 4 — Wazuh agent on `.140` + manager rules `1003xx` + ntfy

### Task 4.1: Install Wazuh agent on `.140` (manual, one-time)

**Files:** Manual install on `.140` (not tracked in IaC, matches `.120` pattern)

- [ ] **Step 1: Add Wazuh apt repo on `.140`**

```bash
ssh -i ~/.ssh/id_ed25519 root@192.168.1.140
# inside .140:
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
apt-get update
```

- [ ] **Step 2: Install wazuh-agent pinned to 4.14.5 (matches manager)**

```bash
WAZUH_MANAGER='192.168.1.133' apt-get install -y wazuh-agent=4.14.5-1
```

(`WAZUH_MANAGER` env var causes the postinst to auto-fill the manager address in `/var/ossec/etc/ossec.conf`.)

Pin the package to prevent silent upgrades:
```bash
echo "wazuh-agent hold" | dpkg --set-selections
```

- [ ] **Step 3: Verify agent connects to manager**

```bash
systemctl enable wazuh-agent
systemctl start wazuh-agent
sleep 5
tail -20 /var/ossec/logs/ossec.log | grep -E 'Connected|Started thread'
```

Expected: `Connected to enrollment service` and `Started thread`.

- [ ] **Step 4: Confirm from manager side**

On `.133`:
```bash
ssh -i ~/.ssh/openwrt root@192.168.1.133 '/var/ossec/bin/agent_control -l | grep fileserver01'
```

Expected: one line listing fileserver01 / `192.168.1.140` / `Active`.

- [ ] **Step 5: Update host_vars to note agent install was done**

Edit `/opt/soc-ansible/inventory/host_vars/fileserver-140/main.yml` — add a comment:

```yaml
---
# fileserver-140 — internal canary host (see docs/specs/2026-06-01-canary-design.md)
# Wazuh agent 4.14.5 installed manually 2026-06-XX, pinned (`dpkg --set-selections hold`)
```

- [ ] **Step 6: Commit the host_vars update**

```bash
git add inventory/host_vars/fileserver-140/main.yml
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'inventory: note Wazuh agent install on fileserver-140'
```

---

### Task 4.2: Add Wazuh localfile blockinfile to canary role

**Files:**
- Modify: `/opt/soc-ansible/roles/canary/tasks/main.yml` (append wazuh-agent section)

- [ ] **Step 1: Append the localfile block to `roles/canary/tasks/main.yml`**

After the sinkhole `wait_for` task, append:

```yaml
# ============================================================================
# Wazuh agent localfile inputs (.140)
# Agent ossec.conf is not otherwise Ansible-managed — only the canary
# log inputs are added via blockinfile, same idiom as Zeek on .120.
# ============================================================================

- name: Add canary log inputs to Wazuh agent (.140)
  ansible.builtin.blockinfile:
    path: /var/ossec/etc/ossec.conf
    marker: "<!-- {mark} ANSIBLE MANAGED: canary localfiles -->"
    insertbefore: "</ossec_config>"
    block: |
      <localfile>
        <location>{{ canary_opencanary_log }}</location>
        <log_format>json</log_format>
      </localfile>
      <localfile>
        <location>{{ canary_sinkhole_log }}</location>
        <log_format>json</log_format>
      </localfile>
  notify: Restart wazuh-agent
  when: inventory_hostname in groups['canary']
```

- [ ] **Step 2: Lint and converge**

```bash
cd /opt/soc-ansible
ansible-lint
ansible-playbook playbooks/site.yml --limit fileserver-140 --diff
```

Expected: `changed=1` for the blockinfile, handler `Restart wazuh-agent` fires.

- [ ] **Step 3: Verify the agent restarts cleanly and re-connects**

```bash
ssh -i ~/.ssh/id_ed25519 root@192.168.1.140 'systemctl is-active wazuh-agent; tail -5 /var/ossec/logs/ossec.log'
```

Expected: `active`, log tail shows successful (re)connect.

- [ ] **Step 4: Verify agent is tailing the logs**

```bash
ssh -i ~/.ssh/id_ed25519 root@192.168.1.140 'grep -E "opencanary|sinkhole" /var/ossec/logs/ossec.log | tail'
```

Expected: log lines mentioning the new localfile paths (`Analyzing file: '/var/log/sinkhole.json'.`, etc.).

- [ ] **Step 5: Trigger a fresh hit + verify it reaches the manager**

From `.13`:
```powershell
$nc = New-Object System.Net.Sockets.TcpClient
$nc.Connect("192.168.1.140", 4444)
$nc.Close()
```

On `.133`:
```bash
ssh -i ~/.ssh/openwrt root@192.168.1.133 'tail -50 /var/ossec/logs/archives/archives.log | grep -E "sinkhole_hit|192.168.1.140"'
```

Expected: at least one event line containing `192.168.1.13` as the client and `4444` as the dst_port. If no `archives.log`, enable `<logall_plain>yes</logall_plain>` temporarily for the test.

- [ ] **Step 6: Commit**

```bash
git add roles/canary/tasks/main.yml
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'canary: add Wazuh agent localfile inputs (opencanary.log + sinkhole.json)

Same blockinfile idiom as Zeek on .120 — agent ossec.conf otherwise
not Ansible-managed, only the canary inputs come from IaC. Verified
the agent tails both files and events reach .133 manager.'
```

---

### Task 4.3: Add manager rules `1003xx` to `roles/wazuh-manager/files/local_rules.xml`

**Files:**
- Modify: `/opt/soc-ansible/roles/wazuh-manager/files/local_rules.xml`

- [ ] **Step 1: Capture a real OpenCanary JSON sample for field-path confirmation**

From `.13` trigger an FTP probe (banner module logs USERNAME on failed login):
```powershell
ssh -i $env:USERPROFILE\.ssh\openwrt root@192.168.1.140 'ftp -inv 192.168.1.140 <<EOF
user admin bait
quit
EOF
exit 0'  # ftp client returns non-zero on bad login, that's fine
```

On `.140`:
```bash
tail -5 /var/tmp/opencanary.log
```

Expected: at least one JSON line like:
```json
{"dst_host":"192.168.1.140","dst_port":21,"local_time":"2026-06-XX HH:MM:SS","logdata":{"LOCALVERSION":"...","REMOTEVERSION":"...","USERNAME":"admin","PASSWORD":"bait"},"logtype":2000,"node_id":"fileserver01-140","src_host":"192.168.1.13","src_port":N}
```

**Note:** OpenCanary's actual decoded path may be `src_host` at top level (not `logdata.src_host`). The spec used `logdata.src_host` as a placeholder. Use the real top-level keys from this output in the next step.

- [ ] **Step 2: Run wazuh-logtest with the sample**

Copy one JSON line. On `.133`:
```bash
echo '<paste the JSON line here>' | /var/ossec/bin/wazuh-logtest
```

Read the decoded fields under `**Decoder output**`. Use those exact field names in the rules below.

- [ ] **Step 3: Add the canary rules group to `local_rules.xml`**

Open `/opt/soc-ansible/roles/wazuh-manager/files/local_rules.xml`. Insert after the closing `</group>` of the last existing group (Zeek), before the file's final blank line:

```xml
<!-- ================================================================
     Canary trip-wire rules (100300-100309) — internal lateral movement
     Spec: docs/specs/2026-06-01-canary-design.md
     ================================================================ -->
<group name="canary,internal_tripwire,">

  <rule id="100300" level="3">
    <decoded_as>json</decoded_as>
    <field name="dst_host">192.168.1.140</field>
    <description>Canary hit on .140 (base)</description>
  </rule>

  <rule id="100301" level="10">
    <if_sid>100300</if_sid>
    <field name="src_host" type="pcre2">^192\.168\.1\.</field>
    <field name="dst_port" type="pcre2">^(21|23|80|443)$</field>
    <description>Canary banner-port hit from LAN: $(src_host) -> :$(dst_port)</description>
    <group>canary_banner,</group>
  </rule>

  <rule id="100302" level="12">
    <if_sid>100300</if_sid>
    <field name="src_host" type="pcre2">^192\.168\.1\.</field>
    <field name="dst_port" type="pcre2">^(445|3306|3389|5900|4444|4445|4449|6667|6697|9001|1337|31337)$</field>
    <description>Canary critical-port hit from LAN: $(src_host) -> :$(dst_port)</description>
    <group>canary_critical,</group>
  </rule>

  <rule id="100303" level="12">
    <if_sid>100300</if_sid>
    <field name="logdata.USERNAME" type="pcre2">.+</field>
    <description>Canary credential attempt captured: user=$(logdata.USERNAME)</description>
    <group>canary_creds,</group>
    <!-- intentionally NOT deduplicated — each unique credential pair is intel -->
  </rule>

  <rule id="100304" level="3" frequency="2" timeframe="3600" ignore="3600">
    <if_matched_sid>100301</if_matched_sid>
    <same_field>src_host</same_field>
    <description>Canary banner-port repeat from same source (dedup hourly)</description>
  </rule>

  <rule id="100305" level="3" frequency="2" timeframe="3600" ignore="3600">
    <if_matched_sid>100302</if_matched_sid>
    <same_field>src_host</same_field>
    <description>Canary critical-port repeat from same source (dedup hourly)</description>
  </rule>

  <!-- Sinkhole hits — same fields are `client_ip` and `dst_port` per sinkhole.py JSON.
       Separate parent so we don't have to alias field names. -->
  <rule id="100306" level="3">
    <decoded_as>json</decoded_as>
    <field name="event">^sinkhole_hit$</field>
    <description>Sinkhole hit on .140 (base)</description>
  </rule>

  <rule id="100307" level="12">
    <if_sid>100306</if_sid>
    <field name="client_ip" type="pcre2">^192\.168\.1\.</field>
    <description>Sinkhole C2-port hit from LAN: $(client_ip) -> :$(dst_port)</description>
    <group>canary_critical,</group>
  </rule>

  <rule id="100308" level="3" frequency="2" timeframe="3600" ignore="3600">
    <if_matched_sid>100307</if_matched_sid>
    <same_field>client_ip</same_field>
    <description>Sinkhole repeat from same source (dedup hourly)</description>
  </rule>

</group>
```

**If the wazuh-logtest output in Step 2 showed different field names** (e.g. nested under `data.` instead of top-level), update the `<field name=...>` paths in rules 100300/100301/100302/100303 to match before saving.

- [ ] **Step 4: Lint XML**

```bash
xmllint --noout /opt/soc-ansible/roles/wazuh-manager/files/local_rules.xml
```

Expected: no output (valid XML).

- [ ] **Step 5: Deploy the rules to the manager**

```bash
cd /opt/soc-ansible
ansible-playbook playbooks/site.yml --limit elk-133
```

**DEPLOY GOTCHA (per `[[ansible]]` memory):** `--tags wazuh-manager` only gathers facts (`ok=2 changed=0`); the wazuh-manager role tasks aren't tagged. Use untagged `--limit elk-133`.

Expected: `changed=1` for the rules file, `wazuh-manager` restarted via handler.

- [ ] **Step 6: Re-test the canary rules with wazuh-logtest on `.133`**

```bash
ssh -i ~/.ssh/openwrt root@192.168.1.133
# inside .133:
echo '<OpenCanary FTP creds sample JSON>' | /var/ossec/bin/wazuh-logtest
```

Expected: rule `100303` fires at level 12, group `canary_creds`. If not, the field path is wrong — adjust and re-deploy.

```bash
echo '{"event":"sinkhole_hit","client_ip":"192.168.1.13","client_port":54321,"dst_port":4444,"timestamp":"2026-06-XX"}' | /var/ossec/bin/wazuh-logtest
```

Expected: rule `100307` fires at level 12, group `canary_critical`.

- [ ] **Step 7: Commit**

```bash
git add roles/wazuh-manager/files/local_rules.xml
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'wazuh-manager: canary rules 1003xx (internal trip-wire)

100300/01/02/03 — OpenCanary tiered by port (lvl 10 banner, lvl 12 critical/cred).
100304/05/08 — hourly dedup per src_host/client_ip.
100306/07 — sinkhole.py base + LAN-source escalation.
Source-IP filter ^192\.168\.1\. so only LAN hits page. Creds rule intentionally
NOT deduplicated — each cred pair is intel. Field names verified via wazuh-logtest
against real OpenCanary + sinkhole.py JSON samples. See docs/specs/2026-06-01-
canary-design.md.'
```

---

### Task 4.4: Extend `custom-ntfy` integration to forward canary rules

**Files:**
- Modify: `/opt/soc-ansible/roles/wazuh-manager/templates/ossec.conf.j2` (locate the existing `<integration name="custom-ntfy">` block and add canary rule IDs to its `<rule_id>` list)

- [ ] **Step 1: Locate the existing integration block**

```bash
ssh -i ~/.ssh/openwrt root@192.168.1.120
# inside .120:
grep -n 'custom-ntfy' /opt/soc-ansible/roles/wazuh-manager/templates/ossec.conf.j2
grep -B1 -A6 'custom-ntfy' /opt/soc-ansible/roles/wazuh-manager/templates/ossec.conf.j2
```

Expected output:
```xml
<integration>
  <name>custom-ntfy</name>
  <hook_url>https://ntfy.sh/wazuh-Qzwhd0BgI6pQDaxb</hook_url>
  <rule_id>100030,100031,100040,100041</rule_id>
  <alert_format>json</alert_format>
</integration>
```

(If the integration lives in a different file — `files/ossec.conf` vs `templates/ossec.conf.j2` — grep both. The existing repo pattern uses templates per the elk role's `local_decoder.xml.j2` etc.)

- [ ] **Step 2: Check `custom-ntfy` script handles canary-shaped alerts**

```bash
cat /opt/soc-ansible/roles/wazuh-manager/files/custom-ntfy
```

Look at how it constructs the ntfy title/body. If it parses `alert.data.<field>` generically (just reads the description + level + agent), it'll work for canary alerts without modification. If it hard-codes Suricata-specific fields (e.g. `alert.signature`), it needs a generalization or a sibling `custom-ntfy-canary` script.

**Decision branch:**
- If generic: extend the rule_id list (Step 3 below) and skip Step 3-alt
- If Suricata-hardcoded: write a sibling script following the existing pattern, register as a SECOND `<integration name="custom-ntfy-canary">` (Step 3-alt)

The spec defers this verification to the implementer. Both paths converge — the canary rules fire ntfy.

- [ ] **Step 3 (generic path): Extend existing integration rule_id**

In `ossec.conf.j2`, change:
```xml
<rule_id>100030,100031,100040,100041</rule_id>
```
to:
```xml
<rule_id>100030,100031,100040,100041,100301,100302,100303,100307</rule_id>
```

(Only the high-severity canary rules — not the lvl 3 dedup/base rules.)

- [ ] **Step 3-alt (Suricata-specific path): Add a second integration block**

If `custom-ntfy` is Suricata-hardcoded, write `/opt/soc-ansible/roles/wazuh-manager/files/custom-ntfy-canary` as a copy/adaptation that builds canary-shaped titles (`[CANARY/.140] $src_host -> :$dst_port`). Then in `ossec.conf.j2`, add immediately after the existing integration:

```xml
<integration>
  <name>custom-ntfy-canary</name>
  <hook_url>https://ntfy.sh/wazuh-Qzwhd0BgI6pQDaxb</hook_url>
  <rule_id>100301,100302,100303,100307</rule_id>
  <alert_format>json</alert_format>
</integration>
```

Also add a task in `roles/wazuh-manager/tasks/main.yml` to deploy the new script (follow the existing `custom-ntfy` deploy pattern — likely a `copy:` task with mode `0750`).

- [ ] **Step 4: Lint, converge, restart manager**

```bash
cd /opt/soc-ansible
ansible-lint
ansible-playbook playbooks/site.yml --limit elk-133
```

Expected: `changed=1` for the ossec.conf template, manager restart handler fires.

- [ ] **Step 5: Trigger an alert end-to-end and verify ntfy push**

From `.13`:
```powershell
$nc = New-Object System.Net.Sockets.TcpClient
$nc.Connect("192.168.1.140", 445)
$nc.Close()
```

Expected within ~10 seconds on the phone subscribed to `wazuh-Qzwhd0BgI6pQDaxb`: a ntfy push with priority `urgent` (rule 100302 → lvl 12) and a body referencing `192.168.1.13` and `:445`.

Cross-check from `.133`:
```bash
tail -20 /var/ossec/logs/ossec.log | grep -i 'integration'
tail -20 /var/ossec/logs/integrations.log 2>/dev/null
```

- [ ] **Step 6: Commit**

```bash
cd /opt/soc-ansible
git add roles/wazuh-manager/
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'wazuh-manager: route canary 1003xx alerts to ntfy

Extended the existing custom-ntfy <integration> rule_id list to include
100301/302/303/307 (or added a sibling custom-ntfy-canary integration if
the existing script is Suricata-specific — see commit notes). Verified
end-to-end: TCP connect from .13 to .140:445 fires rule 100302 lvl 12,
ntfy push arrives within ~10s.'
```

---

## Phase 5 — T-Pot Wazuh tap

### Task 5.1: Install Wazuh agent on `.130` and `.125` (manual, one-time)

**Files:** Manual install on both hosts.

- [ ] **Step 1: Install wazuh-agent on `.130` (T-Pot HIVE)**

SSH on port 64295 (T-Pot's SSH alt-port):
```bash
ssh -i ~/.ssh/openwrt -p 64295 root@192.168.1.130
# inside .130:
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
apt-get update
WAZUH_MANAGER='192.168.1.133' apt-get install -y wazuh-agent=4.14.5-1
echo "wazuh-agent hold" | dpkg --set-selections
systemctl enable wazuh-agent
systemctl start wazuh-agent
sleep 5
tail -10 /var/ossec/logs/ossec.log | grep -E 'Connected|Started thread'
```

Expected: `Connected to enrollment service` confirmation.

- [ ] **Step 2: Same on `.125` (T-Pot SENSOR)**

```bash
ssh -i ~/.ssh/openwrt -p 64295 root@192.168.1.125
# repeat the install commands above
```

- [ ] **Step 3: Verify both agents register**

On `.133`:
```bash
/var/ossec/bin/agent_control -l | grep -E 'tpot|130|125'
```

Expected: two new lines, both `Active`. Total agent count should now be 6 (existing 4 + `.140` + `.130`). Adding `.125` makes 7.

- [ ] **Step 4: No commit (manual setup)**

---

### Task 5.2: Extend `tpot` role with Wazuh localfile blockinfile

**Files:**
- Modify: `/opt/soc-ansible/roles/tpot/tasks/main.yml`
- Modify: `/opt/soc-ansible/roles/tpot/handlers/main.yml` (or create if absent)

- [ ] **Step 1: Read existing tpot role tasks**

```bash
cat /opt/soc-ansible/roles/tpot/tasks/main.yml
ls /opt/soc-ansible/roles/tpot/handlers/ 2>/dev/null
```

(The role is backup-only per memory — likely just `fetch:` tasks for config backup.)

- [ ] **Step 2: Append the Wazuh tap task to `roles/tpot/tasks/main.yml`**

At the end of the file, add:

```yaml
# ============================================================================
# Wazuh agent localfile inputs — JSON honeypot logs.
# Agent install is manual (see docs/runbooks/tpot-rebuild.md "Wazuh agent");
# only the localfile block is Ansible-managed (matches Zeek/.120 idiom).
# JSON-emitting honeypots only — Heralding (CSV), RDPY (text), Mailoney
# (text), Citrixhoneypot (text) deferred until decoders exist.
# ============================================================================

- name: Add T-Pot JSON honeypot inputs to Wazuh agent
  ansible.builtin.blockinfile:
    path: /var/ossec/etc/ossec.conf
    marker: "<!-- {mark} ANSIBLE MANAGED: tpot localfiles -->"
    insertbefore: "</ossec_config>"
    block: |
      <localfile>
        <location>/data/cowrie/log/cowrie.json</location>
        <log_format>json</log_format>
      </localfile>
      <localfile>
        <location>/data/dionaea/log/dionaea.json</location>
        <log_format>json</log_format>
      </localfile>
      <localfile>
        <location>/data/adbhoney/log/adbhoney.json</location>
        <log_format>json</log_format>
      </localfile>
      <localfile>
        <location>/data/tanner/log/tanner_report.json</location>
        <log_format>json</log_format>
      </localfile>
      <localfile>
        <location>/data/sentrypeer/log/sentrypeer.json</location>
        <log_format>json</log_format>
      </localfile>
      <localfile>
        <location>/data/conpot/log/conpot.json</location>
        <log_format>json</log_format>
      </localfile>
  notify: Restart wazuh-agent
  when: inventory_hostname in groups['tpot']
```

- [ ] **Step 3: Add or extend handler `Restart wazuh-agent`**

```bash
mkdir -p /opt/soc-ansible/roles/tpot/handlers
```

Create or edit `/opt/soc-ansible/roles/tpot/handlers/main.yml`:

```yaml
---
- name: Restart wazuh-agent
  ansible.builtin.systemd:
    name: wazuh-agent
    state: restarted
```

- [ ] **Step 4: Lint and converge**

```bash
cd /opt/soc-ansible
ansible-lint
ansible-playbook playbooks/site.yml --limit tpot --check --diff
ansible-playbook playbooks/site.yml --limit tpot
```

Expected: `changed=2` (one blockinfile + one handler per host), `failed=0`.

- [ ] **Step 5: Verify agents are tailing the new files**

```bash
ssh -i ~/.ssh/openwrt -p 64295 root@192.168.1.130 'grep -E "cowrie|dionaea" /var/ossec/logs/ossec.log | tail'
ssh -i ~/.ssh/openwrt -p 64295 root@192.168.1.125 'grep -E "cowrie|dionaea" /var/ossec/logs/ossec.log | tail'
```

Expected: `Analyzing file: '/data/cowrie/log/cowrie.json'.` and similar lines on both hosts.

- [ ] **Step 6: Idempotence**

```bash
ansible-playbook playbooks/site.yml --limit tpot
```

Expected: `changed=0`.

- [ ] **Step 7: Commit**

```bash
git add roles/tpot/
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'tpot: add Wazuh agent localfile inputs for 6 JSON honeypots

Tails cowrie/dionaea/adbhoney/tanner/sentrypeer/conpot on .130 + .125
into the .133 manager. T-Pot self-managed otherwise — only the localfile
block is Ansible-managed via blockinfile (matches Zeek/.120 idiom).
Heralding/RDPY/Mailoney/Citrixhoneypot log non-JSON and are deferred.'
```

---

### Task 5.3: Add manager rules `1004xx` for T-Pot internal hits

**Files:**
- Modify: `/opt/soc-ansible/roles/wazuh-manager/files/local_rules.xml`

- [ ] **Step 1: Capture a real Cowrie sample to confirm field names**

Trigger a Cowrie SSH probe from `.13`:
```powershell
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 wronguser@192.168.1.130 'exit' 2>$null
```

(Connects to T-Pot's Cowrie on 22, not the real T-Pot SSH which is 64295.)

On `.130`:
```bash
tail -2 /data/cowrie/log/cowrie.json
```

Sample (typical Cowrie format):
```json
{"eventid":"cowrie.session.connect","src_ip":"192.168.1.13","src_port":N,"dst_ip":"192.168.1.130","dst_port":22,"session":"xxxx","timestamp":"2026-06-XX..."}
```

Note the top-level field names: `src_ip`, `dst_port`, `eventid`. (Cowrie uses these; Dionaea uses similar.)

- [ ] **Step 2: Add the `1004xx` rules group after the canary group in `local_rules.xml`**

```xml
<!-- ================================================================
     T-Pot internal lateral-movement rules (100400-100409)
     Only LAN-source hits page — external scanners stay in T-Pot's
     own Kibana on .130:64297 (unchanged).
     Spec: docs/specs/2026-06-01-canary-design.md
     ================================================================ -->
<group name="tpot,internal_tripwire,">

  <rule id="100400" level="3">
    <decoded_as>json</decoded_as>
    <field name="eventid" type="pcre2">^cowrie\.|^dionaea|^adbhoney|^tanner|^sentrypeer|^conpot</field>
    <description>T-Pot honeypot hit (base)</description>
  </rule>

  <!-- Cowrie/Dionaea/etc. all log src_ip at top level. -->
  <rule id="100401" level="10">
    <if_sid>100400</if_sid>
    <field name="src_ip" type="pcre2">^192\.168\.1\.</field>
    <description>T-Pot hit from LAN: $(src_ip) -> $(dst_ip):$(dst_port)</description>
    <group>tpot,</group>
  </rule>

  <rule id="100402" level="12">
    <if_sid>100401</if_sid>
    <field name="dst_port" type="pcre2">^(22|445|3306|3389|5900)$</field>
    <description>T-Pot critical-port hit from LAN: $(src_ip) -> :$(dst_port)</description>
    <group>tpot,</group>
  </rule>

  <rule id="100403" level="3" frequency="2" timeframe="3600" ignore="3600">
    <if_matched_sid>100401</if_matched_sid>
    <same_field>src_ip</same_field>
    <description>T-Pot hit repeat from same source (dedup hourly)</description>
  </rule>

</group>
```

(If `eventid` doesn't match for non-Cowrie hits — Dionaea uses `connection.protocol`, ConPot uses `event_type` — the base rule's regex won't catch them. Add per-honeypot base rules under 100400 if wazuh-logtest shows misses. Simplest fix: drop the eventid filter from 100400 and rely on `_log_file_` name decoding which Wazuh adds automatically.)

- [ ] **Step 3: Lint XML and deploy**

```bash
xmllint --noout /opt/soc-ansible/roles/wazuh-manager/files/local_rules.xml
cd /opt/soc-ansible
ansible-playbook playbooks/site.yml --limit elk-133
```

Expected: `changed=1`, manager restart fires.

- [ ] **Step 4: wazuh-logtest the Cowrie sample**

On `.133`:
```bash
echo '<paste cowrie JSON from step 1>' | /var/ossec/bin/wazuh-logtest
```

Expected: `100400` → `100401` (LAN source) → `100402` (port 22 = critical). Levels 3 → 10 → 12.

- [ ] **Step 5: Extend ntfy integration rule_id list with `1004xx`**

In `roles/wazuh-manager/templates/ossec.conf.j2`, extend the rule_id attribute again:
```xml
<rule_id>100030,100031,100040,100041,100301,100302,100303,100307,100401,100402</rule_id>
```

Re-deploy:
```bash
ansible-playbook playbooks/site.yml --limit elk-133
```

- [ ] **Step 6: End-to-end test**

From `.13`:
```powershell
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 wronguser@192.168.1.130 'exit' 2>$null
```

Expected within ~10s: ntfy push with priority `urgent`, body referencing T-Pot Cowrie hit from `.13`.

- [ ] **Step 7: Commit**

```bash
git add roles/wazuh-manager/files/local_rules.xml roles/wazuh-manager/templates/ossec.conf.j2
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'wazuh-manager: T-Pot internal-source rules 1004xx + ntfy routing

100400 base (any T-Pot JSON event), 100401 escalates LAN source (lvl 10),
100402 escalates LAN+critical-port (lvl 12), 100403 dedup hourly per src_ip.
RFC1918 source filter so external scanners stay silent in T-Pot Kibana
on .130:64297. Field paths confirmed via wazuh-logtest against real
cowrie.json. ntfy rule_id list extended.'
```

---

## Phase 6 — Health-check additions + `.120` cutover

### Task 6.1: Extend `playbooks/ops/health-check.yml` with canary play

**Files:**
- Modify: `/opt/soc-ansible/playbooks/ops/health-check.yml`

- [ ] **Step 1: Add the canary play after the T-Pot play and before the OpenWrt play**

Find the `- name: Health check — T-Pot hosts (.130, .125)` block. After its tasks, before `- name: Health check — OpenWrt router`, insert:

```yaml
- name: Health check — canary (.140)
  hosts: canary
  gather_facts: true
  tasks:
    - name: Check systemd services (.140)  # noqa: command-instead-of-module
      ansible.builtin.command: "systemctl is-active {{ item }}"
      loop: [opencanary, sinkhole, wazuh-agent]
      register: svc_140
      failed_when: false
      changed_when: false

    - name: Canary listening port count (.140)
      ansible.builtin.shell: ss -tln '! ( sport = :22 )' | grep -c LISTEN
      args:
        executable: /bin/bash
      register: ports_140
      failed_when: false
      changed_when: false

    - name: OpenCanary log stat (.140)
      ansible.builtin.stat:
        path: /var/tmp/opencanary.log
      register: ocan_log_140

    - name: Sinkhole log stat (.140)
      ansible.builtin.stat:
        path: /var/log/sinkhole.json
      register: sink_log_140

    - name: Disk pct (.140)
      ansible.builtin.shell: df / | awk 'NR==2{print $5}' | tr -d '%'
      register: disk_pct_140
      failed_when: false
      changed_when: false

    - name: Disk detail (.140)
      ansible.builtin.command: df -h /
      register: disk_140
      failed_when: false
      changed_when: false
```

- [ ] **Step 2: Add `wazuh-agent` to T-Pot service loop**

In the existing `- name: Health check — T-Pot hosts (.130, .125)` block, change:
```yaml
loop: [tpot]
```
to:
```yaml
loop: [tpot, wazuh-agent]
```

- [ ] **Step 3: Add canary section to summary table**

Find the `Summary table` task. In the `msg: |` block, after the `--- T-Pot hosts ---` block and before the `--- Router ---` block, insert:

```jinja
          --- .140 canary services ---
          {% for r in hostvars['fileserver-140']['svc_140']['results'] | default([]) %}
          {{ '[OK]  ' if r.stdout == 'active' else '[FAIL]' }} {{ '%-20s' | format(r.item) }} {{ r.stdout | default('?') }}
          {% endfor %}
          listening    : {{ hostvars['fileserver-140']['ports_140']['stdout'] | default('?') | trim }} ports{{ ' [FAIL] expected ' ~ canary_expected_port_count if (hostvars['fileserver-140']['ports_140']['stdout'] | default('0') | trim | int) < 22 else '' }}
          opencanary.log : {{ 'present' if hostvars['fileserver-140']['ocan_log_140']['stat']['exists'] | default(false) else '[FAIL] missing' }}
          sinkhole.json  : {{ 'present' if hostvars['fileserver-140']['sink_log_140']['stat']['exists'] | default(false) else '[FAIL] missing' }}
          disk         : {{ hostvars['fileserver-140']['disk_pct_140']['stdout'] | default('?') | trim }}%{{ ' [WARN]' if (hostvars['fileserver-140']['disk_pct_140']['stdout'] | default('0') | trim | int) >= 80 else '' }}
          {{ hostvars['fileserver-140']['disk_140']['stdout'] | default('n/a') }}

```

(Note: `canary_expected_port_count` lives in role defaults; when referenced inside playbook templating it may not auto-resolve. The fix is either to define the var on `vars:` at the play level, OR hardcode `22` in the template. Simpler: hardcode `22` in the warn message.)

- [ ] **Step 4: Update Wazuh agent count drift assert**

Locate the existing summary line `Wazuh agents : {{ ... }}` — it currently expects 4. Now expect 7. If there's an explicit fail task tied to agent count != 4, update the threshold. (If not, the existing summary line still displays the count; the assert isn't gated on it.)

Find the line in the summary template:
```jinja
          MISP feeds   : {{ ... }} enabled{{ ' [FAIL] expected 8' if ... != 8 else '' }}
```

If a similar pattern exists for `Wazuh agents`, update `expected 4` → `expected 7`. If not, add one:
```jinja
          Wazuh agents : {{ hostvars['elk-133']['wazuh_agents_133']['stdout'] | default('n/a') | trim }}{{ ' [FAIL] expected 7' if (hostvars['elk-133']['wazuh_agents_133']['stdout'] | default('-1') | trim | int) != 7 else '' }}
```

And add a fail task at the end (after the existing `Fail if MISP enabled feed count drifted`):
```yaml
- name: Fail if Wazuh agent count drifted
  ansible.builtin.fail:
    msg: "Wazuh enrolled agent count != 7 — check /var/ossec/etc/client.keys on .133 for missing/extra agents"
  when: (hostvars['elk-133']['wazuh_agents_133']['stdout'] | default('-1') | trim | int) != 7
```

- [ ] **Step 5: Add new fail asserts at the bottom**

After existing fail tasks, before the closing of the summary play:

```yaml
- name: Fail if canary services down
  ansible.builtin.fail:
    msg: "One or more canary services down on .140 — opencanary/sinkhole/wazuh-agent (see summary)"
  when: >
    hostvars['fileserver-140']['svc_140']['results'] | default([])
      | selectattr('stdout', '!=', 'active') | list | length > 0

- name: Fail if canary port count drifted
  ansible.builtin.fail:
    msg: "Canary listening port count < 22 on .140 — OpenCanary or sinkhole missing ports (expected 8+14)"
  when: (hostvars['fileserver-140']['ports_140']['stdout'] | default('0') | trim | int) < 22

- name: Fail if canary log files missing
  ansible.builtin.fail:
    msg: "Canary log file(s) missing on .140 — OpenCanary or sinkhole never started writing"
  when: >
    not (hostvars['fileserver-140']['ocan_log_140']['stat']['exists'] | default(false))
    or not (hostvars['fileserver-140']['sink_log_140']['stat']['exists'] | default(false))
```

- [ ] **Step 6: Lint**

```bash
cd /opt/soc-ansible
ansible-lint playbooks/ops/health-check.yml
```

Expected: `0 failure(s)`. If Jinja whitespace issues surface, use inline ternary or `{% endif +%}` per `feedback/jinja-trim-blocks-fix.md`.

- [ ] **Step 7: Run health-check**

```bash
ansible-playbook playbooks/ops/health-check.yml
```

Expected: all 8 hosts `[OK]`, Wazuh agent count 7, canary section all green, 0 fail asserts triggered.

- [ ] **Step 8: Commit**

```bash
git add playbooks/ops/health-check.yml
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'ops: health-check coverage for canary (.140) + T-Pot wazuh-agent

New canary play: 3 service checks (opencanary/sinkhole/wazuh-agent),
port count, both log file stats, disk. T-Pot service loop gains
wazuh-agent. Wazuh agent count drift assert updated 4 -> 7 (added
.140 + .130 + .125). Three new fail asserts. Verified clean run.'
```

---

### Task 6.2: `.120` cutover — decommission `.121` alias + `sinkhole.service`

**Files:**
- Modify: `/opt/soc-ansible/roles/canary/tasks/main.yml` (append cutover block)

- [ ] **Step 1: Pre-cutover verification — confirm `.140` is fully live**

Run health-check and verify canary section is green:
```bash
cd /opt/soc-ansible
ansible-playbook playbooks/ops/health-check.yml
```

Trigger a hit and confirm ntfy:
```powershell
$nc = New-Object System.Net.Sockets.TcpClient
$nc.Connect("192.168.1.140", 445)
$nc.Close()
```

If ntfy doesn't fire, DO NOT proceed — fix the alert pipeline first. The cutover removes the only live canary on `.120`, so `.140` must be confirmed working.

- [ ] **Step 2: Append the cutover block to `roles/canary/tasks/main.yml`**

At the bottom of the file, after the Wazuh agent localfile blockinfile task, append:

```yaml
# ============================================================================
# .120 cutover — decommission legacy .121 alias + sinkhole.service
# Gated on inventory_hostname == 'suricata-120'. Runs as part of the canary
# role to keep migration + cleanup in a single change-set. Reversible from git.
# ============================================================================

- name: Stop and disable legacy sinkhole.service on .120
  ansible.builtin.systemd:
    name: sinkhole
    state: stopped
    enabled: false
    daemon_reload: true
  failed_when: false  # service may already be absent on a previous re-run
  when: inventory_hostname == 'suricata-120'

- name: Remove legacy sinkhole.service unit file from .120
  ansible.builtin.file:
    path: /etc/systemd/system/sinkhole.service
    state: absent
  notify: Reload systemd
  when: inventory_hostname == 'suricata-120'

- name: Remove legacy sinkhole.py from .120
  ansible.builtin.file:
    path: /usr/local/bin/sinkhole.py
    state: absent
  when: inventory_hostname == 'suricata-120'

- name: Remove legacy .121 alias interface config from .120
  ansible.builtin.file:
    path: /etc/network/interfaces.d/sinkhole
    state: absent
  register: alias_removed
  when: inventory_hostname == 'suricata-120'

- name: Tear down .121 alias immediately if it was removed (ifdown enp0s3:0)
  ansible.builtin.command: ifdown enp0s3:0
  failed_when: false  # idempotent — succeeds if already down
  when:
    - inventory_hostname == 'suricata-120'
    - alias_removed.changed
```

- [ ] **Step 3: Add `suricata-120` to canary play in site.yml temporarily for the cutover**

Edit `/opt/soc-ansible/playbooks/site.yml`. The existing canary play targets `canary` group only — but the cutover tasks need to run on `.120`. Two options:

**(a)** Add a one-off limit override for the cutover commit, then revert:
```bash
ansible-playbook playbooks/site.yml --limit suricata-120 --tags <none>
```
But the tasks are gated `when: inventory_hostname == 'suricata-120'` so they won't fire unless `suricata-120` is targeted by the play.

**(b)** Add a sibling play to site.yml that runs the canary role on `suricata-120` JUST for the cutover tasks (which then become no-ops on future runs since files are already absent):

```yaml
- name: Canary cutover on .120 (decommission legacy sinkhole)
  hosts: suricata-120
  become: true
  roles:
    - canary
  tags:
    - canary_cutover
```

Use option (b) — keeps cutover idempotent and visible in `site.yml`. The role's `inventory_hostname` gates ensure non-cutover canary tasks (OpenCanary install, etc.) skip on `.120`.

- [ ] **Step 4: Lint and dry-run**

```bash
cd /opt/soc-ansible
ansible-lint
ansible-playbook playbooks/site.yml --limit suricata-120 --tags canary_cutover --check --diff
```

Expected diff: removal of 3 files + systemd disable.

- [ ] **Step 5: Live cutover converge**

```bash
ansible-playbook playbooks/site.yml --limit suricata-120 --tags canary_cutover
```

Expected: `changed=4-5`. Watch for the alias removal step to fire.

- [ ] **Step 6: Verify `.121` is gone and sinkhole.service is gone**

```bash
ssh -i ~/.ssh/openwrt root@192.168.1.120 'echo "=== ip ==="; ip -br addr show enp0s3; echo "=== service ==="; systemctl status sinkhole 2>&1 | head -3; echo "=== files ==="; ls -la /usr/local/bin/sinkhole.py /etc/systemd/system/sinkhole.service /etc/network/interfaces.d/sinkhole 2>&1 | grep -v "No such"; echo done'
```

Expected:
- `ip -br addr`: only `192.168.1.120/24` on enp0s3 (no `.121` aux address)
- `systemctl status sinkhole`: `Unit sinkhole.service could not be found.`
- `ls`: all three "No such file or directory" → no lines printed before "done"

- [ ] **Step 7: Idempotence**

```bash
ansible-playbook playbooks/site.yml --limit suricata-120 --tags canary_cutover
```

Expected: `changed=0` (all files already absent).

- [ ] **Step 8: Run full health-check to confirm nothing broke**

```bash
ansible-playbook playbooks/ops/health-check.yml
```

Expected: all 8 hosts green, no new failures.

- [ ] **Step 9: Commit**

```bash
git add roles/canary/tasks/main.yml playbooks/site.yml
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'canary: cutover — remove legacy sinkhole.service + .121 alias from .120

Pre-cutover: verified .140 canary live + ntfy fires end-to-end.
Tasks gated on inventory_hostname == suricata-120 (state: absent for the
.service unit, the python script, and the interfaces.d alias config),
plus a one-shot ifdown enp0s3:0 to tear the alias down immediately
(not wait for next reboot). New canary_cutover-tagged play in site.yml
runs the role on .120 for these tasks only.
Idempotent: changed=0 on re-run. Reversible: git revert + re-converge.'
```

---

## Phase 7 — Sleep script, backup, runbooks, memory

### Task 7.1: Exclude `fileserver01` from `soc-sleep-savestate.ps1`

**Files:**
- Modify: `C:\scripts\soc-sleep-savestate.ps1` on `.15`

- [ ] **Step 1: Read the existing sleep script**

```powershell
ssh -i $env:USERPROFILE\.ssh\openwrt Games@192.168.1.15 'powershell -Command "Get-Content C:\scripts\soc-sleep-savestate.ps1"'
```

Identify the VM iteration loop.

- [ ] **Step 2: Add the skip clause**

Edit the script (via `notepad` over an interactive RDP, or pipe through `ssh ... 'powershell -Command "Set-Content ..."'`). Insert at the top of the foreach loop body:

```powershell
if ($vm -eq 'fileserver01') {
    Write-Output "$(Get-Date -Format 'HH:mm:ss') skipping fileserver01 (24/7 canary)"
    continue
}
```

(Exact variable name depends on the existing script — could be `$vmName`, `$vm`, etc. Match whatever the foreach uses.)

- [ ] **Step 3: Test the change at runtime**

The script runs nightly at 23:00. To test now: dry-run a no-op version of the script in a sandbox session, OR wait until 23:01 and verify via `C:\scripts\soc-sleep-savestate.log` that `fileserver01` was skipped and other VMs were processed.

- [ ] **Step 4: Commit the script (if it's tracked in IaC)**

The `.15` script lives outside the soc-ansible repo. If it's mirrored anywhere (likely `roles/openwrt/files/` or similar — verify), commit there. Otherwise just document in the runbook (Task 7.3).

```bash
# If tracked:
git -C <repo> commit -m "ops: skip fileserver01 in soc-sleep-savestate.ps1 (24/7 canary)"
```

---

### Task 7.2: One-time VBox export backup of `.140`

**Files:**
- Create: `C:\Users\xndre\OneDrive\Claude\backup\vms\fileserver01-YYYYMMDD.ova`

- [ ] **Step 1: ACPI-shutdown `fileserver01` before export**

```powershell
ssh -i $env:USERPROFILE\.ssh\openwrt Games@192.168.1.15 'powershell -Command "& ''C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'' controlvm fileserver01 acpipowerbutton"'
sleep 30
```

Confirm:
```powershell
ssh -i $env:USERPROFILE\.ssh\openwrt Games@192.168.1.15 'powershell -Command "& ''C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'' list runningvms"'
```

Expected: `fileserver01` not in the list.

- [ ] **Step 2: Export to OVA**

```powershell
$ts = Get-Date -Format 'yyyyMMdd'
ssh -i $env:USERPROFILE\.ssh\openwrt Games@192.168.1.15 "powershell -Command `"& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' export fileserver01 --output C:\Users\Games\Desktop\fileserver01-$ts.ova`""
```

- [ ] **Step 3: Pull the OVA to OneDrive on `.13`**

```powershell
$ts = Get-Date -Format 'yyyyMMdd'
$dest = "C:\Users\xndre\OneDrive\Claude\backup\vms"
New-Item -ItemType Directory -Path $dest -Force | Out-Null
scp -i $env:USERPROFILE\.ssh\openwrt "Games@192.168.1.15:C:/Users/Games/Desktop/fileserver01-$ts.ova" "$dest\"
ssh -i $env:USERPROFILE\.ssh\openwrt Games@192.168.1.15 "powershell -Command Remove-Item C:\Users\Games\Desktop\fileserver01-$ts.ova"
Get-Item "$dest\fileserver01-$ts.ova" | Format-List Name, Length
```

Expected: file ~500 MB.

- [ ] **Step 4: Restart `fileserver01`**

```powershell
ssh -i $env:USERPROFILE\.ssh\openwrt Games@192.168.1.15 "powershell -Command `"& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' startvm fileserver01 --type headless`""
sleep 30
ping -c 2 192.168.1.140
```

- [ ] **Step 5: Re-verify health-check post-restart**

```bash
ssh -i ~/.ssh/openwrt root@192.168.1.120 'cd /opt/soc-ansible && ansible-playbook playbooks/ops/health-check.yml'
```

Expected: clean run.

- [ ] **Step 6: No commit (backup is binary in OneDrive, not git-tracked)**

---

### Task 7.3: New runbook `docs/runbooks/canary-140-rebuild.md`

**Files:**
- Create: `/opt/soc-ansible/docs/runbooks/canary-140-rebuild.md`

- [ ] **Step 1: Write the runbook**

```markdown
# Runbook — Rebuild `.140 fileserver01` (canary)

Rebuilds the internal trip-wire canary host from scratch. ~30 min.

## Prereqs
- `.15` hypervisor up
- `.133` Wazuh manager reachable
- soc-ansible repo on `.120` clean

## Steps

### 1. Restore the VM (fast path — from OVA backup)
```powershell
$ova = (Get-ChildItem C:\Users\xndre\OneDrive\Claude\backup\vms\fileserver01-*.ova | Sort-Object Name -Descending | Select-Object -First 1)
scp -i $env:USERPROFILE\.ssh\openwrt $ova "Games@192.168.1.15:C:/Users/Games/Desktop/"
ssh -i $env:USERPROFILE\.ssh\openwrt Games@192.168.1.15 `
  "powershell -Command `"& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' import C:\Users\Games\Desktop\$($ova.Name) --vsys 0 --vmname fileserver01`""
ssh -i $env:USERPROFILE\.ssh\openwrt Games@192.168.1.15 `
  "powershell -Command `"& 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' startvm fileserver01 --type headless`""
```

### 1-alt. Cold rebuild (no OVA available)
See `docs/specs/2026-06-01-canary-design.md` §3a + §7 for VBoxManage commands and the Debian 12 minimal install steps. Then:
```bash
ssh -i ~/.ssh/openwrt root@192.168.1.140 # set hostname, IP, ssh keys
```

### 2. Install Wazuh agent (manual, one-time)
```bash
ssh -i ~/.ssh/openwrt root@192.168.1.140 << 'EOF'
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
apt-get update
WAZUH_MANAGER='192.168.1.133' apt-get install -y wazuh-agent=4.14.5-1
echo "wazuh-agent hold" | dpkg --set-selections
systemctl enable --now wazuh-agent
EOF
```

### 3. Converge IaC
```bash
ssh -i ~/.ssh/openwrt root@192.168.1.120 'cd /opt/soc-ansible && ansible-playbook playbooks/site.yml --limit fileserver-140'
```

### 4. Verify
```bash
ssh -i ~/.ssh/openwrt root@192.168.1.120 'cd /opt/soc-ansible && ansible-playbook playbooks/ops/health-check.yml --limit fileserver-140'
```

Expected: canary section green, 22 listening ports + sshd.

### 5. Sleep policy reminder
`fileserver01` must remain excluded from `C:\scripts\soc-sleep-savestate.ps1` on `.15` — search for `fileserver01` in the script; if absent, re-add the skip clause (see canary design spec §7).

## Recovery time
- Fast path (OVA): ~5 min
- Cold rebuild: ~30 min
```

Save as `/opt/soc-ansible/docs/runbooks/canary-140-rebuild.md`.

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/canary-140-rebuild.md
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'docs: runbook — rebuild fileserver01 (canary host)

Fast path (OVA restore) ~5 min, cold rebuild ~30 min. Includes Wazuh agent
install step (out-of-band, matches existing convention) and sleep-policy
reminder for soc-sleep-savestate.ps1 on .15.'
```

---

### Task 7.4: Extend `docs/runbooks/tpot-rebuild.md` with Wazuh agent section

**Files:**
- Modify: `/opt/soc-ansible/docs/runbooks/tpot-rebuild.md`

- [ ] **Step 1: Append a Wazuh agent section to the existing runbook**

```bash
cat >> /opt/soc-ansible/docs/runbooks/tpot-rebuild.md <<'EOF'

## Wazuh agent (post-rebuild step)

T-Pot rebuilds wipe `/var/ossec`. Re-install the agent after the rebuild
so internal-source hits keep paging via .133 + ntfy.

```bash
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
apt-get update
WAZUH_MANAGER='192.168.1.133' apt-get install -y wazuh-agent=4.14.5-1
echo "wazuh-agent hold" | dpkg --set-selections
systemctl enable --now wazuh-agent
```

Then converge the IaC to restore localfile blocks:

```bash
ssh -i ~/.ssh/openwrt root@192.168.1.120 \
  'cd /opt/soc-ansible && ansible-playbook playbooks/site.yml --limit <tpot-hive-130|tpot-sensor-125>'
```

Verify agent enrolled (count should return to 7):
```bash
ssh -i ~/.ssh/openwrt root@192.168.1.120 \
  'cd /opt/soc-ansible && ansible-playbook playbooks/ops/health-check.yml'
```

EOF
```

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/tpot-rebuild.md
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'docs: tpot-rebuild runbook — Wazuh agent post-rebuild section

T-Pot rebuilds wipe /var/ossec. Documents the agent re-install + IaC
re-converge sequence so internal-source hits keep paging via .133.'
```

---

### Task 7.5: Final verification + push to GitHub mirror

**Files:** none (push-only)

- [ ] **Step 1: Run the full verification matrix from the spec**

From `.120`:
```bash
nmap -sV 192.168.1.140 -p 21,23,80,443,445,3306,3389,5900
```
Expected: banners on all 8 ports (no "filtered" or "closed").

From `.13`:
```powershell
smbclient -L 192.168.1.140 -N
curl http://192.168.1.140/
$nc = New-Object System.Net.Sockets.TcpClient
$nc.Connect("192.168.1.140", 4444); $nc.Close()
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 wronguser@192.168.1.130 'exit' 2>$null
```

Verify each triggers a ntfy push within ~10s (4 pushes total). Then re-trigger one of them within the hour and verify NO second push (dedup works).

Run full health-check:
```bash
ssh -i ~/.ssh/openwrt root@192.168.1.120 'cd /opt/soc-ansible && ansible-playbook playbooks/ops/health-check.yml'
```

Expected: 8 hosts green, no fail asserts.

- [ ] **Step 2: Push the accumulated commits to GitHub mirror**

```powershell
cd $env:TEMP\soc-home-push
git pull --ff-only
```

For each commit on `.120` since the spec push:
```powershell
# pull the latest from .120 and replay onto the mirror clone
ssh -i $env:USERPROFILE\.ssh\openwrt root@192.168.1.120 'cd /opt/soc-ansible && git log --oneline cf5db89..HEAD'
# for each file modified in each commit:
#   scp file from .120 to $env:TEMP\soc-home-push\ansible\<path>
#   git add + commit with the same message
#   then push at the end
```

Simpler approach — batch all changes since the spec commit into a single mirror commit:
```powershell
cd $env:TEMP\soc-home-push
# copy the full updated tree
foreach ($f in @('inventory/hosts.yml','playbooks/site.yml','playbooks/ops/health-check.yml','roles/canary','roles/tpot','roles/wazuh-manager','docs/runbooks/canary-140-rebuild.md','docs/runbooks/tpot-rebuild.md','inventory/host_vars/fileserver-140/main.yml')) {
    $src = "root@192.168.1.120:/opt/soc-ansible/$f"
    $dst = "ansible/$f"
    if ($f.EndsWith('/')) { scp -r -i $env:USERPROFILE\.ssh\openwrt $src $dst }
    else { scp -i $env:USERPROFILE\.ssh\openwrt $src $dst }
}
git add ansible/
git -c user.email='168788872+andrei-majer@users.noreply.github.com' -c user.name='Andrei Majer' commit -m 'sync: canary deployment (per spec 2026-06-01-canary-design.md)

Mirror sync of .120 master commits since 48d38f2: canary role + inventory,
sinkhole migration, Wazuh tap (.140/.130/.125), manager rules 1003xx/1004xx,
ntfy routing, .120 cutover, health-check additions, runbooks.'
git push origin main
```

- [ ] **Step 3: Mark the deployment complete**

Update memory (Phase 8 below) and announce in chat.

---

## Phase 8 — Memory updates (post-deploy)

### Task 8.1: New memory file `soc-lab/canary.md`

**Files:**
- Create: `C:\Users\xndre\.claude\projects\C--Users-xndre-OneDrive-Claude\memory\soc-lab\canary.md`

- [ ] **Step 1: Write the memory file**

```markdown
---
name: canary
description: Internal canary on .140 fileserver01 — OpenCanary banners + sinkhole.py C2 ports, rules 1003xx, ntfy
metadata:
  node_type: memory
  type: reference
  last_verified: 2026-06-XX
---

# Internal Canary (.140 fileserver01)

Deployed 2026-06-XX per `[[ansible]]` commit chain ending `<HEAD-after-cutover>`.
Spec: `/opt/soc-ansible/docs/specs/2026-06-01-canary-design.md`.

## Host
- VM on .15, Debian 12 minimal, 1 vCPU/768MB/4GB, single IP 192.168.1.140
- Hostname `fileserver01`, registered as `Games` (matches existing pattern)
- Excluded from `C:\scripts\soc-sleep-savestate.ps1` on .15 — 24/7 canary
- OVA backup at `C:\Users\xndre\OneDrive\Claude\backup\vms\fileserver01-YYYYMMDD.ova` (fast-path rebuild via runbook)

## Services + ports
- Real `sshd` on :22 for Ansible/admin (`ssh -i ~/.ssh/openwrt root@192.168.1.140`)
- OpenCanary `/opt/opencanary-venv` — config `/etc/opencanaryd/opencanary.conf` — 8 banner ports: 21/23/80/443/445/3306/3389/5900
- SMB module — 3 fake shares (`HR`, `Backups`, `IT`) under `/srv/smb-decoys/` (~30 decoy files, no live tokens)
- sinkhole.py `/usr/local/bin/sinkhole.py` — 14 C2/exotic ports: 25/465/587/1080/1337/31337/4444/4445/4449/6667/6697/8443/8888/9001
- Logs: `/var/tmp/opencanary.log` + `/var/log/sinkhole.json`

## Wazuh + alerting
- Agent 4.14.5 → .133:1514, pinned (`dpkg hold`)
- Manager rules `1003xx` on .133 (`roles/wazuh-manager/files/local_rules.xml`):
  - `100300` OpenCanary base (any hit on dst_host=.140)
  - `100301` LAN source + banner port (21/23/80/443) → lvl 10
  - `100302` LAN source + critical port (445/3306/3389/5900/4444/4445/4449/6667/6697/9001/1337/31337) → lvl 12
  - `100303` credential capture (logdata.USERNAME present) → lvl 12 (NOT deduplicated)
  - `100304/305` hourly dedup per src_host for 100301/302
  - `100306` sinkhole base (event=sinkhole_hit)
  - `100307` LAN source → lvl 12
  - `100308` hourly dedup per client_ip
- ntfy: `custom-ntfy` integration extends `<rule_id>` to include 100301/302/303/307 → `https://ntfy.sh/wazuh-Qzwhd0BgI6pQDaxb`

## Verification commands
- `nmap -sV 192.168.1.140 -p 21,23,80,443,445,3306,3389,5900` from .120 → banners on all 8 ports
- `smbclient -L 192.168.1.140 -N` → HR/Backups/IT shares visible
- `ansible-playbook playbooks/ops/health-check.yml` → canary section all `[OK]`, 22 listening ports

## Gotchas
- OpenCanary SSH module DISABLED (collides with real sshd on 0.0.0.0:22)
- `--tags canary` only fires fact-gathering (role tasks not tagged) — deploy untagged `--limit fileserver-140`
- Wazuh agent install is manual one-time (matches existing convention — agent ossec.conf not Ansible-managed except for the localfile blockinfile)
- Decoy SMB shares are world-readable on purpose (`risky-file-permissions` lint suppression)
- Field name caveat: OpenCanary's exact decoded paths confirmed empirically via `wazuh-logtest` during deploy — if a future OpenCanary upgrade changes the JSON layout, re-test before relying on rules
```

- [ ] **Step 2: Add to MEMORY.md index**

Edit `C:\Users\xndre\.claude\projects\C--Users-xndre-OneDrive-Claude\memory\MEMORY.md`. In the soc-lab/ table, add:

```markdown
| `soc-lab/canary.md` | Internal canary on .140 — OpenCanary + sinkhole, rules 1003xx, ntfy |
```

---

### Task 8.2: Update `soc-lab/infrastructure.md` + Core Facts in MEMORY.md

**Files:**
- Modify: `soc-lab/infrastructure.md`
- Modify: `MEMORY.md` Core Facts

- [ ] **Step 1: Add `.140` to infrastructure host list**

In `soc-lab/infrastructure.md`, in the "Infrastructure" section, add after the `.135` line:

```markdown
- **.140 (fileserver01):** Debian 12, 1 vCPU, 768MB — internal canary (OpenCanary + sinkhole.py) — VM on .15 — excluded from nightly sleep, 24/7. See [[canary]].
```

Re-stamp `last_verified` to today.

- [ ] **Step 2: Update Core Facts active-projects in MEMORY.md**

In `MEMORY.md`'s "Core Facts" section, the active projects line currently mentions PaperMill + SOC lab. Add:
```markdown
- **Active projects:** PaperMill (RAG academic writing tool) · SOC lab (home SOC, Ansible IaC phase 3 complete, internal canary .140 deployed 2026-06-XX)
```

---

### Task 8.3: Update `soc-lab/ansible.md` Latest-commit pointer + role list

**Files:**
- Modify: `soc-lab/ansible.md`

- [ ] **Step 1: Update Latest commit**

Prepend a new entry in the Latest-commit section pointing to the cutover commit (last commit of the deployment). Include the canary deployment summary (one paragraph similar to existing entries).

- [ ] **Step 2: Add `canary` to the roles list in the repo layout block**

In the `## Structure` section, in the `roles/` block, add a line:
```
│   ├── canary/              # OpenCanary + sinkhole.py + SMB decoys on .140 (cutover removes .121 from .120)
```

- [ ] **Step 3: Update the "Daily/weekly use patterns" if relevant**

If health-check is now part of the morning workflow with the canary section, note it.

---

### Task 8.4: Update `soc-lab/tpot.md` with Wazuh tap

**Files:**
- Modify: `soc-lab/tpot.md`

- [ ] **Step 1: Add Wazuh tap section**

Append:
```markdown
## Wazuh tap (added 2026-06-XX)
Wazuh agent 4.14.5 installed manually on both .130 (HIVE) and .125 (SENSOR).
Localfile blockinfile in tpot role tails 6 JSON honeypot logs per host:
cowrie/dionaea/adbhoney/tanner/sentrypeer/conpot. Manager rules 1004xx on
.133 filter on `^192\.168\.1\.` source IPs — only LAN hits page via ntfy
(rules 100401/100402); external internet noise stays silent in T-Pot's own
Kibana on .130:64297. Total enrolled agents now 7. See [[canary]] + spec
`docs/specs/2026-06-01-canary-design.md`.

T-Pot upgrades wipe `/var/ossec` — re-install the agent per
`docs/runbooks/tpot-rebuild.md` Wazuh agent section.
```

---

### Task 8.5: New feedback memory `feedback/recon-list-systemd-services.md`

**Files:**
- Create: `feedback/recon-list-systemd-services.md`

- [ ] **Step 1: Write**

```markdown
---
name: recon-list-systemd-services
description: During host recon, list /etc/systemd/system/*.service directly — don't trust `grep keyword` for finding existing services
metadata:
  type: feedback
  last_verified: 2026-06-XX
---

# Recon — list systemd services directly, don't grep

When reconning a host for "is there already a canary / honeypot / X
running here?", use `ls /etc/systemd/system/*.service` and `systemctl
list-units --type=service --all`, NOT `grep <keyword> /etc/systemd/...`.

**Why:** During canary design 2026-06-01, initial recon used
`systemctl list-units ... | grep -i canary` which found nothing — the
existing `/etc/systemd/system/sinkhole.service` on .120 was missed because
the keyword grep didn't catch it. Almost recommended a duplicate deployment.
The service had been running unmanaged for ~2 months.

**How to apply:** During host recon, the FIRST scan should enumerate ALL
services and look for unfamiliar ones:
- `ls -la /etc/systemd/system/*.service`
- `systemctl list-units --type=service --all`
- For each unfamiliar one: cat its ExecStart, check the file at that path

Only THEN narrow by keyword. The most interesting findings are usually
the things you didn't think to grep for.
```

- [ ] **Step 2: Add to MEMORY.md index**

```markdown
| `feedback/recon-list-systemd-services.md` | List `/etc/systemd/system/*.service` directly during recon — don't trust keyword grep |
```

---

### Task 8.6: Final commit + announce

- [ ] **Step 1: No git commit (memory is outside the soc-ansible repo, stored locally)**

- [ ] **Step 2: Announce completion to user**

> Deployment complete. Summary:
> - `.140 fileserver01` live as internal canary (OpenCanary + sinkhole.py)
> - T-Pot hits piped into Wazuh via .130/.125 agents + rules 1004xx
> - `.121` alias + legacy sinkhole.service decommissioned from .120
> - ntfy paging verified end-to-end
> - Health-check covers everything, agent count = 7
> - OVA backup of .140 captured to OneDrive
> - 5 memory updates committed
>
> Recommended next step from the original list: Atomic Red Team to actually measure detection coverage now that the canary + T-Pot tap are live.

---

## Self-review notes

**Spec coverage check:**
- ✅ §2 In-scope: every item has a task (provision, OpenCanary, sinkhole migrate, .120 cutover, role, agent install, manager rules, ntfy, SMB decoys, health-check, sleep, runbook, memory)
- ✅ §3 Architecture: Tasks 1.x + 2.x + 3.x build the host shape
- ✅ §4 Components: Task 2.x scaffolds the role; Task 1.4 + 5.2 + cutover modify inventory/site/tpot
- ✅ §5 Wazuh wiring: Tasks 4.2 (agent localfile), 4.3 (rules 1003xx), 4.4 (ntfy), 5.3 (rules 1004xx)
- ✅ §6 Health-check: Task 6.1
- ✅ §7 DR + runbooks: Tasks 7.1 (sleep) + 7.2 (OVA backup) + 7.3/7.4 (runbooks)
- ✅ §8 Verification: Task 7.5 (Step 1)
- ✅ §9 Memory updates: Tasks 8.1–8.5
- ✅ §10 Implementation notes: woven into Tasks 2.3 (`--copyconfig`), 4.3 (wazuh-logtest), 6.2 (cutover ordering), 6.1 (Jinja whitespace)

**Type / name consistency:**
- Inventory host name `fileserver-140`, group `canary` — used consistently throughout
- Variables in defaults match references in tasks/templates
- Rule IDs cross-referenced correctly: 100301/302/303/307 in ntfy integration matches definitions in local_rules.xml
- Log paths `/var/tmp/opencanary.log` + `/var/log/sinkhole.json` used in role tasks + Wazuh blockinfile + health-check stat + memory file

**Placeholder scan:** clean — no TBDs, every step has actual content or exact commands.

**Known open implementation-time decisions** (deliberate, called out in tasks):
- OpenCanary config key compatibility: implementer trims unknown keys after first `--copyconfig` (Task 2.3 step 6)
- wazuh-logtest field-name confirmation: implementer adjusts pcre2 paths if decoded fields differ from spec (Task 4.3 step 2, Task 5.3 step 1)
- custom-ntfy script generic vs Suricata-specific: implementer picks Step 3 vs Step 3-alt in Task 4.4
- Sleep-script repo tracking: implementer checks if `soc-sleep-savestate.ps1` is mirrored anywhere in IaC; commit only if so (Task 7.1 step 4)
