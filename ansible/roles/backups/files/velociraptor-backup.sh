#!/usr/bin/env bash
# velociraptor-backup.sh - tar Velociraptor server config + client enrollments

set -euo pipefail
umask 077

SERVICE=velociraptor
BACKUP_DIR=/backup/${SERVICE}
TS=$(date +%Y%m%d-%H%M%S)
TARGET="${BACKUP_DIR}/${SERVICE}-${TS}.tar.gz"
LOG=/var/log/${SERVICE}-backup.log
RETENTION_DAYS=7

CONFIG_DIR=/etc/velociraptor
DATASTORE=/opt/velociraptor

# Verified live on .120 — actual layout differs from plan:
# - Configs in /etc/velociraptor/ (server.config.yaml, client.config.yaml,
#   automation_api.yaml)
# - Datastore root at /opt/velociraptor/ (FileBaseDataStore, NOT a 'datastore'
#   subdir). Subdirs we preserve: clients/ (enrollments), client_info/,
#   config/ (server state inventory + monitoring), acl/
PATHS=(
  "${CONFIG_DIR}/server.config.yaml"
  "${CONFIG_DIR}/client.config.yaml"
  "${CONFIG_DIR}/automation_api.yaml"
  "${DATASTORE}/clients"
  "${DATASTORE}/client_info"
  "${DATASTORE}/config"
  "${DATASTORE}/acl"
)

log()  { echo "[$(date +%FT%T)] $*" | tee -a "${LOG}"; }
fail() { log "FAIL: $*"; exit 1; }

mkdir -p "${BACKUP_DIR}"
log "starting ${SERVICE} backup -> ${TARGET}"

for p in "${PATHS[@]}"; do
  [ -e "${p}" ] || fail "expected path ${p} missing"
done

tar -czf "${TARGET}" "${PATHS[@]}" || fail "tar failed"

SIZE=$(stat -c %s "${TARGET}")
log "done - ${SIZE} bytes"

log "rotation: deleting files older than ${RETENTION_DAYS} days"
find "${BACKUP_DIR}" -name "${SERVICE}-*.tar.gz" -mtime +${RETENTION_DAYS} -print -delete | tee -a "${LOG}"
