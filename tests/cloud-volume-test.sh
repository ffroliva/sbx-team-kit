#!/usr/bin/env bash
# N1: can two cloud sandboxes mount one volume at once, and if so, whose writes survive?
# Round 1 removes A then B; round 2 removes B then A. A reader box lists what survived each round.
# Git Bash rewrites /vol into a Windows path in arguments; v1 of this run lost its writes to that.
export MSYS_NO_PATHCONV=1
set -u
V=n1b-$(date +%H%M)
log(){ echo "[$(date -u +%T)] $*"; }
run(){ log "\$ $*"; "$@" 2>&1 | sed 's/^/    /'; log "rc=${PIPESTATUS[0]}"; }
mk(){ run sbx --cloud create --name "$1" --volume "$V:/vol" --on-timeout delete --ttl 30m --no-progress shell; }
rmbox(){ run sbx --cloud rm -f "$1"; }

run sbx version
run sbx --cloud volume create "$V"
for r in 1 2; do
  log "===== round $r"
  mk n1-a$r
  run sbx --cloud exec n1-a$r sudo chown agent:agent /vol
  mk n1-b$r                                  # the API says exclusive: expect a refusal here
  run sbx --cloud exec n1-b$r sudo chown agent:agent /vol
  run sbx --cloud exec n1-a$r sh -c "echo A$r > /vol/a$r.txt && ls -la /vol"
  run sbx --cloud exec n1-b$r sh -c "echo B$r > /vol/b$r.txt && ls -la /vol"   # does B see A's file live?
  if [ $r = 1 ]; then rmbox n1-a$r; sleep 20; rmbox n1-b$r; else rmbox n1-b$r; sleep 20; rmbox n1-a$r; fi
  sleep 30
  mk n1-r$r
  run sbx --cloud exec n1-r$r sh -c "ls -la /vol; cat /vol/*.txt"
  rmbox n1-r$r
  sleep 30
done
run sbx --cloud volume inspect "$V"
run sbx --cloud volume rm -f "$V"
run sbx --cloud ls
