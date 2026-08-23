#!/usr/bin/env bash
# Installed at /etc/nut/upssched-cmd.sh, run by upssched (as the nut user).
case "$1" in
  onbatt)
    logger -t upssched "ONBATT -> starting ups-resilience.service"
    sudo -n /usr/bin/systemctl start --no-block ups-resilience.service
    ;;
  *)
    logger -t upssched "unhandled: $1"
    ;;
esac
