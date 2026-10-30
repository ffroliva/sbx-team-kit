# Proposal: monitoring and fleet commands for Docker Sandboxes (DRAFT)

Status: **draft, not sent.** It goes to an LLM council for completeness first, and it is sent upstream only after the
author has read it. Each ask links to the finding and evidence behind it. **Measured** means a script and a log exist,
and the number of runs is stated. **Proposed** is a design that nobody has built or measured yet.

sbx v0.50.0, 30 Oct 2026. The use case behind this: a team runs a large test suite (about 22,500 tests, Python with
pytest-xdist, PostgreSQL in testcontainers, Playwright) across N cloud sandboxes, once per change it ships.

## 1. What exists today (measured, one capture)

[bench/cli/sbx-cli-surface-2026-10-30.log](../bench/cli/sbx-cli-surface-2026-10-30.log): `sbx --help`, `sbx --cloud --help`,
`ls`, `tui`, `env`, `diagnose`, `ttl`.

| Need | Today | Gap |
|---|---|---|
| Live resource use | `sbx tui`, local sandboxes only | nothing in the cloud (FINDINGS 8.15, 8.17) |
| State of a sandbox | `sbx ls --json`: name, agent, status, ports, workspace | no shape, runtime, cost, exit reason |
| When a run ends | poll `sbx exec` | no events and no wait (8.14, 8.17) |
| What ran yesterday | nothing; a deleted sandbox leaves no record | no history (8.16) |
| Host contention | not visible inside the guest | 8.18 (draft) |
| Quota | an error at create time | no `sbx quota`, enforced inconsistently (8.5) |
| N sandboxes as one job | a hand-written script that creates, uploads, polls, collects and removes | no fleet primitive (8.2, 8.5, 8.6, 8.7) |
| Declare one sandbox in a file | `sbx env` + `sbxenv.yaml`, experimental, works with `--cloud` | one sandbox per file |

## 2. Monitoring (proposed)

One surface, the same locally and in the cloud, with JSON on every command so it can be scripted.

- **`sbx stats [NAME...] [--cloud] [--json] [-f]`**: CPU %, memory, disk, network I/O, and steal / CPU pressure from
  the host side, per sandbox. Modelled on `docker stats`. Host-side steal is the figure a guest cannot see (8.18).
- **`sbx events [--since T] [--filter ...] [--json] [-f]`**: a lifecycle stream: created, started, quota refused,
  exec started and exited (with exit code), TTL warning, reaped, removed. Modelled on `docker events`. It replaces
  poll loops.
- **`sbx wait NAME... [--exec ID]`**: blocks until a sandbox, or a detached exec, ends, and returns its exit code.
- **`sbx history [--since T] [--json|--csv]`**: one record per sandbox that existed: template or kit and its digest,
  shape, created/started/stopped times, runtime, exit reason, CPU and memory totals, accrued cost, creator, labels.
- **`sbx quota [--json]`**: the vCPU limit, current use, and what is queued.
- **Host facts** in `sbx ls --json` / `inspect`: physical CPU model and clock, and a host-load or contention value.

## 3. Fleets (proposed)

Extend what already exists, `sbxenv.yaml`, rather than adding a new file format. The platform runs N indexed
workers; the workload decides what each index does. The analogies are Kubernetes Indexed Job and the GitHub Actions
matrix.

```yaml
# sbxenv.yaml
fleet:
  budget: { vcpu: 40, on_short: wait }      # wait | refuse | start-what-fits
  timeout: 20m
  artifacts: out/
  pools:
    db: { count: 3, shape: 8cpu-16gb, kit: python-e2e, run: ./run-shard.sh db }
    ui: { count: 4, shape: 4cpu-8gb,  kit: python-e2e, run: ./run-shard.sh playwright }
```

`sbx env run --cloud` then gives each box `SBX_POOL`, `SBX_POOL_INDEX`, `SBX_POOL_SIZE`, `SBX_FLEET_INDEX` and its
`SBX_VCPU`. It:
- checks the quota before creating anything;
- uploads once and fans out (8.7);
- guarantees teardown even if the client dies (8.2);
- releases each pool's vCPUs when that pool finishes;
- collects artifacts per box;
- returns one exit code plus a status per pool and per box;
- writes one history record for the fleet.

It stays the workload's job to split the work (by recorded test durations), merge results, and decide pass or fail.

## 4. Open questions for the council

Use cases and scenarios we have not covered, how people would script these commands, the API shape (REST endpoints,
the event schema, pagination, auth scopes), local versus cloud parity, cost and billing, security (who can read
another sandbox's stats or history), failure modes, and what is already in Docker's roadmap or docs.
