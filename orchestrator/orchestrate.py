"""Orchestrator PoC: fan headless Claude Code workers out to Docker Sandboxes, collect via git.

Host side (this process):
  - an HTTP inbox on 127.0.0.1:<port>, the ONLY writer of inbox.jsonl (single writer by construction)
  - creates one clone-mode sandbox per task, allows it to reach the inbox, dispatches the task with
    `sbx exec <worker> claude -p ... --model <model>` in parallel
  - fetches each worker's `sandbox-<name>` remote, merges into `integration`, runs the tests

Workers never share a writable folder: input is their private clone, output is git commits,
status is an HTTP POST to the inbox. Usage:
  python orchestrate.py <repo> [--model haiku] [--port 8765] [--keep]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TASKS = {
    "slugify": "slugify must join words with '-' (test_textkit.TestSlugify).",
    "duration": "parse_duration must treat a trailing bare number as seconds (test_textkit.TestParseDuration).",
    "chunk": "chunk must keep the last partial chunk (test_textkit.TestChunk).",
}

PROMPT = """You are worker {worker} in an orchestrated team. Your one task: in textkit.py, {task}
Rules: change ONLY that function; do not edit tests or other functions.
1. Report start:   curl -s -X POST http://host.docker.internal:{port}/report -H 'Content-Type: application/json' -d '{{"worker":"{worker}","task":"{name}","status":"started"}}'
2. Fix it and run: python3 -m unittest -q test_textkit.{test}
3. Commit only textkit.py with message 'fix {name}'.
4. Report result:  same curl with "status":"done" (or "failed") and a "detail" field with the test result.
Reply with one line: commit hash and test result."""

TEST_FOR = {"slugify": "TestSlugify", "duration": "TestParseDuration", "chunk": "TestChunk"}


class Inbox:
    """Single-writer message log: only this process appends, under one lock."""

    def __init__(self, path: Path):
        self.path, self.lock, self.messages = path, threading.Lock(), []

    def add(self, msg: dict) -> None:
        msg["received_at"] = time.strftime("%H:%M:%S")
        with self.lock:
            self.messages.append(msg)
            with self.path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(msg) + "\n")


def serve_inbox(inbox: Inbox, port: int) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802 — http.server naming
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0)
            try:
                inbox.add(json.loads(body or b"{}"))
                self.send_response(202)
            except json.JSONDecodeError:
                self.send_response(400)
            self.end_headers()

        def log_message(self, format: str, *args: object) -> None:  # noqa: A002 — keep the console for orchestrator output
            del format, args

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def run(cmd: list[str], timeout: int = 900, cwd: str | None = None) -> tuple[int, str]:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd,
                       encoding="utf-8", errors="replace")
    return p.returncode, (p.stdout + p.stderr).strip()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("repo")
    ap.add_argument("--model", default="haiku")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    repo = str(Path(a.repo).resolve())
    inbox = Inbox(Path(repo).parent / f"inbox-{time.strftime('%H%M%S')}.jsonl")
    server = serve_inbox(inbox, a.port)
    workers = {name: f"o-{name}" for name in TASKS}
    t0 = time.time()

    def create(name: str) -> str:
        w = workers[name]
        code, _ = run(["sbx", "create", "--name", w, "--clone", "--memory", "2g", "--cpus", "2", "claude", repo])
        run(["sbx", "policy", "allow", "network", "--sandbox", w, f"localhost:{a.port}"])
        return f"{w}: create exit {code}"

    def dispatch(name: str) -> dict:
        w, start = workers[name], time.time()
        prompt = PROMPT.format(worker=w, task=TASKS[name], port=a.port, name=name, test=TEST_FOR[name])
        code, out = run(["sbx", "exec", w, "claude", "-p", prompt, "--model", a.model])
        return {"worker": w, "task": name, "exit": code, "seconds": round(time.time() - start), "reply": out[-200:]}

    print("== create workers (parallel)")
    with ThreadPoolExecutor(len(TASKS)) as ex:
        for line in ex.map(create, TASKS):
            print("  ", line)
    print(f"== dispatch {len(TASKS)} tasks (parallel, model={a.model})")
    with ThreadPoolExecutor(len(TASKS)) as ex:
        results = list(ex.map(dispatch, TASKS))
    for r in results:
        print(f"   {r['worker']}: exit {r['exit']} in {r['seconds']}s — {r['reply'].splitlines()[-1] if r['reply'] else ''}")

    print("== collect: fetch each worker's remote and merge into 'integration'")
    run(["git", "checkout", "-q", "-B", "integration", "main"], cwd=repo)
    for w in workers.values():
        run(["git", "fetch", "-q", f"sandbox-{w}"], cwd=repo)
        code, out = run(["git", "merge", "--no-edit", "-q", f"sandbox-{w}/main"], cwd=repo)
        print(f"   merge {w}: {'ok' if code == 0 else 'CONFLICT/FAIL: ' + out[-160:]}")
        if code != 0:
            run(["git", "merge", "--abort"], cwd=repo)
    code, out = run(["python", "-m", "unittest", "-q", "test_textkit"], cwd=repo)
    print(f"== integration tests: {'PASS' if code == 0 else 'FAIL'} — {out.splitlines()[-1] if out else ''}")
    print(f"== inbox ({inbox.path.name}, single writer): {len(inbox.messages)} messages")
    for m in inbox.messages:
        print(f"   {m.get('received_at')} {m.get('worker')} {m.get('task')} {m.get('status')} {str(m.get('detail', ''))[:80]}")
    print(f"== total {round(time.time() - t0)}s")
    server.shutdown()
    if not a.keep:
        for w in workers.values():
            run(["sbx", "rm", "-f", w])


if __name__ == "__main__":
    main()
