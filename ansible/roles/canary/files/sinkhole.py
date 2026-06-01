#!/usr/bin/env python3
"""TCP sinkhole listener on 192.168.1.140 (C2/exotic port set).
Logs all inbound connections as JSON -> /var/log/sinkhole.json.
Companion to OpenCanary on the same host — sinkhole covers C2/exotic ports
OpenCanary does not ship; OpenCanary covers banner-emulated service ports.
"""
import asyncio, json, sys, logging
from datetime import datetime, timezone

SINKHOLE_IP = "192.168.1.140"
LOG_FILE    = "/var/log/sinkhole.json"

PORTS = [
    25, 465, 587,        # SMTP, SMTPS, submission
    1080,                # SOCKS
    1337, 31337,         # classic backdoor
    4444, 4445, 4449,    # Metasploit / C2
    6667, 6697,          # IRC, IRC-TLS
    8443, 8888,          # alt HTTP/S
    9001,                # Tor
]

file_log = logging.getLogger("sinkhole.file")
file_log.setLevel(logging.INFO)
fh = logging.FileHandler(LOG_FILE)
fh.setFormatter(logging.Formatter("%(message)s"))
file_log.addHandler(fh)

sys_log = logging.getLogger("sinkhole.sys")
sys_log.setLevel(logging.INFO)
sh = logging.StreamHandler(sys.stdout)
sh.setFormatter(logging.Formatter("%(message)s"))
sys_log.addHandler(sh)

async def handle(reader, writer):
    peer = writer.get_extra_info("peername") or ("unknown", 0)
    sock = writer.get_extra_info("sockname") or ("unknown", 0)
    entry = json.dumps({
        "timestamp" : datetime.now(timezone.utc).isoformat(),
        "event"     : "sinkhole_hit",
        "client_ip" : peer[0],
        "client_port": peer[1],
        "dst_port"  : sock[1],
    })
    file_log.info(entry)
    sys_log.info(entry)
    try:
        writer.close()
        await writer.wait_closed()
    except Exception:
        pass

async def main():
    servers, failed = [], []
    for port in PORTS:
        try:
            s = await asyncio.start_server(handle, SINKHOLE_IP, port,
                                           reuse_address=True)
            servers.append(s)
        except Exception as e:
            failed.append((port, e))
    for port, e in failed:
        print(f"WARN: could not bind {port}: {e}", file=sys.stderr)
    print(f"Sinkhole up on {SINKHOLE_IP} — {len(servers)}/{len(PORTS)} ports", flush=True)
    async with asyncio.TaskGroup() as tg:
        for s in servers:
            tg.create_task(s.serve_forever())

if __name__ == "__main__":
    asyncio.run(main())
