# Proposal: monitoring and fleet commands for Docker Sandboxes (DRAFT)

Revised after the council of 2026-10-30 ([record](2026-10-30-council-sbx-command-proposal.md)).

Status: **draft, not sent.** It is sent upstream only after the author has read it and the measured items have been
measured a second time. Each ask links to the finding and evidence behind it. **Measured** means a script and a log
exist, and the number of runs is stated. **Proposed** is a design nobody has built or measured yet.

sbx v0.50.0 and the Sandboxes API v1 (experimental), 30 Oct 2026. The use case behind it: a team runs a large test
suite (about 22,000 tests, Python with pytest-xdist, PostgreSQL in testcontainers, Playwright) across N cloud
sandboxes, once per change it ships (council A7). Section 2 lists the other workloads with the same shape (council B1).

## 1. What exists today (measured, one capture each)

Evidence:
- [bench/cli/sbx-cli-surface-2026-10-30.log](../bench/cli/sbx-cli-surface-2026-10-30.log): the verbs `sbx --help`
  lists, and the help of `ls`, `tui`, `env`, `diagnose`, `ttl`.
- [bench/cli/sbx-hidden-verbs-2026-10-30.log](../bench/cli/sbx-hidden-verbs-2026-10-30.log): verbs that exist but
  `sbx --help` does not list. A nonsense verb is the control: a verb that does not exist prints the root description
  (council A1, A2).
- [bench/cli/sbx-api-surface-2026-10-30.log](../bench/cli/sbx-api-surface-2026-10-30.log): the paths of the published
  OpenAPI document and a count of the terms below (council C1, C2).

Column *API v1* says whether the HTTP API has it (council C1, D1). "Help" means the help text was read; the command
was not run.

| Need | CLI today | API v1 today | Gap |
|---|---|---|---|
| Live resource use | `sbx tui` (help accepts `--cloud`; not run, council A5) | none (`stats` appears 0 times) | per-sandbox figures a script can read |
| State of a sandbox | `ls --json` (fields per help: name, agent, status, ports, workspace; council A6); hidden `inspect`, help accepts `--cloud` (council A2) | `GET /v1/sandboxes/{sandbox}`, `labels` | runtime, cost, exit reason |
| Events | hidden `sbx events`: local daemon stream, `--json`; `--cloud` answers "not yet supported" (council A1) | none: every 202 says "read it or follow its events" (8 times), and no events path exists (council C2) | events in `--cloud` and in the API |
| When a process ends | `sbx exec`, no detach ("Detached mode (not supported)") | `POST /v1/processes`, `GET /v1/processes/{process}`, `.../output` with `resumeFrom`, `exitCode` | CLI parity: `exec -d`, `wait --exec`, `logs --exec` (council D1, B3) |
| What ran yesterday | nothing; a deleted sandbox leaves no record | none | history (8.16) |
| Host contention | guest-visible steal stays at 0.01-0.05% while summed test time rose 15-50% (8.18 draft; council A3, A4) | none | a contention signal for the caller's own sandbox |
| Quota | an error at create time, enforced inconsistently (8.5) | `QuotaFailure`, `RetryInfo` error details | `sbx quota`, and the CLI honouring `retryDelay` (8.6; council C3) |
| Retries and labels | no `--label`, no idempotency key on `create` (council A14) | `Idempotency-Key` header, `labels` | CLI flags for what the API has (8.2; council C1) |
| N sandboxes as one job | a hand-written script: create, upload, poll, collect, remove | none | a fleet (section 4) |
| One sandbox in a file | `sbx env` + `sbxenv.yaml` (`schemaVersion`, `sandboxOptions`, `kits`), experimental, works with `--cloud` | n/a | one sandbox per file |

## 2. Who needs this (proposed)

The same shape, N boxes that each run one indexed slice and then end, recurs beyond test suites (council B1):
sharded CI test and build jobs; agent swarms (one agent per issue or per repository); evaluation runs (one model or
prompt variant per box); data fan-out (one partition per box); preview environments per pull request; load tests
(N clients); scheduled jobs; and a team lead who watches spend across all of these.

## 3. Monitoring (proposed)

One surface, the same locally and in the cloud. Every verb follows the conventions sbx already has: `--format
table|json|yaml`, `--json`, `-q` (council C5). `-f` keeps its sbx meaning, `--force`, so streaming is the default and
`--no-stream` turns it off, as in `docker stats` (council C4). Streams print JSON Lines (council B5).

- **`sbx stats [NAME...] [--no-stream] [--format ...] [--json]`**: CPU (usage and steal in ns, percent over
  `intervalMs`, limit), memory, disk and network bytes, and CPU pressure (PSI), for the caller's own sandboxes
  (council C12, A10).
- **`sbx events [--since T] [--until T] [--filter k=v]... [--format ...] [--json]`**: extend the hidden local verb to
  `--cloud` and add the cloud event types: created, started, stopped, failed, deleted, ttl warning, ttl reaped,
  quota refused/queued/admitted, exec started and exited (with exit code) (council A1, C2). Events and history never
  carry argv, environment, secret values or host paths (council A8).
- **`sbx wait SANDBOX... [--condition stopped|deleted|failed] [--exec PROCESS] [--timeout D] [--exit-code]
  [--fail-fast]`**: prints one line per target, `NAME CODE-or-STATUS`. It exits 0, or with the first non-zero
  workload code under `--exit-code`; 124 when the timeout lapses; 125 when a target is unknown, as `sbx exec` does.
  `--exec` needs `sbx exec -d` to print the process name first (council C6, B2, D1).
- **`sbx logs --exec PROCESS [--follow] [--since-sequence N]`**: the API's output cursor on the CLI (council B3, D1).
- **`sbx history [--since T] [--format table|json|yaml|csv]`**: one record per sandbox that existed: template or kit
  and its digest, size, created/started/stopped times, runtime, exit reason, CPU and memory totals, cost
  (`amount, currency, basis: estimate|billed`), creator, labels (council C11, C14). Read with the same scope as
  listing sandboxes; retention stated by Docker, recommended 90 days, with a purge (council A9).
- **`sbx quota [--format ...] [--json]`**: the vCPU limit, current use, and what is queued (council C10).

## 4. Fleets (proposed)

**First ask, bounded (council D2):** N named instances from one spec, each told its index; a wait over all of them;
guaranteed teardown; a status per instance. Scheduling across fleets, artifact collection and history records are a
second step. Whether this is a CLI verb, an API resource or SDK recipes is Docker's choice; the shape below shows
what a user would write (council D3).

A separate verb, because `sbx env run` creates and attaches one sandbox (council C, fleet shape):

```yaml
schemaVersion: "1"              # proposed extension of sbxenv.yaml (council C7)
fleet:
  onShort: wait                 # wait | refuse | startWhatFits; checked against the account quota, no budget field
  maxQueue: 10m                 # how long `wait` may queue (council C10)
  timeout: 20m                  # per box; each box gets ttl = timeout + grace with delete on timeout (council A12, C9)
  pools:                        # a list: list order = start order = SBX_FLEET_INDEX order (council C8)
    - name: db
      count: 3
      sandboxOptions: { cpus: 8, memory: 16g }
      kits: [python-e2e]
      run: ["./run-shard.sh", "db"]          # argv; its exit code is the box result
    - name: ui
      count: 4
      minCount: 2                            # startWhatFits only: sizes are fixed before any box starts
      sandboxOptions: { cpus: 4, memory: 8g }
      kits: [python-e2e]
      run: ["./run-shard.sh", "playwright"]
```

```
sbx fleet run FILE [--cloud] [--detach] [--label k=v] [--idempotency-key K] [--max-parallel N] [--fail-fast]
                   [--keep-on-failure]
sbx fleet ls | inspect | wait | cancel | rm   [--format ...] [--json]
```

Each box gets, counting from 0: `SBX_FLEET_ID`, `SBX_FLEET_INDEX`, `SBX_FLEET_SIZE`, `SBX_POOL`, `SBX_POOL_INDEX`,
`SBX_POOL_SIZE`, `SBX_ATTEMPT`, `SBX_VCPU`, `SBX_MEMORY_MIB` (council C8). Instance states: created, starting,
running, succeeded, failed, cancelled, expired (council D additions).

Rules the fleet keeps:
- **The fleet is a server resource**, so teardown does not depend on the client: a hard TTL per box, a client
  heartbeat lease (for example 60 s with 5 min grace), and deleting the fleet deletes its boxes and its fleet-scoped
  secrets (council A12, C9). Today cloud `rm` leaves scoped secrets behind (8.1) and exits 0 while deletion is still
  completing.
- **Secrets** given to a fleet are scoped to it, never fall back to global, and live no longer than its timeout
  (council A11).
- **Quota first**: nothing is created until the whole fleet fits, or `onShort` says otherwise. `startWhatFits`
  starts each pool whole or not at all, in list order, down to `minCount`, and fixes every `*_SIZE` before the first
  box starts; otherwise it exits non-zero with `incomplete` (council A13, C10; the inconsistency in 8.5).
- **Retries** only for platform failures, never for a non-zero workload exit (council C open question 4).

Exit codes for `fleet run` and `fleet wait` (council C, B5):

| Code | Meaning |
|---|---|
| 0 | every box exited 0 |
| 1 | a workload exited non-zero |
| 2 | the spec or the usage is invalid |
| 3 | quota refused, or `maxQueue` lapsed |
| 124 | timeout |
| 125 | platform failure: a box was not created or was lost |

It stays the workload's job to split the work, merge results and decide pass or fail.

## 5. API shape (proposed)

New endpoints follow the v1 conventions already published: `pageSize`/`pageToken`, `filter`, `orderBy`,
`since`/`until`, `Error{code,message,details}` with `QuotaFailure` and `RetryInfo`, `Idempotency-Key`, camelCase
JSON, additive fields under v1 (council C3, C15). Sketch:

```
GET  /v1/sandboxes/{sandbox}/stats        one sample; Accept: text/event-stream to stream
GET  /v1/events?since=&until=&filter=     a page; text/event-stream with Last-Event-ID to follow (CloudEvents 1.0)
GET  /v1/quotas                           limits, usage, queued
POST /v1/fleets (Idempotency-Key) -> 202 ; GET /v1/fleets/{fleet} ; POST /v1/fleets/{fleet}:cancel ; DELETE (If-Match)
```

A contention figure is exposed only for the caller's own sandbox (its steal and PSI). A host identifier or a
host-wide load figure would be a side channel across tenants, so it is not asked for (council A10).

## 6. Open questions for Docker

1. The billing increment and minimum per box (council C11).
2. Event and history retention (council C open question 3).
3. Fleet as CLI verb, API resource or SDK recipes (council D3).
4. Build caching across boxes stays a kit concern, outside this proposal (council D4).
