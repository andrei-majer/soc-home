# Runbook: MISP Rebuild (192.168.1.133)

MISP 2.5.32 installation + database restore procedure. MISP shares the .133 host with Elasticsearch, Kibana, and Wazuh manager.

## Overview

| Field | Value |
|---|---|
| Version | MISP 2.5.32 |
| Branch | `2.5` |
| Install path | `/var/www/MISP/` |
| PHP | 8.2 |
| Python | 3.11 |
| OS | Debian 12 |

## Services

| Component | Location |
|---|---|
| Apache2 vhost | `/etc/apache2/sites-available/misp.conf` |
| Database | MariaDB (local) |
| Cache / queues | Redis (local) |
| Workers | `misp-workers` systemd unit |

## Access

| Field | Value |
|---|---|
| URL | http://192.168.1.133 |
| Admin user | `admin@admin.test` |
| Admin password | _rotated; stored in vault as `vault_misp_admin_password`_ |

## Install From Scratch

1. **Follow the official MISP install for Debian 12.** Reference: `INSTALL.ubuntu.md` from the MISP repo, adapted for Debian 12 paths (PHP 8.2 vs 8.1).
2. **PHP memory limit** — set `memory_limit = 2G` in `/etc/php/8.2/apache2/php.ini`. The Ansible `misp` role does this automatically.
3. **PHP 8 implode bug fix.** Edit:
   ```
   /var/www/MISP/app/Vendor/iglocska/php-resque-ex/lib/Redisent/Redisent.php
   ```
   Around line 73, change:
   ```php
   implode($args, CRLF)
   ```
   to:
   ```php
   implode(CRLF, $args)
   ```
   (argument order was swapped in PHP 8.) Ansible `misp` role handles this.
4. **Create users:**
   - `admin@admin.test` — site admin
   - `andrei@infomara.com` — org admin

## API Keys (from vault)

| Purpose | Vault variable |
|---|---|
| Control-node pull/push (admin user) | `vault_misp_api_key` |
| OpenCTI connector (admin user) | `vault_misp_api_key_opencti` |

Keys are never stored in this repo — only their vault variable names. With
`advanced_authkeys` enabled (Administration → Server Settings), a user can hold
multiple keys; create/rotate one via the API or `cake User change_authkey` and
record the value in the matching vault variable.

**Regenerate a key:**
```bash
cd /var/www/MISP
sudo -u www-data app/Console/cake User change_authkey admin@admin.test
```

## Enabled Feeds (8)

| ID | Name |
|---|---|
| 1 | CIRCL OSINT |
| 2 | Botvrij.eu |
| 4 | ET blockrules |
| 12 | Feodo Tracker |
| 14 | firehol_level1 |
| 18 | AlienVault reputation |
| 19 | blocklist.de |
| 34 | abuse.ch SSL IPBL |

Enable via UI: **Sync Actions → List Feeds → toggle**.

## Workers

```bash
systemctl status misp-workers
```

On a fresh start the unit sometimes reports `activating` — wait 30 seconds then re-check, or verify directly:
```bash
supervisorctl status
```

## DB Restore

```bash
systemctl stop misp-workers
mysql -u root misp < misp-backup.sql
systemctl start misp-workers
```

Always stop workers before restoring — in-flight Redis jobs will reference stale DB state otherwise.

## Integration Verification

| Flow | Mechanism | Schedule |
|---|---|---|
| MISP to Suricata rules | `/usr/local/bin/misp-pull-rules.sh` on .120 | cron every 6h |
| Suricata to MISP sightings | `/usr/local/bin/misp-push-sightings.py` on .120 | cron hourly at :30 |
| MISP to OpenCTI | connector on .135 | every 5 minutes |

## Known Issues

- **113,748 rules fail at every reload.** Broken PCRE patterns + Cyrillic characters in upstream feeds. Harmless — **317,000+ good rules still load** and Suricata starts cleanly.
- **Export quirks.** Raw MISP Suricata export contains `priority:;` (empty priority) which Suricata rejects. The pull script strips these before writing to disk.
- **`|3b|`-rules** cause roughly 72,000 Suricata parse failures. Non-critical — same category as the PCRE issue.

## Verify

```bash
# Login page reachable
curl http://192.168.1.133

# API works
curl -H "Authorization: <MISP_API_KEY>" \
     http://192.168.1.133/events/index.json | head

# Worker errors
tail /var/www/MISP/app/tmp/logs/resque-worker-error.log
```
