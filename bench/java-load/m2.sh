#!/usr/bin/env bash
set -u
K=C:/development/github/sbx-kits-contrib; WS=$(pwd)/ws; W=docker.io/docker/sbx-kit-claude:2.1.311
now(){ date +%s.%N; }; el(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }
echo "# $(date -u +%FT%TZ) $(sbx version) host=$(uname -m)"
mk(){ local b=$1; shift; sbx rm -f $b >/dev/null 2>&1; local t=$(now); if sbx create --no-progress --name $b "$@" "$WS" > tmp/$b.out 2>&1; then echo "ok $(el $t $(now))"; else echo "FAIL $(el $t $(now)) $(grep -m1 -iE 'error' tmp/$b.out | cut -c1-200)"; fi; }
jv(){ sbx exec $1 sh -c 'java -version 2>&1 | grep -m1 version || echo "java: not found"' 2>&1 | tr -d '\r' | tail -1; }
for r in 1 2; do
  echo "A  r$r sbx/claude:latest no kit: $(mk jl-a docker.io/sbx/claude:latest)"; sbx ls 2>/dev/null | grep -q jl-a && echo "   java: $(jv jl-a)"; sbx rm -f jl-a >/dev/null 2>&1
  echo "A+ r$r sbx/claude:latest + jdk kit: $(mk jl-ak --kit $K/jdk docker.io/sbx/claude:latest)"; sbx rm -f jl-ak >/dev/null 2>&1
  echo "B  r$r v3 workload + jdk mixin: $(mk jl-b --kit $K/jdk $W)"; t=$(now); v=$(jv jl-b); echo "   first java $(el $t $(now))s: $v"; sbx rm -f jl-b >/dev/null 2>&1
  echo "W  r$r v3 workload alone: $(mk jl-w $W)"
  sbx policy allow network --sandbox jl-w "api.adoptium.net,github.com,objects.githubusercontent.com,release-assets.githubusercontent.com" >/dev/null 2>&1
  sbx exec jl-w sh -c 's=$(date +%s.%N); mkdir -p ~/jdk; curl -fsSL https://api.adoptium.net/v3/binary/latest/25/ga/linux/x64/jdk/hotspot/normal/eclipse | tar -xz -C ~/jdk --strip-components=1 2>/dev/null; e=$(date +%s.%N); echo "   download: $(awk -v a=$s -v b=$e "BEGIN{printf \"%.1f\", b-a}")s $(du -sm ~/jdk|cut -f1)MB $(~/jdk/bin/java -version 2>&1 | grep -m1 version)"' 2>&1 | tail -1
  sbx exec jl-w sh -c 's=$(date +%s.%N); sudo apt-get -o DPkg::Lock::Timeout=180 update -qq >/dev/null 2>&1; c=$(apt-cache policy openjdk-25-jdk-headless default-jdk-headless 2>/dev/null | grep -E "^[a-z]|Candidate" | tr -s " " | paste -sd" "); sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq openjdk-25-jdk-headless >/tmp/apt.log 2>&1 || sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq default-jdk-headless >>/tmp/apt.log 2>&1; rc=$?; e=$(date +%s.%N); echo "   apt: rc=$rc $(awk -v a=$s -v b=$e "BEGIN{printf \"%.1f\", b-a}")s [$c] $(java -version 2>&1 | grep -m1 version || tail -2 /tmp/apt.log | tr "\n" " " | cut -c1-200)"' 2>&1 | tail -1
  sbx rm -f jl-w >/dev/null 2>&1
done
echo "# done $(date -u +%FT%TZ)"
