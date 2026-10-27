# PR council review inside one sandbox — gflow-cli PR #1108, measured

External PR by `pedromuniz-ia`: *fix(migrated): serve r2v with a named character entity on
flow.google.com* — 15 files, +77/−84. Reviewed 27 Oct 2026 with `review/run_council.py`
(sbx 0.50.0, Windows 11). **Nothing was posted** — the comment is the maintainer's decision.

## Sealed, secure, closed — what the run showed

| Property | Measured |
|---|---|
| Pinned input | sandbox HEAD `388276527000922380f0e0437acfe49eea3f0349` = PR head from `gh` |
| Protocol from `develop` (`7b6b9054`), not the PR tree | delivered by the host into `/tmp/review`, root-owned (`sbx cp` writes as root) |
| Reviewers changed nothing | `git status --porcelain` on the reviewed tree: **CLEAN** |
| Credential | `api.anthropic.com` `forward` (TLS intercepted by the sbx proxy to inject it), 422 requests |
| Blocked by default-deny | Claude Code's Datadog telemetry (31×); the account's claude.ai MCP connectors trying to start inside the sandbox (Notion, Slack, Atlassian, Linear, Asana, Figma, Intercom) |
| Allowed, not yet explained | 1 request to `api.github.com` (inputs were local — no reviewer should need it); 5 to `mcp-proxy.anthropic.com` (the connectors' route). **To investigate** before production |

## Cost and time per dimension (Claude Code's own `--output-format json`)

| Dim | Tier | Model | Cache read | Output | Cost $ | s | Verdict |
|---|---|---|---|---|---|---|---|
| D1 Correctness | opus | claude-opus-5-5 | 823,426 | 5,025 | 0.788 | 72 | YELLOW |
| D2 Quality | sonnet | claude-sonnet-5-5 | 225,239 | 1,446 | 0.230 | 26 | GREEN |
| D3 Security | opus | claude-opus-5-5 | 298,213 | 2,370 | 0.537 | 36 | GREEN |
| D4 Tests | opus | claude-opus-5-5 | 468,277 | 5,021 | 0.722 | 56 | YELLOW |
| D5 Memory | haiku | claude-haiku-5-5 | 509,998 | 7,508 | **0.022** | 47 | YELLOW |
| D6 Live-verify | sonnet | claude-sonnet-5-5 | 121,022 | 1,309 | 0.210 | 23 | YELLOW |
| D9 Docs drift | sonnet | claude-sonnet-5-5 | 286,207 | 2,290 | 0.249 | 35 | YELLOW |
| D14 YAGNI | sonnet | claude-sonnet-5-5 | 114,661 | 790 | 0.201 | 22 | GREEN |
| D15 Parity | haiku | claude-haiku-5-5 | 852,148 | 8,986 | **0.029** | 55 | YELLOW |
| Synthesis | opus | — | — | — | ≈ 0.56 | — | **YELLOW** |
| **Total** | | | | | **3.55** | **150 wall** | |

Costs are API-equivalent figures reported by Claude Code; on a subscription they are usage, not a bill.
Haiku dimensions cost about 1/30 of an Opus dimension for comparable reading. Cache reads dominate
input: every dimension re-loads Claude Code's own context.

## The review

Synthesis **YELLOW** (no RED; D0 unverified — one CI check without a result). Must-fix:

1. `tests/api/transports/test_migrated_dispatch.py:319` — docstring says r2v's null submit reply "is
   followed on the status poll"; that was dropped in `5c7ed6a8`, at this SHA a null reply ends as
   exit 9. *(D1, D4, D9)*
2. `docs/MCP.md:87` — still says r2v with `reference_entity_names`/`reference_entities` returns the
   exit-36 envelope; this PR serves r2v with a named entity. *(D15 — Haiku)*
3. `docs/superpowers/memory/flow-recon-must-run-on-denon82-ffroliva-migrated.md` — still lists
   character entities on video as unported. *(D5 — Haiku)*
4. No e2e test for the newly allowed **paid** r2v + named-entity path; "holding paid runs" is a
   choice, not a named blocker. *(D4, D6)*
5. Offline gaps: r2v + named-entity happy path; entity-only r2v through the gate. *(D4)*
6. One CI check without a conclusion. *(D0)*

Dismissed by the chair: the deterministic D12/D15 findings (pre-existing, files not in the PR) and
D2 cosmetic nits.

**Independently verified against the pinned SHA** (not trusting the council): #1 — the docstring text
and commit `5c7ed6a8 "…drop adoption"` are both there; #2 — `docs/MCP.md:87` says exactly that; #4 —
the entity e2e tests cover `t2i` and `i2i` only. No false positive found among the claims checked.

## What it took to get here (failures, kept on purpose)

- Run 0: I passed a full SHA I had partly typed — the runner's `git merge-base` refused it. SHAs now
  come from `gh`.
- Run 1: `sbx cp dir/.` copies the directory *as a directory* (unlike `docker cp`); inputs landed
  one level deeper. Fixed + a landing check.
- Run 2: `sbx cp` writes as root, so the agent could not create its output folder; a stale runner
  waited 30 min. Fixed (agent-owned `/tmp/review-out`) + a 20-second fail-fast check.
