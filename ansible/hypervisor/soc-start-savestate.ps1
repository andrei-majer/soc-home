$vboxmanage = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
$logfile = 'C:\scripts\soc-start-savestate.log'

# Start order: providers first, consumers last
$vms = @('ELK', 'T-Pot Hive', 'Suricata', 'T-Pot Sensor', 'OpenCTi')

$vmIPs = @{
    'ELK'          = '192.168.1.133'
    'T-Pot Hive'   = '192.168.1.130'
    'Suricata'     = '192.168.1.120'
    'T-Pot Sensor' = '192.168.1.125'
    'OpenCTi'      = '192.168.1.135'
}

# T-Pot VMs run many containers — need longer ping window
$vmPingRetries = @{
    'ELK'          = 12
    'T-Pot Hive'   = 30
    'Suricata'     = 12
    'T-Pot Sensor' = 30
    'OpenCTi'      = 12
}

function Is-Running($vm) {
    $running = & $vboxmanage list runningvms 2>$null
    return ($running -match [regex]::Escape("`"$vm`""))
}

function Wait-ForPing($vm, $ip, $retries) {
    for ($i = 0; $i -lt $retries; $i++) {
        if (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            return $true
        }
        Start-Sleep -Seconds 15
    }
    return $false
}

"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - SOC startup (cold boot) started" | Add-Content $logfile

foreach ($vm in $vms) {
    if (Is-Running $vm) {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Skipping $vm (already running)" | Add-Content $logfile
    } else {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Starting $vm (headless)" | Add-Content $logfile
        $result = & $vboxmanage startvm $vm --type headless 2>&1
        if ($LASTEXITCODE -ne 0) {
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - WARN: startvm $vm failed: $result" | Add-Content $logfile
        }
        Start-Sleep -Seconds 10
    }
}

"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - All VMs started. Waiting 120s for boot..." | Add-Content $logfile
Start-Sleep -Seconds 120

# Ping check — auto-reset VMs that don't respond (network may not have come up after cold boot)
$failed = @()
foreach ($vm in $vms) {
    $ip = $vmIPs[$vm]
    $retries = $vmPingRetries[$vm]

    if (Wait-ForPing $vm $ip $retries) {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - OK: $vm ($ip) is reachable" | Add-Content $logfile
        continue
    }

    $maxWait = $retries * 15
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - WARN: $vm ($ip) did not respond after ${maxWait}s — resetting" | Add-Content $logfile
    & $vboxmanage controlvm $vm reset 2>&1 | Out-Null
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Reset sent to $vm. Waiting 90s for reboot..." | Add-Content $logfile
    Start-Sleep -Seconds 90

    if (Wait-ForPing $vm $ip $retries) {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - RECOVERED: $vm ($ip) reachable after reset" | Add-Content $logfile
    } else {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - ERROR: $vm ($ip) still unreachable after reset" | Add-Content $logfile
        $failed += $vm
    }
}

if ($failed.Count -eq 0) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - All VMs verified up." | Add-Content $logfile
} else {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - ERROR: $($failed.Count) VM(s) not reachable after reset: $($failed -join ', ')" | Add-Content $logfile
}
