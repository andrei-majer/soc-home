#!/usr/bin/env bash
# restore-suricata-s.sh — Restore .120 from a backup archive on a fresh Debian 12 machine
#
# Prerequisites:
#   - Fresh Debian 12 (bookworm) install, same IP (192.168.1.120), same interface (enp0s8)
#   - Copy backup archive here first:
#       scp soc-s-backup-*.tar.gz root@192.168.1.120:/root/
#   - Run as root: bash restore-suricata-s.sh [--snort] [--snort-build] soc-s-backup-YYYYMMDD-HHMMSS.tar.gz
#
# Flags:
#   --snort       Also restore Snort 3 (binary restore from backup, falls back to source build)
#   --snort-build Force a full source build of Snort 3 + libDAQ even if binaries are in backup
#
# What this does:
#   Phase 1: Add repos + install all packages
#   Phase 2: Extract configs from archive
#   Phase 3: Enable + start services
#   Phase 4: Reload Suricata rules
#   Phase 5: Snort 3 restore (if --snort)
#
# Edit MISP_URL / MISP_KEY below before running if different from defaults.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

RESTORE_SNORT=false
FORCE_SNORT_BUILD=false
ARCHIVE=""
for arg in "$@"; do
    case "$arg" in
        --snort)       RESTORE_SNORT=true ;;
        --snort-build) RESTORE_SNORT=true; FORCE_SNORT_BUILD=true ;;
        *)             ARCHIVE="$arg" ;;
    esac
done

if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
    echo "Usage: bash restore-suricata-s.sh [--snort] [--snort-build] <path-to-backup.tar.gz>"
    exit 1
fi

MISP_URL="http://192.168.1.133"
MISP_KEY="REDACTED"   # set to your MISP automation key before running

SURICATA_VERSION="1:7.0.10-1"   # adjust if OBS repo has moved on
WAZUH_VERSION="4.14.3"

log()  { echo -e "\n\033[1;34m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }

BACKUP_DIR=$(mktemp -d)
trap 'rm -rf "$BACKUP_DIR"' EXIT

log "Extracting archive → ${BACKUP_DIR}"
tar -xzf "$ARCHIVE" -C "$BACKUP_DIR" --strip-components=1

restore_tree() {
    local prefix="$1"
    local src="${BACKUP_DIR}${prefix}"
    if [ -d "$src" ]; then
        mkdir -p "$prefix"   # ensure target exists before cp
        cp -a "$src/." "$prefix/" 2>/dev/null \
            && echo "  OK  $prefix/" \
            || warn "  Could not fully restore $prefix"
    else
        warn "  Not in backup: $prefix"
    fi
}

restore_file() {
    local path="$1"
    local src="${BACKUP_DIR}${path}"
    if [ -f "$src" ]; then
        mkdir -p "$(dirname "$path")"
        cp -a "$src" "$path" && echo "  OK  $path" || warn "  ERR $path"
    else
        echo "  --  $path (not in backup)"
    fi
}

svc_exists() {
    # Returns 0 if systemd knows about the unit (installed or enabled)
    systemctl cat "$1" &>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# PHASE 1 — Package repos + installation
# ═══════════════════════════════════════════════════════════════
log "Phase 1: Package installation"

apt-get update -qq
apt-get install -y --no-install-recommends \
    curl wget gnupg lsb-release ca-certificates apt-transport-https \
    python3 python3-pip python3-requests python3-yaml \
    fail2ban jq geoipupdate mmdb-bin \
    logrotate rsync git

# ── Suricata 7 (OBS repo) ──────────────────────────────────────
log "  Suricata OBS repo"
echo "deb http://download.opensuse.org/repositories/security:/suricata/Debian_12/ /" \
    > /etc/apt/sources.list.d/suricata.list
wget -qO- "https://download.opensuse.org/repositories/security:/suricata/Debian_12/Release.key" \
    | gpg --dearmor > /etc/apt/trusted.gpg.d/suricata.gpg
apt-get update -qq
apt-get install -y suricata suricata-update

# ── Grafana ────────────────────────────────────────────────────
log "  Grafana repo"
mkdir -p /etc/apt/keyrings
wget -qO - https://apt.grafana.com/gpg.key \
    | gpg --dearmor > /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
apt-get update -qq
apt-get install -y grafana

# ── Loki + Promtail ────────────────────────────────────────────
# Installed as binaries — restore from backup or download manually
log "  Loki / Promtail binaries"
LOKI_SRC="${BACKUP_DIR}/usr/local/bin/loki"
PROMTAIL_SRC="${BACKUP_DIR}/usr/local/bin/promtail"
if [ -f "$LOKI_SRC" ]; then
    cp "$LOKI_SRC" /usr/local/bin/loki && chmod +x /usr/local/bin/loki
    echo "  Loki: restored from backup"
else
    warn "  Loki binary not in backup — download manually from https://github.com/grafana/loki/releases"
fi
if [ -f "$PROMTAIL_SRC" ]; then
    cp "$PROMTAIL_SRC" /usr/local/bin/promtail && chmod +x /usr/local/bin/promtail
    echo "  Promtail: restored from backup"
else
    warn "  Promtail binary not in backup — download manually"
fi

# ── Filebeat ──────────────────────────────────────────────────
log "  Filebeat repo"
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch \
    | gpg --dearmor > /etc/apt/trusted.gpg.d/elasticsearch.gpg
echo "deb https://artifacts.elastic.co/packages/8.x/apt stable main" \
    > /etc/apt/sources.list.d/elastic-8.x.list
apt-get update -qq
apt-get install -y filebeat

# ── Wazuh agent ───────────────────────────────────────────────
log "  Wazuh agent ${WAZUH_VERSION}"
curl -sO https://packages.wazuh.com/key/GPG-KEY-WAZUH
gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg \
    --import GPG-KEY-WAZUH && chmod 644 /usr/share/keyrings/wazuh.gpg
rm -f GPG-KEY-WAZUH
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
    > /etc/apt/sources.list.d/wazuh.list
apt-get update -qq
WAZUH_AGENT_VERSION=$(apt-cache show wazuh-agent 2>/dev/null \
    | grep "^Version:" | grep "${WAZUH_VERSION}" | head -1 | awk '{print $2}')
if [ -n "$WAZUH_AGENT_VERSION" ]; then
    WAZUH_MANAGER="192.168.1.133" apt-get install -y "wazuh-agent=${WAZUH_AGENT_VERSION}"
else
    warn "  Exact Wazuh version ${WAZUH_VERSION} not found — installing latest 4.x"
    WAZUH_MANAGER="192.168.1.133" apt-get install -y wazuh-agent
fi

# ── EveBox ────────────────────────────────────────────────────
log "  EveBox"
EVEBOX_SRC="${BACKUP_DIR}/usr/local/bin/evebox"
if [ -f "$EVEBOX_SRC" ]; then
    cp "$EVEBOX_SRC" /usr/local/bin/evebox && chmod +x /usr/local/bin/evebox
    echo "  EveBox: restored from backup"
else
    warn "  EveBox binary not in backup — download from https://evebox.org"
fi

# ── Velociraptor ──────────────────────────────────────────────
log "  Velociraptor"
VELOCI_SRC="${BACKUP_DIR}/usr/local/bin/velociraptor"
if [ -f "$VELOCI_SRC" ]; then
    cp "$VELOCI_SRC" /usr/local/bin/velociraptor && chmod +x /usr/local/bin/velociraptor
    echo "  Velociraptor: restored from backup"
else
    warn "  Velociraptor binary not in backup — download from GitHub releases"
fi

# ── Python deps for custom scripts ───────────────────────────
pip3 install --quiet --break-system-packages requests pymisp 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════
# PHASE 2 — Restore configs from archive
# ═══════════════════════════════════════════════════════════════
log "Phase 2: Restoring configuration files"

# Suricata
restore_tree /etc/suricata
restore_file /var/lib/suricata/rules/local.rules
restore_file /var/lib/suricata/misp-sighting-offset

# Custom scripts
for f in suricata-iprep-update.sh misp-pull-rules.sh misp-push-sightings.py suricata-enforcer.py; do
    restore_file "/usr/local/bin/${f}"
    [ -f "/usr/local/bin/${f}" ] && chmod +x "/usr/local/bin/${f}"
done

# Cron
restore_file /var/spool/cron/crontabs/root
chmod 600 /var/spool/cron/crontabs/root 2>/dev/null || true
restore_tree /etc/cron.d

# fail2ban
restore_file /etc/fail2ban/jail.local
restore_tree /etc/fail2ban/jail.d
restore_tree /etc/fail2ban/filter.d
restore_tree /etc/fail2ban/action.d

# Promtail / Loki
restore_tree /etc/promtail
restore_tree /etc/loki

# Grafana
restore_file /etc/grafana/grafana.ini
restore_tree /etc/grafana/provisioning
restore_tree /var/lib/grafana/dashboards
restore_file /var/lib/grafana/grafana.db
chown -R grafana:grafana /var/lib/grafana 2>/dev/null || true

# EveBox
restore_tree /etc/evebox

# Velociraptor
restore_tree /etc/velociraptor

# Arkime
restore_tree /opt/arkime/etc
restore_file /etc/arkime/config.ini

# Filebeat
restore_tree /etc/filebeat

# Wazuh agent
restore_tree /var/ossec/etc

# GeoIP
restore_file /etc/GeoIP.conf
restore_tree /usr/share/GeoIP
restore_tree /var/lib/GeoIP

# Logrotate
for svc in suricata grafana loki promtail; do
    restore_file "/etc/logrotate.d/${svc}"
done

# Systemd units (custom)
restore_tree /etc/systemd/system
systemctl daemon-reload

# iprep dir (scripts write here)
mkdir -p /etc/suricata/iprep

# ═══════════════════════════════════════════════════════════════
# PHASE 3 — Enable + start services
# ═══════════════════════════════════════════════════════════════
log "Phase 3: Enabling services"

SERVICES=(suricata fail2ban grafana-server filebeat wazuh-agent)

[ -f /etc/systemd/system/loki.service ]             && SERVICES+=(loki)
[ -f /etc/systemd/system/promtail.service ]         && SERVICES+=(promtail)
[ -f /etc/systemd/system/evebox.service ]           && SERVICES+=(evebox)
[ -f /etc/systemd/system/velociraptor.service ]     && SERVICES+=(velociraptor)

for svc in "${SERVICES[@]}"; do
    if svc_exists "${svc}.service"; then
        systemctl enable --now "${svc}" 2>/dev/null \
            && echo "  started: $svc" \
            || warn "  failed to start: $svc — check: journalctl -u $svc -n 20"
    else
        warn "  unit not found: ${svc}.service"
    fi
done

# GeoIP first run
log "  Running geoipupdate"
geoipupdate 2>/dev/null \
    && echo "  GeoIP updated" \
    || warn "  geoipupdate failed — check AccountID/LicenseKey in /etc/GeoIP.conf"

# ═══════════════════════════════════════════════════════════════
# PHASE 4 — Suricata rules
# ═══════════════════════════════════════════════════════════════
log "Phase 4: Loading Suricata rules"

# Re-enable rule sources that were active in the backup
SOURCES_FILE="${BACKUP_DIR}/suricata-update-enabled-sources.txt"
if [ -f "$SOURCES_FILE" ] && [ -s "$SOURCES_FILE" ]; then
    log "  Re-enabling rule sources from backup"
    suricata-update update-sources
    while read -r line; do
        # Lines look like: "et/open" or "  et/open  Enabled"
        src=$(echo "$line" | awk '{print $1}')
        [ -z "$src" ] && continue
        suricata-update enable-source "$src" 2>/dev/null \
            && echo "  enabled: $src" \
            || echo "  skipped: $src (may already be enabled or not available)"
    done < "$SOURCES_FILE"
else
    suricata-update update-sources
fi

log "  Running suricata-update"
suricata-update || warn "  suricata-update had errors (check output)"

log "  Running initial iprep fetch"
/usr/local/bin/suricata-iprep-update.sh 2>/dev/null || warn "  iprep update failed"

log "  Running initial MISP pull"
/usr/local/bin/misp-pull-rules.sh 2>/dev/null || warn "  MISP pull failed (check MISP connectivity)"

log "  Restarting Suricata with full rule set"
systemctl restart suricata

log "  Waiting for Suricata to become ready (up to 10 min)..."
SURICATA_READY=false
for i in $(seq 1 40); do
    sleep 15
    if suricatasc -c "version" &>/dev/null; then
        COUNT=$(grep "signatures processed" /var/log/suricata/suricata.log 2>/dev/null | tail -1)
        echo "  Ready: ${COUNT}"
        SURICATA_READY=true
        break
    fi
    echo "  ... still loading ($((i*15))s)"
done
[ "$SURICATA_READY" = "false" ] && warn "  Suricata socket not ready after 10 min — check: journalctl -u suricata -n 50"

# ═══════════════════════════════════════════════════════════════
# PHASE 5 — Snort 3 (optional, requires --snort flag)
# ═══════════════════════════════════════════════════════════════
if [ "$RESTORE_SNORT" = "true" ]; then
    log "Phase 5: Snort 3 restore"

    SNORT_VERSION="3.3.7.0"
    LIBDAQ_VERSION="3.0.16"

    # ── Try binary restore first ──────────────────────────────
    SNORT_BIN="${BACKUP_DIR}/usr/local/bin/snort"
    SNORT_BUILD_NEEDED=false

    if [ "$FORCE_SNORT_BUILD" = "false" ] && [ -f "$SNORT_BIN" ]; then
        log "  Restoring Snort 3 binaries from backup"
        restore_file /usr/local/bin/snort
        chmod +x /usr/local/bin/snort

        restore_tree /usr/local/lib/daq
        if [ -d "${BACKUP_DIR}/usr/local/lib" ]; then
            find "${BACKUP_DIR}/usr/local/lib" -maxdepth 1 -name "libdaq*" | while read -r f; do
                dst="/usr/local/lib/$(basename "$f")"
                cp -a "$f" "$dst" && echo "  OK  $dst"
            done
        fi
        restore_tree /usr/local/lib/snort_extra 2>/dev/null || true
        ldconfig

        if /usr/local/bin/snort --version &>/dev/null; then
            echo "  Snort binary OK: $(/usr/local/bin/snort --version 2>&1 | head -1)"
        else
            warn "  Snort binary failed to run — falling back to source build"
            SNORT_BUILD_NEEDED=true
        fi
    else
        [ "$FORCE_SNORT_BUILD" = "true" ] && log "  --snort-build forced — skipping binary restore"
        [ ! -f "$SNORT_BIN" ]             && warn "  Snort binary not in backup — will build from source"
        SNORT_BUILD_NEEDED=true
    fi

    # ── Source build fallback ─────────────────────────────────
    if [ "$SNORT_BUILD_NEEDED" = "true" ]; then
        log "  Building Snort ${SNORT_VERSION} + libDAQ ${LIBDAQ_VERSION} from source"
        echo "  This will take 15-20 minutes..."

        apt-get install -y \
            build-essential cmake pkg-config \
            libpcap-dev libpcre2-dev libdumbnet-dev zlib1g-dev \
            liblzma-dev openssl libssl-dev libnghttp2-dev \
            libhwloc-dev libnuma-dev libluajit-5.1-dev \
            libunwind-dev libfl-dev bison flex \
            autoconf automake libtool

        mkdir -p /usr/local/src
        cd /usr/local/src

        # libDAQ
        LIBDAQ_TAR="libdaq-${LIBDAQ_VERSION}.tar.gz"
        if [ ! -f "$LIBDAQ_TAR" ]; then
            wget -q "https://github.com/snort3/libdaq/releases/download/v${LIBDAQ_VERSION}/${LIBDAQ_TAR}" \
                || { warn "  Failed to download libDAQ — place tarball at /usr/local/src/${LIBDAQ_TAR} and re-run"; exit 1; }
        fi
        tar -xzf "$LIBDAQ_TAR"
        cd "libdaq-${LIBDAQ_VERSION}"
        autoreconf -fi
        ./configure
        make -j"$(nproc)"
        make install
        ldconfig
        cd /usr/local/src

        # Snort 3
        # NOTE: do NOT use --tweaks balanced — breaks detection in this build
        SNORT_TAR="snort3-${SNORT_VERSION}.tar.gz"
        if [ ! -f "$SNORT_TAR" ]; then
            wget -q "https://github.com/snort3/snort3/releases/download/v${SNORT_VERSION}/${SNORT_TAR}" \
                || { warn "  Failed to download Snort — place tarball at /usr/local/src/${SNORT_TAR} and re-run"; exit 1; }
        fi
        tar -xzf "$SNORT_TAR"
        cd "snort3-${SNORT_VERSION}"
        cmake -DCMAKE_INSTALL_PREFIX=/usr/local \
              -DDAQ_INCLUDE_DIR=/usr/local/include \
              -DDAQ_LIBRARIES=/usr/local/lib/libdaq.so \
              -DENABLE_TCMALLOC=OFF \
              -B build .
        cmake --build build -j"$(nproc)"
        cmake --install build
        ldconfig
        cd /root

        echo "  Build complete: $(/usr/local/bin/snort --version 2>&1 | head -1)"
    fi

    # ── Restore Snort configs ─────────────────────────────────
    log "  Restoring Snort 3 config + rules"
    restore_tree /etc/snort
    restore_file /usr/local/bin/snort3-update-rules.sh
    [ -f /usr/local/bin/snort3-update-rules.sh ] && chmod +x /usr/local/bin/snort3-update-rules.sh
    restore_file /etc/logrotate.d/snort3

    mkdir -p /var/log/snort
    touch /var/log/snort/alert_fast.txt /var/log/snort/alert_json.txt

    # Validate config
    log "  Validating Snort config"
    snort -c /etc/snort/snort.lua --daq-dir /usr/local/lib/daq -T \
        && echo "  Config OK" \
        || warn "  Config validation failed — check /etc/snort/snort.lua"

    # Enable service
    systemctl daemon-reload
    if svc_exists snort3.service; then
        systemctl enable --now snort3 \
            && echo "  snort3 started" \
            || warn "  snort3 failed to start — check: journalctl -u snort3 -n 30"
    else
        warn "  snort3.service not found — create it manually"
    fi
else
    log "Phase 5: Snort 3 — skipped (pass --snort to restore)"
fi

# ═══════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════
log "Restore complete"
echo ""
echo "  Verify:"
echo "    suricatasc -c 'version'"
echo "    systemctl status suricata fail2ban grafana-server filebeat"
echo "    tail -f /var/log/suricata/eve.json | python3 -m json.tool | head -40"
echo ""
echo "  Dashboards:"
echo "    Grafana:      http://192.168.1.120:3000  (admin / CHANGEME)"
echo "    EveBox:       http://192.168.1.120:8080"
echo "    Velociraptor: http://192.168.1.120:8889"
echo ""
if [ "$RESTORE_SNORT" = "true" ]; then
    echo "  Snort:"
    echo "    systemctl status snort3"
    echo "    tail -f /var/log/snort/alert_fast.txt"
    echo "    snort -c /etc/snort/snort.lua --daq-dir /usr/local/lib/daq -T"
    echo ""
fi
warn "  Manual steps if needed:"
echo "    1. Verify enp0s8 is promiscuous (check /etc/network/interfaces.d/enp0s8-promisc)"
echo "    2. suricata-enforcer: systemctl enable --now suricata-enforcer (disable fail2ban first)"
echo "    3. Arkime: manual capture start via UI at :8005"
echo "    4. Wazuh: confirm agent enrolled to 192.168.1.133:1514"
if [ "$RESTORE_SNORT" = "true" ]; then
    echo "    5. Snort rules: run /usr/local/bin/snort3-update-rules.sh to pull latest"
    echo "    6. If Snort won't start: journalctl -u snort3 -n 30 — do NOT use --tweaks balanced"
fi
