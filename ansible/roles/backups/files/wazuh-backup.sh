#!/usr/bin/env bash
# wazuh-backup.sh - tar Wazuh enrollment + SSL identity, retain 7 daily

set -euo pipefail
umask 077

SERVICE=wazuh
BACKUP_DIR=/backup/${SERVICE}
TS=$(date +%Y%m%d-%H%M%S)
TARGET="${BACKUP_DIR}/${SERVICE}-${TS}.tar.gz"
LOG=/var/log/${SERVICE}-backup.log
RETENTION_DAYS=180
OSSEC=/var/ossec

PATHS=(
  etc/client.keys
  etc/sslmanager.cert
  etc/sslmanager.key
  etc/lists
)

log()  { echo "[$(date +%FT%T)] $*" | tee -a "${LOG}"; }
fail() { log "FAIL: $*"; exit 1; }

mkdir -p "${BACKUP_DIR}"
log "starting ${SERVICE} backup -> ${TARGET}"

for p in "${PATHS[@]}"; do
  [ -e "${OSSEC}/${p}" ] || fail "expected path ${OSSEC}/${p} missing"
done

tar -czf "${TARGET}" -C "${OSSEC}" "${PATHS[@]}" || fail "tar failed"

SIZE=$(stat -c %s "${TARGET}")
log "done - ${SIZE} bytes"

log "rotation: deleting files older than ${RETENTION_DAYS} days"
find "${BACKUP_DIR}" -name "${SERVICE}-*.tar.gz" -mtime +${RETENTION_DAYS} -print -delete | tee -a "${LOG}"
