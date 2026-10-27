# Single-writer shared memory — implementation proposal

## The problem, precisely

Several sandboxes — separate microVMs — share one memory store. Today the spec offers two ways:
`host-mount@1` (a host directory shared by every sandbox composing the same Kit, over virtiofs) and
a memory service reached over MCP (PR #126, Mem0; PR #118, `mcp-server@1`). Neither says who may
write, or when.

What goes wrong without a rule:

- **SQLite or any single-file database over a shared mount.** Two VMs open the same file. SQLite's
  safety depends on POSIX/Windows file locks working across every writer; whether virtiofs
  propagates those locks between VMs and the Windows host is unknown («?» — must be tested, not
  assumed). If it doesn't, both write and the file or its index corrupts. **This has happened before:**
  concurrent writers corrupted my own agent-memory store's SQLite/FTS5 index on 14 Sep 2026, badly enough that a
  plain upsert segfaulted and the index had to be rebuilt.
- **Markdown memory files** (`MEMORY.md`, Claude auto-memory). Two agents read, edit, write back —
  the last writer silently erases the other's lines. No crash, just lost memory.
- **A crashed writer.** A sandbox dies holding a lock file. Everyone waits forever, or someone
  deletes the lock by hand while the "dead" writer is only paused — and now there are two.

Requirements: **one writer at a time; a crashed writer can't block forever; a writer that lost its
right can't write later (zombie); every write attributable to a sandbox; readers never blocked.**

## Five options

### A. Lock file inside the shared mount
Each sandbox takes `flock`/`O_EXCL` on a file in the mount before writing.
- **For:** zero new infrastructure; works today.
- **Against:** correctness rests on lock semantics crossing the VM boundary over virtiofs on three
  host OSes — unverified. Stale locks after a crash. No protection from a paused-then-resumed
  writer.
- **Verdict:** don't ship without a test that proves cross-VM locking; even then, no zombie
  protection.

### B. Host-side lease with fencing tokens (the fix I use for my own agent-memory store, generalised)
`sandboxd` — one process on the host — grants a **writer lease** per store. The lease is backed by
an OS lock the daemon holds (`flock` on Linux/macOS, `LockFileEx` on Windows), so **the kernel
releases it if the daemon dies**: no stale locks at that level. Each grant carries a
**monotonically increasing fencing token**; the store rejects any write carrying a token lower than
the highest it has seen.
- **For:** strong, explicit, works for any store including SQLite; crash-safe; zombie-safe.
- **Against:** new runtime API; TTL tuning (too short → flapping, too long → slow recovery); writers
  must pass the token and the store must check it.

### C. Single-writer service (actor) — writes only through MCP
The store is owned by one process — host-side, or its own sandbox via `mcp-server@1`. Agents never
open the files; they call `memory_write` / `memory_search` tools. The service serialises writes on
a queue.
- **For:** no client-side locking at all; the gateway can **authenticate, attribute, audit and
  apply policy (Cedar) to every write**; same path local and cloud. It is where PR #126 already
  points.
- **Against:** the service is a single point of failure; adds latency; agents that expect plain
  files (Claude auto-memory) need an adapter.

### D. Per-sandbox append-only journal + one merger
Each sandbox writes only its **own** journal file (no shared writes). One merger — `sandboxd` on
stop, or on an explicit `sbx memory accept` — folds journals into the shared memory.
- **For:** no locks; nothing to corrupt; **natural review gate** (show the diff, accept or reject);
  full provenance; fits clone mode's "hand back a remote, don't write the host" model.
- **Against:** eventual, not immediate, sharing; merge rules needed for conflicting facts; journals
  grow until compacted.

### E. Optimistic concurrency (compare-and-swap)
Every memory document has a version; a write says "replace version 7"; a stale write gets a
conflict and retries. Git is a ready-made version: each sandbox commits to its own branch, merge by
PR.
- **For:** no locks held; conflicts are explicit, never silent.
- **Against:** hot files (one `MEMORY.md`) conflict constantly; agents handle retry/merge poorly.

## Trade-off table

| | A lock file | B lease + fencing | C service | D journal + merge | E CAS / git |
|---|---|---|---|---|---|
| Prevents corruption | if virtiofs locks work | **yes** | **yes** | **yes** | yes |
| Crash can't block forever | no | **yes** (TTL + kernel lock) | yes | yes | yes |
| Zombie writer rejected | no | **yes** (fencing) | yes | n/a | yes |
| Write attribution / audit | no | partial | **yes** | **yes** | yes |
| Review before it's shared | no | no | possible | **yes** | **yes** |
| Immediate visibility | yes | yes | yes | no | after merge |
| Works for plain files | yes | yes | adapter | yes | yes |
| Works in cloud | no | needs cloud broker | **yes** | yes | yes |
| New runtime work | none | medium | medium (#118 helps) | medium | low |

## Proposal: C for live memory, D for curated memory, B underneath

1. **Live, searchable memory → C.** One memory service per scope, reached through the MCP gateway.
   It is the only writer of its store. Every write is a tool call: attributed to the sandbox,
   logged in the audit trail that already records network decisions, and subject to policy.
2. **Curated, file-based memory (`MEMORY.md`, team rules) → D.** Sandboxes append to their own
   journal; `sbx memory diff` / `sbx memory accept` merges into the shared files — reviewed like a
   pull request.
3. **Anything that must open a store directly (the service itself, the merger, SQLite) → B.** The
   lease is what guarantees there is only ever one service instance or one merger, even across a
   daemon restart.

### The lease protocol (B)

```
acquire(store, holder=sandbox_id, ttl=30s)
    → sandboxd takes/holds an OS lock for `store`
    → returns {lease_id, token: N+1, expires_at}
renew(lease_id)            every ttl/3; a missed renew lets the lease lapse
write(store, data, token)  store checks token >= highest_seen, records it, applies
                           token < highest_seen → reject (STALE_LEASE)
release(lease_id)          explicit, on clean exit
crash / pause              renewals stop → lease expires after ttl
                           → next acquire gets token N+2
                           → the resumed zombie's writes carry N+1 → rejected
daemon dies                kernel drops the OS lock; on restart, tokens resume
                           from the highest persisted value (never reused)
```

The fencing token is what makes it safe against pauses and clock skew: expiry alone cannot stop a
writer that woke up late, the token check at the store can.

### Where it lands in the spec

- `host-mount@1` gains `writers: single | shared` (default `shared`, today's behaviour). With
  `single`, a conforming runtime MUST grant at most one write lease per mount.
- Or a new `memory@1` capability: `scope: kit | user | team`, `mode: service | journal`.
- Conformance tests, in the spec's own style:
  - `memory@1/second-writer-rejected` — a second sandbox's write lease is refused while one is held
  - `memory@1/lease-expires-on-crash` — killing the holder frees the lease within ttl
  - `memory@1/stale-token-rejected` — a write with an old token is refused after re-grant
  - `memory@1/readers-not-blocked` — reads succeed while a writer holds the lease
  - `memory@1/write-attributed` — every accepted write records the sandbox id

## Evidence

Reproduced on sbx 0.50.0 — see [../FINDINGS.md](../FINDINGS.md) §1: two writers lost 97% of markdown appends and left a SQLite store unopenable; one writer lost nothing.

## How to prove it before proposing it

1. On sbx 0.50.0, two sandboxes composing the same Kit, `host-mount@1` at one path, both writing a
   SQLite database in a loop. Run `PRAGMA integrity_check`. Expected: corruption or `database is
   locked` storms — the evidence that a contract is needed.
2. Same test, both writing one markdown file → count lost lines.
3. Prototype B as a tiny host-side broker (a Python script holding `LockFileEx` + token counter) and
   rerun 1 and 2 through it → zero corruption, zero lost lines.

That is a reproducible case, a design, and a test suite — the format `GOVERNANCE.md` says a
proposal must take.
