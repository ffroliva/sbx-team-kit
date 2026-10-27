#!/usr/bin/env bash
# Memory persistence and sharing on sbx >= 0.50 — volume@1 vs host-mount@1. Cleans up after itself.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
WL=docker.io/docker/sbx-kit-shell:1.0.0
K="--kit ./kits/team-memory"
x(){ echo "\$ ${*: -1}"; "$@" 2>&1 | grep -v "already present\|downloaded" | tail -12; echo "[exit ${PIPESTATUS[0]}]"; }
sx(){ local s=$1; shift; x sbx exec "$s" sh -c "$*"; }
echo "=== M0 create mem-a"; x sbx create --name mem-a --memory 2g --cpus 2 $WL $K
echo "=== M1 write to volume and to shared mount"
sx mem-a 'echo "private: learned in mem-a" > ~/.claude/projects/MEMORY.md; echo "shared: learned in mem-a" >> ~/team-memory/MEMORY.md; ls -la ~/.claude/projects ~/team-memory; mount | grep -E "projects|team-memory"'
echo "=== M2 rm + recreate SAME name: volume should survive (0.50 notes)"
x sbx rm -f mem-a; x sbx create --name mem-a --memory 2g --cpus 2 $WL $K
sx mem-a 'cat ~/.claude/projects/MEMORY.md; cat ~/team-memory/MEMORY.md'
echo "=== M3 second sandbox mem-b, same kit: private volume should be empty, shared mount should be visible"
x sbx create --name mem-b --memory 2g --cpus 2 $WL $K
sx mem-b 'ls ~/.claude/projects; cat ~/.claude/projects/MEMORY.md; cat ~/team-memory/MEMORY.md'
echo "=== M4 where does the shared mount live on the host?"
find "$LOCALAPPDATA/DockerSandboxes" -name MEMORY.md 2>/dev/null | head
echo "=== cleanup"; x sbx rm -f mem-a mem-b; x sbx ls
