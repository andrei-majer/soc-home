##! Raise a notice on large OUTBOUND transfers (possible data exfiltration).
##! Internal (Site::local_nets) origin -> external destination, orig payload over threshold.
##! Internal->internal (e.g. NAS LAN copies) never fires (direction-scoped).

@load base/frameworks/notice
@load base/protocols/conn
@load base/utils/site

module LargeTransfer;

export {
    redef enum Notice::Type += { Large_Outbound };
    ## Outbound orig-payload bytes over this raises the notice. Tune as needed.
    const outbound_threshold = 1073741824 &redef;  # 1 GiB
}

event connection_state_remove(c: connection)
    {
    if ( ! c?$id || ! c?$orig )
        return;
    if ( ! Site::is_local_addr(c$id$orig_h) )
        return;                          # origin must be internal
    if ( Site::is_local_addr(c$id$resp_h) )
        return;                          # internal->internal is not exfil
    if ( c$orig$size < LargeTransfer::outbound_threshold )
        return;
    NOTICE([$note=LargeTransfer::Large_Outbound,
            $conn=c,
            $msg=fmt("Large outbound transfer %s -> %s: %d bytes (orig payload)",
                     c$id$orig_h, c$id$resp_h, c$orig$size),
            $identifier=cat(c$id$orig_h, c$id$resp_h)]);
    }
