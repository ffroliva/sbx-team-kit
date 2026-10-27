# Benchmark — a team of agents building real features in Docker Sandboxes

The claim under test: **sandboxes are the work-horse for parallel feature work** — one disposable
microVM per feature, a headless agent in each, the host merging the results and running the real
build. Target: [tiny-ledger](https://github.com/ffroliva/tiny-ledger), a real Java 25 / Spring
Boot service (291 commits, ArchUnit, Cucumber, Spotless). Every number below is measured; anything
not measured says so.

## Setup

| | |
|---|---|
| sbx | v0.50.0, Windows 11 host |
| Worker | `sbx create --clone --cpus 4 --memory 4g claude <repo>`, `claude -p --model sonnet` |
| Collection | `git fetch sandbox-<name>` **immediately** after each agent exits, into `refs/bench/<name>` |
| Integration | host merges every collected branch, runs the full `./mvnw verify` |
| Features | [tasks-tiny-ledger.json](tasks-tiny-ledger.json) — LIFO lot selection; the two §6.5 domain errors owed by the spec; Merkle proof by leaf hash. Independent files on purpose |
| Runner | [parallel_features.py](parallel_features.py) (`--selfcheck`) |

## 1. Baseline — can the real build run in a sandbox at all? (27 Oct, [baseline-build.log](baseline-build.log))

| Full `./mvnw verify` | Cold | Warm |
|---|---|---|
| Sandbox (Linux microVM) | 101 s | **54 s** |
| Host (Windows) | 71 s (Maven cache already warm) | 69 s |

Full suite passes in the sandbox, 32 Cucumber scenarios included. **Warm, the sandbox builds 22 %
faster than the Windows host it runs on.** Not yet explained — likely Linux file I/O versus Windows
with Defender, unmeasured. **Cold costs ~47 s per fresh sandbox**: each new worker starts with an
empty Maven cache.

## 2. First parallel run — what went wrong, and what it taught (run p123203)

All three agents exited 0 (576 s, 767 s, 1152 s). **One of three features was collected.**

- **A sandbox stops itself once its agent finishes, and a stopped sandbox no longer serves its git
  remote.** The runner collected only after the slowest agent, by which time two had stopped.
- **`sbx rm` then deleted those two commits** (it removes the remote and refs). The runner removed
  sandboxes without checking what it had secured — a runner bug, now fixed: collect on exit, retry,
  never remove an uncollected sandbox.
- **Two agents reported "Maven wrapper download blocked by the network".** That was not sbx policy —
  see §3.

## 3. The network finding — post-quantum TLS behind a corporate firewall

Laptop on a Fortinet-filtered Wi-Fi. Inside a sandbox (Ubuntu 26.04, OpenSSL 3.5.5), request
**allowed** by sbx policy (`forward-bypass`), curl to repo.maven.apache.org:

| ClientHello offers | Result |
|---|---|
| default (X25519MLKEM768 hybrid) | 0/3 — 15 s timeout |
| X25519MLKEM768 only | 0/3 |
| X25519 only | **3/3**, ~0.09 s |
| default + `OPENSSL_CONF` → Groups X25519:secp256r1:secp384r1 | **3/3** |

git to github.com worked either way; Java's HttpClient worked either way. The same network breaks
the sbx CLI itself (Go, same post-quantum default) — filed as
[docker/sbx-releases#773](https://github.com/docker/sbx-releases/issues/773) with a follow-up
comment on the in-sandbox effect and the docs gap. On a different Wi-Fi everything works 3/3 with
defaults. **The lesson for an orchestrator: an agent's "the network is blocked" is a symptom, not
a diagnosis — the policy log said allowed.**

## 4. Parallel run on the real repo, with fixes (run p130444, [run-parallel-3.log](run-parallel-3.log))

Fixes in place: collect on exit, classic-TLS groups in the VM, daemon restarted with
`GODEBUG=tlsmlkem=0` (the daemon takes it from the shell that restarts it).

| Feature | Create | Agent | Turns | Cost* | Tests in VM | Merged | Draft PR |
|---|---|---|---|---|---|---|---|
| lifo | 8 s | 136 s | 7 | $0.20 | passed | ✅ | [#115](https://github.com/ffroliva/tiny-ledger/pull/115) |
| domain-errors | 9 s | 139 s | 8 | $0.19 | passed | ✅ | [#116](https://github.com/ffroliva/tiny-ledger/pull/116) |
| merkle-proof-by-hash | 9 s | 88 s | 4 | $0.14 | passed | ✅ | [#117](https://github.com/ffroliva/tiny-ledger/pull/117) |

**3 features, 177 s end to end, $0.53, 3 clean merges.** Full `./mvnw verify` on the merged
branch on the host: **PASS in 58 s**, 32/32 Cucumber scenarios ([verify-parallel-130444.log](verify-parallel-130444.log)).
The PRs run the repo's real CI.

\* `total_cost_usd` reported by `claude -p --output-format json` — API-equivalent; the run used a
Claude subscription. One run so far; a repeat is owed before the number is quoted as typical.

## 5. Serial baseline — one sandbox, same features in turn (run s130909, [run-serial-1.log](run-serial-1.log))

| | Parallel, 3 sandboxes (p130444) | Serial, 1 sandbox (s130909) |
|---|---|---|
| Agent wall time | **140 s** | 206 s |
| Per feature | 136 / 139 / 88 s | 126 / **47 / 30 s** |
| Cost* | $0.53 | $0.47 |
| Merges, full verify | 3/3, PASS | 3/3 commits, PASS (57 s) |

**Parallel is only 1.47× faster, and the serial column says why:** the first serial task pays the
cold Maven cache, the next two reuse it. In parallel every sandbox pays it. A dependency cache
shared across sandboxes is the fix — and sharing a writable cache between sandboxes is the
single-writer problem measured in [FINDINGS.md](../FINDINGS.md) (93–97 % write loss, locks do
not cross VMs). The proposal: one writer populates, workers mount it read-only — filed as
[docker/sbx-releases#775](https://github.com/docker/sbx-releases/issues/775).

## 7. Parallel run in Docker Cloud Sandboxes (run p132934, [run-cloud-parallel-1.log](run-cloud-parallel-1.log))

Cloud has no host workspace: each worker clones from GitHub, the agent works, the worker pushes a
scratch branch with the proxy-held token, the host fetches it and deletes the scratch branch. Claude
runs on a **Claude subscription** via `sbx --cloud secret set anthropic --oauth` — on 0.50 this works
with no workaround (default `claude -p` → CLOUD-OK in 3 s; all three auth shapes from
[docker/sbx-releases#638](https://github.com/docker/sbx-releases/issues/638) return 200,
[cloud-oauth.log](cloud-oauth.log); reported on #638 the same day).

| | Local, 4 CPU / 4 GB (p130444) | Cloud Medium, 4 vCPU / 8 GB (p132934) |
|---|---|---|
| Create (+ clone, cloud) | 8–9 s | 14–18 s |
| Agent wall time | 140 s | **97 s** |
| Per feature | 136 / 139 / 88 s | 88 / 97 / 87 s |
| Turns | 7 / 8 / 4 | 6 / 9 / 4 |
| Cost* (tokens) | $0.53 | $0.40 |
| Compute | laptop | ~$0.035 (3 × Medium $0.28/h × ~2.5 min, estimated from the price list) |
| Merges, full verify on host | 3/3, PASS 58 s | 3/3, PASS 49 s |
| End to end | 177 s | **166 s** |

Cloud agents were 31 % faster here, on a 4 vCPU / 8 GB shape against a laptop shared with the
orchestrator and a Windows host. One run each — a repeat is owed before either is quoted as typical.

## 6. Cloud (27 Oct, Fortinet network, `GODEBUG=tlsmlkem=0` on the CLI)

| Check | Result |
|---|---|
| `sbx --cloud create` (2 vCPU / 4 GB) | **9 s** |
| JDK in the template | OpenJDK 25.0.4.1 |
| Network allow-list (account default deny-all; allowed github, anthropic, maven) | github.com 200, example.com **blocked** |
| Claude Code inside | "Not logged in" — cloud Claude needs an **Anthropic API key**; subscription OAuth is supported only for Codex ([docs](https://docs.docker.com/ai/sandboxes/cloud/credentials/)) |
| Cost of the smoke test | ~1 cent, removed after |
| Git round trip, no agent (`shell`, 1 vCPU / 2 GB, allow github.com) | create **8 s**; clone + commit + **push 6 s** through the proxy with a fine-grained token stored as `sbx --cloud secret set github` (never in the VM); branch verified on GitHub, then deleted |

## 8. Sharing the Maven cache between sandboxes (27 Oct, FINDINGS §6)

The obvious fix for §5's cold-cache cost, tried on the real build with the spec's own pattern
(`host-mount@1`, [kits/maven-cache](../kits/maven-cache/maven-cache.yaml)):

| 3 sandboxes building at once | Passed | Wall |
|---|---|---|
| Private caches, cold | 6/6 | 147–156 s |
| Shared cache, cold, 3 writers | **2/9** — `IOException: File exists` in Maven Resolver | — |
| Shared cache filled by one writer first | **6/6** | **101–107 s** |

**A shared writable cache works only with one writer.** Fill it once, then share it — which is what
[docker/sbx-releases#775](https://github.com/docker/sbx-releases/issues/775) asks the platform to do.

## 9. Three agents in one sandbox vs one sandbox each (27 Oct)

Asked on [docker/sbx-releases#775](https://github.com/docker/sbx-releases/issues/775): why not run the
agents in parallel inside one sandbox? Same 3 features, same base commit, same total resources:
`--mode onebox` gives one 12 CPU / 12 GB sandbox, 3 `git worktree`s, 3 `claude -p` at once.
Two rounds each, back to back.

| | 3 sandboxes × 4 CPU / 4 GB | 1 sandbox, 12 CPU / 12 GB, 3 worktrees |
|---|---|---|
| Runs | p130444, p155613 | o155212, o160014 |
| Agent wall time | 140 s, 144 s | **137 s, 130 s** |
| Cost* | $0.53, $0.54 | **$0.41, $0.38** |
| Merged + full verify | 3/3 PASS, 3/3 PASS | 3/3 PASS, 3/3 PASS |

Logs: [run-parallel-3.log](run-parallel-3.log), [run-parallel-4.log](run-parallel-4.log),
[run-onebox-1.log](run-onebox-1.log), [run-onebox-2.log](run-onebox-2.log).

- **One sandbox is a little faster (2–10 %) and about 25 % cheaper in tokens, in both rounds.** The
  shared `~/.m2` is safe there: one kernel, so Maven's locks work. The cost gap is not explained; turn
  counts overlap (17–22 per run in both modes).
- **Agent time is mostly model time.** Even 3 cold caches cost little against 2+ minutes of turns,
  so the cold-cache tax matters more for CI-style builds (§8) than for agent work.
- **What separate sandboxes buy is not speed:** a blast radius per agent (an untrusted PR or an injected
  agent can't touch the others' worktrees), a network policy and resource limits per agent,
  independent lifecycle, and fan-out beyond one VM (cloud xl tops out at 16 CPU).
