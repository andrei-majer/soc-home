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

- `openwrt` — used for `root@192.168.1.1` and `root@192.168.1.20`
- `id_ed25519` — used for `root@192.168.1.21`, `root@192.168.1.22`

Verified outbound SSH targets:
- 192.168.1.1 (OpenWrt router)
- 192.168.1.20 (Suricata / soc-ansible control node)
- 192.168.1.21 (ELK / Wazuh / MISP)
- 192.168.1.22 (OpenCTI)

## Sysmon

Installed 2026-04-03. Service name: **Sysmon64**.

| Path | Purpose |
|---|---|
| `C:\Program Files\Velociraptor\Tools\sysmonconfig-export.xml` | **ACTIVE configuration** (SwiftOnSecurity base, Velociraptor-deployed) — verified 2026-08-02 |
| `C:\tools\sysmon\sysmon-config.xml` | Legacy config — **NOT loaded**; kept for reference only |
| `C:\tools\sysmon\configure_wazuh_sysmon.ps1` | Setup/reload script — run elevated |

> Confirm which config is live with `Sysmon64.exe -c` (prints "Config file" + hash). A Velociraptor
> Sysmon flow can redeploy the stock SwiftOnSecurity file and silently revert local edits — re-check
> after any VR-driven Sysmon change.

**EID 3 is include-based** in this config (only a curated image list is logged, not everything).
`python.exe`, `pythonw.exe`, `pip.exe` and `uv.exe` were added to that include list on 2026-08-02 to
give install-time visibility for the malicious-package threat class (backup:
`sysmonconfig-export.xml.bak-20260802`). Reload after editing:

```powershell
& 'C:\tools\sysmon\Sysmon64.exe' -c 'C:\Program Files\Velociraptor\Tools\sysmonconfig-export.xml'
```

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

Agent **003** (name `147_K`) reports to manager `192.168.1.21:1514`. (Earlier docs said 008 — that
id predates the manager rebuild; `agent_control -l` on `.21` is authoritative.)

File integrity monitoring for credential paths (`.aws`, `.ssh`, `soc-keys`, `.claude`, the PaperMill
decoy `.env`) is pushed centrally from the manager via
`/var/ossec/etc/shared/default/agent.conf` (`<agent_config os="Windows">`), **not** from this host's
local `ossec.conf`. That shared file is currently hand-managed, not Ansible-templated.

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
| 100040 | Sysmon | IOC match — network connect (EID 3) |
| 100041 | Sysmon | IOC match — DNS query (EID 22) |

Rule 100040 chained on `if_sid 61603` (Sysmon **Event 1**) until 2026-08-02 and therefore could never
fire; it now chains on `61605` (Event 3). Two alert-only supply-chain rules were added alongside it —
see the `supply-chain-defenses` runbook.

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
3. **Install Wazuh agent** (MSI from 192.168.1.21), register with manager, accept agent ID 008.
4. **Deploy `ossec.conf`** with the Sysmon `localfile` block and AR command definitions; restart agent.
5. **Restore SSH keys** to `C:\Users\xndre\.ssh\` (`openwrt`, `id_ed25519`) with correct ACLs (Users: deny, xndre: read).
6. **Install Tailscale**, join tailnet `cerberus-barometric.ts.net`, enable Magic DNS.
7. **Verify Active Response**: tail `active-responses.log`, trigger test rule 100030 from manager, confirm `netsh` firewall rule appears and auto-removes after 3600s.

## OpenSSH Server

Installed 2026-04-20. Listens on Tailscale interface only — not accessible from LAN or internet.

| Field | Value |
|---|---|
| Service | `sshd` (Automatic startup) |
| Bind address | `100.78.84.60:22` (Tailscale IP) |
| Config | `C:\ProgramData\ssh\sshd_config` |
| Admin authorized keys | `C:\ProgramData\ssh\administrators_authorized_keys` |

### Install / reconfigure

```powershell
# Install (elevated PowerShell)
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# Restrict to Tailscale IP (get current IP first: Get-NetIPAddress | Where InterfaceAlias -like '*Tailscale*')
$cfg = 'C:\ProgramData\ssh\sshd_config'
(Get-Content $cfg) -replace '#Port 22', 'Port 22' `
                   -replace '#AddressFamily any', 'AddressFamily inet' `
                   -replace '#ListenAddress 0\.0\.0\.0', 'ListenAddress <tailscale-ip>' `
                   -replace '#ListenAddress ::', '' |
    Set-Content $cfg
Restart-Service sshd
```

**Note:** Tailscale IP (`100.78.x.x`) is assigned by Tailscale and is stable per device but may change after a full Tailscale reinstall. Verify with `Get-NetIPAddress | Where InterfaceAlias -like '*Tailscale*'` after rebuild and update `sshd_config` if needed.
