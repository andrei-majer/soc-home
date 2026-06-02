#!/usr/bin/env bash
# Provisioner: shrink image - clean apt cache, zero unused blocks, truncate logs.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get -y autoremove
apt-get -y clean
find /var/lib/apt/lists -mindepth 1 -delete

# Truncate logs
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true

# Zero free space so the .box compresses well
dd if=/dev/zero of=/EMPTY bs=1M status=none || true
find / -maxdepth 1 -name EMPTY -delete 2>/dev/null || true
sync
