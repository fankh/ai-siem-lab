#!/usr/bin/env python3
"""오픈소스 AI-SIEM 실습용 샘플 보안 로그 적재기.

OpenSearch 'security-web' 인덱스에 정상 트래픽 + 공격(브루트포스/SQLi/XSS) 로그를 적재한다.
표준 라이브러리만 사용. 결정적(seed 고정).

사용: python load_sample_logs.py [http://localhost:9200]
"""
import json, random, urllib.request, datetime, sys

OS = (sys.argv[1] if len(sys.argv) > 1 else "http://localhost:9200").rstrip("/")
INDEX = "security-web"
random.seed(1337)


def req(method, path, body=None):
    data = body.encode("utf-8") if isinstance(body, str) else body
    r = urllib.request.Request(OS + path, data=data, method=method,
                               headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(r) as resp:
        return resp.status, resp.read().decode("utf-8")


# 1) 인덱스 재생성 (매핑 명시 — @timestamp date, source.ip ip)
try:
    req("DELETE", "/" + INDEX)
except Exception:
    pass
mapping = {"mappings": {"properties": {
    "@timestamp": {"type": "date"},
    "source": {"properties": {"ip": {"type": "ip"}}},
    "url": {"properties": {"path": {"type": "keyword"}, "query": {"type": "keyword"}}},
    "http": {"properties": {"request": {"properties": {"method": {"type": "keyword"}}},
                            "response": {"properties": {"status_code": {"type": "integer"}}}}},
    "user_agent": {"properties": {"original": {"type": "keyword"}}},
    "event": {"properties": {"category": {"type": "keyword"}, "outcome": {"type": "keyword"}}},
}}}
req("PUT", "/" + INDEX, json.dumps(mapping))

now = datetime.datetime.now(datetime.timezone.utc)
docs = []


def doc(ts, ip, method, path, status, query="", ua="Mozilla/5.0", cat="web", outcome="success"):
    docs.append({"@timestamp": ts.isoformat(), "source": {"ip": ip},
                 "url": {"path": path, "query": query},
                 "http": {"request": {"method": method}, "response": {"status_code": status}},
                 "user_agent": {"original": ua}, "event": {"category": cat, "outcome": outcome}})


normal_ips = ["192.168.10.%d" % i for i in range(2, 40)]
paths = ["/", "/index.html", "/products", "/about", "/api/items", "/static/app.js", "/images/logo.png", "/cart"]
uas = ["Mozilla/5.0 (Windows NT 10.0)", "Mozilla/5.0 (Macintosh)", "Mozilla/5.0 (X11; Linux)"]

# 정상 트래픽 (최근 3시간)
for _ in range(550):
    ts = now - datetime.timedelta(seconds=random.randint(0, 3 * 3600))
    doc(ts, random.choice(normal_ips), "GET", random.choice(paths),
        random.choice([200, 200, 200, 304, 404]), ua=random.choice(uas))

# 브루트포스: 단일 IP가 최근 12분간 /login 401 폭주
for _ in range(160):
    ts = now - datetime.timedelta(seconds=random.randint(0, 12 * 60))
    doc(ts, "10.13.37.7", "POST", "/login", random.choice([401, 401, 401, 200]),
        ua="python-requests/2.31", cat="authentication", outcome="failure")

# SQLi
for q in ["id=1 UNION SELECT username,password FROM users", "id=1' OR '1'='1",
          "id=1; DROP TABLE users--", "search=1 UNION SELECT NULL,version()"]:
    ts = now - datetime.timedelta(seconds=random.randint(0, 30 * 60))
    doc(ts, "45.155.205.99", "GET", "/api/items", random.choice([200, 500]),
        query=q, ua="sqlmap/1.7", cat="web", outcome="failure")

# XSS
for q in ["q=<script>alert(1)</script>", "comment=<img src=x onerror=alert(1)>"]:
    ts = now - datetime.timedelta(seconds=random.randint(0, 40 * 60))
    doc(ts, "203.0.113.66", "GET", "/search", 200, query=q, cat="web")

# 2) _bulk 적재
lines = []
for d in docs:
    lines.append(json.dumps({"index": {"_index": INDEX}}))
    lines.append(json.dumps(d))
status, resp = req("POST", "/_bulk?refresh=true", "\n".join(lines) + "\n")
errors = json.loads(resp).get("errors")
print("loaded %d docs into '%s' (bulk errors=%s)" % (len(docs), INDEX, errors))

_, c = req("GET", "/" + INDEX + "/_count")
print("doc count:", json.loads(c)["count"])
