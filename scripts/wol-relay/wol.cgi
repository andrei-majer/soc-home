#!/bin/sh
# WOL relay CGI for the OpenWrt router (.1). Token-authenticated; fronted by
# nginx (LAN + Tailscale allowlist) and served by uhttpd on the IoT VLAN.
#
# Install: /usr/share/wol-relay/cgi-bin/wol   (chmod 755)
# Replace __WOL_TOKEN__ with a real random token and the example MACs with your
# devices' MACs. Real values are kept in the private memory store, NOT this repo.
case "$QUERY_STRING" in
  *token=__WOL_TOKEN__*)
    case "$QUERY_STRING" in
      *host=15*) MAC=AA:BB:CC:DD:EE:15 ;;   # hypervisor .15
      *)         MAC=AA:BB:CC:DD:EE:03 ;;   # default target .3 (backward compatible)
    esac
    printf 'Content-Type: text/plain\r\n\r\n'
    etherwake -i br-lan "$MAC"
    printf 'WOL sent to %s\n' "$MAC"
    ;;
  *)
    printf 'Status: 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nUnauthorized\n'
    ;;
esac
