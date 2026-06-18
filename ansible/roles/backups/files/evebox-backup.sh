#!/usr/bin/env bash
# evebox-backup.sh - snapshot EveBox config + auth/config sqlite DBs into one
# tarball. EveBox is NOT Ansible-managed, so this is the only DR path for
# evebox.yaml (retention tuning, auth type, geoip, the zeek-to-eve input path).
# Skips events.sqlite (large + regenerable from eve.json bookmarks).

set -euo pipefail
umask 077

SERVICE=evebox
BACKUP_DIR=/backup/${SERVICE}
TS=$(date +%Y%m%d-%H%M%S)
TARGET="${BACKUP_DIR}/${SERVICE}-${TS}.tar.gz"
LOG=/var/log/${SERVICE}-backup.log
RETENTION_DAYS=180
CONF=/etc/evebox/evebox.yaml
LIBDIR=/var/lib/evebox

log()  { echo "[$(date +%FT%T)] $*" | tee -a "${LOG}"; }
fail() { log "FAIL: $*"; exit 1; }

mkdir -p "${BACKUP_DIR}"
[ -r "${CONF}" ] || fail "evebox.yaml missing or unreadable at ${CONF}"

log "starting ${SERVICE} backup -> ${TARGET}"

STAGE="/tmp/evebox-backup-${TS}"
mkdir -p "${STAGE}"
cp -a "${CONF}" "${STAGE}/evebox.yaml"

# sqlite3 .backup = consistent snapshot while EveBox keeps running (skip events.sqlite)
for db in auth config; do
  if [ -r "${LIBDIR}/${db}.sqlite" ]; then
    sqlite3 "${LIBDIR}/${db}.sqlite" ".backup '${STAGE}/${db}.sqlite'" || fail "sqlite .backup ${db} failed"
  fi
done

tar -czf "${TARGET}" -C "${STAGE}" . || fail "tar failed"
rm -rf "${STAGE}"

SIZE=$(stat -c %s "${TARGET}")
log "done - ${SIZE} bytes"

log "rotation: deleting files older than ${RETENTION_DAYS} days"
find "${BACKUP_DIR}" -name "${SERVICE}-*.tar.gz" -mtime +${RETENTION_DAYS} -print -delete | tee -a "${LOG}"
