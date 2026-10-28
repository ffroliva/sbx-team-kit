# Findings — sbx 0.50.0 on Windows 11, 26 Oct 2026

Every result below comes from a script in `tests/`, run sequentially on a clean daemon. Where a
result was repeated, the section says how often; a single run is labelled as one.
Logs are in `logs/` (gitignored — rerun the scripts to reproduce).

## 1. Shared memory corrupts under concurrent writers — the headline

`host-mount@1` gives every sandbox composing a Kit the same host directory. Nothing in the spec or
the runtime decides who may write to it.

`tests/race-test.sh` — two sandboxes, one `host-mount@1`, writing at the same time:

| Store | Expected | Got |
|---|---|---|
| Markdown memory, read-modify-write (what agents do to `MEMORY.md`) | 400 lines | **11 lines** — 97% of writes silently lost. Repeated 3× (`tests/md-race-repeat.sh`): **28, 17, 16** of 400 (93–97% lost); one-writer control **200/200** every round |
| SQLite, 200 inserts per sandbox, `.timeout 2000` | 400 rows | **228 of 400 inserts failed**: `Bus error` (6 + 6), `disk I/O error` (33 + 28), `unable to open database file` (36 + 35). Afterwards the database **could not be opened at all** (error 14) |

`tests/race-control.sh` — the same work with **one** writer:

| Store | Shared mount | VM-local disk |
|---|---|---|
| SQLite, `journal_mode=WAL` | 0 failed, 200 rows, `integrity_check: ok` | 0 failed, 200, ok |
| SQLite, `journal_mode=DELETE` | 0 failed, 200 rows, ok — *one insert per `sqlite3` process; with two writes per connection DELETE fails on this mount, see §1b root cause* | 0 failed, 200, ok |
| Markdown read-modify-write | 200 / 200 lines | — |

The race and the control use the same one-write-per-process pattern, so the only variable between
them is the second writer — the concurrency conclusion is unaffected by the inode issue.

**Conclusion:** the mount is fine for one writer; the failures are caused by concurrent writers in
separate VMs. SQLite's own file locking does not hold across sandboxes on a `host-mount@1`, and
plain files have no locking at all. A shared-memory capability needs an explicit single-writer
contract — see `docs/single-writer-design.md`.

## 1b. The Mem0 kit from docker/sandbox-kit-spec PR #126 — tested, not assumed

Kit: `examples/mem0` at PR head `8e0c42f` (16 Oct 2026), built locally by sbx 0.50.0. LLM and
embeddings via an OpenAI-compatible gateway on the host, reached from the sandbox at
`host.docker.internal:3001`.

**One sandbox works** (`tests/mem0-functional.py`): configure → add two facts (LLM extraction) →
semantic search returns the right memory first (0.671 vs 0.474; 0.775 vs 0.472). It needed two
Windows-host workarounds, below.

**Two sandboxes composing the kit share one `host-mount@1` `PGDATA` — and both run PostgreSQL on it:**

1. Sandbox b could not see a's `postmaster.pid` on the shared mount, so its postmaster started while
   a's was running, and ran crash recovery underneath it ("database system was not properly shut
   down; automatic recovery in progress").
2. Both postmasters accepted connections at the same time (`pg_isready` OK in both).
3. Within about a minute both shut down: "performing immediate shutdown because data directory lock
   file is invalid". Mem0's `/docs` kept returning 200; `/search` returned 502.
4. Concurrent writes through both postmasters for 75 s (`tests/pg-writer.sh`), then one postmaster
   restarted alone:

| Writer | Rows acknowledged as committed | Rows present after restart |
|---|---|---|
| mem0-a | 495,200 | **31,400** — 463,800 acknowledged rows (93.7%) gone |
| mem0-b | 521,400 | 632,000 — 110,600 more than acknowledged in this run; origin not established (an earlier writer attempt, or replay of pre-`TRUNCATE` WAL) |

   Recovery stopped at a torn WAL record ("invalid contrecord length 67 (expected 8)").
   **`pg_amcheck --heapallindexed` passed and there were no duplicate ids** — the database looks
   healthy and is missing most of one writer's confirmed data. Silent loss, not a crash.

**Clean re-run on fresh storage** (`tests/mem0-traced-test.sh`, both sandboxes `--mount` one new,
empty host directory; every acknowledged batch logged):

- d **could** see c's `postmaster.pid` (PID 130) and started a second postmaster anyway — PID 130
  does not exist in d's VM, so PostgreSQL judged the lock stale.
- Acknowledged: c 218,200 rows, d 276,600 rows. Both postmasters went down mid-run.
- Restarted alone, the cluster **would not start**: `PANIC: could not locate a valid checkpoint
  record` ("invalid resource manager ID in checkpoint record").
- Forced open with `pg_resetwal -f`: the table exists and is **empty** — d: 0 of 1,383 acknowledged
  batches present; no rows from c either. **494,800 acknowledged rows, 100% lost.**

This replaces the earlier run's "extra rows" puzzle: that run reused storage from previous cycles,
so its surplus could not be attributed; on clean storage the outcome is total loss.

**Mechanism** (`tests/lock-visibility-test.sh`, two sandboxes on one `host-mount@1`):

| Probe | Result |
|---|---|
| File created / rewritten in one sandbox, read in the other | visible immediately (t=0), both directions |
| `flock` exclusive lock held in a | a second process **in a** is blocked; **b gets the lock** |
| POSIX `fcntl` lock (what SQLite and PostgreSQL use) held in a | **in a**: `errno 11` (blocked); **b gets the lock** |
| PID liveness (`postmaster.pid`) | each sandbox has its own PID namespace; a PID from another sandbox reads as dead |

Locks are per-VM. On a shared `host-mount@1`, every sandbox believes it holds the only lock.

**Through the Mem0 API — what an agent sees** (`tests/mem0-api-test.sh`, run 3 of 3; runs 1–2 were invalid
because on a `--mount` folder the kit's own hook started Mem0 with sbx's credential placeholder):

| Time (UTC) | From the shared `postgres.log` |
|---|---|
| 22:30:36 | e's postmaster [147] starts |
| 22:30:55 | f's hook postmaster [130] starts on the same data and runs crash recovery under 147 |
| 22:31:13 | f's postmaster [584] starts — two live postmasters; f begins adding memories |
| 22:31:36 | 147: `lock file "postmaster.pid" contains wrong PID: 584 instead of 147` → immediate shutdown |
| 22:31:53 | f's writer done: **50 memories acknowledged (HTTP 200)** |
| restart alone | **20 present — 30 acknowledged memories (60%) lost**, no duplicates |

e's own adds failed with "Provider rejected the request (authentication)" although its environment was
correct (gateway URL and key set) — cause not established («?»); e acknowledged nothing, so f's figure stands.
Two-postmaster runs ending in a destroyed or damaged cluster: 4 of 4.

**Windows-host issues in the kit as written** (each reproduced; each fix tested):

| Issue | Symptom | Fix |
|---|---|---|
| No `.gitattributes`; Git for Windows checks `start.sh` out CRLF | `set: pipefail\r: invalid option`; nothing starts, `sbx ls` says running | `*.sh text eol=lf` |
| PostgreSQL socket dir is the host mount (`-k $data`) | `could not bind Unix address "/var/lib/mem0/.s.PGSQL.5432": Invalid argument` — on the **runtime-managed** `host-mount@1` location. *Root cause measured (`tests/mount-probe.sh` + a name-length sweep): Windows' Unix-socket path limit applied to the **host-side** path — bind succeeds up to 107 host characters and fails with `EINVAL` from 108, in one folder, only the name length changing. The runtime-managed location (`%LOCALAPPDATA%\DockerSandboxes\…\kit-host-mounts\<64-hex>\<hash>\`) is always over it; a short `--mount` path is not. Inside the guest the failing path is only ~75 characters, so nothing in the sandbox hints at the cause. Mount options are identical for both (`virtiofs rw,nosuid,nodev,relatime`).* | `-k /tmp` |
| SQLite rollback journal on the host mount | `attempt to write a readonly database` (history DB); API exits, PostgreSQL stopped by trap | WAL journal mode (works on the mount) |

**Root cause of the SQLite failure — an sbx (Windows host) issue, not SQLite or Mem0**
(`tests/sqlite-repeat.sh`, `tests/inode-probe.py`):

| Measurement | Host mount | VM disk |
|---|---|---|
| DELETE / TRUNCATE / PERSIST, fresh DB, 2+ writes per connection (CLI and Python, 50 each) | **0/50** | 50/50 |
| WAL, same | 50/50 | 50/50 |
| One write per process (CLI, 10) | 10/10 | — |
| Second write in the same connection | `SQLITE_READONLY_DBMOVED` (1032), 3/3 | OK |
| Inode of a new file before → after its first write | **922 → 14918173777999148** (and 925 → …, 928 → …) | 917585 → 917585 |

On a Windows host, `host-mount@1` — and equally a user `--mount` folder (measured: 34 → 3096224756194740) — reports an inode that **changes when a file is first written**
(a small virtual number, then what looks like the NTFS file ID). `stat` and `fstat` agree with each
other at every moment — the number itself moves. SQLite records the inode at open, sees a different
one after the first commit, concludes the database was moved, and refuses all further writes. WAL
mode does not take that path. Anything that relies on inode identity (SQLite, file watchers, rsync,
build caches) is exposed.

*Correction:* an earlier version of this file said SQLite DELETE mode works for one writer on the
mount. That run did one write per process, which never triggers the check. Repeated with two
writes per connection it fails every time.

Also: with the default (Gemini 3072-dim) embeddings, pgvector refuses the HNSW index — "column
cannot have more than 2000 dimensions". Requesting 1536 via the OpenAI `dimensions` parameter
works. That is a gateway/model choice, not a kit defect.

## 2. Memory primitives in 0.50.0 — they work as specified

`tests/memory-test.sh`:

| Behaviour | Result |
|---|---|
| `volume@1` survives `sbx rm` + recreate with the **same name** | ✅ (new in 0.50.0) |
| `volume@1` is private — a second sandbox sees an empty volume | ✅ |
| `host-mount@1` is shared across sandboxes composing the same Kit | ✅ |
| `host-mount@1` outlives every sandbox | ✅ — stored at `%LOCALAPPDATA%\DockerSandboxes\sandboxes\data\kit-host-mounts\<kit-hash>\<path-hash>`; no command lists or removes it |
| No user-level agent config (`~/.claude`) inside a sandbox | confirmed on 0.46 (`tests/run-poc.sh`) |

## 3. The team kit — works on 0.50.0

`tests/kit-test.sh` with `kits/team-context`:

| Check | Result |
|---|---|
| Local v3 mixin assembles with a v3 workload on Windows | ✅ (failed on 0.46 — fixed in 0.49.1) |
| Team rules reach the agent | ✅ written to a `kits-agent-context/` directory beside the workspace |
| Maven Central / GitHub HTTPS | 200 / 200 |
| GitHub SSH :22 | allowed — `sbx policy log` shows `github.com:22 transparent` (the script's banner read is not a reliable probe) |
| Unlisted host (example.org) | 403, default deny |
| Memory convention: `docs/agent-memory.md` in the workspace survives `sbx rm` | ✅ |

## 4. CLI and authoring friction

| Finding | Version |
|---|---|
| Kit assembly failure reported as "failed to run sandbox container"; the cause (`no manifest found for platform`) only in `daemon.log` | 0.46 |
| `sbx kit validate` could not check a source kit without the builder (`--offline` added in 0.49.1) | 0.46 |
| Default sizing is the whole host: 22 CPUs / 15.7 GiB with no flags | 0.46 |
| `sbx daemon start` runs in the foreground and never returns; a script that calls it blocks. `sbx ls` starts the daemon in the background on its own | 0.50 |
| Update notice: daily check recorded 0.49.2, never shown in ~20 non-interactive commands; `sbx diagnose` found 0.50.0. Windows notices are gated on WinGet (0.47 notes) | 0.46 |
| `sbx diagnose` exits 0 with warnings; checks the install, not kits, policy or sandboxes | 0.46 |
| Windows paths: `C:\…` appears in the VM as `/c/…`, not "the same absolute path" | 0.46, 0.50 |
| Git Bash rewrites `msiexec` `/switches`; the silent MSI install hangs with no log unless run from PowerShell | installer |
| A kit's failed startup hook is invisible: `sbx ls` shows "● running (detached)" with the service dead | 0.50 |
| Allowing `host.docker.internal:3001` does not match — the proxy evaluates it as `localhost:3001` and asks approval for that name | 0.50 |
| A non-interactive `sbx create` of a kit with a required credential warns "no binding authorizes …" and creates the sandbox without it | 0.50 |

## 4b. What the proxy does with TLS — measured

| Sandbox | Host | Policy log | Certificate the sandbox sees |
|---|---|---|---|
| `claude` (Anthropic credential injected) | api.anthropic.com | `forward` | **issued by `Docker Sandboxes Proxy CA`** — TLS intercepted |
| `claude` | pypi.org, github.com | `forward-bypass` | the real public CA (GlobalSign, Sectigo) |
| `shell` (no credential) | api.anthropic.com, pypi.org, github.com, maven, npm | `forward-bypass` | the real public CA |
| any, raw TLS (openssl, ignores proxy env) | same hosts | `transparent` | the real public CA |

`forward` = the proxy terminates TLS (to inject a credential or apply L7 rules); `forward-bypass` = an untouched tunnel;
`transparent` = traffic that did not use the proxy settings. This is how the key reaches the provider without existing in the VM.

## 4d. In-run integrity — can the reviewer tamper with what it reads? (27 Oct)

| Probe | Result |
|---|---|
| Agent identity | `agent`, **passwordless `sudo`** |
| File baked into a kit (`/usr/share/sandbox/kit/…`, root 644): agent write | refused (`Permission denied`) |
| Same file, `sudo` write | **succeeded**; the change **survived `sbx stop` / start** |
| `:ro` workspace: agent write / `sudo` write | refused (`Read-only file system`) |
| Agent installs `mount` (`sudo apt`, Balanced allows Ubuntu archives), `sudo mount -o remount,rw` | remount **succeeded in the guest** (`options now: rw`) — write **still refused**: read-only is enforced host-side (virtiofs); host file unchanged |
| `sudo umount` the `:ro` mount, then write at the same path | **succeeded** — the agent reads its own replacement for the rest of its run; host copy unchanged |

Conclusion: kits and signatures protect **provenance**; neither a baked file nor a `:ro` mount protects what the
agent reads *during its own run*. Instructions that must hold belong in the prompt; the sandbox is used once.

## 4e. Running the council on a real PR — see `docs/council-1108-result.md`

## 4c. Where sbx can run — measured

| Host | KVM | Local sbx |
|---|---|---|
| Windows 11 laptop | Windows Hypervisor Platform | ✅ (all tests here) |
| WSL Ubuntu 24.04 on that laptop | `/dev/kvm` present (nested) | possible — pending sudo + sign-in |
| A cloud VPS (KVM guest, Ubuntu 24.04.3, 4 CPU, 7 GB) | **no `/dev/kvm`, 0 vmx/svm flags** | ❌ — Cloud Sandboxes only |

## 6. A shared Maven cache over `host-mount@1` — measured 27 Oct

The spec's own `examples/shared-cache` shares pip's cache across a Kit's sandboxes and says "pip is
responsible for coordinating cache writes"; `host-mount@1` says "Kits coordinate access; the grant
promises no locking". Same pattern for Maven: [kits/maven-cache](kits/maven-cache/maven-cache.yaml),
real build (tiny-ledger `./mvnw -B verify`, Java 25, Spring Boot, 442 jars / 207 MB of dependencies),
3 sandboxes (4 CPU / 4 GB) building at once on the Windows laptop. Scripts
[tests/maven-cache-test.sh](tests/maven-cache-test.sh), [tests/maven-cache-diag.sh](tests/maven-cache-diag.sh);
logs [bench/maven-cache-1.log](bench/maven-cache-1.log), [bench/maven-cache-2.log](bench/maven-cache-2.log).

| 3 concurrent builds | Rounds | Builds passed | Wall per round |
|---|---|---|---|
| Private caches, cold (control) | 2 | 6/6 | 156 s, 147 s |
| **Shared cache, cold — 3 writers at once** | 3 | **2/9** | — |
| Shared cache, complete (filled by one writer first) | 2 | **6/6** | **107 s, 101 s** |
| One build alone, offline (`-o`), from the shared cache | 1 | 1/1 | 43 s |

- **Concurrent cold writers crash the build, loudly.** 7 of 9 failed within 4–18 s with
  `java.io.IOException: File exists` in Maven Resolver's
  `DefaultTrackingFileManager.update` ← `DefaultUpdateCheckManager.touchArtifact` — the tracking-file
  write after a download, which Resolver protects with file locks. Locks don't cross sandboxes (§1:
  `flock` and `fcntl` held in one VM don't block another). The exact syscall behind `EEXIST` is not
  established.
- **No silent corruption found.** Two integrity passes over the shared cache after the crashes
  ([tests/m2-check.py](tests/m2-check.py): every jar's CRC, every pom parsed, partial downloads):
  0 corrupt, 0 partial. Unlike §1, Maven fails rather than loses writes — but a cache that crashes
  7 builds in 9 is not usable.
- **Filled by one writer, then shared, it works:** 6/6, about 30 % faster than private cold caches
  under the same 3-way contention. The single-writer contract again.
- **Slower than a private warm cache.** Warm builds read 900+ files over the host share; the in-VM warm
  build in bench §1 took 54 s alone. Concurrency on one laptop also costs (43 s alone vs ~100 s with 3).

### Authoring findings on the way (sbx 0.50.0)

| Finding | Effect |
|---|---|
| A v3 mixin can't be added to a built-in agent (`sbx create claude --kit …`): "a set of v3 kits needs exactly one with kind: workload" | Use the v3 workload `docker.io/docker/sbx-kit-claude:2.1.311` |
| A mixin using capability **groups** (as `examples/shared-cache` does) is refused with a built-in agent: "resolve only when it is composed with its workload" | The kit drops the optional group |
| The v3 claude workload ships **no JDK**; the built-in `claude` template has JDK 25 (local and cloud) | Moving a Java project to kits silently loses Java. [kits/jdk25](kits/jdk25/jdk25.yaml) adds it back |
| A kit dockerfile can be **multi-stage**: `FROM eclipse-temurin:25-jdk AS jdk` → `FROM scratch` + `COPY --from=jdk` | Toolchains, or a pre-filled cache, can be baked into a kit |
| `host-mount@1` at `/home/agent/.m2/repository` creates the **parent `~/.m2` owned by root**, so `mvnw` can't create `~/.m2/wrapper` (every build failed in 0 s) | Workaround: a root `startup` hook `chown agent:agent /home/agent/.m2`. The spec's SHOULD covers only the mount root |
| `--mount HOST:PATH` binds a host dir chosen by the user to a kit's `host-mount@1` path; writes flow both ways | Lets a test start from an empty cache |

## 7. Cloud volumes: two sandboxes on one volume, and the last to exit wins (measured 28 Oct)

Cloud volumes (`sbx --cloud volume`) are a different mechanism from §1. They are cloud-side storage, and `sbx`
forwards to the Cloud Sandboxes API: the local `sandboxd` and no host folder are involved. The docs disagree on
whether two sandboxes may share one:

- The API schema `AttachmentMode` has one value, `exclusive`: "permits one sandbox to attach the volume read-write",
  and "never silently enables shared writers".
- The CLI cloud usage page says: "If multiple sandboxes mount the same volume at the same time, the last sandbox to
  exit overwrites the stored snapshot."

Script: [tests/cloud-volume-test.sh](tests/cloud-volume-test.sh). Log: [bench/cloud-volume-1.log](bench/cloud-volume-1.log).
Setup: sbx v0.50.0, 2 vCPU `shell` boxes. Two rounds, with the exit order swapped; a third box mounts the volume
afterwards and reads it.

| | Round 1: A exits first | Round 2: B exits first |
|---|---|---|
| Second box attaches while the first holds the volume | yes, no warning | yes, no warning |
| A box sees the other's new file | no, each box has its own copy | no |
| What the reader finds | B's file only: **A's write lost** | A's file plus round 1's file: **B's write lost** |
| Exit codes | all 0 | all 0 |

- **The CLI page describes what happens; the API's `exclusive` is not enforced on this path.**
- **The loss is silent and whole-box.** Each sandbox works on a private copy, and the volume becomes the copy of
  whichever exits last. Every command returned 0.
- **§1 has the same shape at a different layer.** Locally, a shared host folder is live, and writes are lost because
  locks don't cross VMs. In the cloud, nothing is live at all, and every write of every box but one is dropped at
  exit. In both, the safe pattern is one writer.
- A first run is void: Git Bash rewrote `/vol` in `sbx --cloud exec` arguments into a Windows path, so the writes
  never happened. The script sets `MSYS_NO_PATHCONV=1` for that reason. That run still showed the concurrent attach.
- The ask: refuse the second attach, as the schema says; or offer a real shared or read-only mode. At the least,
  warn at attach that the other box's writes will be lost.

## 5. Not tested

- macOS and Linux hosts.
- A real agent (Claude Code) writing memory concurrently — the tests use the same read-modify-write
  pattern with a shell loop.
- macOS hosts. Linux: WSL Ubuntu 24.04 on this machine has `/dev/kvm` (nested virtualisation) —
  Linux runs pending; until then the socket and SQLite workarounds are Windows-only findings.
- Concurrent writes through the Mem0 API itself (the loss test wrote SQL directly to each
  sandbox's postmaster).
