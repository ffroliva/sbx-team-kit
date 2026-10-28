#!/usr/bin/env bash
# Spec (volume@1): removing a sandbox MUST delete its volume storage; same name -> fresh storage.
# Docs (use-kits): local volumes keep data across sandbox removal; reattach when name, kit source and path match.
export MSYS_NO_PATHCONV=1
set -u
cd "$(dirname "$0")"
W=docker.io/docker/sbx-kit-claude:2.1.311
K=../kits/volume-probe
log(){ echo "[$(date -u +%T)] $*"; }
run(){ log "\$ $*"; "$@" 2>&1 | sed 's/^/    /'; log "rc=${PIPESTATUS[0]}"; }
mk(){ run sbx create --name "$1" --no-progress "$W" --kit "$K"; }
run sbx version
for r in 1 2; do
  log "===== round $r"
  mk voltest-$r
  run sbx exec voltest-$r sh -c "mount | grep voltest; ls -la /home/agent/voltest; echo round$r-\$(date +%s) > /home/agent/voltest/marker && cat /home/agent/voltest/marker"
  log "--- stop + exec (spec: MUST persist across restart)"
  run sbx stop voltest-$r
  run sbx exec voltest-$r cat /home/agent/voltest/marker
  log "--- remove, recreate same name and kit (spec: fresh; docs: reattached)"
  run sbx rm -f voltest-$r
  mk voltest-$r
  run sbx exec voltest-$r sh -c "ls -la /home/agent/voltest; cat /home/agent/voltest/marker"
  run sbx rm -f voltest-$r
  log "--- control: other name, same kit (both: fresh)"
  mk voltest-x$r
  run sbx exec voltest-x$r sh -c "ls -la /home/agent/voltest; cat /home/agent/voltest/marker"
  run sbx rm -f voltest-x$r
done
run sbx ls
