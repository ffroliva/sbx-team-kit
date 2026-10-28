#!/usr/bin/env bash
# Host-side cold-start benchmark: stock shell-docker vs the python-e2e kit, each step timed. Usage: coldstart.sh <repo.tgz>
set -u
export GODEBUG=tlsmlkem=0
TGZ=$1; KIT=$(dirname "$0")/../kit/python-e2e
NET=(--allow-network github.com --allow-network 'pypi.org' --allow-network files.pythonhosted.org
     --allow-network '**.docker.com' --allow-network '**.docker.io' --allow-network '*.playwright.dev'
     --allow-network storage.googleapis.com --allow-network astral.sh --allow-network '**.astral.sh')
now() { date +%s%3N; }
t() { local name=$1; shift; local s=$(now); "$@" > /tmp/cs_$name.log 2>&1; local rc=$?
      printf '%-28s rc=%s ms=%s | %s
' "$name" "$rc" "$(( $(now) - s ))" "$(tail -1 /tmp/cs_$name.log | cut -c1-120)"; }
inbox() { sbx --cloud exec "$1" bash -c "$2"; }
# Inside the box: the steps a test VM pays before its first test, cold caches forced.
STEPS='set -u; cd ~; T(){ local n=$1; shift; local s=$(date +%s%3N); "$@" >/tmp/$n.log 2>&1; echo "  $n rc=$? ms=$(( $(date +%s%3N) - s )) | $(tail -1 /tmp/$n.log | cut -c1-100)"; }
echo "  uv-cache-before: $(du -sh ~/.cache/uv 2>/dev/null | cut -f1 || echo none)"; echo "  python: $(command -v python3) uv: $(uv --version 2>/dev/null)"
echo "  browsers: $(ls ${PLAYWRIGHT_BROWSERS_PATH:-~/.cache/ms-playwright} 2>/dev/null | tr "\n" " ")"
T untar tar -xzf ~/k.tgz -C ~; rm -rf ~/.cache/uv
T uv_sync_cold bash -c "cd ~/k && uv sync --frozen"
T pw_install bash -c "cd ~/k && uv run playwright install chromium"
T pw_launch bash -c "cd ~/k && uv run python -c \"from playwright.sync_api import sync_playwright as p; b=p().start().chromium.launch(); print(b.version)\""
T pg_pull docker pull -q postgres:17-alpine'
run() {  # run <label> <create args...>
  local label=$1; shift; echo "### $label"
  local s=$(now); local id; id=$(sbx --cloud create "$@" --cpus 2 --memory 4g --ttl 30m --on-timeout delete --no-progress "${NET[@]}" 2>&1 | grep -oE 'sbx_[a-z0-9]+' | head -1)
  printf '%-28s ms=%s | %s
' create "$(( $(now) - s ))" "${id:-FAILED}"; [ -n "$id" ] || return
  t first_exec inbox "$id" true
  t copy_repo sbx --cloud cp "$TGZ" "$id:/home/agent/k.tgz"
  inbox "$id" "$STEPS" 2>&1
  t delete sbx --cloud rm -f "$id"
}
run stock shell --name cs-stock
run kit-first "$KIT" --name cs-kit1
run kit-cached "$KIT" --name cs-kit2
echo COLDSTART DONE
