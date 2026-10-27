#!/usr/bin/env bash
# Mechanism probe for FINDINGS §1/§1b: across two sandboxes on one host-mount@1,
#  V) how soon does a file created in one become visible in the other (new file, rewritten file)?
#  L) does a lock held in one block the other? flock(2) and POSIX fcntl locks.
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
WL=docker.io/docker/sbx-kit-shell:1.0.0
K="--kit ./kits/team-memory"
D=/home/agent/team-memory
x(){ echo "\$ ${*: -1}" | cut -c1-160; "$@" 2>&1 | grep -v "already present\|downloaded" | tail -${TAILN:-6}; }
for s in lv-a lv-b; do x sbx create --name $s --memory 1g --cpus 1 $WL $K; done
for s in lv-a lv-b; do sbx exec $s true >/dev/null 2>&1; done
RUN=$(date +%H%M%S)  # unique names per run: nothing to clean up on the shared mount

echo "=== V1 new file: a creates, b looks at t=0..30s"
sbx exec lv-a sh -c "echo 4242 > $D/vis-new-$RUN; date +%T.%N | cut -c1-12"
for t in 0 1 2 5 10 30; do
  [ $t -gt 0 ] && sleep $(( t - ${prev:-0} )); prev=$t
  echo "t=${t}s b: $(sbx exec lv-b sh -c "cat $D/vis-new-$RUN 2>&1 | head -1; ls $D | grep -c vis-new-$RUN | sed 's/^/listed=/'" | tr '\n' ' ')"
done

echo "=== V2 rewrite in place (what postmaster does to postmaster.pid): a writes v1, b reads, a writes v2, b reads"
sbx exec lv-a sh -c "echo v1 > $D/vis-rw-$RUN"; sleep 2
echo "b reads: $(sbx exec lv-b cat $D/vis-rw-$RUN 2>&1)"
sbx exec lv-a sh -c "echo v2-longer-content > $D/vis-rw-$RUN"
for t in 0 2 10; do sleep $t; echo "after ${t}s b reads: $(sbx exec lv-b cat $D/vis-rw-$RUN 2>&1)"; done

echo "=== V3 file created by b while a has the directory open: does a see it?"
sbx exec lv-b sh -c "echo from-b > $D/vis-from-b-$RUN"
for t in 0 2 10; do sleep $t; echo "after ${t}s a: $(sbx exec lv-a sh -c "cat $D/vis-from-b-$RUN 2>&1")"; done

echo "=== L1 flock: a holds an exclusive flock 25s; b tries non-blocking"
sbx exec lv-a sh -c "setsid nohup flock -x $D/lock-flock-$RUN -c 'sleep 25' >/dev/null 2>&1 </dev/null &"; sleep 3
echo "a holds it (self-check in a): $(sbx exec lv-a sh -c "flock -n -x $D/lock-flock-$RUN -c 'echo GOT-IT' || echo blocked")"
echo "b tries:                      $(sbx exec lv-b sh -c "flock -n -x $D/lock-flock-$RUN -c 'echo GOT-IT' || echo blocked")"

echo "=== L2 POSIX fcntl lock (what SQLite uses): a holds 25s; b tries non-blocking"
for s in lv-a lv-b; do sbx cp tests/fcntl-lock.py $s:/tmp/fl.py >/dev/null 2>&1; sbx exec -u root $s sh -c 'command -v python3 >/dev/null || (apt-get -qq update && apt-get -qq install -y python3 >/dev/null)'; done
sleep 25
sbx exec lv-a sh -c "setsid nohup python3 /tmp/fl.py $D/lock-fcntl-$RUN 25 >/tmp/fl.out 2>&1 </dev/null &"; sleep 3
echo "a holder:                     $(sbx exec lv-a cat /tmp/fl.out)"
echo "a second process in a:        $(sbx exec lv-a python3 /tmp/fl.py $D/lock-fcntl-$RUN)"
echo "b tries:                      $(sbx exec lv-b python3 /tmp/fl.py $D/lock-fcntl-$RUN)"

echo "=== cleanup"; sbx rm -f lv-a lv-b >/dev/null 2>&1; sbx ls | tail -1
