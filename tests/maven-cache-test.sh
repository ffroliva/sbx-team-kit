#!/usr/bin/env bash
# Shared Maven cache across sandboxes (kits/maven-cache, host-mount@1): is it faster, and does it survive
# concurrent cold writers? FINDINGS §6. Real build: tiny-ledger ./mvnw -B verify, 3 sandboxes at once.
#  P0 control: private caches, cold          P1 shared cache, cold, all 3 write at once (x REPS, fresh dir each)
#  P2 integrity of the shared cache + an offline (-o) build from it in a fresh sandbox
#  P3 shared cache, warm
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
REPO=${REPO:-C:/development/github/tiny-ledger-sbx-work}
R=/${REPO/C:/c}; R=${R//\/\//\/}               # path of the clone inside the VM
WL=docker.io/docker/sbx-kit-claude:2.1.311     # v3 workload: mixins don't attach to built-in agent names
N=${N:-3}; REPS=${REPS:-2}; TAG=$(date +%H%M%S)
CLASSIC='openssl_conf = openssl_init\n[openssl_init]\nssl_conf = ssl_sect\n[ssl_sect]\nsystem_default = tls_sect\n[tls_sect]\nGroups = X25519:secp256r1:secp384r1\n'
BUILD='export OPENSSL_CONF=/tmp/classic-tls.cnf; cd '"$R"' && s=$(date +%s); ./mvnw -B $0 verify > /tmp/mvn.log 2>&1; rc=$?;
echo "$1 rc=$rc $(( $(date +%s)-s ))s"; [ $rc = 0 ] || { grep -E "ERROR|zip|corrupt|checksum" /tmp/mvn.log | head -6; tail -3 /tmp/mvn.log; }'

mk(){ # name [cache-dir]  -> create, print seconds
  local t=$(date +%s) extra=()
  [ -n "${2:-}" ] && extra=(--kit ./kits/maven-cache --mount "$(cygpath -m "$2"):/home/agent/.m2/repository")
  sbx create --name "$1" --clone --cpus 4 --memory 4g --kit ./kits/jdk25 "${extra[@]}" $WL "$REPO" >/tmp/mk-$1.log 2>&1 \
    || { echo "$1 CREATE FAILED"; tail -3 /tmp/mk-$1.log; }
  sbx exec "$1" sh -c "printf '$CLASSIC' > /tmp/classic-tls.cnf"
  echo "$1 created $(( $(date +%s)-t ))s"
}
phase(){ # label flags cache-dir|"" -> N sandboxes created, then built concurrently
  echo "=== $1"; local boxes=()
  for i in $(seq 1 $N); do boxes+=("mc-$TAG-$2$i"); done
  for b in "${boxes[@]}"; do mk "$b" "$4" & done; wait
  local t=$(date +%s)
  for b in "${boxes[@]}"; do sbx exec "$b" sh -c "$BUILD" "$3" "$b" & done; wait
  echo "--- $1: wall $(( $(date +%s)-t ))s for $N concurrent builds"
  LAST=("${boxes[@]}")
}
rmall(){ sbx rm -f "$@" >/dev/null 2>&1; }

phase "P0 control: private caches, cold" p "" ""; rmall "${LAST[@]}"
for r in $(seq 1 $REPS); do
  C=$PWD/tmp/m2-$TAG-$r; mkdir -p "$C"
  phase "P1.$r shared cache, cold, $N writers" s$r "" "$C"
  echo "--- P2.$r integrity (checked inside the VM, on the shared mount)"
  sbx cp tests/m2-check.py "${LAST[0]}":/tmp/m2-check.py >/dev/null && sbx exec "${LAST[0]}" python3 /tmp/m2-check.py
  rmall "${LAST[@]}"
  mk "mc-$TAG-o$r" "$C"; echo "--- P2.$r offline build from the shared cache:"; sbx exec "mc-$TAG-o$r" sh -c "$BUILD" "-o" "mc-$TAG-o$r"
  rmall "mc-$TAG-o$r"
done
phase "P3 shared cache, warm" w "" "$C"; rmall "${LAST[@]}"
echo "=== done $TAG; caches in tmp/m2-$TAG-*"; sbx ls | tail -2
