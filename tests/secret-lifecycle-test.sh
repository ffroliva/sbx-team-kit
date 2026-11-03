#!/usr/bin/env bash
# Runbook A (docs/pre-report-runbook.md): does a scoped secret reach a NEW sandbox that reuses the name?
# Dummy secret only. Observable: GitHub /rate_limit from inside the box.
#   401            -> the dummy scoped secret was injected
#   200, limit 5000 -> a real token was injected (the account's GLOBAL github secret)
#   200, limit 60   -> nothing injected (anonymous)
# Usage: tests/secret-lifecycle-test.sh [rounds=3] [cloud|local]
export GODEBUG=tlsmlkem=0 MSYS_NO_PATHCONV=1
ROUNDS=${1:-3}; MODE=${2:-cloud}
S="sbx"; [ "$MODE" = cloud ] && S="sbx --cloud"
T=$(date +%s); t0=$T
log(){ echo "[$(date +%T) +$(( $(date +%s)-t0 ))s] $*"; }
probe(){ # $1 box, $2 label
  local out
  out=$($S exec "$1" sh -c 'curl -s -w "\nHTTP=%{http_code}\n" https://api.github.com/rate_limit | tr -d " " | grep -m1 -E "\"limit\":" ; curl -s -o /dev/null -w "HTTP=%{http_code}\n" https://api.github.com/rate_limit; env | grep -c -E "^(GH_TOKEN|GITHUB_TOKEN)=" | sed "s/^/token_env_vars=/"' 2>&1 | tr '\n' ' ')
  log "PROBE $2 [$1]: $out"
}
mk(){ local e; e=$($S create shell --name "$1" $([ "$MODE" = cloud ] && [ -n "$2" ] && echo "--ttl $2 --on-timeout delete") --no-progress 2>&1 >/dev/null); local rc=$?
  log "create $1 rc=$rc${e:+ err: $(echo "$e" | grep -m1 -i error)}"; }
sec(){ log "secret ls --sandbox $1: $($S secret ls --sandbox "$1" 2>&1 | grep -v -e '^SCOPE' -e 'No secrets found' | grep -c "$1") row(s) scoped to it"; }
CREATED=()
cleanup(){ for b in "${CREATED[@]}"; do $S rm -f "$b" >/dev/null 2>&1; $S secret rm --sandbox "$b" github --force >/dev/null 2>&1; done
  log "cleanup: boxes left $($S ls 2>&1 | grep -c "sl-.-$T")  scoped secrets left $($S secret ls 2>&1 | grep -c "sl-.-$T")"; }
trap cleanup EXIT

log "mode=$MODE rounds=$ROUNDS $($S version 2>/dev/null | head -1)"
log "global secrets (names only): $($S secret ls 2>&1 | awk '$1=="(global)"{print $2}' | tr '\n' ' ')"

for r in $(seq 1 "$ROUNDS"); do
  P=sl-p-$T-$r; Q=sl-q-$T-$r; R=sl-t-$T-$r; CREATED+=("$P" "$Q" "$R")
  log "===== round $r: rm path"
  printf 'dummy-not-a-token' | $S secret set --sandbox "$P" github >/dev/null 2>&1; log "set scoped dummy for $P rc=$?"
  mk "$P" 10m; probe "$P" "step2 first box (expect 401)"
  $S rm -f "$P" >/dev/null 2>&1; log "rm $P rc=$?"; sleep 30
  log "boxes named $P listed: $($S ls 2>&1 | grep -c "$P")"; sec "$P"
  mk "$P" 10m; probe "$P" "step4 NEW box, same name (DECISIVE)"
  mk "$Q" 10m; probe "$Q" "step5 control, other name"
  $S rm -f "$P" "$Q" >/dev/null 2>&1

  if [ "$MODE" = cloud ]; then
    log "===== round $r: TTL reaper path"
    printf 'dummy-not-a-token' | $S secret set --sandbox "$R" github >/dev/null 2>&1; log "set scoped dummy for $R rc=$?"
    mk "$R" 2m; probe "$R" "step6 first box (expect 401)"
    for i in $(seq 1 24); do sleep 15; n=$($S ls 2>&1 | grep -c "$R"); [ "$n" = 0 ] && { log "reaped after poll $i"; break; }; done
    sleep 30; sec "$R"
    mk "$R" 10m; probe "$R" "step6 NEW box after reap, same name (DECISIVE)"
    $S rm -f "$R" >/dev/null 2>&1
  fi
done
log done
