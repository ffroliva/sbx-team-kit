# Upstream — issues and PRs we raised with Docker

Every finding here that is Docker's to fix gets filed upstream with its evidence, and tracked in this
table until it is resolved. Check status with `python scripts/upstream.py`: it shows each item's state
and who spoke last. **`ours`** means a maintainer or another user replied and the next move is ours.
Where the project is open source (docker/sandbox-kit-spec), we open the PR ourselves.

| Item | What | Our part | Evidence | Next |
|---|---|---|---|---|
| docker/sbx-releases#773 | sbx login says "signed in" while cloud fails behind a TLS-filtering firewall (post-quantum ClientHello) | filed 27 Oct + follow-up comment (in-sandbox OpenSSL, docs gap) | bench/README.md §3 | wait for triage |
| docker/sbx-releases#775 | Shared dependency cache across sandboxes (single writer, read-only for the rest) | filed 27 Oct. @kiview asked: why not run the agents in parallel within one sandbox? | bench/README.md §5, FINDINGS.md §1, §6 | measured (bench §9: one sandbox 130–137 s / $0.38–0.41 vs 140–144 s / $0.53–0.54, 2 rounds each); replied 27 Oct with the measurements + host-mount@1 correction (issuecomment-6447231964) | wait for kiview |
| docker/sbx-releases#638 | Cloud claude + `--oauth` anthropic secret hung (apiKeyHelper placeholder) | commented 27 Oct: looks fixed on 0.50; @ericcurtin closed it 28 Oct, fixed in v0.50.0, thanked us | bench/cloud-oauth.log | — done |
| docker/sandbox-kit-spec#171 | host-mount@1: locks don't cross sandboxes, so "Kits coordinate access" fails for lock-based tools; propose `readOnly`, parent ownership, fix the pip example's wording | filed 27 Oct | FINDINGS.md §1, §6 | wait for triage; offer the PR for (1), (3) and (4) |
| docker/sandbox-kit-spec#172 | Kit request: toolchain mixins, starting with a JDK — the v3 claude workload ships no JDK, the built-in template did | filed 27 Oct. @cdupuis: move the kits to sbx-kits-contrib; agreed, and asked @mdelapenya whether standalone or `mise` presets | FINDINGS.md §6 (authoring table) | wait for mdelapenya |
| docker/sandbox-kit-spec#173, #174 | PRs: `examples/jdk`, `examples/python` | closed 27 Oct, moved to sbx-kits-contrib#439 | — | — |
| docker/sbx-kits-contrib#439 | PR: `jdk` + `python` toolchain mixins on `v3`, version args enforced at build, kit index updated | opened 27 Oct, DCO + signed commits | both build lint-clean; composed on `sbx-kit-claude:2.1.311`: JAVA_HOME set, Python 3.14.10, uv 0.13.6, `requests` installed via the proxy | wait for review; side note in the body: `docker.io/sbx/claude:latest` is refused on sbx 0.50 ("agent claude is already registered") |

## Planned

| Item | What | Depends on |
|---|---|---|
| docker/sbx-releases (new) | Cloud volumes: a second sandbox attaches a volume despite `AttachmentMode: exclusive`; the last to exit silently replaces the other's writes | FINDINGS §7, 2 rounds | needs the owner's go |
| docker/sandbox-kit-spec or sbx-releases (new) | Local `volume@1` data survives `sbx rm` and reattaches by name, against the spec MUST (`volume@1/removal-deletes-storage`); the docs describe the runtime | FINDINGS §7, 2 rounds | needs the owner's go; first decide which is meant to change, the spec or the runtime |
| docs/single-writer-design.md | Make the broker (option C) the recommendation: sandboxes write through a host- or platform-side broker that issues fencing tokens. Option B's file lock becomes the single-host case only. Add failure domains: durability locally, a managed service when shared, fail soft (cached reads, queued writes) | — |
| sandbox-kit-spec: `memory@1` | Spec change: a memory capability served by a broker, declared like `credential@1`. Per-sandbox attribution and policy, fencing tokens, the same API locally and in the cloud. Cites #171, #775, FINDINGS §1, §1b, §6 | the design doc update |
| sandbox-kit-spec#126 comment | Is one Mem0 sandbox per store the intended model? Two-sandbox measurements (FINDINGS §1b), three Windows-host fixes, offer of a PR. Point to the `memory@1` issue as the general answer | the `memory@1` issue |
