"""After a single-instance restart: which acknowledged Mem0 memories still exist?

Usage (inside a Mem0 sandbox, API running alone): mem0-api-verify.py <who>=<acked-file> ...
Lists every memory for user_id race-api and matches it against each writer's acknowledged texts.
"""
import json
import sys
import urllib.request

API = "http://127.0.0.1:8000"
KEY = open("/var/lib/mem0/jwt-secret").read().strip()
req = urllib.request.Request(f"{API}/memories?user_id=race-api&limit=10000",
                             headers={"X-API-Key": KEY})
with urllib.request.urlopen(req, timeout=120) as r:
    body = json.loads(r.read())
items = body.get("results", []) if isinstance(body, dict) else body
present = [m.get("memory", "") for m in items]
print(f"memories present for race-api: {len(present)}")

for arg in sys.argv[1:]:
    who, path = arg.split("=", 1)
    acked = [line for line in open(path).read().splitlines() if line]
    present_set = set(present)
    lost = [t for t in acked if t not in present_set]
    dup = sum(present.count(t) - 1 for t in set(acked) if present.count(t) > 1)
    phantom = [t for t in present if t.startswith(f"{who} fact") and t not in set(acked)]
    print(f"{who}: acked={len(acked)} lost_acked={len(lost)} ({100 * len(lost) / max(len(acked), 1):.1f}%) "
          f"duplicates={dup} present_not_acked={len(phantom)}")
