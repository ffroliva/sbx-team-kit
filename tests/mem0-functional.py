"""Functional check of a running Mem0 (PR #126 kit) inside a sandbox: configure, add, search.

Runs inside the sandbox. Uses Mem0's legacy admin key (the JWT secret start.sh exports as
ADMIN_API_KEY) via X-API-Key. LLM and embedder go to OPENAI_BASE_URL (any OpenAI-compatible gateway) through the
server process's own environment; only model names and vector size are configured here.
"""
import json
import sys
import time
import urllib.error
import urllib.request
from typing import Any

API = "http://127.0.0.1:8000"
KEY = open("/var/lib/mem0/jwt-secret").read().strip()
DIMS = int(sys.argv[1]) if len(sys.argv) > 1 else 3072
USER = "sbx-team-kit-test"


def call(method: str, path: str, body: Any = None, timeout: int = 180) -> tuple[int, Any]:
    req = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"X-API-Key": KEY, "Content-Type": "application/json"},
    )
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            out = json.loads(r.read() or b"null")
            code = r.status
    except urllib.error.HTTPError as e:
        code, out = e.code, e.read().decode()[:400]
    print(f"{method} {path} -> {code} in {time.time() - t:.1f}s")
    return code, out


code, cfg = call("GET", "/configure")
assert code == 200, cfg
cfg["vector_store"]["config"].update({"embedding_model_dims": DIMS, "collection_name": f"memories_{DIMS}"})
cfg["embedder"]["config"].update({"model": "auto", "embedding_dims": DIMS})
cfg["llm"]["config"].update({"model": "auto"})
for part in ("llm", "embedder"):  # leave api_key/base_url to the server's environment
    cfg[part]["config"] = {k: v for k, v in cfg[part]["config"].items() if k != "api_key" and "REDACTED" not in str(v)}
code, out = call("POST", "/configure", cfg)
assert code == 200, out

facts = [
    "I build backend services in Java 25 with Spring Boot 4.",
    "For agent memory I care most about not losing writes when several agents run at once.",
]
for f in facts:
    code, out = call("POST", "/memories", {"messages": [{"role": "user", "content": f}], "user_id": USER, "infer": True})
    print("  add ->", json.dumps(out)[:300])
    assert code == 200, out

for q in ["Which language and framework do I use for backend work?", "What matters to me about agent memory?"]:
    code, out = call("POST", "/search", {"query": q, "user_id": USER})
    hits = out.get("results", out) if isinstance(out, dict) else out
    print(f"  search '{q}' ->", json.dumps([(h.get("memory"), round(h.get("score", 0), 3)) for h in hits][:3]) if isinstance(hits, list) else hits)
    assert code == 200 and hits, out

code, out = call("GET", f"/memories?user_id={USER}")
n = len(out.get("results", [])) if isinstance(out, dict) else len(out) if isinstance(out, list) else "?"
print("stored memories for", USER, "=", n)
print("FUNCTIONAL TEST PASSED")
