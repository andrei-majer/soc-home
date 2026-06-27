# Installs the .13 UPS collector as a scheduled task (runs as SYSTEM, every minute).
# Run elevated. Deploys ups-loki-push.py to %ProgramData%\soc-ups\ and registers the task.
#requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

$py  = (Get-Command python).Source
$dir = Join-Path $env:ProgramData 'soc-ups'
$dst = Join-Path $dir 'ups-loki-push.py'
$src = Join-Path $PSScriptRoot 'ups-loki-push.py'

New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item $src $dst -Force
Write-Host "Deployed $dst"

$taskName = 'SOC-UPS-13-Loki'
$action   = New-ScheduledTaskAction -Execute $py -Argument "`"$dst`""
# Start at boot, then repeat every minute indefinitely.
$trigger  = New-ScheduledTaskTrigger -AtStartup
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
                        -RepetitionInterval (New-TimeSpan -Minutes 1) `
                        -RepetitionDuration ([TimeSpan]::MaxValue)).Repetition
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
                -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Registered task '$taskName' (SYSTEM, every 1 min)."

Start-ScheduledTask -TaskName $taskName
Write-Host "Kicked off one run."
