import json, sys
har = json.load(open(sys.argv[1], encoding="utf-8"))
def shape(v, d=0):
    if isinstance(v, dict): return {k: shape(x, d+1) for k, x in v.items()} if d < 6 else "{..}"
    if isinstance(v, list): return [shape(v[0], d+1)] if v else []
    return type(v).__name__
def j(t):
    try: return shape(json.loads(t))
    except Exception: return f"<non-json {len(t)}b>"
seen = {}
for e in har["log"]["entries"]:
    u = e["request"]["url"]
    if "agentic-platform.docker.com/api/" not in u: continue
    m = u.split("/api/")[1].split("?")[0]
    if m in seen: continue
    req = (e["request"].get("postData") or {}).get("text") or ""
    res = (e["response"].get("content") or {}).get("text") or ""
    ct = [h["value"] for h in e["response"]["headers"] if h["name"].lower() == "content-type"][:1]
    names = sorted({h["name"].lower() for h in e["request"]["headers"]})
    hdr = [n for n in names if n in ("authorization", "connect-protocol-version", "cookie") or n.startswith("x-")]
    auth = m.startswith("auth.v1.AuthService")
    seen[m] = (e["response"]["status"], ct, hdr, j(req) if req else None, "<auth: not shown>" if auth else (j(res) if res else None))
for m, (st, ct, hdr, rq, rs) in seen.items():
    print(f"## {m}  {st} {ct} headers={hdr}\n  req={json.dumps(rq)}\n  res={json.dumps(rs)[:1200]}")
