# `docs/archive/`

Superseded material. Nothing here describes the current lab — it is kept because
it is the only record of a configuration that once ran, and because deleting it
would make a past decision unrecoverable.

Do not follow anything in this directory as a procedure. If a file here looks
like it answers your question, find its live replacement in `../runbooks/` first.

| File | Superseded | By |
|---|---|---|
| `windows-15.md` | 2026-06-08 — `.15` migrated Windows 11 Pro → Ubuntu 24.04 | `../runbooks/hypervisor-15.md` + `roles/hypervisor` |
| `soc-start-savestate.ps1` | 2026-06-08 — same migration | `roles/hypervisor` (`soc-wake.sh` / `soc-wake.timer`) |

Both files above were the Windows-era VM power management: a PowerShell script at
`C:\scripts\` driven by two Task Scheduler entries (`SOC-ResumeVMs` daily 06:00,
`SOC-StartVMs` on boot). The Ubuntu equivalent is `soc-sleep`/`soc-wake`, systemd
timers deployed by `roles/hypervisor`. `soc-start-savestate.ps1` still carries the
pre-2026-07-15 IPs, deliberately — it is a snapshot of what ran then, not a
document to renumber.
