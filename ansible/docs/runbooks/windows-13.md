# Runbook: Windows Workstation 147K (192.168.1.13)

**NOT managed by Ansible.** This runbook documents manual procedures for the Windows 11 Enterprise workstation used as the SOC analyst endpoint. Ansible cannot configure Windows without WinRM/PowerShell remoting, which is intentionally disabled on this host.

## Host Overview

| Field | Value |
|---|---|
| Hostname | 147K |
| IP | 192.168.1.13 |
| OS | Windows 11 Enterprise |
| Primary user | xndre |
| Wazuh agent ID | 008 (147_K) |
| Role | SOC analyst workstation, Sysmon telemetry source |

## SSH

SSH client keys live under `C:\Users\xndre\.ssh\`:

- `openwrt` — used for `root@192.168.1.1` and `root@192.168.1.120`
- `id_ed25519` — used for `root@192.168.1.133`, `root@192.168.1.135`

Verified outbound SSH targets:
- 192.168.1.1 (OpenWrt router)
- 192.168.1.120 (Suricata / soc-ansible control node)
- 192.168.1.133 (ELK / Wazuh / MISP)
- 192.168.1.135 (OpenCTI)

## Sysmon

Installed 2026-04-03. Service name: **Sysmon64**.

| Path | Purpose |
|---|---|
| `C:\tools\sysmon\sysmon-config.xml` | Active Sysmon configuration |
| `C:\tools\sysmon\configure_wazuh_sysmon.ps1` | Setup/reload script — run elevated |

### Event types collected

| EID | Event | SOC use |
|---|---|---|
| 1 | Process create | Baseline, parent-child chains |
| 3 | Network connect | IOC matching against MISP indicators |
| 8 | CreateRemoteThread | Injection detection |
| 10 | ProcessAccess | Credential dumping (LSASS access) |
| 11 | FileCreate | Watching `.exe` / `.dll` / `.ps1` drops |
| 12 / 13 | Registry object | Run key persistence |
| 22 | DnsQuery | IOC matching against MISP domain indicators |

## Wazuh Agent

Agent **008** (name `147_K`) reports to manager `192.168.1.133:1514`.

`C:\Program Files (x86)\ossec-agent\ossec.conf` contains a localfile block for the Sysmon channel:

```xml
<localfile>
  <location>Microsoft-Windows-Sysmon/Operational</location>
  <log_format>eventchannel</log_format>
</localfile>
```

## Wazuh Active Response

| Rule | Source | Meaning |
|---|---|---|
| 100030 | Suricata | IOC match (MISP-backed) |
| 100031 | Suricata | IOC match (high confidence) |
| 100040 | Sysmon | IOC match — network connect |
| 100041 | Sysmon | IOC match — DNS query |

**Action:** `netsh.exe` adds a Windows Firewall block rule for the offending IP.
**Timeout:** 3600 seconds (1 hour, auto-removed).

| Path | Purpose |
|---|---|
| `C:\Program Files (x86)\ossec-agent\active-response\bin\netsh.exe` | AR binary |
| `C:\Program Files (x86)\ossec-agent\active-responses.log` | AR activity log |

Test an AR trigger: tail the AR log in one window, then curl a known-bad IOC from the manager lab.

## Tailscale

Tailnet: `cerberus-barometric.ts.net`. Magic DNS: `100.100.100.100:53`.
Exit node available via router (`100.105.36.55`).

## Known False Positives

**Do not investigate these** — they are the user's own infrastructure reached via Tailscale:

| Host / FQDN | Destination |
|---|---|
| `cellpex.com`, `cpx.loc`, `mail.cpx.loc` | 172.105.155.47 (via Tailscale) |

Ports seen: **22, 143, 443, 995, 20000**.

Generates alerts like **"ET SCAN Potential SSH Scan OUTBOUND"** — suppress / tune these out rather than investigating.

## Notifications

| Field | Value |
|---|---|
| Topic | `wazuh-Qzwhd0BgI6pQDaxb` |
| URL | `https://ntfy.sh/wazuh-Qzwhd0BgI6pQDaxb` |

## Rebuild From Scratch

1. **Install Windows 11 Enterprise**, create local user `xndre`, join workgroup, disable telemetry.
2. **Install Sysmon**: drop binaries to `C:\tools\sysmon\`, run `configure_wazuh_sysmon.ps1` as admin to install service + config.
3. **Install Wazuh agent** (MSI from 192.168.1.133), register with manager, accept agent ID 008.
4. **Deploy `ossec.conf`** with the Sysmon `localfile` block and AR command definitions; restart agent.
5. **Restore SSH keys** to `C:\Users\xndre\.ssh\` (`openwrt`, `id_ed25519`) with correct ACLs (Users: deny, xndre: read).
6. **Install Tailscale**, join tailnet `cerberus-barometric.ts.net`, enable Magic DNS.
7. **Verify Active Response**: tail `active-responses.log`, trigger test rule 100030 from manager, confirm `netsh` firewall rule appears and auto-removes after 3600s.
