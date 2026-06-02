#!/usr/bin/env bash
# kibana-backup.sh - export Kibana saved objects via API, retain 7 daily
# ES + Kibana run with xpack.security.enabled=false (no auth required).

set -euo pipefail
umask 077

SERVICE=kibana
BACKUP_DIR=/backup/${SERVICE}
TS=$(date +%Y%m%d-%H%M%S)
TARGET="${BACKUP_DIR}/${SERVICE}-${TS}.ndjson.gz"
LOG=/var/log/${SERVICE}-backup.log
RETENTION_DAYS=7

KIBANA_URL=${KIBANA_URL:-http://localhost:5601}

log()  { echo "[$(date +%FT%T)] $*" | tee -a "${LOG}"; }
fail() { log "FAIL: $*"; exit 1; }

mkdir -p "${BACKUP_DIR}"
log "starting ${SERVICE} backup -> ${TARGET}"

TYPES='["dashboard","visualization","index-pattern","search","lens","map","canvas-workpad"]'
log "POST ${KIBANA_URL}/api/saved_objects/_export"

curl -fsS \
  -H "kbn-xsrf: true" -H "Content-Type: application/json" \
  -X POST "${KIBANA_URL}/api/saved_objects/_export" \
  -d "{\"type\":${TYPES},\"includeReferencesDeep\":true}" \
  | gzip > "${TARGET}" || fail "Kibana export failed"

SIZE=$(stat -c %s "${TARGET}")
[ "${SIZE}" -gt 200 ] || fail "export too small (${SIZE} bytes) - likely an error response"
log "done - ${SIZE} bytes"

log "rotation: deleting files older than ${RETENTION_DAYS} days"
find "${BACKUP_DIR}" -name "${SERVICE}-*.ndjson.gz" -mtime +${RETENTION_DAYS} -print -delete | tee -a "${LOG}"
