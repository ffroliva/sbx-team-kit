#!/usr/bin/env bash
# Code-transfer spike: a persistent volume holds a git clone and the uv cache; each run ships a small delta bundle.
# Usage: volume.sh <repo-with-.git.tgz> <delta.bundle> <sha>   (run from the folder holding both files)
set -u
export GODEBUG=tlsmlkem=0
TGZ=$1; BUNDLE=$2; SHA=$3; VOL=fleet-base
NET=(--allow-network github.com --allow-network pypi.org --allow-network files.pythonhosted.org
     --allow-network '**.docker.com' --allow-network '**.docker.io' --allow-network '**.astral.sh')
now() { date +%s%3N; }
t() { local name=$1; shift; local log="vol_${name//:/_}.log"; local s=$(now); "$@" > "$log" 2>&1; local rc=$?
      printf '%-24s rc=%s ms=%s | %s\n' "$name" "$rc" "$(( $(now) - s ))" "$(tail -1 "$log" | cut -c1-110)"; }
mk() { sbx --cloud create shell --name "$1" --cpus 8 --memory 16g --ttl 30m --on-timeout delete --no-progress \
       --volume "$VOL:/vol" "${NET[@]}" 2>&1 | grep -oE 'sbx_[a-z0-9]+' | head -1; }

echo "### populate the volume once"
t vol_create sbx --cloud volume create "$VOL"
s=$(now); P=$(mk vol-populate); printf '%-24s ms=%s | %s\n' create_with_volume "$(( $(now) - s ))" "${P:-FAILED}"
[ -n "$P" ] || exit 1
t cp_tgz_once sbx --cloud cp "$TGZ" "$P:/home/agent/k.tgz"
t populate sbx --cloud exec "$P" bash -c 'set -e; ls -ld /vol; sudo -n chown "$(id -u):$(id -g)" /vol; tar -xzf ~/k.tgz -C /vol && cd /vol/k && UV_CACHE_DIR=/vol/uv-cache uv sync --frozen -q && du -sh /vol/k /vol/uv-cache | tr "\n" " "'
t rm_snapshot sbx --cloud rm -f "$P"

echo "### two runs at once, each from the volume plus the delta"
run() {
  local name=$1; local s=$(now); local id; id=$(mk "$name")
  printf '%-24s ms=%s | %s\n' "$name:create" "$(( $(now) - s ))" "${id:-FAILED}"; [ -n "$id" ] || return
  t "$name:cp_bundle" sbx --cloud cp "$BUNDLE" "$id:/home/agent/delta.bundle"
  t "$name:checkout" sbx --cloud exec "$id" bash -c "set -e; s=\$(date +%s%3N); git clone -q --no-hardlinks /vol/k ~/k; c=\$(date +%s%3N); cd ~/k && git fetch -q ~/delta.bundle 'refs/heads/*:refs/remotes/delta/*' && git checkout -q $SHA && echo clone_ms=\$((c-s)) fetch_ms=\$((\$(date +%s%3N)-c)) head=\$(git rev-parse --short HEAD)"
  t "$name:uv_sync_warm" sbx --cloud exec "$id" bash -c 'cd ~/k && UV_CACHE_DIR=/vol/uv-cache uv sync --frozen 2>&1 | tail -1'
  t "$name:pg_pull" sbx --cloud exec "$id" docker pull -q postgres:17-alpine
  t "$name:rm" sbx --cloud rm -f "$id"
}
run vol-a > vol_a.out 2>&1 &
run vol-b > vol_b.out 2>&1 &
wait; cat vol_a.out vol_b.out
echo VOLUME DONE
