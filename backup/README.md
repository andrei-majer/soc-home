# 💾 Backups

This folder **documents the backup strategy** for the SOC lab. It does **not** contain backup archives themselves — those live off-repo, encrypted or in trusted local storage, because they contain secrets that must never reach a public Git host.

---

## 🚨 Why no tarballs are committed here

`scripts/backup-suricata-s.sh` and `scripts/backup-elk-e.sh` collect **live, unredacted** state from the lab. A single tarball typically contains:

| Backup source | Sensitive content captured |
|---|---|
| `/etc/suricata/` | MISP API keys baked into custom scripts |
| `/var/ossec/etc/client.keys` | Wazuh agent enrollment keys |
| `/var/lib/grafana/grafana.db` | Grafana sqlite — admin sessions, dashboards |
| `/etc/grafana/grafana.ini` | `admin_password` if set explicitly |
| `/root/misp-db-credentials.txt` | MISP DB password |
| `/var/www/MISP/app/Config/{config,database,email}.php` | MISP DB password, salt, GPG passphrase, mail creds |
| `/etc/apache2/sites-enabled/misp.conf` | TLS material if inlined |
| `/var/lib/suricata/misp-sighting-offset` | Internal IDs (low risk) |
| `mariadb/all-databases-structure.sql` | Schema only — no data, low risk |

Pushing any of these to a public repo (or even a public GitHub release) leaks credentials and forces a rotation across the entire lab. The cost of cleanup is much higher than the convenience of having tarballs in `git history`.

GitHub also enforces a **100 MB hard limit per file** on `git push`. The current `.120` config tarball is ~242 MB, so the largest snapshots would be rejected even if secrets weren't a concern.

---

## 📂 Where backups actually live

Three independent backup tracks cover the lab:

### 1. Bare-metal config tarballs (`scripts/backup-*.sh`)

Used for full-host disaster recovery of `.120` (Suricata + Snort 3 + dashboards) and `.133` (ELK + Wazuh + MISP).

| Field | Value |
|---|---|
| Generator | `scripts/backup-suricata-s.sh`, `scripts/backup-elk-e.sh` |
| Output | `/root/soc-{s,e}-backup-YYYYMMDD-HHMMSS.tar.gz` on the source host |
| Storage | OneDrive (`C:\Users\xndre\OneDrive\Claude\soc-lab\`) — synced + offline copies |
| Size | `.120`: ~5–250 MB depending on `--no-binaries` flag · `.133`: <1 MB (config only) |
| Restore | `scripts/restore-suricata-s.sh` for `.120`. ELK has no automated restore — follow the manual phase order in `scripts/README.md` |
| Cadence | Ad-hoc — run before risky changes or major upgrades |

### 2. SOC Ansible repo snapshots (git bundle + state)

Captures the entire `/opt/soc-ansible/` repo (this codebase, as it exists on the live control node) so a lost `.120` can be rebuilt from a single set of files.

| Field | Value |
|---|---|
| Generator | Manual `git bundle` + `tar` from `.120` |
| Outputs | `soc-ansible-<TS>.bundle` (full git history + tags) · `soc-ansible-untracked-<TS>.tar.gz` (`files/originals/` + `backups/`) · `vault_pass-<TS>.txt` (vault password) |
| Storage | OneDrive (`C:\Users\xndre\OneDrive\Claude\backup\soc-ansible\`) |
| Size | Bundle: ~150 KB · Untracked tar: ~70 MB · vault_pass: 33 B |
| Cadence | After each `v0.x.y` tag or significant convergence |

**Refresh command** (run from a Windows workstation with the openwrt SSH key):

```bash
cd "C:/Users/xndre/OneDrive/Claude/backup/soc-ansible"
TS=$(date +%Y%m%d-%H%M%S)

ssh -i ~/.ssh/openwrt root@192.168.1.120 \
    'cd /opt/soc-ansible && \
     git bundle create /tmp/soc-ansible.bundle --all && \
     tar czf /tmp/soc-ansible-untracked.tar.gz files/originals backups'

scp -i ~/.ssh/openwrt root@192.168.1.120:/tmp/soc-ansible.bundle \
    "./soc-ansible-${TS}.bundle"
scp -i ~/.ssh/openwrt root@192.168.1.120:/tmp/soc-ansible-untracked.tar.gz \
    "./soc-ansible-untracked-${TS}.tar.gz"
scp -i ~/.ssh/openwrt root@192.168.1.120:/root/.vault_pass \
    "./vault_pass-${TS}.txt"

ssh -i ~/.ssh/openwrt root@192.168.1.120 \
    'rm -f /tmp/soc-ansible.bundle /tmp/soc-ansible-untracked.tar.gz'
```

> **Restore prerequisite — control-node SSH private key (NOT captured above).**
> Step 4 of the restore reinstalls `/root/.ssh/id_ed25519` — the private key
> that authorizes `root` on every other host, and without which a rebuilt `.120`
> cannot reach anything to converge. The refresh command above does **not** copy
> it (and it must never land in a public repo). Treat it exactly like the vault
> password: stash it separately in two secure places (offline + password
> manager). Either add it to the refresh by scp-ing
> `root@192.168.1.120:/root/.ssh/id_ed25519` to `./id_ed25519-${TS}` (then
> `chmod 600`, store offline only), or keep a known-good copy stashed out of
> band. If it is ever lost, recovery means generating a new keypair and
> re-authorizing the new pubkey on every host's `authorized_keys` by hand.

**Restore to a fresh `.120`:**

```bash
# 1. Install Debian 12 + Ansible
apt-get install -y ansible-core git

# 2. Clone from the bundle
git clone soc-ansible-<TS>.bundle /opt/soc-ansible
cd /opt/soc-ansible

# 3. Restore vault password (from your own secure copy — NOT from a public location)
install -m 600 vault_pass-<TS>.txt /root/.vault_pass

# 4. Restore the SSH private key that authorizes root on every other host
install -m 600 id_ed25519 /root/.ssh/id_ed25519

# 5. Restore the gitignored 'untracked' content (live config originals + per-host backups)
tar xzf soc-ansible-untracked-<TS>.tar.gz -C /opt/soc-ansible/

# 6. Verify
ansible-playbook playbooks/site.yml --check
ansible-playbook playbooks/ops/health-check.yml
```

### 3. Service-native backups

Each service that has its own native backup strategy keeps using it — Ansible only **schedules** the backup, the data lives wherever the service writes it.

| Service | Backup type | Schedule | Location |
|---|---|---|---|
| OpenCTI | Docker volume + `.env` tar | cron, weekly | `/opt/opencti/backups/` on `.135` (gitignored) |
| MISP event data | Manual `mysqldump` of full DB | Pre-upgrade | `.133:/root/` (manual) |
| Elasticsearch indices | Snapshot API | Not currently configured | — |
| T-Pot | Self-managed | T-Pot's own retention | T-Pot internal |

> **Gap:** ES snapshots are not automated. Index data is treated as ephemeral — the `es-cleanup.yml` playbook deletes anything older than the retention window. If you need historical alerts, query Wazuh archive logs (`/var/ossec/logs/archives/`), which are compressed daily and retained on disk.

---

## 🗓️ Snapshot manifest

Latest snapshots known to the lab (kept up to date manually — these are *expected* file names, not committed content):

| Track | Latest snapshot | Date | Size |
|---|---|---|---|
| `.120` config tarball | `soc-s-backup-20260402-121604.tar.gz` | 2026-04-02 | 5.6 MB |
| `.120` config tarball (with binaries) | `soc-s-backup-20260329-092037.tar.gz` | 2026-03-29 | 242 MB |
| `.133` config tarball | `soc-e-backup-20260329-095516.tar.gz` | 2026-03-29 | 891 KB |
| SOC Ansible bundle | `soc-ansible-20260607-154706.bundle` | 2026-06-07 | 734 KB |
| SOC Ansible untracked | `soc-ansible-untracked-20260607-154706.tar.gz` | 2026-06-07 | 70 MB |
| Vault password | `vault_pass-20260607-154706.txt` | 2026-06-07 | 33 B |

---

## ✅ Backup checklist

Use this list before any risky operation (OS upgrade, schema migration, hardware swap):

- [ ] `.120` bare-metal tarball is fresh (`scripts/backup-suricata-s.sh`)
- [ ] `.133` bare-metal tarball is fresh (`scripts/backup-elk-e.sh`)
- [ ] SOC Ansible bundle is fresh (refresh command above)
- [ ] Vault password is in **two** locations (OneDrive + offline / password manager)
- [ ] Control-node SSH private key (`/root/.ssh/id_ed25519` on `.120`) is stashed separately in **two** secure locations (it is a restore prerequisite the backup set does not capture)
- [ ] `playbooks/ops/backup.yml` has been run (service-native backups)
- [ ] `ansible-playbook playbooks/site.yml --check` reports `0 changed` (no uncaptured drift)

---

## 🔐 Secret-handling rules

1. **Never commit a backup tarball to a public repo.** Use OneDrive, an encrypted bucket, or an encrypted local disk.
2. **Never commit `vault_pass-*.txt`** — even temporarily, even in a private repo. Treat it like a root password.
3. If a tarball must be moved across an untrusted channel, encrypt with `age` or `gpg --symmetric` first:
   ```bash
   age -p -o soc-s-backup-<TS>.tar.gz.age soc-s-backup-<TS>.tar.gz
   ```
4. Rotate every secret captured in any backup that ends up somewhere it shouldn't have. The cleanup cost is real — prevention is cheaper.
