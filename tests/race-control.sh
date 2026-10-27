#!/usr/bin/env bash
# Control for race-test.sh: ONE writer on the same host-mount@1. Separates "concurrency" from "SQLite over virtiofs".
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
WL=docker.io/docker/sbx-kit-shell:1.0.0
K="--kit ./kits/team-memory"
N=${N:-200}
x(){ echo "\$ ${*: -1}"; "$@" 2>&1 | grep -v "already present\|downloaded" | tail -8; echo "[exit ${PIPESTATUS[0]}]"; }
x sbx create --name ctl-a --memory 2g --cpus 2 $WL $K
x sbx exec -u root ctl-a sh -c 'command -v sqlite3 || (apt-get -qq update && apt-get -qq install -y sqlite3 >/dev/null); sqlite3 --version'
for mode in WAL DELETE; do
  echo "=== C-$mode one writer, $N inserts, journal_mode=$mode, on the shared mount"
  x sbx exec ctl-a sh -c "cd ~/team-memory && rm -f c.db c.db-*; sqlite3 c.db 'PRAGMA journal_mode=$mode; CREATE TABLE m(id INTEGER PRIMARY KEY, n INT);' ; i=0; f=0; while [ \$i -lt $N ]; do sqlite3 -cmd '.timeout 2000' c.db \"INSERT INTO m(n) VALUES(\$i);\" 2>>/tmp/e || f=\$((f+1)); i=\$((i+1)); done; echo failed=\$f; sort /tmp/e | uniq -c | head -3; rm -f /tmp/e; sqlite3 c.db 'SELECT count(*) FROM m; PRAGMA integrity_check;'"
  echo "=== C-$mode-local same, on the VM's own disk (not the shared mount)"
  x sbx exec ctl-a sh -c "cd /tmp && rm -f c.db c.db-*; sqlite3 c.db 'PRAGMA journal_mode=$mode; CREATE TABLE m(id INTEGER PRIMARY KEY, n INT);' ; i=0; f=0; while [ \$i -lt $N ]; do sqlite3 c.db \"INSERT INTO m(n) VALUES(\$i);\" 2>/dev/null || f=\$((f+1)); i=\$((i+1)); done; echo failed=\$f; sqlite3 c.db 'SELECT count(*) FROM m; PRAGMA integrity_check;'"
done
echo "=== C-MD one writer, $N read-modify-write appends on the shared mount"
x sbx exec ctl-a sh -c "f=~/team-memory/c.md; : > \$f; i=0; while [ \$i -lt $N ]; do t=\$(mktemp); cat \$f > \$t; echo \"x \$i\" >> \$t; cp \$t \$f; rm \$t; i=\$((i+1)); done; echo lines=\$(wc -l < \$f) expected=$N"
x sbx rm -f ctl-a
