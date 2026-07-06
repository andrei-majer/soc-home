# netboot-15 — on-demand UEFI Secure-Boot netboot server on `.15`

An **on-demand** PXE/UEFI netboot server on the `.15` hypervisor for booting
maintenance/imaging/installer environments on other LAN machines — primary use
**Clonezilla** (disk clone/image), plus **Ubuntu Server 24.04** and **Fedora 44**
installers. Secure Boot stays **ON** on targets (each distro chainloads its own
Microsoft-signed shim).

## Safety model

- **proxyDHCP only** — `.15` never assigns IPs; `.1` (OpenWrt) stays the sole DHCP
  authority. `dnsmasq` runs with `port=0` (no DNS) and `dhcp-range=...,proxy`.
- **Off = zero footprint.** All units are disabled at boot; the whole stack is
  started/stopped only via `pxe-clone start` / `pxe-clone stop`.
- Dedicated ports (TFTP 69, proxyDHCP 67/4011, HTTP 8088); the stock
  `dnsmasq.service` is **masked** so only the purpose-built instance ever runs.
- NFS export (`/mnt/backup/clonezilla-images` → `192.168.1.0/24`) is active only
  while PXE is running.

## Operate

```sh
pxe-clone start     # bring up proxyDHCP+TFTP, HTTP:8088, NFS export
pxe-clone status    # show unit state, exports, listeners
pxe-clone stop      # tear everything down — back to zero footprint
```

## Files

Config/units/scripts are version-controlled here and deployed to `.15`; boot
assets (ISOs, squashfs, kernels) are fetched manually onto `.15` (large, not in
git). See `docs/superpowers/plans/2026-07-06-pxe-netboot-server.md` for the build
and `docs/superpowers/specs/2026-07-06-pxe-netboot-server-design.md` for the
design.
