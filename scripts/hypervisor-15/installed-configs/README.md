# `.15` installed-config snapshots

Reference copies of the host-level config files that bring the Ubuntu
hypervisor from a bare install to the state described in the migration
notes ([../README.md](../README.md) + `soc-lab/hypervisor-15.md` memory).

These are **snapshots**, not Ansible templates. They aren't pushed to
`.15` by any role. If you change one on `.15` and don't update the
file here, the repo drifts from reality. (Acceptable tradeoff — `.15`
config changes are rare, and the README in the parent directory
documents every requirement so a fresh rebuild from scratch is
~30 minutes from these files.)

## Contents

| File | Install path | Mode | Owner |
|---|---|---|---|
| `99-static-ip.yaml` | `/etc/netplan/99-static-ip.yaml` | 600 | root:root |
| `99-disable-network-config.cfg` | `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` | 644 | root:root |
| `00-key-only.conf` | `/etc/ssh/sshd_config.d/00-key-only.conf` | 644 | root:root |
| `fstab-vms.snippet` | append to `/etc/fstab` | 644 | root:root |

After dropping each in its install path:

```bash
# netplan + cloud-init
sudo netplan apply

# sshd (test config first, then reload — don't restart, you'll drop the session)
sudo sshd -t && sudo systemctl reload ssh

# fstab
sudo mkdir -p /mnt/vms
sudo mount /mnt/vms        # picks up the new fstab entry
```

## Sensitive content

- `00-key-only.conf` contains no secrets — just sshd directives.
- `99-static-ip.yaml` has no secrets — public IPs in the LAN range.
- `99-disable-network-config.cfg` is a one-liner.
- `fstab-vms.snippet` contains the NTFS UUID of the spare disk — not
  sensitive by itself; could leak the disk's identity if the box were
  ever in someone else's hands, but at that point the entire disk is
  the bigger concern.

The MOK signing key pair at `/var/lib/shim-signed/mok/MOK.{priv,der}`
is **deliberately NOT in this directory** — `MOK.priv` is a private
RSA-2048 key and shouldn't be checked in.
