"""Inside a Mem0 sandbox: add N memories through the local Mem0 API, log every one it acknowledges.

Usage: mem0-api-writer.py <who> <count>  -> /tmp/api-acked.txt (one memory text per line), summary on stdout
infer:false stores the text as given (one embedding call per memory, no LLM extraction), so each
acknowledged add maps to exactly one stored memory that can be looked up afterwards.
"""
import json
import sys
import time
import urllib.error
import urllib.request

API = "http://127.0.0.1:8000"
KEY = open("/var/lib/mem0/jwt-secret").read().strip()
who, count = sys.argv[1], int(sys.argv[2])
acked, failed, errors = [], 0, {}


def configure(dims: int = 1536) -> None:
    """Same settings as mem0-functional.py: gateway models, 1536-dim vectors (pgvector HNSW limit 2000)."""
    hdr = {"X-API-Key": KEY, "Content-Type": "application/json"}
    with urllib.request.urlopen(urllib.request.Request(API + "/configure", headers=hdr), timeout=30) as r:
        cfg = json.loads(r.read())
    cfg["vector_store"]["config"].update({"embedding_model_dims": dims, "collection_name": f"memories_{dims}"})
    cfg["embedder"]["config"].update({"model": "auto", "embedding_dims": dims})
    cfg["llm"]["config"].update({"model": "auto"})
    for part in ("llm", "embedder"):
        cfg[part]["config"] = {k: v for k, v in cfg[part]["config"].items() if k != "api_key" and "REDACTED" not in str(v)}
    req = urllib.request.Request(API + "/configure", method="POST", data=json.dumps(cfg).encode(), headers=hdr)
    with urllib.request.urlopen(req, timeout=30) as r:
        assert r.status == 200


configure()

for i in range(1, count + 1):
    text = f"{who} fact {i}: the value of {who}-{i} is {i * 7}."
    body = {"messages": [{"role": "user", "content": text}], "user_id": "race-api", "infer": False}
    req = urllib.request.Request(API + "/memories", method="POST", data=json.dumps(body).encode(),
                                 headers={"X-API-Key": KEY, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            if r.status == 200:
                acked.append(text)
                continue
            key = str(r.status)
    except urllib.error.HTTPError as e:
        key = f"{e.code} {e.read().decode()[:80]}"
    except Exception as e:  # noqa: BLE001 — record every failure kind, never stop the run
        key = type(e).__name__
    failed += 1
    errors[key] = errors.get(key, 0) + 1
    time.sleep(0.5)

open("/tmp/api-acked.txt", "w").write("\n".join(acked) + "\n")
print(f"{who} tried={count} acked={len(acked)} failed={failed} errors={json.dumps(errors)[:300]}")
