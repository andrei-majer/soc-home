#!/usr/bin/env bash
# backup-elk-e.sh — Run on .133 (ssh e) to collect all config + state
# Usage: bash backup-elk-e.sh
# Output: /root/soc-e-backup-$(date).tar.gz  (then fetch it off)
#
# Does NOT dump ES data or full MISP MySQL data — too large.
# Exports Kibana saved objects (dashboards, index patterns, visualizations) via API.
# Exports MISP config files + MariaDB structure + credentials.

set -euo pipefail

STAMP=$(date +%Y%m%d-%H%M%S)
WORKDIR="/tmp/soc-e-backup-${STAMP}"
OUT="/root/soc-e-backup-${STAMP}.tar.gz"

trap 'rm -rf "${WORKDIR}"' EXIT

echo "[+] Backup started — staging in ${WORKDIR}"
mkdir -p "${WORKDIR}"

cp_if() {
    local src="$1"
    local dst="${WORKDIR}${src}"
    if [ -e "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst" 2>/dev/null && echo "    OK  $src" || echo "    ERR $src"
    else
        echo "    --  $src (missing)"
    fi
}

cp_dir() {
    local src="$1"
    local dst="${WORKDIR}${src}"
    if [ -d "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst" 2>/dev/null && echo "    OK  $src/" || echo "    ERR $src/"
    else
        echo "    --  $src/ (missing)"
    fi
}

# ─── Elasticsearch ─────────────────────────────────────────────────────────
echo "[+] Elasticsearch config"
cp_dir /etc/elasticsearch
# Record index list (not data — just names + doc counts for reference)
curl -s "http://localhost:9200/_cat/indices?v&h=index,docs.count,store.size&s=index" \
    > "${WORKDIR}/es-indices.txt" 2>/dev/null || true
echo "    ES indices list → es-indices.txt"
# ILM policies (if any)
curl -s "http://localhost:9200/_ilm/policy" \
    > "${WORKDIR}/es-ilm-policies.json" 2>/dev/null || true
# Index templates
curl -s "http://localhost:9200/_index_template" \
    > "${WORKDIR}/es-index-templates.json" 2>/dev/null || true

# ─── Kibana ────────────────────────────────────────────────────────────────
echo "[+] Kibana config"
cp_dir /etc/kibana

echo "[+] Kibana saved objects export (dashboards, index patterns, visualizations)"
mkdir -p "${WORKDIR}/kibana-saved-objects"
# Export all saved objects in NDJSON format — import with POST /api/saved_objects/_import
curl -s "http://localhost:5601/api/saved_objects/_export" \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    -d '{"type":["dashboard","visualization","lens","search","index-pattern","map","tag"],"includeReferencesDeep":true}' \
    > "${WORKDIR}/kibana-saved-objects/all-saved-objects.ndjson" 2>/dev/null \
    && echo "    OK  Kibana saved objects export" \
    || echo "    ERR Kibana saved objects export (Kibana may be down)"

# ─── Logstash ──────────────────────────────────────────────────────────────
echo "[+] Logstash config"
cp_dir /etc/logstash

# ─── Filebeat ──────────────────────────────────────────────────────────────
echo "[+] Filebeat config"
cp_dir /etc/filebeat

# ─── Wazuh Manager ─────────────────────────────────────────────────────────
echo "[+] Wazuh Manager config"
cp_dir /var/ossec/etc
# Custom rules and decoders
cp_dir /var/ossec/etc/rules
cp_dir /var/ossec/etc/decoders
# SSL certs for agent enrollment
cp_if /var/ossec/etc/sslmanager.cert
cp_if /var/ossec/etc/sslmanager.key
# Agent keys (for re-enrolling same agents without re-running authd)
cp_if /var/ossec/etc/client.keys

# ─── Wazuh Dashboard ───────────────────────────────────────────────────────
echo "[+] Wazuh Dashboard config"
cp_dir /etc/wazuh-dashboard
# Vendor file patches — CRITICAL: these get overwritten on package upgrade
echo "[+] Wazuh Dashboard vendor patches (must reapply after upgrade)"
WAZUH_INTEG="/usr/share/wazuh-dashboard/plugins/wazuh/server/integration-files"
cp_if "${WAZUH_INTEG}/statistics-template.json"
cp_if "${WAZUH_INTEG}/monitoring-template.js"
cp_if "${WAZUH_INTEG}/gdpr-requirements-pdfmake.js"
cp_if "${WAZUH_INTEG}/pci-requirements-pdfmake.js"
cp_if "${WAZUH_INTEG}/tsc-requirements-pdfmake.js"
cp_if "${WAZUH_INTEG}/kibana-template.js"

# ─── MISP ──────────────────────────────────────────────────────────────────
echo "[+] MISP config"
cp_dir /var/www/MISP/app/Config
# Webserver config
cp_if /etc/apache2/sites-enabled/misp.conf
cp_dir /etc/apache2/sites-available
cp_dir /etc/apache2/conf-enabled
# DB credentials
cp_if /root/misp-db-credentials.txt
# MISP DB schema only (no event data — too large; feeds are re-pullable)
echo "[+] MISP MariaDB structure dump (no data)"
mkdir -p "${WORKDIR}/mariadb"
mysqldump --no-data --all-databases \
    > "${WORKDIR}/mariadb/all-databases-structure.sql" 2>/dev/null \
    && echo "    OK  MariaDB structure dump" \
    || echo "    ERR MariaDB structure dump"
# MISP + Wazuh DB credentials from config (already in app/Config above)
# Record which databases exist
mysql -e "SHOW DATABASES;" 2>/dev/null \
    > "${WORKDIR}/mariadb/databases.txt" || true

# ─── Apache2 ───────────────────────────────────────────────────────────────
echo "[+] Apache2 config"
cp_dir /etc/apache2

# ─── Redis ─────────────────────────────────────────────────────────────────
echo "[+] Redis config"
cp_if /etc/redis/redis.conf

# ─── Custom AI scripts ─────────────────────────────────────────────────────
echo "[+] /root/AI scripts and config-backups"
cp_dir /root/AI

# ─── Cron ──────────────────────────────────────────────────────────────────
echo "[+] Crontabs"
cp_if /var/spool/cron/crontabs/root
cp_dir /etc/cron.d

# ─── Logrotate ─────────────────────────────────────────────────────────────
echo "[+] Logrotate (custom configs)"
cp_if /etc/logrotate.d/elasticsearch-soc
cp_if /etc/logrotate.d/logstash-soc
cp_if /etc/logrotate.d/apache2
cp_if /etc/logrotate.d/mariadb

# ─── Systemd units (custom) ────────────────────────────────────────────────
echo "[+] Systemd units"
cp_dir /etc/systemd/system
# Capture wazuh-manager unit override (TimeoutSec=180 fix)
cp_if /lib/systemd/system/wazuh-manager.service
systemctl list-unit-files --state=enabled --no-legend 2>/dev/null \
    > "${WORKDIR}/systemd-enabled-units.txt" || true

# ─── Network ───────────────────────────────────────────────────────────────
echo "[+] Network"
cp_if /etc/network/interfaces
cp_dir /etc/network/interfaces.d
ip addr show 2>/dev/null > "${WORKDIR}/ip-addr.txt" || true

# ─── APT sources ───────────────────────────────────────────────────────────
echo "[+] APT sources"
cp_dir /etc/apt/sources.list.d
cp_if /etc/apt/sources.list
cp_dir /etc/apt/trusted.gpg.d
cp_dir /etc/apt/keyrings

# ─── Package list ──────────────────────────────────────────────────────────
echo "[+] Package list"
dpkg --get-selections > "${WORKDIR}/dpkg-selections.txt" 2>/dev/null || true
dpkg -l | grep -E "elastic|kibana|logstash|filebeat|wazuh|misp|apache|mariadb|redis|php" \
    > "${WORKDIR}/key-packages.txt" 2>/dev/null || true
apt-mark showmanual > "${WORKDIR}/apt-manual.txt" 2>/dev/null || true

# ─── Service versions ──────────────────────────────────────────────────────
echo "[+] Service versions"
{
    echo "=== Elasticsearch ==="
    curl -s http://localhost:9200/ | python3 -m json.tool 2>/dev/null || echo "(down)"
    echo ""
    echo "=== Wazuh Manager ==="
    /var/ossec/bin/wazuh-control info 2>/dev/null || echo "(check /var/ossec/bin/wazuh-control)"
} > "${WORKDIR}/service-versions.txt"

# ─── Pack it up ────────────────────────────────────────────────────────────
trap - EXIT
echo "[+] Creating tarball → ${OUT}"
tar -czf "${OUT}" -C /tmp "soc-e-backup-${STAMP}"
rm -rf "${WORKDIR}"

SIZE=$(du -h "${OUT}" | cut -f1)
echo "[+] Done. Archive: ${OUT} (${SIZE})"
echo ""
echo "    Fetch with:"
echo "      ssh e 'cat ${OUT}' > soc-e-backup-${STAMP}.tar.gz"
