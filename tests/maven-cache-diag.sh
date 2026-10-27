#!/usr/bin/env bash
# Follow-up to maven-cache-test.sh run 152802 (FINDINGS §6):
#  D) root cause of "IOException: File exists": 3 concurrent cold builds with -e, stack traces kept
#  W) a truly warm shared cache (WARM=dir known complete: an offline build passed from it), 3 concurrent builds, x2
set -u
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
REPO=${REPO:-C:/development/github/tiny-ledger-sbx-work}; R=/c/${REPO#C:/}
WL=docker.io/docker/sbx-kit-claude:2.1.311; TAG=$(date +%H%M%S); WARM=${WARM:?complete cache dir}
CLASSIC='openssl_conf = openssl_init\n[openssl_init]\nssl_conf = ssl_sect\n[ssl_sect]\nsystem_default = tls_sect\n[tls_sect]\nGroups = X25519:secp256r1:secp384r1\n'
BUILD='export OPENSSL_CONF=/tmp/classic-tls.cnf; cd '"$R"' && s=$(date +%s); ./mvnw -B -e verify > /tmp/mvn.log 2>&1; rc=$?;
echo "$0 rc=$rc $(( $(date +%s)-s ))s"; [ $rc = 0 ] || grep -m1 -A25 "^java.io\|^\[ERROR\] .*IOException" /tmp/mvn.log | grep -E "Exception|at (java|org.eclipse.aether|org.apache.maven)" | head -14'
mk(){ sbx create --name "$1" --clone --cpus 4 --memory 4g --kit ./kits/jdk25 --kit ./kits/maven-cache \
      --mount "$(cygpath -m "$2"):/home/agent/.m2/repository" $WL "$REPO" >/dev/null 2>&1 || echo "$1 CREATE FAILED"
      sbx exec "$1" sh -c "printf '$CLASSIC' > /tmp/classic-tls.cnf"; }
round(){ echo "=== $1"; local bs=(); for i in 1 2 3; do bs+=("md-$TAG-$2$i"); done
  for b in "${bs[@]}"; do mk "$b" "$3" & done; wait; local t=$(date +%s)
  for b in "${bs[@]}"; do sbx exec "$b" sh -c "$BUILD" "$b" & done; wait
  echo "--- wall $(( $(date +%s)-t ))s"; sbx rm -f "${bs[@]}" >/dev/null 2>&1; }
C=$PWD/tmp/m2-$TAG-diag; mkdir -p "$C"
round "D cold shared, -e stack traces" d "$C"
round "W1 warm shared (complete cache), 3 concurrent" w "$WARM"
round "W2 warm shared, repeat" x "$WARM"
echo "=== done $TAG"; sbx ls | tail -1
