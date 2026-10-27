#!/bin/sh
# Inside a Mem0 sandbox: insert batches for N seconds; every batch carries its number (column n)
# and every batch the server acknowledges is logged, so loss and phantoms can be attributed.
# Usage: pg-writer-traced.sh <who> <seconds>  -> /tmp/acked.txt (one batch number per line), /tmp/pg-writer.out
who=$1; secs=${2:-75}
PG="psql -X -q -t -A -h 127.0.0.1 -U agent -d postgres"
b=0; ok=0; err=0; end=$(( $(date +%s) + secs ))
: > /tmp/acked.txt; : > /tmp/pg-writer.err
while [ "$(date +%s)" -lt "$end" ]; do
  b=$((b+1))
  if $PG -c "INSERT INTO race(who,n) SELECT '$who', $b FROM generate_series(1,200)" >/dev/null 2>>/tmp/pg-writer.err; then
    ok=$((ok+1)); echo "$b" >> /tmp/acked.txt
  else
    err=$((err+1)); sleep 1
  fi
done
{
  echo "$who batches_tried=$b acked=$ok failed=$err rows_acked=$((ok*200))"
  sort /tmp/pg-writer.err | uniq -c | sort -rn | head -3
} > /tmp/pg-writer.out
