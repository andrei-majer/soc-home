#!/usr/bin/env python3
"""zeek-to-eve — translate Zeek JSON logs into Suricata EVE records for EveBox.

EveBox renders Suricata's EVE schema. Zeek's native JSON uses different keys
(`id.orig_h` vs `src_ip`, no `event_type`), so EveBox cannot display it. This
service tails Zeek's already-JSON logs, remaps them to the EVE schema, and
appends them to a STANDALONE file that EveBox reads as a second input.

It deliberately writes its own file, never Suricata's /var/log/suricata/eve.json:
the .120 Wazuh agent reads that file directly and Zeek's wide records would
overflow its JSON decoder (the field-explosion fixed in commit 8f9270b).

conn/ssl/http records that belong to one connection share Zeek's `uid`; we hash
it into a stable `flow_id` so EveBox groups a connection's events together.

Stdlib only (Debian 12 / Python 3.11). Runs as the `evebox` user, which is in
the `zeek` group (reads /opt/zeek/logs) and owns the EveBox event store.
"""

import hashlib
import json
import os
import signal
import time
from datetime import datetime, timedelta

ZEEK_DIR = "/opt/zeek/logs/current"
OUTPUT = "/var/log/zeek-eve/eve.json"
POLL_SECONDS = 0.5

# Zeek `service` -> Suricata `app_proto`
APP_PROTO = {
    "ssl": "tls", "dns": "dns", "http": "http", "ssh": "ssh",
    "ftp": "ftp", "dhcp": "dhcp", "smtp": "smtp",
}


def to_eve_ts(zeek_ts):
    """Zeek `2026-06-18T17:47:04.280668Z` -> EVE `...280668+0000`."""
    if zeek_ts.endswith("Z"):
        return zeek_ts[:-1] + "+0000"
    return zeek_ts


def parse_ts(zeek_ts):
    s = zeek_ts[:-1] + "+00:00" if zeek_ts.endswith("Z") else zeek_ts
    return datetime.fromisoformat(s)


def base(rec):
    """5-tuple / proto / flow_id block common to every event type."""
    out = {
        "timestamp": to_eve_ts(rec["ts"]),
        "src_ip": rec.get("id.orig_h"),
        "src_port": rec.get("id.orig_p"),
        "dest_ip": rec.get("id.resp_h"),
        "dest_port": rec.get("id.resp_p"),
    }
    proto = rec.get("proto")
    if proto:
        out["proto"] = proto.upper()
    uid = rec.get("uid")
    if uid:
        # stable 60-bit flow_id from the Zeek uid -> EveBox groups a conn's events
        out["flow_id"] = int(hashlib.sha1(uid.encode()).hexdigest()[:15], 16)
        out["zeek_uid"] = uid
    svc = rec.get("service")
    if svc in APP_PROTO:
        out["app_proto"] = APP_PROTO[svc]
    return out


def map_conn(rec):
    e = base(rec)
    e["event_type"] = "flow"
    dur = rec.get("duration") or 0.0
    end = parse_ts(rec["ts"]) + timedelta(seconds=dur)
    e["flow"] = {
        "pkts_toserver": rec.get("orig_pkts", 0),
        "pkts_toclient": rec.get("resp_pkts", 0),
        "bytes_toserver": rec.get("orig_ip_bytes", 0),
        "bytes_toclient": rec.get("resp_ip_bytes", 0),
        "start": to_eve_ts(rec["ts"]),
        "end": end.strftime("%Y-%m-%dT%H:%M:%S.%f") + "+0000",
        "age": int(dur),
        "state": rec.get("conn_state"),
    }
    if rec.get("history"):
        e["zeek_history"] = rec["history"]
    if not e.get("app_proto") and rec.get("service"):
        e["app_proto"] = rec["service"]
    return e


def map_ssl(rec):
    e = base(rec)
    e["event_type"] = "tls"
    e.setdefault("proto", "TCP")
    e["app_proto"] = "tls"
    e["tls"] = {
        "sni": rec.get("server_name"),
        "version": rec.get("version"),
        "cipher_suite": rec.get("cipher"),
        "resumed": rec.get("resumed"),
    }
    return e


def map_http(rec):
    e = base(rec)
    e["event_type"] = "http"
    e.setdefault("proto", "TCP")
    e["app_proto"] = "http"
    ver = rec.get("version")
    e["http"] = {
        "hostname": rec.get("host"),
        "url": rec.get("uri"),
        "http_method": rec.get("method"),
        "status": rec.get("status_code"),
        "http_user_agent": rec.get("user_agent"),
        "protocol": "HTTP/" + ver if ver else None,
        "length": rec.get("response_body_len"),
    }
    return e


# Zeek log filename in current/ -> EVE mapper. Add dns/ssh/etc. here to extend.
INPUTS = {
    "conn.log": map_conn,
    "ssl.log": map_ssl,
    "http.log": map_http,
}


class Tail:
    """tail -F one file: follow appends, reopen on rotation, reset on truncate."""

    def __init__(self, path):
        self.path = path
        self.fd = None
        self.ino = None
        self.buf = b""

    def _open(self, seek_end):
        self.fd = open(self.path, "rb")
        self.ino = os.fstat(self.fd.fileno()).st_ino
        if seek_end:
            self.fd.seek(0, os.SEEK_END)
        self.buf = b""

    def _drain(self):
        data = self.fd.read()
        if not data:
            return
        self.buf += data
        parts = self.buf.split(b"\n")
        self.buf = parts[-1]  # trailing partial line, if any
        for ln in parts[:-1]:
            if ln.strip():
                yield ln

    def lines(self):
        if self.fd is None:
            if not os.path.exists(self.path):
                return
            self._open(seek_end=True)  # skip backlog on first open
        try:
            st = os.stat(self.path)
        except FileNotFoundError:
            return
        if st.st_ino != self.ino:           # rotated: drain old, follow new
            yield from self._drain()
            self.fd.close()
            self._open(seek_end=False)
        elif st.st_size < self.fd.tell():   # truncated in place (copytruncate)
            self.fd.seek(0)
            self.buf = b""
        yield from self._drain()


def main():
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    out = open(OUTPUT, "a", buffering=1)  # line-buffered: flush on each newline
    tails = {fn: Tail(os.path.join(ZEEK_DIR, fn)) for fn in INPUTS}

    running = {"v": True}
    signal.signal(signal.SIGTERM, lambda *_: running.update(v=False))
    signal.signal(signal.SIGINT, lambda *_: running.update(v=False))

    while running["v"]:
        wrote = False
        for fn, tail in tails.items():
            mapper = INPUTS[fn]
            for raw in tail.lines():
                try:
                    eve = mapper(json.loads(raw))
                except Exception:
                    continue  # skip malformed / unexpected lines, keep tailing
                out.write(json.dumps(eve) + "\n")
                wrote = True
        if not wrote:
            time.sleep(POLL_SECONDS)

    out.flush()
    out.close()


if __name__ == "__main__":
    main()
