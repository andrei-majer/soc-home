#requires -Version 5.1
<#
.SYNOPSIS
  SOC Lab Bootstrap - provisions the 6-VM SOC lab on a fresh VirtualBox host.

.DESCRIPTION
  Phase 1B (DR mode only): builds Packer image, brings up Vagrant VMs, runs Ansible converge.
  Restore phase and isolated mode are Phase 2.

.PARAMETER Mode
  'dr' (default): bridged adapters on 192.168.1.x. Drop-in replacement for broken .15.
  'isolated': internal VBox network on 192.168.99.x. NOT YET IMPLEMENTED (Phase 2).

.PARAMETER Phase
  Which step to run: image | vms | converge | restore | all (default).
  Phase 'restore' is a no-op in Phase 1B (ships in Phase 2).

.PARAMETER SkipRestore
  Force-skip the restore phase even when -Phase all. No-op in Phase 1B.

.PARAMETER Hosts
  Comma-separated list of hostnames to operate on (default: all 6).

.PARAMETER Profile
  'full' (default) uses specs.yml values. 'minimal' caps RAM/CPU for testing on constrained hosts.

.PARAMETER OverrideMtu
  Skip MTU preflight, set this MTU value on the VM bridge. Use only if VPN/Tailscale is intentional.

.PARAMETER BridgedNic
  Skip NIC autodetect, use this interface name as the bridge target.

.PARAMETER ForceImage
  Rebuild the Packer image even if source hash unchanged.

.PARAMETER ForceWifiBridge
  Allow Wi-Fi NIC as bridge target (otherwise warned and rejected).

.PARAMETER OverwriteExisting
  Allow restore phase to overwrite a populated lab. No-op in Phase 1B.

.PARAMETER Force
  Skip interactive confirmations (use with care).

.EXAMPLE
  .\deploy.ps1 -Mode dr -Phase image
  Builds the Packer .box only. Safe to run on any host with VBox.

.EXAMPLE
  .\deploy.ps1 -Mode dr -Hosts suricata-120 -Profile minimal
  Brings up only .120 with reduced specs (testing).
#>
[CmdletBinding()]
param(
  [ValidateSet('dr','isolated')]
  [string]$Mode = 'dr',

  [ValidateSet('image','vms','converge','restore','all')]
  [string]$Phase = 'all',

  [switch]$SkipRestore,
  [string]$Hosts = '',
  [ValidateSet('full','minimal')]
  [string]$Profile = 'full',
  [int]$OverrideMtu = 0,
  [string]$BridgedNic = '',
  [switch]$ForceImage,
  [switch]$ForceWifiBridge,
  [switch]$OverwriteExisting,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Anchor everything to bootstrap/
$script:BootstrapRoot = $PSScriptRoot
$script:LogDir        = Join-Path $script:BootstrapRoot 'logs'
New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
$script:LogFile       = Join-Path $script:LogDir ("deploy-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Step($msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 's'), $msg
  Add-Content -LiteralPath $script:LogFile -Value $line
  Write-Host $line -ForegroundColor Cyan
}

function Write-Fail($msg) {
  $line = "[{0}] FAIL: {1}" -f (Get-Date -Format 's'), $msg
  Add-Content -LiteralPath $script:LogFile -Value $line
  Write-Host $line -ForegroundColor Red
  throw $msg
}

function Resolve-BridgedNic {
  # Returns the best bridged-interface candidate, or $null if ambiguous.
  $excludePattern = '^(Loopback|VirtualBox Host-Only|vEthernet|VMware|Tailscale|tap|tun|WireGuard|TAP-)'

  # Pull all up adapters with an active IPv4 default route. Force array
  # so .Count behaves cleanly on 0 or 1 results.
  $candidates = @(Get-NetAdapter |
    Where-Object {
      $_.Status -eq 'Up' -and
      $_.Name -notmatch $excludePattern -and
      $_.MediaType -ne 'Native 802.11'
    } |
    Where-Object {
      $iface = $_.ifIndex
      $null -ne (Get-NetRoute -InterfaceIndex $iface -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    } |
    Select-Object Name, InterfaceDescription, ifIndex)

  if ($candidates.Count -eq 0) { return $null }
  if ($candidates.Count -eq 1) {
    Write-Step "  NIC autodetect: $($candidates[0].Name) (single Ethernet candidate)"
    return $candidates[0].Name
  }

  Write-Step "  NIC autodetect: $($candidates.Count) candidates"
  $candidates | ForEach-Object { Write-Host ("    {0,-30}  {1}" -f $_.Name, $_.InterfaceDescription) }
  if ($Force) {
    Write-Fail "multiple bridged NIC candidates - pass -BridgedNic '<name>'"
  }
  $picked = Read-Host "Enter NIC name to use"
  if (-not ($candidates | Where-Object Name -eq $picked)) {
    Write-Fail "'$picked' is not in the candidate list"
  }
  return $picked
}

function Test-Mtu {
  param([string]$NicName)
  $adapter = Get-NetAdapter -Name $NicName -ErrorAction Stop
  $mtu = $adapter.MtuSize
  Write-Step "  bridge MTU: $mtu"
  if ($OverrideMtu -gt 0) {
    Write-Step "  -OverrideMtu $OverrideMtu - skipping MTU check"
    return
  }
  if ($mtu -lt 1500) {
    Write-Fail "bridge MTU $mtu < 1500 (VPN/Tailscale likely on bridge). Disable VPN or pass -OverrideMtu $mtu"
  }
}

function Invoke-Preflight {
  Write-Step "preflight: VBox / Packer / Vagrant / secrets / MTU / bridge NIC"

  # VirtualBox
  $vboxPath = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
  if (-not (Test-Path $vboxPath)) { Write-Fail "VirtualBox not found at $vboxPath" }
  $vboxVersion = & $vboxPath --version
  Write-Step "  VirtualBox: $vboxVersion"
  $expectedPin = '7.2.6r172322'
  if ($vboxVersion -notlike "$expectedPin*") {
    Write-Step "  WARN: expected VBox $expectedPin, found $vboxVersion (proceeding - pin is advisory)"
  }

  # Packer
  if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
    Write-Fail "packer not in PATH - install via 'winget install Hashicorp.Packer'"
  }
  $packerVer = (packer version 2>&1 | Select-Object -First 1)
  Write-Step "  Packer: $packerVer"

  # Vagrant
  if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) {
    Write-Fail "vagrant not in PATH - install via 'winget install Hashicorp.Vagrant'"
  }
  $vagrantVer = ((vagrant --version 2>&1) -join ' ')
  Write-Step "  Vagrant: $vagrantVer"

  # secrets/
  $secretsDir = Join-Path $script:BootstrapRoot 'secrets'
  $needed = @('vault_pass.txt', 'id_ed25519', 'id_ed25519.pub')
  foreach ($f in $needed) {
    $p = Join-Path $secretsDir $f
    if (-not (Test-Path $p)) {
      Write-Fail "secrets/$f missing - see bootstrap/docs/secrets-checklist.md"
    }
  }
  Write-Step "  secrets/: present (vault_pass + ssh keypair)"

  # Bridge NIC (DR mode only)
  if ($Mode -eq 'dr') {
    if ($BridgedNic) {
      $script:ResolvedBridge = $BridgedNic
      Write-Step "  bridged NIC: $($script:ResolvedBridge) (from -BridgedNic flag)"
    } else {
      $cacheFile = Join-Path $script:BootstrapRoot '.deploy-config.local'
      if (Test-Path $cacheFile) {
        $cache = Get-Content $cacheFile | ConvertFrom-StringData
        if ($cache.BridgedNic) {
          $script:ResolvedBridge = $cache.BridgedNic
          Write-Step "  bridged NIC: $($script:ResolvedBridge) (from cache)"
        }
      }
      if (-not $script:ResolvedBridge) {
        $script:ResolvedBridge = Resolve-BridgedNic
        if (-not $script:ResolvedBridge) {
          Write-Fail "no bridged NIC candidate after filtering - pass -BridgedNic '<name>'"
        }
        "BridgedNic=$($script:ResolvedBridge)" | Out-File -FilePath $cacheFile -Encoding ascii
        Write-Step "  cached selection to .deploy-config.local"
      }
    }
    Test-Mtu -NicName $script:ResolvedBridge
    $env:SOC_BRIDGED_NIC = $script:ResolvedBridge
  }

  Write-Step "preflight: PASS"
}
function Invoke-PhaseImage {
  Write-Step "phase image: building Debian 12 golden box"

  $packerDir = Join-Path $script:BootstrapRoot 'packer'
  $boxFile   = Join-Path $packerDir 'soc-lab-debian-12.box'
  $hashFile  = Join-Path $packerDir 'soc-lab-debian-12.box.sha'

  # Source hash: sha256 of all packer/ files except outputs and the box itself
  $srcFiles = Get-ChildItem -Path $packerDir -Recurse -File |
    Where-Object {
      $_.FullName -notmatch '\.(box|sha)$' -and
      $_.FullName -notmatch 'output-' -and
      $_.FullName -notmatch 'packer_cache'
    } |
    Sort-Object FullName
  $combined = ($srcFiles | ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash }) -join "`n"
  $tmp = [System.IO.Path]::GetTempFileName()
  [System.IO.File]::WriteAllText($tmp, $combined, [System.Text.UTF8Encoding]::new($false))
  $currentHashStr = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
  Remove-Item $tmp -Force

  if ((Test-Path $boxFile) -and (Test-Path $hashFile) -and -not $ForceImage) {
    $storedHash = (Get-Content $hashFile -Raw).Trim()
    if ($storedHash -eq $currentHashStr) {
      Write-Step "  image up to date (hash matches) - skipping build. Use -ForceImage to override."
      return
    }
    Write-Step "  source changed since last build - rebuilding"
  }

  Push-Location $packerDir
  try {
    & packer init .
    if ($LASTEXITCODE -ne 0) { Write-Fail "packer init failed" }
    & packer build -force .
    if ($LASTEXITCODE -ne 0) { Write-Fail "packer build failed" }
  } finally {
    Pop-Location
  }

  if (-not (Test-Path $boxFile)) { Write-Fail "packer reported success but .box not found" }
  Set-Content -LiteralPath $hashFile -Value $currentHashStr -Encoding ascii -NoNewline
  Write-Step "  image built, hash recorded"

  & vagrant box add --force soc-lab/debian-12 $boxFile
  if ($LASTEXITCODE -ne 0) { Write-Fail "vagrant box add failed" }
}

function Invoke-PhaseVms {
  Write-Step "phase vms: vagrant up"

  $vagrantDir = Join-Path $script:BootstrapRoot 'vagrant'
  Push-Location $vagrantDir
  try {
    $env:SOC_MODE    = $Mode
    $env:SOC_HOSTS   = $Hosts
    $env:SOC_PROFILE = $Profile

    # vagrant up will likely return non-zero because its built-in SSH probe
    # times out (Vagrant 2.4.9 doesn't accept communicator=:none; VBox NAT
    # loopback on Win11 hosts is unreliable; the Vagrant insecure key isn't
    # wired for root). The VM boots regardless - that's all we need here.
    # soc-first-boot service inside the VM applies hostname/IP/mode from DMI
    # strings; Ansible reaches each VM via its bridged IP next phase.
    $args = @('up', '--no-provision')
    if ($Hosts) { $args += ($Hosts.Split(',') | ForEach-Object { $_.Trim() }) }

    & vagrant @args
    if ($LASTEXITCODE -ne 0) {
      Write-Step "  vagrant up exit=$LASTEXITCODE (expected SSH-timeout - VMs still boot, proceeding)"
    }
  } finally {
    Pop-Location
  }

  Write-Step "  VMs created. Waiting 60s for first-boot service to apply networking..."
  Start-Sleep -Seconds 60
  Write-Step "  VMs should now be reachable on per-VM bridged IPs"
}

function Invoke-PhaseConverge {
  Write-Step "phase converge: ansible-playbook site.yml"

  if (-not (Get-Command ansible-playbook -ErrorAction SilentlyContinue)) {
    Write-Fail "ansible-playbook not in PATH. Install via 'pip install ansible-core>=2.15' or run convergence remotely from the new .120 control node."
  }

  $repoRoot     = Split-Path -Parent $script:BootstrapRoot
  $invPrimary   = Join-Path $repoRoot 'ansible/inventory/hosts.yml'
  $invOverrides = Join-Path $script:BootstrapRoot '.vagrant/ansible-overrides'

  if (-not (Test-Path $invPrimary))   { Write-Fail "primary Ansible inventory missing at $invPrimary" }
  if (-not (Test-Path $invOverrides)) { Write-Fail "inventory overrides not generated - did vms phase run?" }

  $vaultPass = Join-Path $script:BootstrapRoot 'secrets/vault_pass.txt'
  $sshKey    = Join-Path $script:BootstrapRoot 'secrets/id_ed25519'
  $playbook  = Join-Path $repoRoot 'ansible/playbooks/site.yml'

  $argList = @(
    $playbook,
    '-i', $invPrimary,
    '-i', $invOverrides,
    '--vault-password-file', $vaultPass,
    '--private-key', $sshKey
  )
  if ($Hosts) { $argList += @('--limit', $Hosts) }

  & ansible-playbook @argList
  if ($LASTEXITCODE -ne 0) { Write-Fail "ansible-playbook failed" }
  Write-Step "  converge complete"
}
function Invoke-PhaseRestore { Write-Step "phase restore: no-op in Phase 1B (ships in Phase 2)" }

Write-Step "deploy.ps1 starting - Mode=$Mode Phase=$Phase Hosts='$Hosts' Profile=$Profile"

if ($Mode -eq 'isolated') {
  Write-Fail "isolated mode is Phase 2 - not yet implemented"
}

Invoke-Preflight

switch ($Phase) {
  'image'    { Invoke-PhaseImage }
  'vms'      { Invoke-PhaseVms }
  'converge' { Invoke-PhaseConverge }
  'restore'  { Invoke-PhaseRestore }
  'all' {
    Invoke-PhaseImage
    Invoke-PhaseVms
    Invoke-PhaseConverge
    if (-not $SkipRestore) { Invoke-PhaseRestore }
  }
}

Write-Step "deploy.ps1 complete"
