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
# Two triggers: AtStartup runs it right after boot; a Once-trigger with a concrete start
# time carries the every-minute repetition (an AtStartup trigger's repetition wouldn't begin
# until the next boot). Task Scheduler rejects TimeSpan.MaxValue, so use a long finite span.
$tBoot = New-ScheduledTaskTrigger -AtStartup
$tRep  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(30) `
            -RepetitionInterval (New-TimeSpan -Minutes 1) `
            -RepetitionDuration (New-TimeSpan -Days 3650)
$trigger = @($tBoot, $tRep)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
                -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Registered task '$taskName' (SYSTEM, every 1 min)."

Start-ScheduledTask -TaskName $taskName
Write-Host "Kicked off one run."
