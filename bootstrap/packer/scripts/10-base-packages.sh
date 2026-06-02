#!/usr/bin/env bash
# Provisioner: install packages required by Ansible + base lab needs.
# Also disables predictable network interface names so the Vagrant shell
# provisioner can reliably target eth1 as the second NIC.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get -y install \
  python3 \
  python3-apt \
  sudo \
  openssh-server \
  curl \
  ca-certificates \
  gnupg \
  chrony

# Note: VirtualBox guest additions (virtualbox-guest-utils) live in Debian's
# 'contrib' component and aren't needed for the SOC lab flow - Ansible doesn't
# require them, Vagrant uses scp-based provisioning, and chrony handles time
# sync. If shared folders ever become a need, enable contrib in preseed.cfg
# (d-i apt-setup/contrib boolean true) and add the package back.

# Disable predictable NIC names (so adapters are eth0, eth1, eth2...)
# Required for the Vagrant first-boot shell provisioner that writes
# /etc/network/interfaces.d/eth1. Without this, Debian 12 names the second
# adapter enp0s8 (or similar) and the provisioner can't find it.
if ! grep -q 'net.ifnames=0' /etc/default/grub; then
  sed -ri 's/^GRUB_CMDLINE_LINUX="(.*)"$/GRUB_CMDLINE_LINUX="\1 net.ifnames=0 biosdevname=0"/' /etc/default/grub
  update-grub
fi
