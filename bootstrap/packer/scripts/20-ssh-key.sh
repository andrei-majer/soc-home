#!/usr/bin/env bash
# Provisioner: install the well-known Vagrant insecure public key for
# initial `vagrant ssh`. The real deploy key (secrets/id_ed25519) is added
# per-VM by the Vagrantfile's first-boot shell provisioner.
set -euo pipefail

install -d -m 0700 -o vagrant -g vagrant /home/vagrant/.ssh
# SUPPLY-CHAIN NOTE: this fetches the Vagrant insecure public key from GitHub at
# Packer build time. Two caveats:
#   1. NETWORK DEPENDENCY - the build fails if raw.githubusercontent.com is
#      unreachable (offline/DR build host, GitHub outage). curl -f makes that a
#      hard, visible failure rather than writing an empty authorized_keys.
#   2. TRUST - we pull from hashicorp/vagrant@main (a moving ref), so the key is
#      whatever that branch serves at build time. This is the *insecure* key
#      (publicly known, by design) used only for the initial `vagrant ssh`; the
#      real deploy key (secrets/id_ed25519) is injected per-VM at first boot. The
#      risk is low, but to remove the network dependency entirely, vendor
#      keys/vagrant.pub into the repo and `install` it from a local copy instead.
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

# Defensive sshd_config tweaks. UseDNS/GSSAPI skip reverse-DNS and Kerberos probes
# that don't apply on an isolated lab network. IPQoS cs0 avoids old 'lowdelay'
# values some hypervisors mishandle.
for line in 'UseDNS no' 'GSSAPIAuthentication no' 'IPQoS cs0 cs0'; do
  key=$(echo "$line" | awk '{print $1}')
  if ! grep -qE "^${key}\s" /etc/ssh/sshd_config; then
    echo "$line" >> /etc/ssh/sshd_config
  fi
done

# NOTE: an earlier version of this script masked ssh.socket and force-enabled
# ssh.service, trying to dodge a suspected first-boot race. That broke sshd
# entirely - Debian 12's openssh-server requires ssh.socket to bind port 22;
# ssh.service alone doesn't listen. Rolled back 2026-06-02 after .15 smoke
# test reproduced the same hang as .13. Default Debian sshd setup is fine.
