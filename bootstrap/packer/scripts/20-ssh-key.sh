#!/usr/bin/env bash
# Provisioner: install the well-known Vagrant insecure public key for
# initial `vagrant ssh`. The real deploy key (secrets/id_ed25519) is added
# per-VM by the Vagrantfile's first-boot shell provisioner.
set -euo pipefail

install -d -m 0700 -o vagrant -g vagrant /home/vagrant/.ssh
curl -fsSL https://raw.githubusercontent.com/hashicorp/vagrant/main/keys/vagrant.pub \
  -o /home/vagrant/.ssh/authorized_keys
chmod 0600 /home/vagrant/.ssh/authorized_keys
chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys

# Also prepare root SSH for the deploy key (Vagrant first-boot provisioner appends)
install -d -m 0700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys

# Ensure PermitRootLogin allows key-based authentication
sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
