#!/usr/bin/env bash
# sbx spike 2026-10-28: P1 scoped secret vs box rm, P2 create with client killed, P3 TTL reap. Dummy secret only.
export GODEBUG=tlsmlkem=0 MSYS_NO_PATHCONV=1
S="sbx --cloud"; T=$(date +%s)
log(){ echo "[$(date +%T) +$(( $(date +%s)-T ))s] $*"; }
P1=spike-sec-$T; P2=spike-int-$T; P3=spike-ttl-$T
log "== P1 scoped secret lifetime"
printf 'dummy-not-a-token' | $S secret set --sandbox $P1 github; log "secret set rc=$?"
log "control, before create:"; $S secret ls --sandbox $P1 2>&1
$S create shell --name $P1 --ttl 15m --on-timeout delete --no-progress >/dev/null 2>&1; log "create rc=$?"
$S ls 2>&1 | grep -c $P1 | sed 's/^/boxes listed: /'
$S secret ls --sandbox $P1 2>&1 | sed 's/^/before rm: /'
$S rm -f $P1 2>&1 | tail -1; log "rm done"
sleep 30
$S ls 2>&1 | grep -c $P1 | sed 's/^/boxes listed after rm: /'
$S secret ls --sandbox $P1 2>&1 | sed 's/^/after rm (30s): /'; log "secret ls rc=$?"
$S secret ls 2>&1 | grep -c $P1 | sed 's/^/rows naming box in global ls: /'
log "== P2 create, client killed at 3 s"
s=$(date +%s); timeout 3 $S create shell --name $P2 --ttl 15m --on-timeout delete --no-progress >/dev/null 2>&1; log "client rc=$? after $(( $(date +%s)-s ))s"
for i in 1 2 3 4 5 6 7 8 9; do sleep 10; n=$($S ls 2>&1 | grep -c $P2); log "P2 poll $i: listed=$n"; done
log "== P3 TTL 3m, delete, no client"
s=$(date +%s); $S create shell --name $P3 --ttl 3m --on-timeout delete --no-progress >/dev/null 2>&1; log "create rc=$? in $(( $(date +%s)-s ))s"
$S ttl $P3 2>&1 | sed 's/^/ttl: /'
$S ls 2>&1 | grep $P3 | sed 's/^/ls: /'
for i in $(seq 1 24); do sleep 20; n=$($S ls 2>&1 | grep -c $P3); log "P3 poll $i: listed=$n"; [ "$n" = 0 ] && { log "P3 gone"; break; }; done
log "== cleanup"
for b in $P1 $P2 $P3; do $S rm -f $b >/dev/null 2>&1; $S secret rm --sandbox $b github --force >/dev/null 2>&1; done
$S ls 2>&1 | grep -c spike- | sed 's/^/spike boxes left: /'
$S secret ls 2>&1 | grep -c spike- | sed 's/^/spike secrets left: /'
log done
