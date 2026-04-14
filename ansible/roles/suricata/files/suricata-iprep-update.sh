#!/usr/bin/env python3
"""
Suricata IP Reputation updater.
Downloads free threat intel feeds and formats them for Suricata iprep.

Categories (must match /etc/suricata/iprep/categories.txt):
  1 = malware
  2 = spam
  3 = scanner
  4 = phishing
  5 = botnet

Runs as root. Safe to re-run at any time; reloads Suricata rules on change.
"""

import ipaddress
import logging
import os
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime, timezone

IPREP_DIR = "/etc/suricata/iprep"
OUTPUT_FILE = os.path.join(IPREP_DIR, "reputation.list")

CAT_MALWARE = 1
CAT_SPAM    = 2
CAT_SCANNER = 3
CAT_PHISHING = 4
CAT_BOTNET  = 5
CAT_ABUSE   = 6

FEEDS = [
    {
        "name": "Feodo Tracker (Botnet C2)",
        "url":  "https://feodotracker.abuse.ch/downloads/ipblocklist.txt",
        "category": CAT_BOTNET,
        "score": 100,
    },
    {
        "name": "Emerging Threats - Compromised IPs",
        "url":  "https://rules.emergingthreats.net/blockrules/compromised-ips.txt",
        "category": CAT_MALWARE,
        "score": 85,
    },
    {
        "name": "Emerging Threats - Block List",
        "url":  "https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt",
        "category": CAT_MALWARE,
        "score": 80,
    },
    {
        "name": "CINS Score - Bad Guys",
        "url":  "http://cinsscore.com/list/ci-badguys.txt",
        "category": CAT_SCANNER,
        "score": 75,
    },
    {
        "name": "Feodo Tracker C2 (aggressive)",
        "url":  "https://feodotracker.abuse.ch/downloads/ipblocklist_aggressive.txt",
        "category": CAT_BOTNET,
        "score": 95,
    },
    {
        "name": "URLhaus - Malware URLs (IPs)",
        "url":  "https://urlhaus.abuse.ch/downloads/text_online/",
        "category": CAT_MALWARE,
        "score": 88,
        "extract_hosts_only": True,  # strip port/path, keep IP only
    },
    {
        "name": "Spamhaus DROP (Don't Route Or Peer — EDROP merged in Feb 2026)",
        "url":  "https://www.spamhaus.org/drop/drop.txt",
        "category": CAT_ABUSE,
        "score": 90,
    },
]


def fetch(url: str, timeout: int = 30) -> str | None:
    try:
        req = urllib.request.Request(
            url, headers={"User-Agent": "Suricata-iprep-updater/1.0"}
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except Exception as exc:
        logging.warning("Fetch failed [%s]: %s", url, exc)
        return None


def parse_ips(content: str, extract_hosts_only: bool = False) -> list[str]:
    """Extract valid IPs/CIDRs from raw feed text, ignoring comments."""
    result = []
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        token = line.split()[0]   # first whitespace-separated token

        if extract_hosts_only:
            # Strip scheme, port, path — keep bare IP
            token = token.replace("https://", "").replace("http://", "")
            token = token.split("/")[0].split(":")[0]

        try:
            if "/" in token:
                net = ipaddress.ip_network(token, strict=False)
                # Skip RFC1918 / link-local / loopback
                if net.is_private or net.is_link_local or net.is_loopback:
                    continue
                result.append(str(net))
            else:
                addr = ipaddress.ip_address(token)
                if addr.is_private or addr.is_link_local or addr.is_loopback:
                    continue
                result.append(str(addr))
        except ValueError:
            pass
    return result


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
        stream=sys.stdout,
    )

    os.makedirs(IPREP_DIR, exist_ok=True)

    # ip -> (category, score)  — keep highest score on collision
    entries: dict[str, tuple[int, int]] = {}
    total_fetched = 0

    for feed in FEEDS:
        logging.info("Fetching: %s", feed["name"])
        content = fetch(feed["url"])
        if content is None:
            continue

        ips = parse_ips(content, extract_hosts_only=feed.get("extract_hosts_only", False))
        cat   = feed["category"]
        score = feed["score"]
        added = 0
        for ip in ips:
            if ip not in entries or score > entries[ip][1]:
                entries[ip] = (cat, score)
                added += 1
        logging.info("  -> %d entries (feed total before dedup)", len(ips))
        total_fetched += len(ips)

    if not entries:
        logging.error("No reputation entries fetched — aborting to avoid overwriting existing list")
        return 1

    # Write to temp file then atomically replace
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    tmp_path = OUTPUT_FILE + ".tmp"
    with open(tmp_path, "w") as f:
        f.write(f"# Suricata IP Reputation List\n")
        f.write(f"# Generated: {now}\n")
        f.write(f"# Unique entries: {len(entries)} (from {total_fetched} raw)\n")
        f.write(f"# Format: ip/cidr,category_id,score(0-127)\n\n")
        for ip, (cat, score) in sorted(entries.items(), key=lambda x: x[0]):
            f.write(f"{ip},{cat},{score}\n")

    os.replace(tmp_path, OUTPUT_FILE)
    logging.info("Written %d unique entries to %s", len(entries), OUTPUT_FILE)

    # Signal Suricata to reload rules (also reloads iprep data).
    # reload-rules blocks until complete — with 320k+ rules this can take >5 min.
    # We use a long timeout but treat TimeoutExpired as a non-fatal warning:
    # the reputation.list is already written atomically; Suricata will use the
    # new data on its next scheduled restart or manual reload.
    socket_path = "/var/run/suricata-command.socket"
    if os.path.exists(socket_path):
        try:
            result = subprocess.run(
                ["suricatasc", "-c", "reload-rules"],
                capture_output=True, text=True, timeout=600
            )
            if result.returncode == 0:
                logging.info("Suricata reload-rules: OK")
            else:
                logging.warning("suricatasc reload-rules failed: %s", result.stderr.strip())
        except subprocess.TimeoutExpired:
            logging.warning(
                "suricatasc reload-rules timed out (>600s) — reputation.list is updated; "
                "Suricata will load new data on next restart or manual reload"
            )
    else:
        logging.warning("Suricata socket not found at %s — skipping reload", socket_path)

    return 0


if __name__ == "__main__":
    sys.exit(main())
