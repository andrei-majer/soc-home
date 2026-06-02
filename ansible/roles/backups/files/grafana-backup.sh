#!/usr/bin/env bash
# grafana-backup.sh - sqlite consistent snapshot of grafana.db, retain 7 daily

set -euo pipefail
umask 077

SERVICE=grafana
BACKUP_DIR=/backup/${SERVICE}
TS=$(date +%Y%m%d-%H%M%S)
TARGET="${BACKUP_DIR}/${SERVICE}-${TS}.db.gz"
LOG=/var/log/${SERVICE}-backup.log
RETENTION_DAYS=180
DB=/var/lib/grafana/grafana.db

log()  { echo "[$(date +%FT%T)] $*" | tee -a "${LOG}"; }
fail() { log "FAIL: $*"; exit 1; }

mkdir -p "${BACKUP_DIR}"
[ -r "${DB}" ] || fail "grafana.db missing or unreadable at ${DB}"

log "starting ${SERVICE} backup -> ${TARGET}"

# sqlite3 .backup gives a consistent snapshot while Grafana keeps running
SNAPSHOT="/tmp/grafana-backup-${TS}.db"
sqlite3 "${DB}" ".backup '${SNAPSHOT}'" || fail "sqlite .backup failed"
gzip -c "${SNAPSHOT}" > "${TARGET}" || fail "gzip failed"
rm -f "${SNAPSHOT}"

SIZE=$(stat -c %s "${TARGET}")
log "done - ${SIZE} bytes"

log "rotation: deleting files older than ${RETENTION_DAYS} days"
find "${BACKUP_DIR}" -name "${SERVICE}-*.db.gz" -mtime +${RETENTION_DAYS} -print -delete | tee -a "${LOG}"
