# Proposal: a memory broker for shared agent memory in Docker Sandboxes (DRAFT)

Status: **draft, not sent.** It extends option C of [single-writer-design.md](single-writer-design.md) with a working
reference implementation and the pieces sbx already has. **Measured** means a script and a log exist, with the run
count. **Observed** means seen once on the author's Windows host, outside sbx, with no script yet. **Proposed** is a
design nobody has built or measured on sbx.

MemPalace 3.11.0 (released 2026-10-14) and sbx 0.50.0, 1 Nov 2026.

## 1. The claim

Shared agent memory needs a **broker**: one process that owns the store and is its only writer. Every sandbox reaches it
over MCP and never opens the store's files. sbx already has the matching pieces (an MCP server capability, a host-side
egress proxy that injects credentials, a policy log), so the broker does not need new storage machinery in the runtime,
only a contract.

## 2. Broker, not proxy

The two patterns are easy to confuse because both sit between the agent and something else.

| | sbx secrets proxy (exists) | Memory broker (proposed) |
|---|---|---|
| Owns the state | No. The authority is upstream (`api.anthropic.com`). | Yes. It holds the store and its writer lease. |
| What it does with a request | Forwards it, swapping a sentinel value for the real key on named domains. | Terminates the MCP call, serialises the write, answers itself. |
| What the client knows | Believes it talks to the real API, with a fake key. | Knows it talks to a memory service. |
| If it dies | Calls fail; no data at risk. | Writes stop; the OS releases its lock (no stale lock). |
| Correctness comes from | Never letting the secret into the VM. | Being the only writer. |

A broker can still sit behind thin local proxies: MemPalace's per-agent stdio server forwards every call to a live hub,
so agents need no configuration change. The safety comes from the broker, not from the proxies.

## 3. A working reference: the MemPalace hub

MemPalace is an open-source agent memory store (SQLite plus a vector index) used by several agent harnesses at once. Its
upstream docs describe exactly option C and part of option B (`docs/write-routing-policy.md`,
`website/guide/shared-brain.md`, repository `MemPalace/mempalace`):

- **One writer per palace.** "File-backed backends ... support exactly one writable process per palace. Serializing
  individual calls is not enough because each long-lived process can retain SQLite/WAL, FTS, or vector index state
  between calls."
- **Two brokers, one at a time.** A daemon (a durable job queue for mines and hook writes) or a hub (`mempalace serve`,
  an HTTP MCP server). "One `serve` process holds the palace's writer lease and safely serializes concurrent writes from
  every client — never point two server processes at the same palace."
- **The lease is an OS lock** held for the broker's lifetime, so the kernel drops it if the broker dies. This is option
  B's crash safety. "Do not delete or unlink a live palace lock to recover ownership. Stop the owning process cleanly."
- **Readers are never blocked.** Read-only clients open the store with `query_only` and coexist with the writer.
- **Writes never fall back to a direct open.** With the `require` policy, a hook or CLI write goes to the broker or is
  skipped with a visible notice; a failed submission is never replayed locally, because the broker may already have
  accepted it.

What it does **not** have: fencing tokens (a paused-then-resumed writer is not rejected), authenticated per-client
identity (agents self-declare a `host:harness:project` name and share one bearer token), and per-write policy.

## 4. Why it matters: what happened without a broker (observed)

On the author's Windows host, before the daemon was the sole writer, agents in different harnesses (Claude Code, Codex,
Antigravity) each ran their own MemPalace server. Concurrent writers corrupted the SQLite/FTS5 index on 14 Sep 2026
badly enough that a plain upsert segfaulted and the index had to be rebuilt (the same incident cited in
[single-writer-design.md](single-writer-design.md)).

An audit on 1 Nov 2026 found the residual risk was configuration, not code: one harness was the designated writer and
three ran their MCP server with `--read-only`, but two Antigravity profiles had no `--read-only`. They could take the writer lease whenever the broker was down, and
then block it. One profile also ran a full mine after every tool call, held off only by a disabled auto-save switch.
**Lesson for sbx:** if any client may open the store directly, the one-writer rule depends on every client being
configured correctly. The rule has to be enforced where the store lives, not trusted to each sandbox.

## 5. The proposal for sbx (proposed)

1. **The broker runs host-side**, or in its own sandbox via `mcp-server@1` (PR #118). It is the only process that opens
   the store, and it holds the store's lease (option B) for its lifetime.
2. **Sandboxes reach it only over MCP**, through the gateway the network policy already governs. The store's directory
   is never mounted into a sandbox, so the untested question of whether virtiofs carries locks between VMs never arises.
3. **The broker's credential never enters the VM.** Each sandbox gets a sentinel token and the egress proxy swaps in the
   real one for the broker's host, the same mechanism sbx uses for model API keys today.
4. **The gateway stamps identity.** The sandbox id is added by the gateway, not declared by the agent, so every write is
   attributable and policy (Cedar) can be applied per write. This closes the gap MemPalace leaves open.
5. **Tie the token to the sandbox's lifetime.** [FINDINGS.md](../FINDINGS.md) records cloud secrets that survive `rm`
   and the TTL reaper; a broker token must not.
6. **File-based memory stays on option D.** A broker serialises tool calls; it does not fix two agents rewriting one
   `MEMORY.md`. Per-sandbox journals and a reviewed merge remain the answer for curated files.

### Spec shape

A `memory@1` capability, `mode: service`, with:

- `broker`: where it runs (`host` or `sandbox`), and its MCP endpoint.
- `credential`: injected by the proxy; the sandbox sees a sentinel.
- Conformance tests, adding to those in [single-writer-design.md](single-writer-design.md):
  - `memory@1/store-not-mounted`: no sandbox can open the store's files directly
  - `memory@1/credential-not-in-vm`: the real broker token is absent from the sandbox environment and filesystem
  - `memory@1/identity-from-gateway`: a write that claims another sandbox's id is recorded with the caller's real id
  - `memory@1/broker-down-no-direct-write`: with the broker stopped, a write fails visibly and nothing opens the store
  - `memory@1/token-dies-with-sandbox`: after `sbx rm`, the sandbox's broker token is refused

## 6. How to prove it before sending it

1. **Reachability (first, unmeasured).** From a sandbox under the default-deny policy, call a host-side MCP endpoint.
   Record whether the policy needs an allow rule and what `sbx policy log` shows for the call.
2. **Rerun the race tests through a broker.** `tests/race-test.sh` showed two writers on a shared `host-mount@1` lost
   93–97% of markdown appends (3 repeats, `tests/md-race-repeat.sh`) and left SQLite unopenable
   ([FINDINGS.md](../FINDINGS.md) §1). Rerun the SQLite half with
   both sandboxes writing through one MemPalace hub on the host. Expected: zero corruption, `PRAGMA integrity_check`
   clean, every write present. Repeat at least three times and state the count.
3. **Kill the broker mid-run.** Expected: writes fail visibly, no sandbox falls back to the file, and a restarted broker
   takes the lease without manual cleanup.
4. **Sentinel token.** Inject the hub's bearer token through the proxy and confirm the real value never appears inside
   the VM (`env`, `/proc/1/environ`, the filesystem).
5. **Overhead.** Measure p50 and p99 added latency per write through the broker against a local write. Nobody has
   published this for the sbx proxy either.

Until steps 1 and 2 have logs, this document is a design.
