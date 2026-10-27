#!/usr/bin/env bash
# Unknown #4 from FINDINGS: concurrent writes through the Mem0 API (the path an agent uses), two
# sandboxes on one fresh shared PGDATA. Needs MEM0_KIT (PR #126, LF) and an OpenAI-compatible
# gateway on the host at 127.0.0.1:3001 with its client key in GATEWAY_KEY.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
KIT=${MEM0_KIT:?}; : "${GATEWAY_KEY:?}"
N=${N:-50}
FRESH="$(pwd -W)/tmp/mem0-api-$(date +%H%M%S)"; mkdir -p "$FRESH"
echo "fresh shared dir: $FRESH  memories per writer: $N"

prep(){ # sandbox: Windows workarounds (FINDINGS §1b), then start Mem0 pointed at the gateway
  local s=$1
  sbx policy allow network --sandbox "$s" localhost:3001 >/dev/null
  # On a --mount folder the kit's own hook succeeds and starts Mem0 with sbx's credential placeholder
  # and no gateway URL; stop this sandbox's hook-started processes before starting ours.
  sbx exec "$s" sh -c 'pkill -f "uvicorn app:app"; pkill -f "node server.js"; pkill -f "/opt/mem0/start.sh"; pg_ctl -D /var/lib/mem0/postgres stop -m fast >/dev/null 2>&1; sleep 2; true'
  sbx exec "$s" sh -c 'sed "s#-k \$data#-k /tmp#" /opt/mem0/start.sh > /tmp/start-fixed.sh'
  sbx exec "$s" sh -c 'test -e /var/lib/mem0/history.db || /opt/mem0/venv/bin/python -c "import sqlite3;sqlite3.connect(\"/var/lib/mem0/history.db\").execute(\"PRAGMA journal_mode=WAL\")"'
  OPENAI_API_KEY=$GATEWAY_KEY sbx exec -e OPENAI_API_KEY -e OPENAI_BASE_URL=http://host.docker.internal:3001/v1 \
    -e MEM0_DEFAULT_LLM_MODEL=auto -e MEM0_DEFAULT_EMBEDDER_MODEL=auto -e MEM0_TELEMETRY=false \
    "$s" sh -c 'setsid nohup bash /tmp/start-fixed.sh > /tmp/mem0-start.log 2>&1 < /dev/null &'
  for i in $(seq 1 40); do
    [ "$(sbx exec "$s" sh -c 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8000/docs' 2>/dev/null)" = 200 ] && { echo "$s api ready"; return 0; }
    sleep 5
  done
  echo "$s api NOT ready"; sbx exec "$s" sh -c 'tail -5 /tmp/mem0-start.log'; return 1
}

echo "=== mem0-e on fresh storage"
sbx create --name mem0-e --memory 4g --cpus 4 --mount "$FRESH:/var/lib/mem0" "$KIT" 2>&1 | grep -E "Created|error"
sbx exec mem0-e true >/dev/null 2>&1
for i in $(seq 1 60); do sbx exec mem0-e test -s /var/lib/mem0/postgres/PG_VERSION 2>/dev/null && break; sleep 3; done; sleep 10
prep mem0-e || exit 1

echo "=== mem0-f on the same host dir"
sbx create --name mem0-f --memory 4g --cpus 4 --mount "$FRESH:/var/lib/mem0" "$KIT" 2>&1 | grep -E "Created|error"
sbx exec mem0-f true >/dev/null 2>&1; sleep 15
prep mem0-f || exit 1
for s in mem0-e mem0-f; do echo "$s: $(sbx exec $s pg_isready -h 127.0.0.1 2>&1)"; done

echo "=== both add $N memories through their own Mem0 API, concurrently"
for s in mem0-e mem0-f; do
  sbx cp tests/mem0-api-writer.py $s:/tmp/mem0-api-writer.py >/dev/null
  sbx exec $s sh -c "setsid nohup /opt/mem0/venv/bin/python /tmp/mem0-api-writer.py $s $N > /tmp/api-writer.out 2>&1 < /dev/null &"
done
for i in $(seq 1 120); do
  done_n=0; for s in mem0-e mem0-f; do sbx exec $s test -s /tmp/api-writer.out 2>/dev/null && done_n=$((done_n+1)); done
  [ $done_n -eq 2 ] && break; sleep 5
done
for s in mem0-e mem0-f; do echo "--- $s writer output"; sbx exec $s sh -c "tail -15 /tmp/api-writer.out 2>&1"; echo "--- $s server log: auth/provider/errors"; sbx exec $s sh -c "grep -i -E \"auth|401|403|provider|Traceback|Error\" /tmp/mem0-start.log | grep -v Deprecation | tail -8"; done
for s in mem0-e mem0-f; do echo "$s after: $(sbx exec $s pg_isready -h 127.0.0.1 2>&1)"; done

echo "=== stop both; restart Mem0 in e alone; which acknowledged memories exist?"
mkdir -p tmp
sbx cp mem0-f:/tmp/api-acked.txt tmp/api-acked-f.txt >/dev/null && sbx cp tmp/api-acked-f.txt mem0-e:/tmp/api-acked-f.txt >/dev/null
for s in mem0-e mem0-f; do sbx exec $s sh -c 'pkill -f "uvicorn app:app"; pkill -f "node server.js"; pg_ctl -D /var/lib/mem0/postgres stop -m fast >/dev/null 2>&1; pkill -x postgres; sleep 2; true'; done
prep mem0-e
sbx exec mem0-e sh -c 'grep -E "PANIC|recovery|redo|contrecord" /var/lib/mem0/postgres.log | tail -4'
sbx cp tests/mem0-api-verify.py mem0-e:/tmp/mem0-api-verify.py >/dev/null
sbx exec mem0-e /opt/mem0/venv/bin/python /tmp/mem0-api-verify.py mem0-e=/tmp/api-acked.txt mem0-f=/tmp/api-acked-f.txt

echo "=== cleanup"
if [ "${KEEP:-0}" = 1 ]; then echo "KEEP=1: sandboxes left for inspection"; else sbx rm -f mem0-e mem0-f 2>&1 | tail -2; fi
