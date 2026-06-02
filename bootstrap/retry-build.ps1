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

# Step 4: smoke test
Write-Host "[4/4] Smoke test - boot minimal VM and try SSH" -ForegroundColor Cyan
$tmp = New-Item -ItemType Directory -Force -Path "$env:TEMP\packer-smoke-$(Get-Random)"
Push-Location $tmp
try {
  @"
Vagrant.configure("2") do |config|
  config.vm.box = "soc-lab/debian-12"
  config.vm.hostname = "packer-smoke"
  config.vm.boot_timeout = 600
  config.ssh.connect_timeout = 60
  config.vm.provider :virtualbox do |vb|
    vb.memory = 1024
    vb.cpus = 2
  end
end
"@ | Out-File Vagrantfile -Encoding ascii
  vagrant up
  if ($LASTEXITCODE -eq 0) {
    Write-Host "  SSH WORKED. The .13 NAT issue is resolved." -ForegroundColor Green
    vagrant ssh -c "uname -a; cat /etc/debian_version"
    vagrant destroy -f
  } else {
    Write-Host "  STILL HANGING. Reboot did not clear the VBox NAT loopback issue." -ForegroundColor Red
    Write-Host "  Next: try on .15 (Hyper-V disabled there per windows-15.md)" -ForegroundColor Yellow
    vagrant destroy -f
  }
} finally {
  Pop-Location
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
