#!/usr/bin/env bash
# Two sandboxes, one host-mount@1, concurrent writers. Measures lost updates (markdown) and SQLite integrity.
# Evidence for a single-writer contract. Cleans up after itself.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
WL=docker.io/docker/sbx-kit-shell:1.0.0
K="--kit ./kits/team-memory"
N=${N:-200}
x(){ echo "\$ ${*: -1}"; "$@" 2>&1 | grep -v "already present\|downloaded" | tail -12; echo "[exit ${PIPESTATUS[0]}]"; }
for s in race-a race-b; do x sbx create --name $s --memory 2g --cpus 2 $WL $K; done
x sbx exec race-a sh -c 'rm -f ~/team-memory/race.md ~/team-memory/race.db*; touch ~/team-memory/race.md'
for s in race-a race-b; do x sbx exec -u root $s sh -c 'command -v sqlite3 || (apt-get -qq update && apt-get -qq install -y sqlite3 >/dev/null) ; sqlite3 --version'; done

echo "=== R1 markdown read-modify-write, $N appends per sandbox, concurrently"
W='i=0; while [ $i -lt '$N' ]; do f=~/team-memory/race.md; t=$(mktemp); cat $f > $t; echo "$(cat /etc/hostname 2>/dev/null || echo w) $i" >> $t; cp $t $f; rm $t; i=$((i+1)); done'
sbx exec race-a sh -c "$W" & sbx exec race-b sh -c "$W" & wait
x sbx exec race-a sh -c "echo lines=\$(wc -l < ~/team-memory/race.md) expected=$((2*N))"

echo "=== R2 SQLite, $N inserts per sandbox, concurrently, default locking"
x sbx exec race-a sh -c 'sqlite3 ~/team-memory/race.db "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS m(id INTEGER PRIMARY KEY, who TEXT, n INT);"'
S='i=0; fail=0; while [ $i -lt '$N' ]; do sqlite3 -cmd ".timeout 2000" ~/team-memory/race.db "INSERT INTO m(who,n) VALUES(\"$(hostname)\",$i);" 2>>/tmp/err || fail=$((fail+1)); i=$((i+1)); done; echo "$(hostname) failed=$fail"; sort /tmp/err | uniq -c | head -3'
sbx exec race-a sh -c "$S" & sbx exec race-b sh -c "$S" & wait
x sbx exec race-a sh -c 'sqlite3 ~/team-memory/race.db "SELECT who, count(*) FROM m GROUP BY who; PRAGMA integrity_check;"'

echo "=== cleanup"; x sbx rm -f race-a race-b; x sbx ls
