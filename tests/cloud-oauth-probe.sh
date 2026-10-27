#!/bin/sh
# Cloud sandbox + `sbx --cloud secret set anthropic --oauth`: does Claude Code work, and if not, does
# a bearer placeholder instead of the image's apiKeyHelper fix it? (docker/sbx-releases#638)
# Prints no secret values: the VM only ever holds placeholders.
P='Reply with exactly: CLOUD-OK'

echo "== claude $(claude --version 2>/dev/null)"
echo "== settings.json apiKeyHelper: $(grep -o '"apiKeyHelper"[^,}]*' ~/.claude/settings.json 2>/dev/null || echo none)"
echo "== auth-related env (names only): $(env | grep -oE '^(SBX_CRED[A-Z_]*|ANTHROPIC[A-Z_]*|CLAUDE_CODE[A-Z_]*)=' | tr '\n' ' ')"
echo "== SBX_CRED_ANTHROPIC_MODE=${SBX_CRED_ANTHROPIC_MODE:-unset}"

echo "== 1. default claude -p (60 s cap)"
s=$(date +%s); out=$(timeout 60 claude -p "$P" --model haiku </dev/null 2>&1); rc=$?
echo "rc=$rc $(( $(date +%s)-s ))s :: $(echo "$out" | tail -2 | tr '\n' ' ' | cut -c1-200)"

echo "== 2. raw API shapes through the proxy"
H1='anthropic-version: 2023-06-01'; H2='content-type: application/json'
D='{"model":"claude-haiku-4-5","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}'
U=https://api.anthropic.com/v1/messages
echo "no auth + oauth beta:       $(curl -s -o /dev/null -m 30 -w '%{http_code}' $U -H "$H1" -H "$H2" -H 'anthropic-beta: oauth-2025-04-20' -d "$D")"
echo "x-api-key placeholder:      $(curl -s -o /dev/null -m 30 -w '%{http_code}' $U -H "$H1" -H "$H2" -H 'x-api-key: proxy-managed' -d "$D")"
echo "Bearer placeholder + beta:  $(curl -s -o /dev/null -m 30 -w '%{http_code}' $U -H "$H1" -H "$H2" -H 'anthropic-beta: oauth-2025-04-20' -H 'Authorization: Bearer proxy-managed' -d "$D")"

echo "== 3. workaround: drop apiKeyHelper, bearer placeholder via CLAUDE_CODE_OAUTH_TOKEN"
python3 - <<'EOF'
import json, pathlib
p = pathlib.Path.home() / ".claude" / "settings.json"
d = json.loads(p.read_text()) if p.exists() else {}
d.pop("apiKeyHelper", None)
p.write_text(json.dumps(d, indent=2))
print("apiKeyHelper removed")
EOF
for i in 1 2 3; do
  s=$(date +%s)
  out=$(env -u ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN=proxy-managed timeout 90 claude -p "$P" --model haiku </dev/null 2>&1); rc=$?
  echo "#$i rc=$rc $(( $(date +%s)-s ))s :: $(echo "$out" | tail -2 | tr '\n' ' ' | cut -c1-200)"
done
