##! Raise a notice on large OUTBOUND transfers (possible data exfiltration).
##! Internal (Site::local_nets) origin -> external destination, orig payload over threshold.
##! Internal->internal (e.g. NAS LAN copies) never fires (direction-scoped).

@load base/frameworks/notice
@load base/protocols/conn
@load base/protocols/ssl
@load base/utils/site

module LargeTransfer;

export {
    redef enum Notice::Type += { Large_Outbound };
    ## Outbound orig-payload bytes over this raises the notice. Tune as needed.
    const outbound_threshold = 1073741824 &redef;  # 1 GiB
    ## Destinations that look external but are trusted overlays / private space
    ## (Tailscale CGNAT, RFC1918, IPv6 ULA/link-local) — never treated as exfil.
    const exfil_exclude_nets: set[subnet] = {
        10.0.0.0/8,
        172.16.0.0/12,
        192.168.0.0/16,
        100.64.0.0/10,    # Tailscale / CGNAT
        [fc00::]/7,       # IPv6 unique-local
        [fe80::]/10,      # IPv6 link-local
    } &redef;
    ## Operator-owned upload endpoints, matched on TLS SNI. Keyed on SNI and not
    ## on address because these live on shared CDN anycast IPs: excluding the IP
    ## would whitelist every other tenant on that edge. An attacker can forge an
    ## SNI, so keep this list to endpoints whose bulk uploads are expected.
    const exfil_exclude_sni: set[string] = {
        "de85475856982e903df18911ce3c2ca1.r2.cloudflarestorage.com",
    } &redef;
    ## Operator-owned single-tenant hosts, matched on address. Needed alongside
    ## exfil_exclude_sni because bulk uploads to these arrive over SSH/rsync, which
    ## carries no SNI to key on. Dedicated hosts only — a whole-address exclusion is
    ## a permanent blind spot if that host is ever taken over.
    const exfil_exclude_hosts: set[addr] = {
        172.105.155.47,   # ht4.cellpex.com
    } &redef;
}

event connection_state_remove(c: connection)
    {
    if ( ! c?$id || ! c?$orig )
        return;
    if ( ! Site::is_local_addr(c$id$orig_h) )
        return;                          # origin must be internal
    if ( Site::is_local_addr(c$id$resp_h) )
        return;                          # internal->internal is not exfil
    if ( c$id$resp_h in LargeTransfer::exfil_exclude_nets )
        return;                          # trusted overlay / private dest, not exfil
    if ( c$id$resp_h in LargeTransfer::exfil_exclude_hosts )
        return;                          # operator-owned host, any protocol
    if ( c?$ssl && c$ssl?$server_name &&
         c$ssl$server_name in LargeTransfer::exfil_exclude_sni )
        return;                          # operator-owned upload endpoint
    if ( c$orig$size < LargeTransfer::outbound_threshold )
        return;
    NOTICE([$note=LargeTransfer::Large_Outbound,
            $conn=c,
            $msg=fmt("Large outbound transfer %s -> %s: %d bytes (orig payload)",
                     c$id$orig_h, c$id$resp_h, c$orig$size),
            $identifier=cat(c$id$orig_h, c$id$resp_h)]);
    }
