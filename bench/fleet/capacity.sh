#!/usr/bin/env bash
# Capacity of ONE 8 vCPU / 16 GiB cloud sandbox: how many pytest workers, and which mix of suites, saturate it.
# Runs inside the box against a checkout at ~/k. The project's own test-only environment (CI=true and its dummy
# signing keys) is read from ~/suite.env, which is not in this repository.
set -u
OUT=$HOME/bench2; mkdir -p "$OUT"; cd "$HOME"
T0=$(date +%s)
stage() {  # stage <name> <cmd...>: time one step, keep its exit code, log and the last summary line
  local name=$1; shift; local s=$(date +%s)
  echo "== $name start $(( s - T0 ))" | tee -a "$OUT/timeline.txt"
  ( "$@" ) > "$OUT/$name.log" 2>&1; local rc=$?
  echo "== $name rc=$rc secs=$(( $(date +%s) - s )) | $(tail -1 "$OUT/$name.log")" | tee -a "$OUT/timeline.txt"
}
set -a; . ~/suite.env; set +a   # the suite's own test-only settings: CI=true, dummy keys
export PATH=$HOME/.local/bin:$PATH
BASE='not playwright and not ffmpeg_behaviour and not slow'
{ nproc; free -m; docker version --format '{{.Server.Version}}'; head -2 /etc/os-release; } > "$OUT/env.txt" 2>&1
# Resource samples for the whole run: CPU split and memory every 5 s, containers every 15 s.
vmstat -t -n 5 > "$OUT/vmstat.log" 2>&1 &
( while :; do echo "T $(( $(date +%s) - T0 ))"; docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}'; sleep 15; done ) > "$OUT/dstats.log" 2>&1 &
stage clone  bash -c "tar -xzf ~/k.tgz -C ~ && cd k && git rev-parse HEAD"
stage sync   bash -c 'cd k && uv sync --frozen'
stage pgpull docker pull -q postgres:17-alpine
stage pwinst bash -c 'cd k && (uv run playwright install chromium || uv run playwright install chromium)'
cd k
py() { local name=$1; shift; stage "$name" uv run pytest -q -p no:cacheprovider --junitxml="$OUT/$name.xml" "$@"; }
# A. Worker sweep on one fixed workload: the 1/8 shard of the Docker-backed suite (212 s at -n 4 on the first box).
for n in 4 8 12 16; do KLIPER_TEST_SHARD=1/8 py "a_n$n" -n $n --dist loadfile -m "$BASE and not subprocess"; done
# B. Playwright under xdist: the 1/4 shard took 875 s serial on the first box.
for n in 4 8; do KLIPER_TEST_SHARD=1/4 py "b_pw_n$n" -n $n --dist loadfile -m playwright; done
# D. The subprocess tests, serial on Windows only because of 0xC0000142: all of them under xdist on Linux.
py d_sub_n8 -n 8 --dist loadfile -m "$BASE and subprocess"
# C. Both suites at once on the same box: Docker-backed 1/8 at -n 8 next to Playwright 1/4 at -n 4.
KLIPER_TEST_SHARD=1/8 py c_int_n8 -n 8 --dist loadfile -m "$BASE and not subprocess" &
KLIPER_TEST_SHARD=1/4 py c_pw_n4 -n 4 --dist loadfile -m playwright &
wait
echo "== total secs=$(( $(date +%s) - T0 ))" | tee -a "$OUT/timeline.txt"
kill %1 %2 2>/dev/null; echo DONE >> "$OUT/timeline.txt"
