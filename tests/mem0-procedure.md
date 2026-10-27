# Mem0 kit (PR #126) — the exact procedure behind FINDINGS §1b

Run on sbx 0.50.0, Windows 11, 26 Oct 2026. Git Bash with `MSYS_NO_PATHCONV=1`.

## 0. Kit and gateway

```bash
git clone https://github.com/docker/sandbox-kit-spec && cd sandbox-kit-spec
git fetch origin pull/126/head && git checkout 8e0c42f
# Git for Windows checks scripts out CRLF; force LF or start.sh fails ("pipefail\r")
git -c core.autocrlf=false rm -q --cached -r . && git -c core.autocrlf=false reset -q --hard
KIT="$(cygpath -w "$PWD/examples/mem0")"
```

An OpenAI-compatible gateway on the host at `127.0.0.1:3001` (any one will do). Sandboxes reach it as
`host.docker.internal:3001`; the allow rule must name `localhost:3001`.

## 1. One sandbox — functional baseline

```bash
sbx create --name mem0-a --memory 4g --cpus 4 "$KIT"
sbx policy allow network --sandbox mem0-a localhost:3001

# Windows-host workarounds (FINDINGS §1b): socket off the host mount; history DB in WAL mode
sbx exec mem0-a sh -c 'sed "s#-k \$data#-k /tmp#" /opt/mem0/start.sh > /tmp/start-fixed.sh'
sbx exec mem0-a sh -c '/opt/mem0/venv/bin/python -c "import sqlite3;sqlite3.connect(\"/var/lib/mem0/history.db\").execute(\"PRAGMA journal_mode=WAL\")"'

export OPENAI_API_KEY=<gateway client key>
sbx exec -e OPENAI_API_KEY -e OPENAI_BASE_URL=http://host.docker.internal:3001/v1 \
  -e MEM0_DEFAULT_LLM_MODEL=auto -e MEM0_DEFAULT_EMBEDDER_MODEL=auto -e MEM0_TELEMETRY=false \
  mem0-a sh -c 'setsid nohup bash /tmp/start-fixed.sh > /tmp/mem0-start.log 2>&1 < /dev/null &'

sbx cp tests/mem0-functional.py mem0-a:/tmp/
sbx exec mem0-a /opt/mem0/venv/bin/python /tmp/mem0-functional.py 1536   # → FUNCTIONAL TEST PASSED
```

## 2. Second sandbox, same kit, same host mount

```bash
sbx create --name mem0-b --memory 4g --cpus 4 "$KIT"
sbx policy allow network --sandbox mem0-b localhost:3001
sbx exec mem0-b ls /var/lib/mem0                       # a's data is visible…
sbx exec mem0-b cat /var/lib/mem0/postgres/postmaster.pid   # …a's lock file is not
# start b exactly as a (step 1) → second postmaster on the same PGDATA; check postgres.log
```

## 3. Concurrent writes, then verify with one postmaster

```bash
START='pg_ctl -D /var/lib/mem0/postgres -l /tmp/pg.log -o "-h 127.0.0.1 -k /tmp -p 5432" start -w -t 90'
sbx exec mem0-a sh -c "$START; psql -h 127.0.0.1 -U agent -d postgres -c 'CREATE TABLE IF NOT EXISTS race(id bigserial primary key, who text, n int); TRUNCATE race'"
sbx exec mem0-b sh -c "$START"
for s in mem0-a mem0-b; do sbx cp tests/pg-writer.sh $s:/tmp/; done
for s in mem0-a mem0-b; do sbx exec $s sh -c "setsid nohup sh /tmp/pg-writer.sh $s 75 >/dev/null 2>&1 </dev/null &"; done
# after 75 s:
for s in mem0-a mem0-b; do sbx exec $s cat /tmp/pg-writer.out; done      # rows acknowledged
sbx exec mem0-a sh -c "$START; psql -h 127.0.0.1 -U agent -d postgres -c 'SELECT who, count(*) FROM race GROUP BY who'; pg_amcheck -h 127.0.0.1 -U agent -d postgres --heapallindexed"
```

Compare acknowledged rows with rows present.
