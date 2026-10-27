#!/usr/bin/env bash
# Markdown memory race, repeated: ROUNDS x (two sandboxes, N read-modify-write appends each, concurrently)
# plus a one-writer control per round. Same pattern as race-test.sh R1. Unique file per round, nothing deleted.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
WL=docker.io/docker/sbx-kit-shell:1.0.0
K="--kit ./kits/team-memory"
N=${N:-200}; ROUNDS=${ROUNDS:-3}
D=/home/agent/team-memory
for s in md-a md-b; do sbx create --name $s --memory 2g --cpus 2 $WL $K 2>&1 | grep -E "Created|error"; sbx exec $s true >/dev/null 2>&1; done
RUN=$(date +%H%M%S)
W='f=$1; i=0; while [ $i -lt '$N' ]; do t=$(mktemp); cat $f > $t; echo "$(cat /etc/hostname 2>/dev/null || echo w) $i" >> $t; cp $t $f; rm $t; i=$((i+1)); done'
for r in $(seq 1 $ROUNDS); do
  f=$D/md-$RUN-r$r.md; c=$D/md-$RUN-r$r-control.md
  sbx exec md-a sh -c ": > $f; : > $c"
  sbx exec md-a sh -c "$W" _ "$f" & sbx exec md-b sh -c "$W" _ "$f" & wait
  sbx exec md-a sh -c "$W" _ "$c"
  echo "round $r: two writers $(sbx exec md-a sh -c "wc -l < $f") of $((2*N)) lines; one writer $(sbx exec md-a sh -c "wc -l < $c") of $N"
done
sbx rm -f md-a md-b 2>&1 | tail -1
