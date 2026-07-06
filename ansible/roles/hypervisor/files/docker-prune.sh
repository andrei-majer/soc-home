#!/bin/sh
# Weekly Docker cleanup. Removes UNUSED images, build cache, and stopped
# containers older than 7 days. Never prunes volumes (preserves teslamate DB, etc).
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
echo "[docker-prune] $(date -Is) start"
docker image prune  -af --filter until=168h
docker builder prune -af --filter until=168h
docker container prune -f  --filter until=168h
echo "[docker-prune] $(date -Is) done"
