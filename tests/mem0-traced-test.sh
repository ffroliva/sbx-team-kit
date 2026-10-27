#!/usr/bin/env bash
# Unknown #3 from FINDINGS §1b, closed cleanly: fresh shared storage (--mount to a new host dir for
# both sandboxes), traced writers, attribution of every lost or phantom batch.
# Needs MEM0_KIT=<PR #126 checkout, LF>/examples/mem0. No gateway needed (SQL only).
# Leaves sandboxes running on failure for inspection; removes them only at the end.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
KIT=${MEM0_KIT:?}
FRESH="$(pwd -W)/tmp/mem0-fresh-$(date +%H%M%S)"; mkdir -p "$FRESH"
START='pg_ctl -D /var/lib/mem0/postgres -l /tmp/pg.log -o "-h 127.0.0.1 -k /tmp -p 5432" start -w -t 120'
PG='psql -X -q -t -A -h 127.0.0.1 -U agent -d postgres'
SECS=${SECS:-75}
echo "fresh shared dir: $FRESH"

echo "=== create mem0-c on fresh storage; its startup hook runs initdb, then fails on the Windows socket"
sbx create --name mem0-c --memory 4g --cpus 4 --mount "$FRESH:/var/lib/mem0" "$KIT" 2>&1 | grep -E "Created|error"
sbx exec mem0-c true >/dev/null 2>&1
for i in $(seq 1 60); do sbx exec mem0-c test -s /var/lib/mem0/postgres/PG_VERSION 2>/dev/null && break; sleep 3; done
sleep 10   # let the hook's failed pg_ctl and trap finish
sbx exec mem0-c sh -c "ls /var/lib/mem0; ps -eo args | grep -c '[p]ostgres -D' | sed 's/^/postmasters in c: /'"

echo "=== c starts alone, creates the table"
sbx exec mem0-c sh -c "$START 2>&1 | tail -1; $PG -c 'CREATE TABLE race(id bigserial primary key, who text, n int)' && echo table-created"

echo "=== create mem0-d on the SAME host dir"
sbx create --name mem0-d --memory 4g --cpus 4 --mount "$FRESH:/var/lib/mem0" "$KIT" 2>&1 | grep -E "Created|error"
sbx exec mem0-d true >/dev/null 2>&1; sleep 15
echo "d sees c's lock file? $(sbx exec mem0-d sh -c 'cat /var/lib/mem0/postgres/postmaster.pid 2>&1 | head -1')"
sbx exec mem0-d sh -c "$START 2>&1 | tail -1"
for s in mem0-c mem0-d; do echo "$s: $(sbx exec $s pg_isready -h 127.0.0.1 2>&1)"; done

echo "=== traced writers in both for ${SECS}s"
for s in mem0-c mem0-d; do
  sbx cp tests/pg-writer-traced.sh $s:/tmp/pg-writer-traced.sh >/dev/null
  sbx exec $s sh -c "setsid nohup sh /tmp/pg-writer-traced.sh $s $SECS >/dev/null 2>&1 </dev/null &"
done
sleep $((SECS + 15))
for s in mem0-c mem0-d; do sbx exec $s cat /tmp/pg-writer.out; done
for s in mem0-c mem0-d; do echo "$s after: $(sbx exec $s pg_isready -h 127.0.0.1 2>&1)"; done

echo "=== stop both, restart c alone, attribute every batch"
for s in mem0-c mem0-d; do sbx exec $s sh -c 'pg_ctl -D /var/lib/mem0/postgres stop -m fast >/dev/null 2>&1; pkill -x postgres 2>/dev/null; true'; done
sbx cp mem0-d:/tmp/acked.txt tmp/acked-d.txt >/dev/null && sbx cp tmp/acked-d.txt mem0-c:/tmp/acked-d.txt >/dev/null
sbx cp tests/pg-verify-traced.py mem0-c:/tmp/pg-verify-traced.py >/dev/null
sbx exec mem0-c sh -c "$START 2>&1 | tail -1; grep -E 'recovery|redo|contrecord|invalid|PANIC' /tmp/pg.log | tail -4"
sbx exec mem0-c sh -c "/opt/mem0/venv/bin/python /tmp/pg-verify-traced.py mem0-c=/tmp/acked.txt mem0-d=/tmp/acked-d.txt"
sbx exec mem0-c sh -c "echo total_rows=\$($PG -c 'SELECT count(*) FROM race'); pg_amcheck -h 127.0.0.1 -U agent -d postgres --heapallindexed 2>&1 | tail -4; echo pg_amcheck_exit=\$?"

echo "=== cleanup"
sbx rm -f mem0-c mem0-d 2>&1 | tail -2
