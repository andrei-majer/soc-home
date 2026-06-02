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

# Speed up SSH handshake from external clients (VBox NAT port-forward + Vagrant SSH).
# Without these, banner exchange often times out because sshd attempts reverse DNS
# (UseDNS) and GSSAPI auth probes against an unreachable DNS/GSS infrastructure.
# IPQoS line: older 'lowdelay throughput' values cause delays on some hypervisors.
if ! grep -q '^UseDNS no' /etc/ssh/sshd_config; then
  echo 'UseDNS no' >> /etc/ssh/sshd_config
fi
if ! grep -q '^GSSAPIAuthentication no' /etc/ssh/sshd_config; then
  echo 'GSSAPIAuthentication no' >> /etc/ssh/sshd_config
fi
if ! grep -q '^IPQoS cs0 cs0' /etc/ssh/sshd_config; then
  echo 'IPQoS cs0 cs0' >> /etc/ssh/sshd_config
fi

# Ensure sshd starts on boot (preseed installs it but socket-activation can be flaky)
systemctl enable ssh.service 2>/dev/null || true
