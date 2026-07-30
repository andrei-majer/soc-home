# opencti-sleep.ps1 — thin wrapper around /usr/local/sbin/opencti-sleep.sh on .20.
#
# The canonical implementation is the bash script on .20 (root, in soc-home
# git under scripts/opencti/). This wrapper just SSHes there so the same
# operator flow (.\opencti-sleep.ps1 from a Windows terminal) still works.
#
# Usage:
#   .\opencti-sleep.ps1

$ssh_key = "$env:USERPROFILE\.ssh\openwrt"
ssh -i $ssh_key -o StrictHostKeyChecking=no root@192.168.1.20 '/usr/local/sbin/opencti-sleep.sh'
exit $LASTEXITCODE
