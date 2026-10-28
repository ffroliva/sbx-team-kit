# sbx-team-kit

I'm Flávio Oliva, a backend engineer (Java first, Python too). This repo is how I evaluated
**Docker Sandboxes** (`sbx`) as the place a team's coding agents do real work: kits, benchmarks on a
real service, and the failures I found along the way, each one measured, reproduced and reported
upstream.

Everything here ran on `sbx` 0.50.0 on a Windows 11 host, plus Docker Cloud Sandboxes, in October
2026. Results: [FINDINGS.md](FINDINGS.md) and [bench/README.md](bench/README.md).

## How I work

- **Measure, don't assume.** Every claim has a script in `tests/` or `bench/` and a log beside it.
- **Repeat what's in doubt.** A surprising number is rerun before it's quoted, and the repeat count
  sits next to it. A single run is labelled as one.
- **Report upstream with the evidence**, and open the PR myself where the project is open source.
  [UPSTREAM.md](UPSTREAM.md) tracks every issue and PR to resolution, and `python
  scripts/upstream.py` shows whose move it is.
- **Record the unflattering parts.** Wrong turns and corrections stay in FINDINGS, marked as such.

## What I found

| Area | Result | Where |
|---|---|---|
| A team of agents on a real repo | 3 headless agents build 3 features on a Java 25 / Spring Boot service; all merged, full build green. Agent time 140 s locally, 97 s in Cloud Sandboxes | [bench §4, §7](bench/README.md) |
| One sandbox or one each | 3 agents in one sandbox: 130–137 s, $0.38–0.41. One sandbox each: 140–144 s, $0.53–0.54 (2 rounds each). Separate sandboxes buy isolation, not speed | [bench §9](bench/README.md) |
| Shared folder, concurrent writers | Locks don't cross sandboxes. Read-modify-write files lose 93–97 % of writes; one writer keeps 200/200 | [FINDINGS §1](FINDINGS.md) |
| Shared Maven cache | 3 sandboxes filling one cache at once: 2 of 9 builds pass. Filled by one writer, then shared: 6 of 6 | [FINDINGS §6](FINDINGS.md) |
| Self-hosted Mem0 kit (spec PR #126) | Two sandboxes start two PostgreSQL servers on one data directory: 4 of 4 runs damaged or destroyed, up to 100 % of acknowledged rows lost | [FINDINGS §1b](FINDINGS.md) |
| In-run integrity | Kits protect provenance, not what the agent reads during its own run: `sudo` rewrites a baked file, `umount` replaces a `:ro` mount | [FINDINGS §4d](FINDINGS.md) |
| A 22,000-test suite on a cloud fleet | Kliper's complete Python suite (unit, integration on testcontainers PostgreSQL, Playwright) on 5 × 8 vCPU sandboxes: 750 s on the first green run, 521 s four fixes later, ~$0.48 a run, against 1 h 49 min on a laptop (one run each) | [case](docs/fleet-case-kliper.md), [FINDINGS §8](FINDINGS.md) |
| Fleet cleanup | A cloud sandbox's scoped secret outlives `rm` and the TTL reaper: a crashed client leaves a live token with no expiry. A killed `create` still completes and bills to its TTL | [FINDINGS §8.1–8.2](FINDINGS.md) |
| TLS behind a filtering firewall | Post-quantum ClientHellos are dropped; `sbx login` says "signed in" while cloud fails | [bench §3](bench/README.md) |

From that, a design for safe shared agent memory: a single-writer contract with leases and fencing
tokens, and conformance tests, in [docs/single-writer-design.md](docs/single-writer-design.md).

## Upstream

| | |
|---|---|
| docker/sbx-releases#773 | TLS failures behind filtering firewalls aren't named |
| docker/sbx-releases#775 | Shared dependency cache across sandboxes (single writer, read-only for the rest) |
| docker/sandbox-kit-spec#171 | `host-mount@1`: locks don't cross sandboxes; a `readOnly` field and parent ownership |
| docker/sandbox-kit-spec#172 | Toolchain mixins: the v3 claude workload ships no JDK |
| docker/sandbox-kit-spec#173, #174 | PRs: `examples/jdk` and `examples/python` |

Status of each: [UPSTREAM.md](UPSTREAM.md).

## What's here

```
kits/team-context/   team rules (agent-context) + a network allow-list built from policy logs
kits/pr-review/      read-only review of an untrusted PR; protocol and checks ship in the kit
kits/maven-cache/    Maven's local repository on host-mount@1 (the subject of FINDINGS §6)
kits/jdk25/          a JDK for the v3 claude workload, copied out of the official image
kits/team-memory/    a volume@1 and a host-mount@1, to test persistence and sharing
kits/python-e2e/     uv, CPython, Playwright's Chromium and ffmpeg baked into shell-docker, for pytest fleets
bench/               parallel_features.py: agents building features in sandboxes, local or cloud
bench/fleet/         capacity, cold-start, code-transfer and lifecycle probes behind the fleet case
review/              run_council.py: a multi-reviewer PR review inside one sandbox
orchestrator/        fan headless workers out to sandboxes, collect through git and a host inbox
tests/               one script per finding; each FINDINGS section names its script
docs/                single-writer design; a measured PR review run; the fleet case
scripts/upstream.py  status of every upstream issue and PR
```

## Run it

```bash
# sbx >= 0.50.0. Creates and removes local sandboxes; these four make no LLM calls.
bash tests/race-test.sh          # two concurrent writers on one host-mount@1
bash tests/race-control.sh       # the same with one writer
bash tests/lock-visibility-test.sh
bash tests/maven-cache-test.sh   # needs a Maven project; see the script header

# the agent benchmark (needs a signed-in claude agent)
python bench/parallel_features.py <repo> --tasks bench/tasks-tiny-ledger.json --mode parallel|serial|onebox
```

On Windows, run the shell scripts from Git Bash. They set `MSYS_NO_PATHCONV=1` so paths reach `sbx`
unmangled.

## Use the kits

```bash
sbx run docker.io/docker/sbx-kit-claude:2.1.311 \
  --kit ./kits/team-context --kit ./kits/jdk25 \
  --memory 4g --cpus 4 ~/code/my-service
```

A v3 mixin needs a v3 workload: `sbx run claude --kit …` is refused.

Reading this with an agent? Start at [AGENTS.md](AGENTS.md).
