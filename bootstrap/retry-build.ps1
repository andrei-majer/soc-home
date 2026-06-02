#requires -Version 5.1
# bootstrap/retry-build.ps1 - re-run Packer build + smoke test after host reboot.
# Run from this directory: .\retry-build.ps1
#
# Goal: confirm whether reboot cleared the VBox NAT loopback issue documented
# in README.md "Known issues". Build #6 produced a working .box; only vagrant
# up's SSH probe was hanging.

$ErrorActionPreference = 'Stop'
$env:PATH = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")

$BootstrapRoot = $PSScriptRoot
$PackerDir     = Join-Path $BootstrapRoot 'packer'
$BoxFile       = Join-Path $PackerDir     'soc-lab-debian-12.box'

# Step 1: ensure Tailscale tunnel is down (the .13-quirk-mitigation)
Write-Host "[1/4] tailscale down..." -ForegroundColor Cyan
tailscale down 2>&1 | Out-String | Write-Host

# Step 2: rebuild image (or skip if .box already fresh)
if (Test-Path $BoxFile) {
  $age = (Get-Date) - (Get-Item $BoxFile).LastWriteTime
  if ($age.TotalHours -lt 24) {
    Write-Host "[2/4] Existing .box is $([math]::Round($age.TotalHours,1))h old - using it (delete to force rebuild)" -ForegroundColor Cyan
  } else {
    Write-Host "[2/4] .box older than 24h - rebuilding..." -ForegroundColor Cyan
    Push-Location $PackerDir
    try { packer build -force . } finally { Pop-Location }
  }
} else {
  Write-Host "[2/4] No .box - building (~25 min)..." -ForegroundColor Cyan
  Push-Location $PackerDir
  try { packer build -force . } finally { Pop-Location }
}

# Step 3: re-register box
Write-Host "[3/4] vagrant box add --force..." -ForegroundColor Cyan
vagrant box add --force soc-lab/debian-12 $BoxFile

# Step 4: smoke test via bridged adapter + SSH-as-vagrant.
# VBox NAT loopback to 127.0.0.1 is unreliable on Win11 hosts (TCP completes
# but SSH banner never arrives) — so we test via bridged DHCP instead.
# Validates: image boots cleanly + sshd works on a real LAN interface.
Write-Host "[4/4] Smoke test - bridged adapter + DHCP + SSH-as-vagrant" -ForegroundColor Cyan

# Discover bridged-capable NIC name (VBox uses InterfaceDescription, not the
# Windows alias). Pick the Ethernet adapter with a default route.
$bridgedDesc = (Get-NetAdapter | Where-Object {
  $_.Status -eq 'Up' -and $_.MediaType -ne 'Native 802.11' -and
  $_.InterfaceDescription -notmatch '(VirtualBox|VMware|Hyper-V|Tailscale|TAP|Loopback)'
} | Where-Object {
  $null -ne (Get-NetRoute -InterfaceIndex $_.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
} | Select-Object -First 1).InterfaceDescription
if (-not $bridgedDesc) { Write-Host "  no bridged NIC candidate found - skipping smoke" -ForegroundColor Yellow; return }
Write-Host "  bridge: $bridgedDesc"

$tmp = New-Item -ItemType Directory -Force -Path "$env:TEMP\packer-smoke-$(Get-Random)"
Push-Location $tmp
try {
  @"
Vagrant.configure("2") do |config|
  config.vm.box = "soc-lab/debian-12"
  config.vm.provider :virtualbox do |vb|
    vb.memory = 1024
    vb.cpus = 2
    vb.customize ['modifyvm', :id, '--nic1', 'bridged']
    vb.customize ['modifyvm', :id, '--bridgeadapter1', '$bridgedDesc']
    vb.customize ['modifyvm', :id, '--macaddress1', 'auto']
  end
end
"@ | Out-File Vagrantfile -Encoding ascii

  # vagrant up will probably SSH-timeout (NAT-loopback issue) - VM boots
  # anyway. We don't care about the exit code here.
  vagrant up 2>&1 | Select-Object -Last 5
  Write-Host "  waiting 60s for boot + DHCP lease..."
  Start-Sleep -Seconds 60

  # Find VM IP via VBox MAC + ARP
  $vmId = Get-Content .vagrant\machines\default\virtualbox\id
  $mac = & 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' showvminfo $vmId --machinereadable |
         Select-String 'macaddress1=' | ForEach-Object { ($_ -split '"')[1] }
  $macFmt = ($mac -replace '(..)(?=.)', '$1-').ToLower()
  $arp = (arp -a) | Select-String $macFmt
  $vmIp = if ($arp) { ($arp.Line.Trim() -split '\s+')[0] } else { $null }
  Write-Host "  VM IP: $vmIp"

  if ($vmIp) {
    $insecureKey = "$env:USERPROFILE\.vagrant.d\insecure_private_keys\vagrant.key.ed25519"
    if (-not (Test-Path $insecureKey)) { $insecureKey = "$env:USERPROFILE\.vagrant.d\insecure_private_keys\vagrant.key.rsa" }
    $out = ssh -i $insecureKey -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
                -o IdentitiesOnly=yes -o ConnectTimeout=15 -o BatchMode=yes `
                vagrant@$vmIp 'hostname; sudo systemctl is-active ssh.service' 2>&1
    if ($LASTEXITCODE -eq 0) {
      Write-Host "  SSH WORKED. Image is good." -ForegroundColor Green
      Write-Host $out
    } else {
      Write-Host "  SSH failed (exit $LASTEXITCODE)" -ForegroundColor Red
      Write-Host $out
    }
  } else {
    Write-Host "  no ARP entry for VM MAC $macFmt - VM may not have DHCP'd" -ForegroundColor Red
  }
} finally {
  vagrant destroy -f 2>&1 | Select-Object -Last 2
  Pop-Location
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
