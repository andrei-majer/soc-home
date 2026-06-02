# Bootstrap Prerequisites

## Host OS

- Windows 11 Pro (matches current .15) - `deploy.ps1` is the primary entry point
- Linux (Debian 12 or Ubuntu 22.04+) - `deploy.sh` works equivalently

## Required software

| Tool | Version | Install |
|---|---|---|
| VirtualBox | 7.2.6r172322 (pin) | `winget install Oracle.VirtualBox` (Windows) / apt + Oracle repo (Linux) |
| VirtualBox Extension Pack | matching version | https://www.virtualbox.org/wiki/Downloads |
| Packer | >= 1.10 | `winget install Hashicorp.Packer` |
| Vagrant | >= 2.4 | `winget install Hashicorp.Vagrant` |
| Ansible Core | >= 2.15 | `pip install ansible-core>=2.15` (or run convergence from .120 after VMs are up) |
| Git for Windows | any recent | `winget install Git.Git` |

## Hardware

| Resource | Minimum (one mode test) | Recommended (full lab) |
|---|---|---|
| RAM | 16 GB free | 64 GB |
| Disk free | 80 GB | 250 GB |
| Network | Wired Ethernet (Wi-Fi bridging is unreliable) | Wired Ethernet |
| Virtualization | VT-x / AMD-V enabled in BIOS | same |

## Networking

- DR mode: host on the same LAN as the lab (192.168.1.0/24)
- The OpenWrt router (.1) must already be reachable from the host
- Tailscale/VPN: the bootstrap refuses to start if MTU on the bridge < 1500. Disable VPN before running, or pass `-OverrideMtu`
