# SOC Lab — Backup & Restore

| Host | IP | SSH | Script |
|---|---|---|---|
| Suricata + Snort 3 | 192.168.1.20 | `ssh s` | `backup-suricata-s.sh` / `restore-suricata-s.sh` |
| ELK + Wazuh + MISP | 192.168.1.21 | `ssh e` | `backup-elk-e.sh` |

Both target fresh **Debian 12 (bookworm)** installs. Backups are config-only — no ES data, no MISP MySQL event data.

---

## Files

| File | Purpose |
|---|---|
| `backup-suricata-s.sh` | Run on .20 — collects all configs into a `.tar.gz` |
| `restore-suricata-s.sh` | Run on fresh .20 — installs packages and restores all configs |
| `backup-elk-e.sh` | Run on .21 — collects all configs + Kibana saved objects into a `.tar.gz` |

---

## Backup

### 1. Copy the script to .20 and run it

```bash
scp backup-suricata-s.sh root@192.168.1.20:/root/
```

**With Snort 3 (default):**
```bash
ssh s "bash /root/backup-suricata-s.sh"
```

**Without Snort 3:**
```bash
ssh s "bash /root/backup-suricata-s.sh --no-snort"
```

Output: `/root/soc-s-backup-YYYYMMDD-HHMMSS.tar.gz` on .20.

### 2. Fetch the archive

```bash
scp root@192.168.1.20:/root/soc-s-backup-*.tar.gz .
```

Store the `.tar.gz` somewhere safe (e.g. this `soc-lab/` folder or external storage).

---

## Restore

### Prerequisites

- Fresh Debian 12 install at `192.168.1.20`
- Same network interface: `enp0s8` (SPAN port, promiscuous)
- Root SSH access
- ELK/MISP host still reachable at `192.168.1.21`
- Router still at `192.168.1.1`

### 1. Copy files to the new machine

```bash
scp soc-s-backup-YYYYMMDD-HHMMSS.tar.gz root@192.168.1.20:/root/
scp restore-suricata-s.sh root@192.168.1.20:/root/
```

### 2. Run the restore script

**Suricata only** (15–20 min):
```bash
ssh s "bash /root/restore-suricata-s.sh /root/soc-s-backup-YYYYMMDD-HHMMSS.tar.gz"
```

**With Snort 3** — binary restore from backup (20–25 min):
```bash
ssh s "bash /root/restore-suricata-s.sh --snort /root/soc-s-backup-YYYYMMDD-HHMMSS.tar.gz"
```

**With Snort 3** — force full source build even if binaries are in backup (30–45 min):
```bash
ssh s "bash /root/restore-suricata-s.sh --snort-build /root/soc-s-backup-YYYYMMDD-HHMMSS.tar.gz"
```

> Use `--snort-build` when deploying to a machine with a different kernel or libc version than the original, as the backed-up binaries may not load.

### 3. Script phases

| Phase | What happens |
|---|---|
| 1 | Adds Suricata OBS, Grafana, Elastic, Wazuh repos; installs all packages |
| 2 | Extracts configs from archive into correct system paths |
| 3 | Enables and starts all services |
| 4 | Runs `suricata-update`, iprep fetch, MISP pull, restarts Suricata |
| 5 | Snort 3 restore: binary restore or source build, config restore, service start |

### 4. Verify

**Suricata:**
```bash
suricatasc -c "version"
systemctl status suricata fail2ban grafana-server filebeat wazuh-agent
tail -f /var/log/suricata/eve.json | python3 -m json.tool | head -40
grep "signatures processed" /var/log/suricata/suricata.log | tail -1
# Expect ~320k signatures
```

**Snort 3 (if restored):**
```bash
systemctl status snort3
snort -c /etc/snort/snort.lua --daq-dir /usr/local/lib/daq -T
tail -f /var/log/snort/alert_fast.txt
```

---

## Services & URLs (post-restore)

> **Credentials below are placeholders.** Set your own admin passwords on first login — do **not** use `CHANGEME` in any environment exposed to the network.

| Service | URL | Credentials |
|---|---|---|
| Grafana | http://192.168.1.20:3000 | admin / CHANGEME |
| EveBox | http://192.168.1.20:8080 | — |
| Velociraptor | http://192.168.1.20:8889 | admin / CHANGEME |
| Arkime | http://192.168.1.20:8005 | admin / CHANGEME |

---

## Manual Steps After Restore

These require manual intervention and are **not** handled by the restore script:

1. **Promiscuous mode** — verify `enp0s8` is set promiscuous in `/etc/network/interfaces`
2. **Loki/Promtail binaries** — if not in backup, download matching versions from [github.com/grafana/loki/releases](https://github.com/grafana/loki/releases)
3. **EveBox/Velociraptor binaries** — if not in backup, download from their release pages
4. **GeoIP** — edit `/etc/GeoIP.conf` if AccountID/LicenseKey changed, then run `geoipupdate`
5. **Wazuh enrollment** — confirm agent is enrolled to `192.168.1.21:1514`
6. **Arkime** — capture is disabled by default; start manually via UI if needed
7. **suricata-enforcer** — installed but inactive; to activate (replaces fail2ban):
   ```bash
   systemctl disable --now fail2ban
   systemctl enable --now suricata-enforcer
   ```
8. **Snort 3 rules** — after restore, pull latest rules manually:
   ```bash
   /usr/local/bin/snort3-update-rules.sh
   ```

---

## What Gets Backed Up

### Always (Suricata)

| Category | Paths |
|---|---|
| Suricata config | `/etc/suricata/` (suricata.yaml, threshold.config, disable/enable/modify.conf, iprep/) |
| Local rules | `/var/lib/suricata/rules/local.rules` |
| Custom scripts | `/usr/local/bin/suricata-iprep-update.sh`, `misp-pull-rules.sh`, `misp-push-sightings.py`, `suricata-enforcer.py` |
| Cron | `/var/spool/cron/crontabs/root`, `/etc/cron.d/` |
| fail2ban | `/etc/fail2ban/jail.local`, `jail.d/`, `filter.d/`, `action.d/` |
| Grafana | `/etc/grafana/grafana.ini`, provisioning, dashboards, `grafana.db` |
| Loki / Promtail | `/etc/loki/`, `/etc/promtail/`, binaries |
| EveBox | `/etc/evebox/`, binary |
| Velociraptor | `/etc/velociraptor/`, binary |
| Arkime | `/opt/arkime/etc/`, `/etc/arkime/config.ini` |
| Filebeat | `/etc/filebeat/` |
| Wazuh agent | `/var/ossec/etc/` |
| GeoIP | `/etc/GeoIP.conf`, mmdb files |
| Logrotate | `/etc/logrotate.d/suricata`, grafana, loki, promtail |
| APT | `dpkg --get-selections`, `/etc/apt/sources.list.d/`, GPG keys |
| Systemd units | `/etc/systemd/system/` (custom units only) |
| MISP state | `/var/lib/suricata/misp-sighting-offset` |

### Optional (Snort 3, default: included, skip with `--no-snort`)

| Category | Paths |
|---|---|
| Snort config + rules | `/etc/snort/` (snort.lua + rules/) |
| Snort binary | `/usr/local/bin/snort` |
| DAQ modules | `/usr/local/lib/daq/`, `/usr/local/lib/libdaq*` |
| Rule update script | `/usr/local/bin/snort3-update-rules.sh` |
| Logrotate | `/etc/logrotate.d/snort3` |
| Systemd unit | `/etc/systemd/system/snort3.service` |
| Version info | `snort-version.txt` (for source rebuild reference) |

---

## Notes

- `suricata-update` re-downloads all rule sources on restore — first run takes several minutes
- MISP has ~113k broken rules (Cyrillic PCRE) that fail at every reload — pre-existing, harmless; ~317k good rules load fine
- Suricata takes ~7 min after restart before the Unix socket is ready; the restore script polls automatically
- Snort 3.3.7.0 was built from source — binaries are included in the backup for fast restore
- If Snort binaries fail on the new machine (kernel/libc mismatch), use `--snort-build` to recompile; takes ~15 min
- Do **not** pass `--tweaks balanced` to Snort — that flag breaks detection in this build
- Grafana Loki datasource UID is `P8E80F9AEF21F6940`; if it changes after reinstall, update dashboard JSONs: `sed -i 's/OLD_UID/NEW_UID/g' /etc/grafana/provisioning/dashboards/*.json`

---

---

# ELK + Wazuh + MISP (.21) — Backup

> No restore script yet — ELK restore is more involved (package order matters, index seeding required).

## Backup

### 1. Copy the script to .21 and run it

```bash
ssh e "cat > /root/backup-elk-e.sh" < backup-elk-e.sh
ssh e "bash /root/backup-elk-e.sh"
```

Output: `/root/soc-e-backup-YYYYMMDD-HHMMSS.tar.gz` on .21.

### 2. Fetch the archive

```bash
ssh e "cat /root/soc-e-backup-YYYYMMDD-HHMMSS.tar.gz" > soc-e-backup-YYYYMMDD-HHMMSS.tar.gz
```

Archive is small (~900 KB) — configs only, no ES indices or MISP event data.

---

## What Gets Backed Up (ELK)

| Category | Paths |
|---|---|
| Elasticsearch | `/etc/elasticsearch/` (elasticsearch.yml, jvm.options, log4j2.properties) |
| ES index list | `es-indices.txt`, `es-ilm-policies.json`, `es-index-templates.json` (reference only) |
| Kibana | `/etc/kibana/kibana.yml` |
| Kibana saved objects | `kibana-saved-objects/all-saved-objects.ndjson` — all dashboards, index patterns, visualizations |
| Logstash | `/etc/logstash/` (suricata.conf + suricata.conf.old) |
| Filebeat | `/etc/filebeat/` |
| Wazuh Manager | `/var/ossec/etc/` (ossec.conf, rules, decoders, SSL certs, client.keys) |
| Wazuh Dashboard | `/etc/wazuh-dashboard/opensearch_dashboards.yml` |
| Wazuh vendor patches | `statistics-template.json`, `monitoring-template.js` + 4 others (reapply after upgrade) |
| MISP config | `/var/www/MISP/app/Config/` (config.php, database.php, email.php) |
| MISP DB credentials | `/root/misp-db-credentials.txt` |
| MariaDB structure | `mariadb/all-databases-structure.sql` (schema only, no event data) |
| Apache2 | `/etc/apache2/` (MISP vhost + conf-enabled) |
| Redis | `/etc/redis/redis.conf` |
| AI scripts | `/root/AI/` (dashboard builder scripts + config-backups) |
| Cron | `/var/spool/cron/crontabs/root`, `/etc/cron.d/` (disk-alert, wazuh cleanup) |
| Logrotate | `/etc/logrotate.d/elasticsearch-soc`, `logstash-soc`, `apache2`, `mariadb` |
| Systemd units | `/etc/systemd/system/`, `/lib/systemd/system/wazuh-manager.service` |
| APT | `dpkg --get-selections`, `/etc/apt/sources.list.d/`, GPG keys |

---

## Manual Restore Order (ELK)

If rebuilding .21 from scratch, install and restore in this order to avoid dependency issues:

1. **MariaDB** — restore first; MISP and Wazuh both need it running
2. **Redis** — restore `/etc/redis/redis.conf`, start service
3. **Elasticsearch** — restore `/etc/elasticsearch/`, start, verify `curl localhost:9200`
4. **Logstash** — restore `/etc/logstash/conf.d/suricata.conf`; fix GeoIP plugin version path if needed
5. **Kibana** — restore `/etc/kibana/kibana.yml`; import saved objects via:
   ```bash
   curl -X POST "http://localhost:5601/api/saved_objects/_import?overwrite=true" \
     -H "kbn-xsrf: true" \
     --form file=@kibana-saved-objects/all-saved-objects.ndjson
   ```
6. **Wazuh Manager** — restore `/var/ossec/etc/`; re-enroll agents if client.keys don't transfer
7. **Wazuh Dashboard** — restore `/etc/wazuh-dashboard/opensearch_dashboards.yml`; reapply vendor patches
8. **MISP** — restore `/var/www/MISP/app/Config/`; restore MariaDB from dump if available; re-pull feeds
9. **Apache2** — restore MISP vhost config, restart

---

## ELK Notes

- **Logstash GeoIP version path** — hardcoded plugin version in `suricata.conf` (e.g. `logstash-filter-geoip-7.3.4-java`); after install check actual version with `ls /usr/share/logstash/vendor/bundle/jruby/*/gems/ | grep geoip` and update the path if different
- **Kibana crash-loop after ES upgrade** — update `migrations.discardUnknownObjects: '<new-version>'` in `/etc/kibana/kibana.yml` to match running Kibana version
- **Wazuh Dashboard file permissions** — after editing `opensearch_dashboards.yml`: `chown root:wazuh-dashboard /etc/wazuh-dashboard/opensearch_dashboards.yml && chmod 640 ...`
- **Wazuh vendor patches** — `statistics-template.json` and `monitoring-template.js` get overwritten on package upgrade; restore from backup after every Wazuh Dashboard upgrade
- **MISP workers crash-loop** — if `misp-workers` fails, check `/var/www/MISP/app/Vendor/iglocska/php-resque-ex/lib/Redisent/Redisent.php` ~line 73 for PHP 8 `implode()` arg order bug
- **Disk** — .21 has a 39 GB disk; ES + Logstash logs fill it fast. Logrotate configs for both are in the backup. Disk alert cron at `/etc/cron.d/disk-alert` (warns at >85%)
