# Runbook: T-Pot Rebuild (HIVE + Sensor)

Procedure for rebuilding T-Pot 24.04.1 on both the HIVE aggregator (192.168.1.23) and the Sensor (192.168.1.25).

Install path on both: `/home/andrei/tpotce/`. User: `andrei`.

## HIVE Overview

| Field | Value |
|---|---|
| IP | 192.168.1.23 |
| TPOT_TYPE | `HIVE` |
| SSH port | 64295 |
| Web UI | https://192.168.1.23:64297 |

## Sensor Overview

| Field | Value |
|---|---|
| IP | 192.168.1.25 |
| TPOT_TYPE | `SENSOR` |
| SSH port | 64295 |
| NIC | virtio-net, MAC `08:00:27:7b:64:01` |
| Interface pin | `/etc/systemd/network/10-enp0s3.link` (match by MAC, name `enp0s3`) |
| VM sizing | 8192 MB RAM / 2 vCPU (raised from 4096 MB on 2026-08-01 — T-Pot's documented sensor minimum is 8 GB) |
| Auto-start | **none** — absent from `.15`'s `soc-wake.sh` `SOC_VMS` map and VBox `autostart-enabled=off`. After any `.15` reboot start it by hand: `VBoxManage startvm "T-Pot Sensor" --type headless` |

The NIC pin is required — without it Debian may name the interface `ens3` or similar on reboot and Docker bridges fail.

## Install HIVE From Scratch

1. Install **Debian 12** base (minimal, SSH server only).
2. Clone T-Pot:
   ```bash
   git clone https://github.com/telekom-security/tpotce /home/andrei/tpotce
   ```
3. As `andrei`, run `./install.sh`, choose **HIVE**.
4. **Reboot.**
5. Edit `/home/andrei/tpotce/.env` and set `TPOT_PULL_POLICY=missing` (avoids unnecessary image pulls on every start).
6. HIVE nginx certificate will be generated at:
   ```
   /home/andrei/tpotce/data/nginx/cert/nginx.crt
   ```
   SAN: `192.168.1.23`. Sensors must trust this cert.

## Install Sensor From Scratch

1. Install **Debian 12** base.
2. **Pin the NIC** before anything else — create `/etc/systemd/network/10-enp0s3.link`:
   ```ini
   [Match]
   MACAddress=08:00:27:7b:64:01

   [Link]
   Name=enp0s3
   ```
3. Clone `tpotce`, run `./install.sh`, choose **SENSOR**.
4. Connect the Sensor to the HIVE using **one** of:

   **Option A — automated (preferred):** run `deploy.sh` on the HIVE. It uses Ansible to push the HIVE cert + credentials to the Sensor. Requires SSH key + sudo password for `andrei@192.168.1.25`.

   **Option B — manual:**
   - Copy HIVE cert to Sensor: `/home/andrei/tpotce/data/hive.crt`
   - Update Sensor `.env` with HIVE IP (`192.168.1.23`) and credentials
   - Copy `compose/sensor.yml` to `docker-compose.yml`
   - Reboot

## Post-Install (REQUIRED for Ansible backup access)

The Ansible control node at .20 needs SSH + firewall access to both T-Pot hosts to run backups.

1. **Add .20's SSH key** to `/root/.ssh/authorized_keys` on both HIVE and Sensor.
2. **Open SSH port 64295 for .20**:
   ```bash
   iptables -I INPUT -s 192.168.1.20 -p tcp --dport 64295 -j ACCEPT
   ```
3. **Persist**:
   ```bash
   netfilter-persistent save
   ```
   (or add the rule to `/etc/rc.local` as a fallback)

Without step 3 the rule is lost on reboot and backups silently fail.

## Post-Install Optimizations

- **Remove conpot containers** (4 × ~438 MB each). Edit `docker-compose.yml` and delete the `conpot_*` service blocks. Reduces image pull + RAM footprint.
- **Docker log rotation**: daily, 7 days retention, 100 MB max per file, compressed. Configure in `/etc/docker/daemon.json`.
- **Sensor Logstash heap — do NOT lower this.** T-Pot ships the sensor at
  `LS_JAVA_OPTS: "-Xms512m -Xmx512m"` / `mem_limit: 1g`, and that is *too small* for the stock
  pipeline: `http_output.conf` loads `/etc/listbot/iprep.yaml` (~20 MB, ~620k entries) into a
  `translate` dictionary, which OOM-kills logstash during pipeline converge — before a single
  event is processed — in an endless restart loop. The HIVE survives the same file only because
  it runs `1024m` / `mem_limit: 2g`. Either give the sensor the HIVE's numbers, or disable the
  iprep lookup (what we do — see "Sensor logstash OOM loop" under Known Issues).
- **HIVE Elasticsearch ILM**: 14-day retention. ES listens on port **64298**.

## Known Issues

### Sensor silently ships nothing after an IP renumber (found 2026-08-01)
Three independent faults, each one masking the next. The sensor looked "up" throughout — all
honeypot containers healthy — while delivering **zero** events to the HIVE. Check all three:

1. **Stale HIVE IP.** `grep TPOT_HIVE_IP /home/andrei/tpotce/.env` must match the live HIVE.
   Verify the credential separately:
   `curl -sk -o /dev/null -w '%{http_code}\n' -H "Authorization: Basic $TPOT_HIVE_USER" https://<hive>:64294`
   → expect `200` (`401` = bad credential, no response = wrong IP).
2. **Sensor logstash OOM loop.** Symptom: the sensor VM pins ~100% of one core on `.15` and
   `docker inspect logstash --format '{{.RestartCount}}'` climbs. Log shows
   `java.lang.OutOfMemoryError` with `org.jruby.ext.psych.PsychParser` in the trace — that is the
   iprep YAML, not a network fault. Fixed by the `tpot` Ansible role, which installs a patched
   `http_output.conf` at `/home/andrei/tpotce/etc/logstash/http_output.conf` with the iprep
   `translate` block commented out, plus the `docker-compose.yml` bind-mount line that exposes it.
   Both are re-asserted on every converge, because a T-Pot upgrade that rewrites
   `docker-compose.yml` drops the mount and the loop returns. Cost: sensor events lose the
   `ip_rep` src_ip reputation field.
3. **Stale HIVE cert.** The HIVE's nginx cert is pinned by IP in its SAN, so an IP renumber
   invalidates every sensor's copy. Symptom once logstash stops crashing: it stays healthy but
   `out=0`, logging `certificate_unknown` / `PKIX path building failed`. Compare:
   ```bash
   openssl x509 -in /home/andrei/tpotce/data/hive.crt -noout -ext subjectAltName   # on the sensor
   openssl x509 -in /home/andrei/tpotce/data/nginx/cert/nginx.crt -noout -ext subjectAltName  # on the HIVE
   ```
   Fix by copying the HIVE's `nginx.crt` to the sensor's `data/hive.crt` and restarting logstash.

Confirm the whole chain end-to-end from the HIVE rather than trusting container health:
```bash
curl -s "http://127.0.0.1:64298/logstash-*/_search?size=0" -H 'Content-Type: application/json' \
  -d '{"query":{"range":{"@timestamp":{"gte":"now-5m"}}},
       "aggs":{"by_host":{"terms":{"field":"t-pot_hostname.keyword","size":10}}}}'
```
Both `t-pot-hive-23` and `t-pot-sensor-25` must appear with non-zero counts.

### Phantom Docker containers
Symptom: `docker ps` shows containers that cannot be stopped; networking broken.
Fix:
```bash
systemctl stop tpot
rm -rf /var/lib/docker/containers/<id>
systemctl restart docker
systemctl start tpot
```

### Sensor network not up on cold boot
Use VRDE console from the hypervisor (see `windows-15.md`) to log in and bring the interface up manually, then investigate the NIC pin link file.

## Sensor Credentials

Sensor-to-HIVE authentication uses HTTP basic auth over HTTPS.

- HIVE `.env` carries `LS_WEB_USER` (base64 htpasswd entries).
- Live htpasswd file: `/home/andrei/tpotce/data/nginx/conf/lswebpasswd`.

**Add a new sensor user:**
```bash
htpasswd /home/andrei/tpotce/data/nginx/conf/lswebpasswd <user>
# then update LS_WEB_USER in .env accordingly
```

## Verify

**HIVE:**
```bash
docker ps | wc -l       # ~39 containers
curl -k https://192.168.1.23:64297   # web UI
```

**Sensor:**
```bash
docker ps | wc -l       # ~32 containers
```

**Logstash HIVE connection (from Sensor):**
```bash
docker logs logstash 2>&1 | grep -E "Hive|Connected|SSL"
```
Expect "Connected" / successful SSL handshake entries.


## Wazuh agent (post-rebuild step, added 2026-06-01)

T-Pot rebuilds wipe `/var/ossec`. Re-install the agent after the rebuild
so internal-source hits keep paging via .21 + ntfy.

```bash
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
apt-get update
WAZUH_MANAGER='192.168.1.21' apt-get install -y wazuh-agent=4.14.5-1
echo "wazuh-agent hold" | dpkg --set-selections
systemctl enable --now wazuh-agent
```

Then converge the IaC to restore the localfile blockinfile:

```bash
ssh -i ~/.ssh/openwrt root@192.168.1.20 'cd /opt/soc-ansible && ansible-playbook playbooks/site.yml --limit <tpot-hive-23|tpot-sensor-25>'
```

Verify agent enrolled (`agent_control -l` should list 8 lines — 7 enrolled agents plus the
`elk (server)` entry; the health-check playbook asserts the enrolled count is 7):

```bash
ssh -i ~/.ssh/openwrt root@192.168.1.20 'cd /opt/soc-ansible && ansible-playbook playbooks/ops/health-check.yml'
```
