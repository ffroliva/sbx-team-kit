#!/usr/bin/env bash
# Team-context kit: rules reach the agent, network allow-list holds, memory convention survives rm.
cd "$(dirname "$0")/.." && mkdir -p tmp/proj-a tmp/proj-b && echo "# project A" > tmp/proj-a/CLAUDE.md && echo "# sibling B" > tmp/proj-b/README.md
export MSYS_NO_PATHCONV=1
set -u
W="$(pwd -W)/tmp"; A="$W/proj-a"; B="$W/proj-b"; VA="/c${A#C:}"
x(){ echo "\$ ${*: -1}"; "$@" 2>&1 | tail -25; echo "[exit ${PIPESTATUS[0]}]"; }
echo "=== create with kit"; x sbx create --name poc-team docker.io/docker/sbx-kit-shell:1.0.0 --memory 2g --cpus 2 --kit ./kits/team-context "$A" "$B:ro"
echo "=== K1 team context reached the agent?"; x sbx exec poc-team sh -c 'ls -R /usr/share/sandbox/kit 2>&1 | head -20; for f in ~/AGENTS.md ~/CLAUDE.md '"$VA"'/../AGENTS.md /home/agent/workspace/AGENTS.md; do [ -f "$f" ] && { echo "--- $f"; head -40 "$f"; }; done; grep -rl "Team rules" / --include=*.md 2>/dev/null | head'
echo "=== K2 network: maven, github ssh, github https, unlisted"; x sbx exec poc-team sh -c 'curl -s -o /dev/null -w "maven %{http_code}\n" --max-time 10 https://repo.maven.apache.org/maven2/; curl -s -o /dev/null -w "github %{http_code}\n" --max-time 10 https://github.com/; (timeout 8 bash -c "exec 3<>/dev/tcp/github.com/22 && head -c 20 <&3" && echo " ssh22 open") || echo "ssh22 blocked"; curl -s -o /dev/null -w "example.org %{http_code}\n" --max-time 10 https://example.org/'
echo "=== K3 memory convention survives rm"; x sbx exec poc-team sh -c "mkdir -p $VA/docs && echo '2026-10-26 proj-a builds with mvnw — because CI uses it' >> $VA/docs/agent-memory.md"
sbx rm -f poc-team >/dev/null
x sbx create --name poc-team2 docker.io/docker/sbx-kit-shell:1.0.0 --memory 2g --cpus 2 --kit ./kits/team-context "$A"
x sbx exec poc-team2 cat "$VA/docs/agent-memory.md"
echo "=== LOGS"; x sbx policy log poc-team --limit 30
sbx rm -f poc-team2 >/dev/null; rm -rf tmp; sbx ls
