# Orchestrator PoC — headless Claude Code workers in Docker Sandboxes

One orchestrator on the host fans tasks out to worker sandboxes and collects the results through
the channels sbx actually offers — no shared writable folder anywhere.

```
host: orchestrate.py ─ HTTP inbox (127.0.0.1:8765, the ONLY writer of inbox-*.jsonl)
  ├─ sbx create --clone claude <repo>          ×3   (one private clone per worker)
  ├─ sbx policy allow network --sandbox wN localhost:8765
  ├─ sbx exec wN claude -p "<task>" --model haiku   (parallel, headless)
  │     worker → curl POST host.docker.internal:8765/report   (status)
  │     worker → git commit in its clone                       (result)
  └─ git fetch sandbox-wN → merge into `integration` → run tests → sbx rm
```

Run: `bash make-demo-repo.sh <dir> && python orchestrate.py <dir> --model haiku [--keep]`

## Measured — sbx 0.50.0, Windows 11, 26 Oct 2026 (`logs/orchestrator-run1.log`)

| Step | Result |
|---|---|
| Feasibility, one worker: clone mode, Python 3.14.4, Claude Code 2.1.306 | ✅ |
| `sbx exec w1 claude -p ... --model haiku` on the stored subscription login, non-interactive | ✅ "WORKER-OK" in 8 s |
| Worker commit fetched on the host via `sandbox-w1` | ✅ |
| 3 workers created, then dispatched in parallel | ✅ all exit 0, ~18 s each |
| Inbox (single writer) | ✅ 6 / 6 messages — 3 started, 3 done with test results |
| Merge of 3 worker branches | ✅ 3 clean merges |
| Tests on the merged result | ✅ PASS (before: 3 of 4 failing) |
| Wall time, end to end | 46 s |

## What the run taught

- **Trust git and structured reports, not the agent's prose.** All three inbox reports carried the
  real commit hash. One worker's final free-text reply named a commit (`ed8f0d18…`) that does not
  exist. The orchestrator merges from the actual `sandbox-<name>` refs, so it did no harm.
- **`sbx rm` removes the `sandbox-<name>` remote and its refs from the host repo** (0 remotes, 0
  refs after). Collect and merge *before* removing a worker.
- **The host git daemon prints `unable to access '/root/.config/git/attributes': Permission denied`**
  on every fetch — harmless noise.
- **No built-in inbox exists.** Sandboxes cannot reach each other; the inbox is a host process
  reached via `host.docker.internal` plus an allow rule for `localhost:<port>` (the proxy evaluates
  the name as `localhost`). Being one process, it is a single writer by construction.
- **All workers share one subscription** — they share its rate limits. Fine for three Haiku workers;
  an API key per team is the realistic setup at scale.

## Not measured yet

- Whether a host-side MCP server (`sbx mcp add --command`) runs one process per sandbox or one
  shared — which decides whether an MCP inbox is a single writer.
- Conflicting tasks (two workers editing the same function) — the merge step is where an
  orchestrator must decide; this run used independent tasks on purpose.
