#!/usr/bin/env bash
# Time to a working `java -version` in a local sbx sandbox, four ways, two rounds each.
# Usage: bash measure.sh <kits-contrib dir> <log>
set -u
K=$1; LOG=$2
WS=$(pwd)/ws; TMPD=$(pwd)/tmp
W=docker.io/docker/sbx-kit-claude:2.1.311
now() { date +%s.%N; }
el() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }
note() { echo "$*" | tee -a "$LOG"; }

run() { # name round create-args... -- java-setup-cmd
  local name=$1 round=$2; shift 2
  local args=() setup=""
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do args+=("$1"); shift; done
  [ "${1:-}" = "--" ] && { shift; setup="$*"; }
  local box="jl-$name-$round"
  sbx rm -f "$box" >/dev/null 2>&1
  local t0; t0=$(now)
  if ! sbx create --no-progress --name "$box" "${args[@]}" "$WS" > "$TMPD/jl-$box.create" 2>&1; then
    note "$name r$round CREATE-FAILED $(el "$t0" "$(now)") s: $(tail -2 $TMPD/jl-$box.create | tr '\n' ' ' | cut -c1-200)"
    return
  fi
  local t1; t1=$(now)
  local st=0
  if [ -n "$setup" ]; then sbx exec "$box" sh -c "$setup" > "$TMPD/jl-$box.setup" 2>&1 || st=$?; fi
  local t2; t2=$(now)
  local jv; jv=$(sbx exec "$box" sh -c 'java -version 2>&1 | grep -m1 version' 2>&1 | tr -d '\r' | head -1)
  local t3; t3=$(now)
  local du; du=$(sbx exec "$box" sh -c 'J=$(readlink -f "$(command -v java)" 2>/dev/null); [ -n "$J" ] && du -sm "$(dirname "$(dirname "$J")")" 2>/dev/null | cut -f1' 2>/dev/null | tr -d '\r')
  note "$name r$round create=$(el "$t0" "$t1")s setup=$(el "$t1" "$t2")s(rc=$st) first_java=$(el "$t2" "$t3")s total=$(el "$t0" "$t3")s jdk_mb=${du:-?} java='$jv'"
  [ "$st" != 0 ] && note "   setup tail: $(tail -3 $TMPD/jl-$box.setup | tr '\n' ' ' | cut -c1-300)"
  sbx rm -f "$box" >/dev/null 2>&1
}

note "# $(date -u +%FT%TZ) $(sbx version 2>&1 | head -1) host=$(uname -m)"
for r in 1 2; do
  run A "$r" docker.io/sbx/claude:latest
  run B "$r" --kit "$K/jdk" "$W"
  run C "$r" "$W" -- 'mkdir -p ~/jdk && curl -fsSL https://api.adoptium.net/v3/binary/latest/25/ga/linux/x64/jdk/hotspot/normal/eclipse | tar -xz -C ~/jdk --strip-components=1 && sudo ln -sf ~/jdk/bin/java /usr/local/bin/java'
  run D "$r" "$W" -- 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && (sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openjdk-25-jdk-headless || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq default-jdk-headless)'
done
note "# done $(date -u +%FT%TZ)"
