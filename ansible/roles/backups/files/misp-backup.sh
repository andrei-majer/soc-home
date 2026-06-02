#!/usr/bin/env bash
# misp-backup.sh - dump MISP MariaDB + tar app/files/, retain 7 daily

set -euo pipefail
umask 077

SERVICE=misp
BACKUP_DIR=/backup/${SERVICE}
TS=$(date +%Y%m%d-%H%M%S)
WORK=$(mktemp -d)
TARGET="${BACKUP_DIR}/${SERVICE}-${TS}.tar.gz"
LOG=/var/log/${SERVICE}-backup.log
RETENTION_DAYS=180

log()  { echo "[$(date +%FT%T)] $*" | tee -a "${LOG}"; }
cleanup() {
  if [ -n "${WORK:-}" ] && [ -d "${WORK}" ]; then
    find "${WORK}" -mindepth 0 -delete 2>/dev/null || true
  fi
}
fail() { log "FAIL: $*"; cleanup; exit 1; }

trap cleanup EXIT

mkdir -p "${BACKUP_DIR}"
log "starting ${SERVICE} backup -> ${TARGET}"

MISP_DB_USER=$(awk -F\' "/'login' =>/{print \$4; exit}" /var/www/MISP/app/Config/database.php)
MISP_DB_PASS=$(awk -F\' "/'password' =>/{print \$4; exit}" /var/www/MISP/app/Config/database.php)
MISP_DB_NAME=$(awk -F\' "/'database' =>/{print \$4; exit}" /var/www/MISP/app/Config/database.php)

[ -n "${MISP_DB_USER}" ] || fail "could not read DB user from database.php"
[ -n "${MISP_DB_NAME}" ] || fail "could not read DB name from database.php"

log "dumping MariaDB ${MISP_DB_NAME}"
mysqldump --single-transaction --quick --routines --triggers \
  -u "${MISP_DB_USER}" -p"${MISP_DB_PASS}" "${MISP_DB_NAME}" \
  > "${WORK}/misp-db.sql" || fail "mysqldump failed"

log "tar attachments dir"
tar -cf "${WORK}/misp-files.tar" -C /var/www/MISP/app files || fail "tar app/files failed"

log "compressing combined tarball"
tar -czf "${TARGET}" -C "${WORK}" misp-db.sql misp-files.tar || fail "compress failed"

SIZE=$(stat -c %s "${TARGET}")
log "done - ${SIZE} bytes"

log "rotation: deleting files older than ${RETENTION_DAYS} days"
find "${BACKUP_DIR}" -name "${SERVICE}-*.tar.gz" -mtime +${RETENTION_DAYS} -print -delete | tee -a "${LOG}"
