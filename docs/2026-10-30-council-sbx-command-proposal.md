# Council of 2026-10-30: monitoring and fleet commands for Docker Sandboxes

Scenario: research (an external feature proposal). Document reviewed:
[sbx-command-proposal.md](sbx-command-proposal.md) at local commit 4f5ee08, with FINDINGS.md §8 and `bench/`.
Brief from the author: look at it from several angles to make the commands, use cases, scripting and API shape
complete. Rules: generic text, measured kept apart from proposed, measured twice before sending, nothing sent upstream
without the author.

## Seats

| Seat | Dimensions | Provider, model, effort | Verdict | Confidence |
|---|---|---|---|---|
| A | security, correctness | Claude subagent, Opus, default effort | CAUTION | 7 |
| B | completeness: use cases, scripting | Codex, default model and effort (no flag) | CAUTION | 9 |
| C | quality: API shape, operations, cost | Claude subagent, Opus, default effort | CAUTION | 7 |
| D | devil's advocate, prior art | Codex, default model and effort (no flag) | CAUTION | 8 |

Two providers; seats did not see each other's output.

## Verification done by the coordinator

- Hidden verbs: each candidate's `--help` compared against a nonsense verb
  ([bench/cli/sbx-hidden-verbs-2026-10-30.log](../bench/cli/sbx-hidden-verbs-2026-10-30.log)). `events` and `inspect`
  exist; `stats`, `top`, `logs`, `metrics`, `usage`, `history`, `quota`, `wait`, `status` do not. `--cloud events`
  answers "not yet supported". `--cloud inspect` and `--cloud tui` were checked at help level only.
- The published OpenAPI document ([bench/cli/sbx-api-surface-2026-10-30.log](../bench/cli/sbx-api-surface-2026-10-30.log)):
  42 paths; `/v1/processes`, `/{process}/output` with `resumeFrom`, `exitCode`, `Idempotency-Key` (79), `labels`,
  `RetryInfo`, `QuotaFailure` present; `text/event-stream`, `/events`, `stats`, `showDeleted` absent; "follow its
  events" appears 8 times. `SandboxStatus` = unspecified, creating, starting, running, stopping, stopped, failed,
  deleting, degraded. A `resources`/`memoryMib` field (C1) was not found by the search.
- The environment-file docs: the example uses `schemaVersion`, `sandboxOptions {cpus, memory}` and `kits`.
- CLI conventions from help: `-f` is `--force` on `rm`; `--format table|json|yaml`, `--json`, `-q` on `ls`; `exec`
  exits 125 when it cannot run the command and lists `-d` as "not supported"; `rm` exits 0 while removal is still
  completing; `create` has no `--label`.
- 8.18: `host_speed_by_run.py` reads steal from the guest's `/proc/stat`. Steal per run: 0.01-0.02% outside the slow
  window, 0.01-0.05% inside it. In the window's first run the verdict says one box did not finish.

## Rulings

Severity B = blocker, M = major, m = minor. Fold marks in the proposal: `(council <id>)`.

| ID | Sev | Finding | Disposition |
|---|---|---|---|
| A1 | B | `sbx events` exists locally, hidden; the proposal and 8.17 said no such verb | Accept: ask is `--cloud` + API; 8.17 corrected; evidence re-captured |
| A2 | M | `inspect` exists, cloud included | Accept-modified: row added, "help accepts `--cloud`", not run |
| A3 | M | steal is guest-visible; "a guest cannot see" is wrong | Accept: rewritten as "guest steal stays flat while time rose" |
| A4 | M | 8.18 steal ranges wrong; box-missing claim uncited | Accept: ranges corrected; box claim verified and cited |
| A5 | m | tui "local only" uncited | Accept-modified: "help accepts `--cloud`; not run" |
| A6 | m | ls fields come from help | Accept |
| A7 | m | 22,500 vs 22,000 | Accept: one number, about 22,000 |
| A8 | M | events/history must not carry argv, env, secrets, host paths | Accept |
| A9 | M | history scopes, retention, purge | Accept-modified: same scope as listing sandboxes; 90 days as a recommendation |
| A10 | M | host-load figure is a cross-tenant side channel | Accept: only the caller's own steal and PSI |
| A11 | M | fleet secrets scoped, deleted with the fleet, no global fallback | Accept |
| A12 | M | server-owned fleet, hard TTL, heartbeat lease | Accept (merged with C9) |
| A13 | M | start-what-fits must fix sizes or fail `incomplete` | Accept (merged with C10) |
| A14 | m | no `--label` on create | Accept (verified) |
| A15 | m | FINDINGS §8 names a client | Owner gate, below |
| B1 | M | only one scenario | Accept-modified: a "who needs this" section, no per-case recipes |
| B2 | M | multi-sandbox wait semantics | Accept (merged with C6): `--fail-fast`, exit 124 |
| B3 | M | exec has no detach; process wait/logs | Accept (merged with D1) |
| B4 | M | fleet IDs, idempotency, artifacts pull, idempotent rm | Accept-modified: IDs and idempotency in; artifacts deferred (D2) |
| B5 | M | versioned JSON, JSONL streams, pagination, exit codes | Accept |
| B6 | m | queue order and status; fleet cancel | Accept |
| C1 | M | several asks exist in the API, CLI lacks them | Accept-modified: API column added; the `resources` claim was not verified and is not used |
| C2 | M | API promises events, has no endpoint | Accept (verified) |
| C3 | M | follow v1 list, error, idempotency conventions | Accept |
| C4 | M | `-f` means force in sbx | Accept (verified) |
| C5 | M | `--format`/`--json`/`-q` convention | Accept (verified) |
| C6 | M | `wait` ambiguous on a sandbox | Accept (status enum verified) |
| C7 | M | fleet YAML vs sbxenv.yaml | Accept-modified: `schemaVersion`, not `version` |
| C8 | M | env vars: 0-based, list order, more vars | Accept |
| C9 | M | client-side teardown cannot be guaranteed | Accept |
| C10 | M | quota behaviour undefined | Accept; `budget` dropped (C open question 2) |
| C11 | m | cost has no unit | Accept; billing increment left as a question |
| C12 | m | stats units and interval | Accept |
| C13 | m | linked evidence names a client | Owner gate, below |
| C14 | m | history API shape | Accept-modified: fields in, the soft-delete mechanism left to Docker |
| C15 | m | versioning, auth, rate limits | Accept |
| D1 | M | API has durable processes; reframe as parity | Accept (verified) |
| D2 | M | fleet bundles too much; bounded first ask | Accept |
| D3 | M | CLI extension vs SDK recipes is Docker's choice | Accept |
| D4 | m | build cache stays separate | Accept |
| D5 | m | audit does not replace usage export; Usage page exists | Accept-modified: the Usage page lag stays in 8.15 |
| D6 | M | 8.18 is an investigation, not a cause | Accept: it stays DRAFT and asks only for a signal |

Conflicts ruled:
- `events`: seat A (exists locally) against B/D (new). Both partly right: a local stream exists; the cloud has
  neither a CLI verb nor an API endpoint (C2). The ask names both.
- Fleet shape: extend `sbx env run` (the draft), a separate verb (C), many sub-verbs (B), a small first ask (D).
  Ruled: a separate `sbx fleet` verb reading a `fleet:` section, with the first ask limited to instances, wait,
  teardown and status.

## Owner gate

- **External send (A15, C13).** FINDINGS §8 and `docs/fleet-case-kliper.md` name the project. Default: send only
  copies of the cited items with names removed; the repository stays as is until the owner decides.
- Nothing has been sent upstream. Commit local only.

## Verdict

**CAUTION.** It becomes GO when: 8.18 is measured a second time (PSI confirmed in a box, the per-box CPU benchmark in
a normal and a slow run); the hidden-verb and API captures are repeated on the sbx version current at send time; and
the owner rules on the external-send gate.

Note: this kit has no index generator, so no index was regenerated.
