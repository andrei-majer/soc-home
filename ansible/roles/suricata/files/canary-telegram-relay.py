#!/usr/bin/env python3
"""Canarytokens webhook -> Telegram relay.

Canarytokens.org POSTs JSON here (via nginx on .1); we reformat to a Telegram
sendMessage. Secrets live in /etc/canary-relay.conf (0600), not in this file.
"""
import json
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

CONF = {}
with open("/etc/canary-relay.conf") as fh:
    for line in fh:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            CONF[k] = v

LISTEN = ("192.168.1.20", 8766)


def send_telegram(text):
    data = urllib.parse.urlencode(
        {"chat_id": CONF["TG_CHAT"], "text": text, "parse_mode": "HTML"}
    ).encode()
    req = urllib.request.Request(
        "https://api.telegram.org/bot%s/sendMessage" % CONF["TG_TOKEN"], data=data
    )
    urllib.request.urlopen(req, timeout=10).read()


def esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def flat(v):
    """Canarytokens wraps scalars in single-element lists; unwrap and join."""
    if isinstance(v, (list, tuple)):
        return ", ".join(str(x) for x in v)
    return str(v)


class Handler(BaseHTTPRequestHandler):
    server_version = "relay"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        if self.path.rstrip("/") != "/hook/" + CONF["HOOK_SECRET"]:
            self.send_response(404)
            self.end_headers()
            return
        try:
            body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
            payload = json.loads(body) if body else {}
        except (ValueError, KeyError):
            payload = {}
        extra = payload.get("additional_data") or {}
        aws = extra.get("aws_key_log_data") or {}
        lines = ["\U0001f6a8 <b>CANARY TOKEN TRIGGERED</b>"]
        if payload.get("memo"):
            lines.append("<b>%s</b>" % esc(payload["memo"]))
        if payload.get("time"):
            lines.append("Time: %s" % esc(payload["time"]))
        if extra.get("src_ip"):
            lines.append("Source IP: <code>%s</code>" % esc(extra["src_ip"]))
        if aws.get("eventName"):
            lines.append("AWS event: <b>%s</b>" % esc(flat(aws["eventName"])))
        if aws.get("accountId"):
            lines.append("AWS account: <code>%s</code>" % esc(flat(aws["accountId"])))
        ua = extra.get("useragent", "")
        if ua:
            # keep the SDK name, drop the platform/config noise
            lines.append("Agent: %s" % esc(ua.split(" ", 1)[0]))
        if payload.get("manage_url"):
            lines.append('<a href="%s">Manage token</a>' % esc(payload["manage_url"]))
        if len(lines) == 1:
            lines.append("(test/handshake ping: %s)" % esc(body[:300].decode("utf-8", "replace")))
        try:
            send_telegram("\n".join(lines))
        except Exception as exc:  # never bounce the webhook: canarytokens may retry-storm
            import syslog

            syslog.syslog(syslog.LOG_ERR, "canary-relay telegram send failed: %s" % exc)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok")

    do_GET = do_POST


HTTPServer(LISTEN, Handler).serve_forever()
