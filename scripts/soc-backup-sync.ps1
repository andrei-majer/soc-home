#requires -Version 5.1
# soc-backup-sync.ps1 - pulls latest backup tarballs from SOC managed hosts to OneDrive
# Idempotent: skips files that already exist locally.
#
# Run via Task Scheduler. SSH uses Windows OpenSSH client with the openwrt key.

$ErrorActionPreference = 'Stop'
$KeyFile  = "$env:USERPROFILE\.ssh\openwrt"
$DestRoot = "$env:USERPROFILE\OneDrive\Claude\backup\soc-data"
$LogFile  = "$env:USERPROFILE\scripts\soc-backup-sync.log"

# Second on-prem copy: mirror each tarball to the encrypted /mnt/backup disk on .15.
# Gated on the target dir existing, so it no-ops (WARN + skip) until the disk is set up.
$MirrorEnabled = $true
$MirrorHost    = '192.168.1.15'
$MirrorUser    = 'andrei'
$MirrorRoot    = '/mnt/backup/soc-data'

# (host, service-list) tuples - must match where the Ansible role deployed scripts
$Sources = @(
  @{ Host = '192.168.1.21'; Services = @('misp','wazuh','kibana') }
  @{ Host = '192.168.1.22'; Services = @('opencti') }
  @{ Host = '192.168.1.20'; Services = @('velociraptor','grafana','evebox') }
)

function Write-Log($msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 's'), $msg
  Add-Content -LiteralPath $LogFile -Value $line
  Write-Host $line
}

Write-Log "starting sync"
$total = 0; $copied = 0; $mirrored = 0

# Probe the .15 mirror once; skip mirroring cleanly if the disk isn't mounted/reachable.
$mirrorOk = $false
if ($MirrorEnabled) {
  & ssh -i $KeyFile -o BatchMode=yes -o ConnectTimeout=10 "$MirrorUser@$MirrorHost" "test -d '$MirrorRoot'" 2>$null
  $mirrorOk = ($LASTEXITCODE -eq 0)
  if (-not $mirrorOk) { Write-Log "WARN: mirror $MirrorUser@${MirrorHost}:$MirrorRoot unavailable - skipping .15 mirror this run" }
}

foreach ($src in $Sources) {
  foreach ($svc in $src.Services) {
    $remoteList = & ssh -i $KeyFile -o BatchMode=yes -o ConnectTimeout=10 "root@$($src.Host)" "ls -1 /backup/$svc/ 2>/dev/null"
    if ($LASTEXITCODE -ne 0 -or -not $remoteList) {
      Write-Log "WARN: cannot list /backup/$svc on $($src.Host) (exit $LASTEXITCODE)"
      continue
    }
    $destDir = Join-Path $DestRoot $svc
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    if ($mirrorOk) { & ssh -i $KeyFile -o BatchMode=yes "$MirrorUser@$MirrorHost" "mkdir -p '$MirrorRoot/$svc'" | Out-Null }
    foreach ($file in ($remoteList -split "`n" | Where-Object { $_ })) {
      $total++
      $localPath = Join-Path $destDir $file
      if (-not (Test-Path -LiteralPath $localPath)) {
        Write-Log "scp $($src.Host):/backup/$svc/$file -> $localPath"
        & scp -i $KeyFile -o BatchMode=yes -o ConnectTimeout=10 -q `
          "root@$($src.Host):/backup/$svc/$file" "$localPath"
        if ($LASTEXITCODE -eq 0) { $copied++ }
        else { Write-Log "FAIL: scp exit $LASTEXITCODE for $file" }
      }
      # Mirror to .15 encrypted disk; also backfills tarballs already in OneDrive.
      if ($mirrorOk -and (Test-Path -LiteralPath $localPath)) {
        $remoteFile = "$MirrorRoot/$svc/$file"
        & ssh -i $KeyFile -o BatchMode=yes "$MirrorUser@$MirrorHost" "test -f '$remoteFile'" 2>$null
        if ($LASTEXITCODE -ne 0) {
          & scp -i $KeyFile -o BatchMode=yes -q "$localPath" "${MirrorUser}@${MirrorHost}:$remoteFile"
          if ($LASTEXITCODE -eq 0) { $mirrored++; Write-Log "mirror -> .15:$remoteFile" }
          else { Write-Log "FAIL: mirror scp exit $LASTEXITCODE for $file" }
        }
      }
    }
  }
}

# Local retention: keep 28 days (covers 4 weeks of weeklies, plus dailies)
Get-ChildItem -LiteralPath $DestRoot -Recurse -File |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-28) } |
  ForEach-Object { Write-Log "prune: $($_.FullName)"; Remove-Item -LiteralPath $_.FullName -Force }

Write-Log "done - $copied/$total copied to OneDrive, $mirrored mirrored to .15 this run"
