# Off-host backup sync (.13) + encrypted mirror (.15)

`soc-backup-sync.ps1` runs on the Windows workstation (`.13`) and aggregates the
monthly config tarballs produced on each managed host into two independent copies.

## Pipeline

```
producers (monthly cron on each host)          .13 (Task Scheduler, monthly)
  .21  /backup/{misp,wazuh,kibana}/  ─┐
  .22  /backup/opencti/              ─┼─►  pull  ─►  OneDrive\Claude\backup\soc-data\   (cloud-replicated)
  .20  /backup/{velociraptor,        ─┘                     │
        grafana,evebox}/                                     └─►  push  ─►  .15:/mnt/backup/soc-data/   (encrypted, on-prem)
```

1. **Pull → OneDrive.** For each host/service the script lists `/backup/<svc>/` over
   SSH (openwrt key, `root@`), then `scp`s any tarball not already present into
   `OneDrive\Claude\backup\soc-data\<svc>\`. OneDrive replicates that copy to the cloud.
2. **Mirror → .15.** Immediately after, it pushes the same file to
   `.15:/mnt/backup/soc-data/<svc>/` (`andrei@`, openwrt key) — a second, on-prem copy
   on a dedicated encrypted disk, independent of OneDrive/cloud.

## The .15 encrypted backup disk

`/mnt/backup` on the hypervisor is a **single, dedicated SSD** with its **own LUKS2**
container (TPM2 auto-unlock, `nofail`) — deliberately kept out of the RAID1 system pool
so redundancy tiers aren't mixed. It is **non-redundant**, so it holds only *copies* of
state that lives safely elsewhere (OneDrive + the source hosts), never an only-copy.
Landing dir `/mnt/backup/soc-data/` is owned by the sync user.

## Behaviour notes

- **Gated.** The mirror leg is skipped with a `WARN` if `/mnt/backup` isn't mounted/
  reachable, so it can never break the OneDrive run.
- **Backfill.** Tarballs already in OneDrive are mirrored on first sight, so a freshly
  provisioned disk fills from existing history.
- **`.22` (OpenCTI)** is normally in on-demand savestate — an SSH timeout there is an
  expected `WARN`, not a failure; it mirrors on a run when the VM is awake.
- **Retention.** OneDrive copy pruned locally after 28 days (cloud copy persists).

## Schedule

Monthly on the 1st via Windows Task Scheduler (`SOC-BackupSync`), after the producers'
02:00–03:00 cron window. Log: `~/scripts/soc-backup-sync.log`.
