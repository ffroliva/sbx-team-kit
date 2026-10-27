set -u
W="$(pwd -W)"; A="$W/proj-a"; B="$W/proj-b"
VA="/c${A#C:}"; VB="/c${B#C:}"
x(){ echo "\$ ${*: -1}"; "$@" 2>&1 | tail -8; echo "[exit ${PIPESTATUS[0]}]"; }
sbx create --name poc-a --quiet shell "$A" "$B:ro"
echo "=== S3 ro context"; x sbx exec poc-a sh -c "cat $VB/README.md; echo hi > $VB/should-fail.txt; echo hi > $VA/written-by-sandbox.txt"; ls proj-a proj-b
echo "=== S2 write memory"; x sbx exec poc-a sh -c 'mkdir -p ~/.claude/projects/poc/memory && echo "learned: proj-a uses X" > ~/.claude/projects/poc/memory/MEMORY.md'
echo "=== S4 stop/start"; sbx stop poc-a >/dev/null; x sbx exec poc-a sh -c 'cat ~/.claude/projects/poc/memory/MEMORY.md'
echo "=== S6 rm/recreate"; sbx rm -f poc-a >/dev/null; sbx create --name poc-a --quiet shell "$A" >/dev/null; x sbx exec poc-a sh -c 'cat ~/.claude/projects/poc/memory/MEMORY.md'
sbx rm -f poc-a >/dev/null; rm -f proj-a/written-by-sandbox.txt; sbx ls
