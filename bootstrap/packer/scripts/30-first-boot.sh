#!/usr/bin/env bash
# Provisioner: bake /usr/local/sbin/soc-first-boot.sh + systemd unit.
# On first boot, the script reads SMBIOS OEM strings (set per-VM by Vagrantfile
# via setextradata) and configures hostname, eth1 static IP, and root's
# authorized_keys. No Vagrant SSH/shell provisioner needed.
set -euo pipefail

apt-get -y install --no-install-recommends dmidecode

cat > /usr/local/sbin/soc-first-boot.sh <<'EOS'
#!/usr/bin/env bash
# soc-first-boot.sh - applied once per VM on first boot. Reads VBox-injected
# SMBIOS OEM strings (Type 11) to configure hostname / network / ssh key.

set -euo pipefail

MARKER=/var/lib/soc-first-boot.done
[ -f "${MARKER}" ] && exit 0

log() { echo "[soc-first-boot] $*" | tee -a /var/log/soc-first-boot.log; }
fail() { log "FAIL: $*"; exit 1; }

# Pull config from SMBIOS DmiSystemSerial (set per-VM by Vagrantfile via
# setextradata). VBox 7.2 reliably exposes this field; DmiOEMVendorExN didn't
# exist in 7.2.6 testing. Single 64-char field, format:
#   "soc-hostname=NAME soc-ip=N.N.N.N soc-mode=dr|isolated"
SERIAL=$(dmidecode -s system-serial-number 2>/dev/null || true)
[ -n "${SERIAL}" ] || fail "dmidecode system-serial-number returned nothing"

extract() {
  echo "${SERIAL}" | grep -oE "$1=[^[:space:]]+" | head -1 | cut -d= -f2-
}

HOSTNAME=$(extract 'soc-hostname')
IP=$(extract 'soc-ip')
MODE=$(extract 'soc-mode')
PUBKEY=""   # TODO: deploy key transport - SSH key doesn't fit in DmiSystemSerial
            #       (64-char limit). Options for Phase 2:
            #         (a) bake into image at Packer build time (ties .box to a key)
            #         (b) cloud-init NoCloud ISO (canonical, needs cloud-init pkg)
            #         (c) deploy.ps1 serves the key via HTTP on default NAT gw,
            #             first-boot does `curl http://10.0.2.2:PORT/pubkey`

# Fail-safe: if no DMI config is present (smoke test, recovery boot, etc.),
# log and exit success. Don't break boot just because the per-VM config wasn't
# injected. The VM still comes up; you can SSH via the baked vagrant insecure
# key on whatever NIC is configured.
if [ -z "${HOSTNAME}" ] || [ -z "${IP}" ]; then
  log "no DMI config (hostname/ip missing) - skipping network/hostname setup"
  touch "${MARKER}"
  exit 0
fi
[ -n "${MODE}" ] || MODE=dr
log "configuring hostname=${HOSTNAME} ip=${IP} mode=${MODE}"

hostnamectl set-hostname "${HOSTNAME}"

# eth1 static IP. Packer image set net.ifnames=0 so the 2nd NIC is eth1.
cat > /etc/network/interfaces.d/eth1 <<EOC
auto eth1
iface eth1 inet static
  address ${IP}
  netmask 255.255.255.0
EOC

if [ "${MODE}" = "dr" ]; then
  cat >> /etc/network/interfaces.d/eth1 <<EOC
  gateway 192.168.1.1
  dns-nameservers 192.168.1.1
EOC
fi

ifup eth1 2>&1 | tee -a /var/log/soc-first-boot.log || systemctl restart networking || true

# Deploy SSH key
if [ -n "${PUBKEY}" ]; then
  install -d -m 0700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 0600 /root/.ssh/authorized_keys
  # Add only if not already present
  if ! grep -qF "${PUBKEY}" /root/.ssh/authorized_keys 2>/dev/null; then
    echo "${PUBKEY}" >> /root/.ssh/authorized_keys
  fi
  log "deploy key installed"
else
  log "WARN: no soc-pubkey_b64 in OEM strings - root ssh remains key-less"
fi

touch "${MARKER}"
log "first-boot complete"
EOS
chmod 0755 /usr/local/sbin/soc-first-boot.sh

cat > /etc/systemd/system/soc-first-boot.service <<'EOS'
[Unit]
Description=SOC Lab first-boot configuration
# Deliberately no Wants=/Before= network-pre.target. A failure or hang in this
# service must not block boot. The script is best-effort: it applies DMI-injected
# config when present, otherwise exits silently. eth0 (default DHCP) still works.
ConditionPathExists=!/var/lib/soc-first-boot.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/soc-first-boot.sh
RemainAfterExit=true
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOS

systemctl enable soc-first-boot.service
