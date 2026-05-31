#!/usr/bin/env python3
"""Generate the improved Zeek NSM Grafana dashboard JSON."""
import json

DS = {"type": "elasticsearch", "uid": "zeek_es"}
_id = [0]
def nid():
    _id[0] += 1
    return _id[0]

def terms(field, size=10, order_by="_count", min_doc="1", bid="2"):
    return {"field": field, "id": bid, "type": "terms",
            "settings": {"min_doc_count": min_doc, "order": "desc", "orderBy": order_by, "size": str(size)}}

def datehist(bid="2"):
    return {"field": "@timestamp", "id": bid, "type": "date_histogram", "settings": {"interval": "auto", "min_doc_count": "0"}}

def statbucket():
    # single wide bucket: 1 bucket per dashboard window -> stat reduce = exact total
    return {"field": "@timestamp", "id": "2", "type": "date_histogram", "settings": {"interval": "1y", "min_doc_count": "0"}}

def target(query="", bucket_aggs=None, metrics=None, refId="A"):
    return {"datasource": DS, "query": query, "refId": refId, "timeField": "@timestamp",
            "metrics": metrics or [{"id": "1", "type": "count"}],
            "bucketAggs": bucket_aggs if bucket_aggs is not None else []}

# ---- layout cursor ----
class Layout:
    def __init__(self):
        self.x = 0; self.y = 0; self.rowh = 0; self.panels = []
    def newrow(self, title):
        if self.x != 0:
            self.y += self.rowh; self.x = 0; self.rowh = 0
        self.panels.append({"type": "row", "collapsed": False, "title": title,
                            "gridPos": {"h": 1, "w": 24, "x": 0, "y": self.y},
                            "id": nid(), "panels": []})
        self.y += 1; self.x = 0; self.rowh = 0
    def add(self, panel, w, h):
        if self.x + w > 24:
            self.y += self.rowh; self.x = 0; self.rowh = 0
        panel["gridPos"] = {"h": h, "w": w, "x": self.x, "y": self.y}
        panel["id"] = nid()
        self.panels.append(panel)
        self.x += w; self.rowh = max(self.rowh, h)

def stat(title, target_, unit="short", red_above=None):
    steps = [{"color": "green", "value": None}]
    if red_above is not None:
        steps = [{"color": "green", "value": None}, {"color": "red", "value": red_above}]
    return {"title": title, "type": "stat", "datasource": DS, "pluginVersion": "12.4.2",
            "fieldConfig": {"defaults": {"unit": unit, "color": {"mode": "thresholds"},
                            "thresholds": {"mode": "absolute", "steps": steps}}, "overrides": []},
            "options": {"colorMode": "value", "graphMode": "area", "justifyMode": "auto",
                        "orientation": "auto", "textMode": "auto",
                        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
            "targets": [target_]}

def table(title, target_, unit="short"):
    return {"title": title, "type": "table", "datasource": DS, "pluginVersion": "12.4.2",
            "fieldConfig": {"defaults": {"unit": unit, "custom": {"align": "auto", "filterable": True}}, "overrides": []},
            "options": {"showHeader": True, "footer": {"show": False}},
            "targets": [target_]}

def pie(title, target_):
    return {"title": title, "type": "piechart", "datasource": DS, "pluginVersion": "12.4.2",
            "fieldConfig": {"defaults": {"custom": {"hideFrom": {"legend": False, "tooltip": False, "viz": False}}}, "overrides": []},
            "options": {"legend": {"displayMode": "table", "placement": "right", "values": ["value", "percent"]},
                        "pieType": "donut", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": True},
                        "tooltip": {"mode": "single", "sort": "desc"}},
            "targets": [target_]}

def tseries(title, target_):
    return {"title": title, "type": "timeseries", "datasource": DS, "pluginVersion": "12.4.2",
            "fieldConfig": {"defaults": {"custom": {"drawStyle": "line", "fillOpacity": 18, "showPoints": "never",
                            "stacking": {"mode": "normal", "group": "A"}, "lineWidth": 1}}, "overrides": []},
            "options": {"legend": {"displayMode": "list", "placement": "right", "showLegend": True},
                        "tooltip": {"mode": "multi", "sort": "desc"}},
            "targets": [target_]}

L = Layout()

# ===== Overview =====
L.newrow("Overview")
L.add(stat("Total events", target(bucket_aggs=[statbucket()])), 3, 4)
L.add(stat("Connections", target(query="zeek_log_type:conn", bucket_aggs=[statbucket()])), 3, 4)
L.add(stat("Unique src IPs", target(metrics=[{"id": "1", "type": "cardinality", "field": "id.orig_h.keyword"}], bucket_aggs=[statbucket()])), 3, 4)
L.add(stat("Unique dst IPs", target(metrics=[{"id": "1", "type": "cardinality", "field": "id.resp_h.keyword"}], bucket_aggs=[statbucket()])), 3, 4)
L.add(stat("DNS queries", target(query="zeek_log_type:dns", bucket_aggs=[statbucket()])), 3, 4)
L.add(stat("TLS sessions", target(query="zeek_log_type:ssl", bucket_aggs=[statbucket()])), 3, 4)
L.add(stat("HTTP txns", target(query="zeek_log_type:http", bucket_aggs=[statbucket()])), 3, 4)
L.add(stat("Notices", target(query="zeek_log_type:notice", bucket_aggs=[statbucket()]), red_above=1), 3, 4)
L.add(tseries("Events over time, by log type",
      target(bucket_aggs=[terms("zeek_log_type.keyword", 12, "_term", "0", "3"), datehist("2")])), 16, 9)
L.add(pie("Events by log type", target(bucket_aggs=[terms("zeek_log_type.keyword", 15)])), 8, 9)

# ===== Connections =====
L.newrow("Connections (conn.log)")
L.add(table("Top talkers by bytes (sent / received)",
      target(query="zeek_log_type:conn",
             bucket_aggs=[terms("id.orig_h.keyword", 15, "1", "1")],
             metrics=[{"id": "1", "type": "sum", "field": "orig_ip_bytes"},
                      {"id": "3", "type": "sum", "field": "resp_ip_bytes"}]), unit="bytes"), 9, 8)
L.add(table("Top destination IPs", target(query="zeek_log_type:conn", bucket_aggs=[terms("id.resp_h.keyword", 15)])), 5, 8)
L.add(table("Top destination ports", target(query="zeek_log_type:conn", bucket_aggs=[terms("id.resp_p", 15)])), 5, 8)
L.add(table("Connection states", target(query="zeek_log_type:conn", bucket_aggs=[terms("conn_state.keyword", 15)])), 5, 8)
L.add(table("Top services", target(query="zeek_log_type:conn", bucket_aggs=[terms("service.keyword", 15)])), 6, 7)
L.add(table("Top connection history", target(query="zeek_log_type:conn", bucket_aggs=[terms("history.keyword", 15)])), 6, 7)
L.add(tseries("Connections over time", target(query="zeek_log_type:conn", bucket_aggs=[datehist("2")])), 12, 7)

# ===== DNS =====
L.newrow("DNS (dns.log)")
L.add(table("Top DNS queries", target(query="zeek_log_type:dns", bucket_aggs=[terms("query.keyword", 20)])), 8, 9)
L.add(pie("Query types", target(query="zeek_log_type:dns", bucket_aggs=[terms("qtype_name.keyword", 12)])), 8, 9)
L.add(table("Response codes", target(query="zeek_log_type:dns", bucket_aggs=[terms("rcode_name.keyword", 12)])), 8, 9)
L.add(table("Top NXDOMAIN queries (DGA / exfil signal)",
      target(query="zeek_log_type:dns AND rcode_name:NXDOMAIN", bucket_aggs=[terms("query.keyword", 20)])), 12, 8)
L.add(table("Top DNS clients", target(query="zeek_log_type:dns", bucket_aggs=[terms("id.orig_h.keyword", 15)])), 12, 8)

# ===== TLS =====
L.newrow("TLS / SSL (ssl.log)")
L.add(table("Top server names (SNI)", target(query="zeek_log_type:ssl", bucket_aggs=[terms("server_name.keyword", 20)])), 8, 9)
L.add(pie("TLS versions", target(query="zeek_log_type:ssl", bucket_aggs=[terms("version.keyword", 10)])), 8, 9)
L.add(table("Cert validation status", target(query="zeek_log_type:ssl", bucket_aggs=[terms("validation_status.keyword", 12)])), 8, 9)
L.add(table("Top ciphers", target(query="zeek_log_type:ssl", bucket_aggs=[terms("cipher.keyword", 15)])), 12, 8)
L.add(table("Top ALPN / next protocol", target(query="zeek_log_type:ssl", bucket_aggs=[terms("next_protocol.keyword", 10)])), 12, 8)

# ===== HTTP =====
L.newrow("HTTP (http.log)")
L.add(pie("Methods", target(query="zeek_log_type:http", bucket_aggs=[terms("method.keyword", 10)])), 6, 9)
L.add(table("Status codes", target(query="zeek_log_type:http", bucket_aggs=[terms("status_code", 15)])), 6, 9)
L.add(table("Top user agents", target(query="zeek_log_type:http", bucket_aggs=[terms("user_agent.keyword", 15)])), 12, 9)
L.add(table("Top URIs", target(query="zeek_log_type:http", bucket_aggs=[terms("uri.keyword", 20)])), 24, 8)

# ===== Security signals =====
L.newrow("Security signals — Notices / Weird / SSH / Certs")
L.add(table("Notices by type", target(query="zeek_log_type:notice", bucket_aggs=[terms("note.keyword", 20)])), 8, 9)
L.add(table("Notice messages", target(query="zeek_log_type:notice", bucket_aggs=[terms("msg.keyword", 20)])), 16, 9)
L.add(table("Weird events", target(query="zeek_log_type:weird", bucket_aggs=[terms("name.keyword", 20)])), 8, 9)
L.add(table("SSH servers (auth attempts)",
      target(query="zeek_log_type:ssh", bucket_aggs=[terms("id.resp_h.keyword", 15, "1", "1")],
             metrics=[{"id": "1", "type": "sum", "field": "auth_attempts"}])), 8, 9)
L.add(table("SSH clients (software)", target(query="zeek_log_type:ssh", bucket_aggs=[terms("client.keyword", 15)])), 8, 9)
L.add(table("Certificate issuers", target(query="zeek_log_type:x509", bucket_aggs=[terms("certificate.issuer.keyword", 15)])), 12, 8)
L.add(table("Certificate subjects", target(query="zeek_log_type:x509", bucket_aggs=[terms("certificate.subject.keyword", 15)])), 12, 8)

dashboard = {
    "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"},
                    "enable": True, "hide": True, "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts", "type": "dashboard"}]},
    "editable": True, "fiscalYearStartMonth": 0, "graphTooltip": 1, "links": [], "liveNow": False,
    "panels": L.panels,
    "refresh": "1m", "schemaVersion": 39, "tags": ["zeek", "soc", "nsm"],
    "templating": {"list": [
        {"name": "filters", "type": "adhoc", "datasource": DS, "label": "Filter", "hide": 0}
    ]},
    "time": {"from": "now-24h", "to": "now"}, "timepicker": {}, "timezone": "browser",
    "title": "Zeek — Network Security Monitor", "uid": "zeek-nsm", "version": 2, "weekStart": ""
}

print(json.dumps(dashboard, indent=2))
