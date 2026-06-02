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

  # NIC autodetect + MTU check land here in Task 1B-9
  if ($Mode -eq 'dr') {
    if (-not $BridgedNic) {
      Write-Fail "DR mode requires -BridgedNic '<name>' for now (autodetect in Task 1B-9)"
    }
    $script:ResolvedBridge = $BridgedNic
    Write-Step "  bridged NIC: $($script:ResolvedBridge) (from -BridgedNic flag)"
    $env:SOC_BRIDGED_NIC = $script:ResolvedBridge
  }

  Write-Step "preflight: PASS"
}
function Invoke-PhaseImage   { Write-Step "phase image: not yet implemented (Task 1B-10)" }
function Invoke-PhaseVms     { Write-Step "phase vms: not yet implemented (Task 1B-10)" }
function Invoke-PhaseConverge{ Write-Step "phase converge: not yet implemented (Task 1B-10)" }
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
