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

# Pull config from SMBIOS Type 11 OEM strings (set per-VM by Vagrantfile via
# setextradata DmiOEMVendorEx0/Ex1). These have no 64-char limit, so the deploy
# SSH key fits (base64-encoded). dmidecode -t 11 emits one "String N: ..." line
# per OEM string. Formats:
#   Ex0: "soc-hostname=NAME soc-ip=N.N.N.N soc-mode=dr|isolated"
#   Ex1: "soc-pubkey_b64=BASE64..."
OEM=$(dmidecode -t 11 2>/dev/null || true)
[ -n "${OEM}" ] || fail "dmidecode -t 11 (OEM strings) returned nothing"

# extract: pull "<key>=<value>" from the OEM strings. Value runs to end of line
# so base64 (which never contains whitespace) survives intact.
extract() {
  echo "${OEM}" | grep -oE "$1=[^[:space:]]+" | head -1 | cut -d= -f2-
}

HOSTNAME=$(extract 'soc-hostname')
IP=$(extract 'soc-ip')
MODE=$(extract 'soc-mode')
PUBKEY_B64=$(extract 'soc-pubkey_b64')
PUBKEY=""
if [ -n "${PUBKEY_B64}" ]; then
  PUBKEY=$(echo "${PUBKEY_B64}" | base64 -d 2>/dev/null || true)
fi

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
