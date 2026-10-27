#!/bin/sh
# Inside a Mem0 sandbox: insert batches into race for N seconds through the local postmaster.
# Usage: pg-writer.sh <who> <seconds>   -> result in /tmp/pg-writer.out
who=$1; secs=${2:-75}
PG="psql -X -q -t -A -h 127.0.0.1 -U agent -d postgres"
ok=0; err=0; end=$(( $(date +%s) + secs ))
: > /tmp/pg-writer.err
while [ "$(date +%s)" -lt "$end" ]; do
  if $PG -c "INSERT INTO race(who,n) SELECT '$who', g FROM generate_series(1,200) g" >/dev/null 2>>/tmp/pg-writer.err; then
    ok=$((ok+1))
  else
    err=$((err+1)); sleep 1
  fi
done
{
  echo "$who ok_batches=$ok failed_batches=$err rows_claimed=$((ok*200))"
  sort /tmp/pg-writer.err | uniq -c | sort -rn | head -4
} > /tmp/pg-writer.out
