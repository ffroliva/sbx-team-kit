# Pre-report runbook: check before filing anything upstream

Status: **Runbook A run on 2 Nov 2026 (results below). Runbook B not run.** Written 2 Nov 2026 for sbx 0.50.x. Nothing here is a finding until
its log exists in `bench/` with a run count.

**Why this exists.** A report gets taken seriously when it has a reproduction, a run count, a check
against the docs and a search for duplicates. Anything less is noise. Every report goes through all
five gates below. If a gate fails, the report is downgraded or dropped.

## The five gates (every report)

1. **Docs.** Quote the page that covers the behaviour, with its URL and the date read. If the docs
   describe what happened, it is not a bug. At most it is a docs gap. (FINDINGS §7 and three §8 items
   were withdrawn this way.)
2. **Duplicates.** `gh search issues --repo docker/sbx-releases "<keywords>"`. Link any related
   issue instead of filing a duplicate.
3. **Reproduction.** A script in `bench/` or `tests/`, run **at least 3 times**, using dummy values
   only. State the count.
4. **Impact.** Say who could exploit it and what it takes. "My own account, my own data" is a
   lifecycle bug, not a vulnerability.
5. **Channel.** Pick it from impact, not from how alarming it sounds:
   - **Crosses a trust boundary** (another account, out of the VM, a secret readable inside the VM):
     email `security@docker.com` per `docker/sbx-releases/SECURITY.md`. GitHub private reporting is
     off on Docker's repos. Nothing public until they answer.
   - **Otherwise**: a public issue, short and factual, with the log attached.

## Runbook A: does a cloud sandbox's scoped secret outlive the sandbox? (FINDINGS §8.1)

**What is already known:** one run on 28 Oct (`bench/fleet/results/lifecycle-2026-10-28.log`). After
`sbx --cloud rm`, `secret ls --sandbox <name>` still listed the secret, and the same happened after
the TTL reaper.

**What one run cannot tell apart.** In sbx a secret is scoped to a **name**, not to a sandbox
instance. Setting it **before** `create` is the supported route (§8.3). So a secret with no sandbox is
a normal state. "Still listed after `rm`" may be by design. The question that matters is the next
one.

**The decisive question:** does a **new, unrelated** cloud sandbox that reuses the name receive the
old credential?

**The cheap observable, no real token needed** (the method from docker/sbx-releases#785): inside
the box, run `curl -s https://api.github.com/rate_limit`.
- **Dummy secret injected** → `401 Bad credentials`. The proxy added a header.
- **Nothing injected** → `200` with anonymous rate-limit JSON.

Run with a 2-vCPU `shell` box, `--ttl 10m --on-timeout delete`. Cost: a few minutes of the smallest
box per round.

| Step | Command (cloud) | Expected if correct |
|---|---|---|
| 0 | Gates 1 and 2. Read the `secret`, `rm` and credentials pages. Note what they say about **cloud** scoped secrets on `rm` | — |
| 1 | `printf dummy-not-a-token \| sbx --cloud secret set --sandbox P github` | created |
| 2 | `create shell --name P`, then exec `curl -s -o /dev/null -w '%{http_code}' https://api.github.com/rate_limit` | **401** (injected): proves the observable works |
| 3 | `rm -f P`; wait 30 s; `secret ls --sandbox P` | listed = §8.1 reproduced |
| 4 | `create shell --name P` again (new instance); same curl | **200** = name-scoped record only, harmless. **401** = an old credential reaches a new box |
| 5 | Control: `create shell --name Q`; same curl | 200 |
| 6 | Repeat steps 1–4 with `--ttl 2m --on-timeout delete` and no `rm` (the reaper path) | same as 3–4 |
| 7 | **Local** control: the same steps without `--cloud` | the `rm` reference says local `rm` deletes scoped secrets |
| 8 | Clean up: `rm -f P Q`; `secret rm --sandbox P github --force`; `secret ls \| grep -c P` = 0 | 0 |

Run the whole thing 3 times. Log to `bench/fleet/results/secret-lifecycle-<date>-<n>.log`.

**Decision:**

| Result | What it is | Channel |
|---|---|---|
| Step 4 gives 200 | A leftover record. Cloud and local differ only in cleanup | Public issue: "cloud `rm` doesn't remove scoped secrets the way local `rm` does" |
| Step 4 gives 401 | A credential set for one box reaches a later, unrelated box with the same name. Same account only | Still the owner's own account. Email `security@docker.com` stating it as **low severity, same-account**, and let them classify it. No public issue until they reply |
| The docs say cloud secrets persist by name | Behaviour as designed | Drop it, or file a docs request |

### Results: 2 Nov 2026, sbx v0.50.1 (measured)

Logs: `bench/fleet/results/secret-lifecycle-2026-11-02-cloud.log` (rounds 1–2 valid; round 3 void,
cloud vCPU quota full from another workload: `resource_exhausted ... 44 in use, limit 40`),
`...-cloud-run2.log` (2 rounds, all valid), `...-local.log` (3 rounds). `...-local-VOID-ttl-flag.log`
is void: the script passed `--ttl` locally.

| Step | Cloud | Local |
|---|---|---|
| 2: first box with a scoped dummy | **401** (6/6) | **401** (3/3) |
| 4: **new box, same name, after `rm`** | **401 (4/4): the old scoped secret is injected** | **200, limit 60 (3/3): not injected** |
| 6: **new box, same name, after the TTL reaper** | **401 (2/2)** | n/a (no TTL locally) |
| 5: control, other name | 200, limit 5000: the account's *global* `github` secret (4/4) | 200, limit 60: no global secret (3/3) |

**Decision (per the table above): step 4 gives 401.** On cloud, a credential scoped to a sandbox name
survives `sbx --cloud rm` and the TTL reaper, and is injected into the next, unrelated sandbox that
reuses the name. Local `rm` deletes it, as the `sbx rm` reference says. Same account only.

**Bug in the script, fixed after these runs:** the "rows scoped to it" count matched the name inside
`No secrets found for scope "<name>"`, so it read 1 even when empty. Ignore those lines in the logs.
The 401/200 probe is the evidence, and is unaffected.

**Also, before any report:** decide whether §8.1 stays in the public FINDINGS. If step 4 gives 401,
remove it until Docker answers.

## Runbook B: can a sandbox reach a broker? (memory-broker-proposal §6, step 1)

**Known, measured:** locally, a sandbox reached an HTTP service on the host at
`host.docker.internal:3001` (FINDINGS §1b, the Mem0 kit). The proxy saw it as `localhost:3001`, and
an allow rule for `host.docker.internal:3001` did not match (FINDINGS §4).

**Known, documented:** all outbound TCP goes through the host proxy, and **sandboxes cannot reach
each other** (docs.docker.com/ai/sandboxes/security/isolation/). There is no shared internal network.

**Unknown:** what any of this looks like in the cloud. A broker in its own cloud sandbox would need
an endpoint the other boxes can reach through their egress proxy. Whether a cloud sandbox can expose
a port at all is unverified.

| Probe | How | Records |
|---|---|---|
| B1 local box → host | Run `python -m http.server 8765` on the host; in a box, `curl host.docker.internal:8765`; check `sbx policy log` | policy decision, the rule needed |
| B2 local box → local box | Run a server in box A; from box B, curl A's IP or name | expected refused (the docs say so) |
| B3 cloud box → public endpoint | A tiny HTTPS echo on the VPS; curl it from a cloud box | does the egress policy allow it, and which rule |
| B4 cloud box → cloud box | Run a server in cloud box A; from B, try A | expected refused |
| B5 cloud exposure | `sbx --cloud --help`, `create --help`: is there any port publish or expose? | yes or no, quoted |

If B4 is refused and B5 says no, a cloud broker has to sit **outside** the fleet, behind a reachable
endpoint, with the egress policy allowing it. It cannot be a peer on a shared network, because sbx
doesn't have one.
