#!/usr/bin/env bash
# sbx memory/context POC — local only, shell agent, throwaway workspaces. Cleans up after itself.
set -u
POC="$(cd "$(dirname "$0")" && pwd -W 2>/dev/null || pwd)"
A="$POC/proj-a"; B="$POC/proj-b"
mkdir -p "$A" "$B"
echo "# project A rules" > "$A/CLAUDE.md"
echo "# project B — sibling repo, read-only context" > "$B/README.md"
AUDIT="$LOCALAPPDATA/DockerSandboxes/sandboxes/logs/auditkit"
START=$(date -u +%Y-%m-%dT%H:%M:%S)
step(){ echo; echo "=== $*"; }
x(){ echo "\$ $*"; "$@" 2>&1 | tail -15; echo "[exit ${PIPESTATUS[0]}]"; }

step "S0 create sandbox poc-a: proj-a rw + proj-b :ro"
x sbx create --name poc-a --quiet shell "$A" "$B:ro"

step "S1 what user-level agent config is visible inside?"
x sbx exec poc-a sh -c 'echo HOME=$HOME; ls -la ~ ~/.claude 2>&1 | head -20; mount | grep -E "virtiofs|proj" | head'

step "S2 write a 'memory' inside the sandbox (stands in for Claude auto-memory)"
x sbx exec poc-a sh -c 'mkdir -p ~/.claude/projects/poc/memory && echo "learned: proj-a uses X" > ~/.claude/projects/poc/memory/MEMORY.md && cat ~/.claude/projects/poc/memory/MEMORY.md'

step "S3 read-only context: read B ok, write B should fail, write A ok"
x sbx exec poc-a sh -c "cat '$B/README.md' 2>&1 || ls /; echo hi > '$B/should-fail.txt'; echo hi > '$A/written-by-sandbox.txt'"
ls "$B" "$A"

step "S4 stop/start: does the memory survive?"
x sbx stop poc-a
x sbx exec poc-a cat /home/agent/.claude/projects/poc/memory/MEMORY.md

step "S5 second sandbox poc-b on the same project: can it see poc-a's memory?"
x sbx create --name poc-b --quiet shell "$A"
x sbx exec poc-b sh -c 'ls ~/.claude/projects 2>&1; cat ~/.claude/projects/poc/memory/MEMORY.md 2>&1'

step "S6 rm and recreate poc-a: is the memory gone?"
x sbx rm -f poc-a
x sbx create --name poc-a --quiet shell "$A" "$B:ro"
x sbx exec poc-a cat /home/agent/.claude/projects/poc/memory/MEMORY.md

step "S7 network: allowed host vs a host outside the preset (expect approval/deny, not a hang)"
x sbx exec poc-a sh -c 'curl -s -o /dev/null -w "pypi %{http_code}\n" --max-time 10 https://pypi.org/simple/ ; curl -s -o /dev/null -w "example.org %{http_code}\n" --max-time 10 https://example.org/ ; echo done'

step "LOGS: sbx policy log (both sandboxes)"
x sbx policy log poc-a --limit 20
x sbx policy log poc-b --limit 20

step "LOGS: audit events since $START for poc-*"
python - "$AUDIT" "$START" <<'EOF'
import json,glob,sys,collections
d,start=sys.argv[1],sys.argv[2]
c=collections.Counter()
for f in glob.glob(d+'/*.jsonl'):
    for l in open(f,encoding='utf-8'):
        try:e=json.loads(l)
        except:continue
        if e.get('timestamp','')[:19]>=start and str(e.get('sandbox_id','')).startswith('poc-'):
            c[(e['sandbox_id'],e.get('category'),e.get('action_type'),e.get('decision'),e.get('resource_id'),e.get('policy_rule'))]+=1
for k,v in sorted(c.items(),key=lambda kv:str(kv[0])): print(v,k)
print('total',sum(c.values()))
EOF

step "CLEANUP"
x sbx rm -f poc-a poc-b
x sbx ls
