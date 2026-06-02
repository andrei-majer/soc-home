#!/usr/bin/env bash
# opencti-backup.sh - stop OpenCTI, tar named volumes + .env, restart
# Designed for weekly cadence; ~30s of OpenCTI downtime per run.

set -euo pipefail
umask 077

SERVICE=opencti
BACKUP_DIR=/backup/${SERVICE}
TS=$(date +%Y%m%d-%H%M%S)
WORK=$(mktemp -d)
TARGET="${BACKUP_DIR}/${SERVICE}-${TS}.tar.gz"
LOG=/var/log/${SERVICE}-backup.log
RETENTION_DAYS=35
COMPOSE_DIR=/opt/opencti
VOLUMES=(opencti_esdata opencti_s3data opencti_redisdata opencti_amqpdata)

log() { echo "[$(date +%FT%T)] $*" | tee -a "${LOG}"; }
cleanup() {
  if [ -n "${WORK:-}" ] && [ -d "${WORK}" ]; then
    find "${WORK}" -mindepth 0 -delete 2>/dev/null || true
  fi
}
restore_opencti() {
  log "ensuring OpenCTI is restarted (recovery path)"
  (cd "${COMPOSE_DIR}" && docker compose up -d) || log "WARN: docker compose up -d failed during recovery"
}
fail() { log "FAIL: $*"; cleanup; restore_opencti; exit 1; }

trap cleanup EXIT

mkdir -p "${BACKUP_DIR}"
log "starting ${SERVICE} backup -> ${TARGET}"

[ -f "${COMPOSE_DIR}/docker-compose.yml" ] || fail "docker-compose.yml not at ${COMPOSE_DIR}"
[ -f "${COMPOSE_DIR}/.env" ] || fail ".env not at ${COMPOSE_DIR}"

log "stopping OpenCTI containers"
(cd "${COMPOSE_DIR}" && docker compose stop) || fail "docker compose stop failed"

for v in "${VOLUMES[@]}"; do
  log "exporting volume ${v}"
  docker run --rm -v "${v}:/src:ro" -v "${WORK}:/dst" alpine \
    tar -cf "/dst/${v}.tar" -C /src . || fail "tar volume ${v} failed"
done

log "copying .env"
cp "${COMPOSE_DIR}/.env" "${WORK}/opencti.env" || fail "cp .env failed"

log "restarting OpenCTI"
(cd "${COMPOSE_DIR}" && docker compose up -d) || fail "docker compose up failed"

log "compressing combined tarball"
tar -czf "${TARGET}" -C "${WORK}" . || fail "compress failed"

SIZE=$(stat -c %s "${TARGET}")
log "done - ${SIZE} bytes"

log "rotation: deleting files older than ${RETENTION_DAYS} days"
find "${BACKUP_DIR}" -name "${SERVICE}-*.tar.gz" -mtime +${RETENTION_DAYS} -print -delete | tee -a "${LOG}"
