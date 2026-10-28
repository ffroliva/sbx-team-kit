# Case: a 22,000-test suite on a fleet of cloud sandboxes

Kliper is a media-monitoring platform: a Python service on FastAPI and PostgreSQL, with Playwright
for its screens. In October 2026 its complete test suite took **1 h 49 min** on a developer machine,
and the GitHub Actions minutes that normally ran it were spent for the month. The question was
whether Docker Cloud Sandboxes could give the same verdict, faster, at a cost a small team can carry.

They can. Five 8 vCPU sandboxes ran all 22,438 tests in **750 s**; four fixes later the same fleet
gives its verdict in **521 s**, for about half a dollar a run. This page is how that was measured,
what limited it, and what sbx should change.

Everything ran on `sbx` 0.50.0 from a Windows 11 host, 27–28 Oct 2026. Scripts: [`bench/fleet/`](../bench/fleet/).
Logs: [`bench/fleet/results/`](../bench/fleet/results/). Kit: [`kits/python-e2e/`](../kits/python-e2e/).
The findings this produced are [FINDINGS §8](../FINDINGS.md).

## The suite

| Layer | Tests | What it needs |
|---|---|---|
| unit | 11,197 | Python only |
| contract (architecture, API schema, catalogues) | 5,170 | Python only |
| integration | 3,642 | a PostgreSQL per worker (testcontainers), so Docker inside the box |
| end to end, HTTP and browser | 2,331 | PostgreSQL, a live app server, Chromium |
| behaviour (Gherkin) | 179 | PostgreSQL |

About 1,860 of them start child processes and run in their own serial stage. That marker exists for
Windows, where process start-up fails at random under xdist; on Linux it costs wall time for nothing.

So a box needs Docker-in-sandbox (the `shell-docker` template), a Python toolchain, a browser, and
ffmpeg. A wrong verdict is worse than a slow one: the run is a merge gate.

## Step 1: what one box can do (8 vCPU / 16 GiB)

Script: [`bench/fleet/capacity.sh`](../bench/fleet/capacity.sh), `vmstat` every 5 s. One run per row.

| Workload | Wall | CPU busy | Free memory, lowest |
|---|---|---|---|
| 1/8 of the Docker-backed tests, `-n 4` | 228 s | 44% | 6.7 GiB |
| same, `-n 8` | **164 s** | 67–71% | 3.5–4.4 GiB |
| same, `-n 12` | 168 s | 78% | 0.3 GiB |
| same, `-n 16` | 190 s | 79% | 0.1 GiB |
| all subprocess tests, `-n 8` | 83 s (10.7 min serial on Windows) | 69% | 6.7 GiB |
| 1/4 of the Playwright tests, serial | 875 s | – | – |
| same, `-n 4` | **311 s** | 37% | 9.0 GiB |
| both at once: Docker 1/8 `-n 8` beside Playwright 1/4 `-n 4` | **376 s** (vs 495 s in sequence) | 82% | 0.7 GiB |

- **One worker per vCPU for database tests; memory runs out before CPU.** Each worker costs about
  1.1 GiB (a PostgreSQL plus Python).
- **Browser tests are light** and stop scaling at 4 workers: one 69-test file held a worker for the
  whole run. The wall was that file.
- **Mixing the two on one box works:** 24% faster than in sequence, at the memory edge.

## Step 2: getting the code and the toolchain in

| Route | Measured | Verdict |
|---|---|---|
| `sbx --cloud cp` of an 81–100 MB tarball | 33–181 s per box (0.4–2.5 MB/s), from one laptop uplink shared by every box | too slow, and it scales the wrong way |
| a cloud volume holding a clone and the uv cache | 89 MB, root-owned; and a second box can attach it, last exit wins ([FINDINGS §7](../FINDINGS.md)) | unusable as a shared base |
| depth-1 `git clone` inside the box | 2–7 s; each box downloads on its own link | **chosen** |

The box clones the **pushed, committed sha** from GitHub. Nothing from the laptop's working tree, and
no `.env`, ever reaches the cloud. The clone authenticates through a GitHub token stored as an sbx
secret **scoped to that one sandbox** and set before `create`, so the token lives only in the sbx
proxy and never in the box ([FINDINGS §8.1, §8.3](../FINDINGS.md)).

Toolchain, stock `shell-docker` against the [`python-e2e`](../kits/python-e2e/) kit (2 vCPU, one run each):

| | stock template | kit 0.2.0 |
|---|---|---|
| first create | 7 s | 325 s (server builds the kit, once) |
| later creates | 7 s | 16 s |
| per run: Chromium's OS libraries, the browser, ffmpeg | ~114 s (47 + 11 + 56) | 0 s, baked in |

Python itself is not a download: the template already ships uv 0.13.4 and CPython 3.14, and a cold
`uv sync` of 143 packages took about 5 s. **The kit saves about 100 s per box per run** once built.

## Step 3: the fleet

The orchestrator (in Kliper's private repository) does this per run:

1. checks the sha is on the remote the boxes clone from;
2. sets a scoped secret per box, creates the boxes with a TTL and `--on-timeout delete`, names them
   with a run id so two runs never delete each other's boxes;
3. in each box: clone, prepare, then the database and Playwright stages **in parallel**, then the
   subprocess stage; each test file goes to a box by its measured duration;
4. copies back each box's junit and timeline, removes boxes and secrets (on Ctrl+C too), and gives one
   exit code: green, red, not runnable, or **no verdict** (no box ran a stage: credit, quota, outage).
   A missing junit, a deadline or a box that never started is red, never green.

The first runs found the limits the docs don't state:

| Run | Boxes × vCPU | Result | Passed | Wall |
|---|---|---|---|---|
| 5 | 8 × 8 (one refused by the 40 vCPU quota at create) | red: box 6 never existed | 21,223 | 761 s |
| 6 | 5 × 8 | **green** | 22,438 | **750 s** |

Five boxes gave the same wall as eight: the suite is about 294 test-minutes, so within 40 vCPU the
floor is about 7.4 min of tests per box, plus prepare.

## Step 4: making it faster, one fix per run

Each change was its own pull request, verified by one fleet run on its pushed commit. Wall is the
orchestrator's start to its exit code; one run per row.

| Change | Wall | Slowest box | Note |
|---|---|---|---|
| baseline (fleet run 6) | 750 s | 713 s | prepare 74–88 s per box |
| verdict correctness (red is red, Ctrl+C cleans up, run ids, count floor) | 649 s | 624 s | no test changed: this is run-to-run spread |
| a race in one browser test's wait | 621 s | | |
| PostgreSQL `trust` auth inside the test containers | **521 s** | 498 s | database and Playwright stage end 316–443 s |

What sets the wall now, from the per-box timelines: the parallel database and Playwright stage on
every box (316–443 s), then prepare (76–96 s, which the kit removes), then one file that slept 3 s
between fake search queries for 182 s (fixed next). Rebalancing alone cannot reach the 300 s target:
at 649 s the boxes finished level (508–624 s), so the work per box has to fall, not move.

## Cost

Billing is per runtime second by shape; an 8 vCPU / 16 GiB box bills as Large, $0.56 an hour.
Run 6 was 3,099 box-seconds: **about $0.48**. The rate is linear in vCPU, so more boxes change the
wall, not the price; faster tests and a prebuilt image lower it. The account's $250 credit covers
about 490 complete runs.

## What it took from sbx, and what sbx should change

The measured gaps are [FINDINGS §8](../FINDINGS.md). In short:

- **A fleet needs its limits stated:** the 40 vCPU quota is enforced at create, one box at a time, and
  is not in the docs; eight creates at once got an HTTP 429 that the CLI does not retry.
- **Cleanup has holes:** a scoped secret outlives `sbx --cloud rm` and a TTL delete; a `create` whose
  client is killed still completes and bills until its TTL.
- **Moving bytes in is the slow part:** `cp` throughput varies 6× and divides one uplink across boxes;
  volumes have no size option and no shared read-only mode.
- **Long runs are blind:** no detached exec in the cloud CLI (the API has it), no resource metrics, no
  per-sandbox cost.

## Rules the fleet keeps

- It tests only a pushed commit, cloned inside the box. No working tree, no `.env`.
- Secrets are scoped to one sandbox, set before create, removed after; tokens are never printed, and
  the run log is masked for token shapes before it is kept.
- No test is skipped, deselected or retried to fit the time budget. A faster wrong verdict is a
  regression.
