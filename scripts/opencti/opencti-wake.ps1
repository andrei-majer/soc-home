# opencti-wake.ps1 — thin wrapper around /usr/local/sbin/opencti-wake.sh on .20.
#
# The canonical implementation is the bash script on .20 (root, in soc-home
# git under scripts/opencti/). This wrapper just SSHes there so the same
# operator flow (.\opencti-wake.ps1 from a Windows terminal) still works.
#
# Usage:
#   .\opencti-wake.ps1                  # resume + verify
#   .\opencti-wake.ps1 -NoVerify        # resume, return immediately
#   .\opencti-wake.ps1 -NoConnectorRestart  # skip cold-boot connector restart

param([switch]$NoVerify, [switch]$NoConnectorRestart)

$ssh_key = "$env:USERPROFILE\.ssh\openwrt"
$args_list = @()
if ($NoVerify) { $args_list += '--no-verify' }
if ($NoConnectorRestart) { $args_list += '--no-restart' }

$remote_cmd = "/usr/local/sbin/opencti-wake.sh $($args_list -join ' ')"
ssh -i $ssh_key -o StrictHostKeyChecking=no root@192.168.1.20 $remote_cmd
exit $LASTEXITCODE
