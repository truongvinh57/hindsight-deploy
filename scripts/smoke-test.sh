#!/usr/bin/env bash
# Hindsight deploy — smoke test (bash / WSL / Git Bash)
set -uo pipefail
API="${API_URL:-http://localhost:8888}"
CP="${CP_URL:-http://localhost:9999}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
pass() { echo "  [PASS] $1"; }
bad()  { echo "  [FAIL] $1 -> $2"; fail=$((fail+1)); }

[ -f "$DIR/.env" ] || { echo "missing $DIR/.env"; exit 1; }
HERMES="$(grep -E '^HERMES_API_KEY=' "$DIR/.env" | cut -d= -f2-)"
HARNESS="$(grep -E '^DEEPSEEK_HARNESS_API_KEY=' "$DIR/.env" | cut -d= -f2-)"

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "API $API — Control Plane $CP"

[ "$(code "$API/health")" = "200" ] && pass "GET /health" || bad "GET /health" "unexpected status"

[ "$(code -H 'Authorization: Bearer nope' "$API/v1/default/banks")" = "401" ] && pass "unknown key -> 401" || bad "unknown key -> 401" "expected 401"

[ "$(code -H "Authorization: Bearer $HERMES" "$API/v1/default/banks")" = "200" ] && pass "hermes-agent lists banks" || bad "hermes-agent lists banks" "expected 200"

DOC="smoke-$(date +%s)"
RET=$(curl -s -X POST "$API/v1/default/banks/smoke/memories/retain" \
  -H "Authorization: Bearer $HERMES" -H 'Content-Type: application/json' \
  -d "{\"items\":[{\"content\":\"The deployment codename is Sea Otter and the owner is hermes-agent.\",\"document_id\":\"$DOC\"}]}")
echo "$RET" | grep -qiE '"success"\s*:\s*false' && bad "hermes retain" "$RET" || pass "hermes retain"

LEAK=$(curl -s -X POST "$API/v1/default/banks/smoke/memories/recall" \
  -H "Authorization: Bearer $HARNESS" -H 'Content-Type: application/json' \
  -d '{"query":"What is the deployment codename?"}')
echo "$LEAK" | grep -qiE 'Sea Otter|codename' && bad "deepseek-harness isolation" "saw hermes-agent data" || pass "deepseek-harness isolation"

OWN=$(curl -s -X POST "$API/v1/default/banks/smoke/memories/recall" \
  -H "Authorization: Bearer $HERMES" -H 'Content-Type: application/json' \
  -d '{"query":"What is the deployment codename?"}')
echo "$OWN" | grep -qiE 'Sea Otter|codename' && pass "hermes recall" || bad "hermes recall" "returned nothing"

SCHEMAS=$(docker compose -f "$DIR/docker-compose.yml" exec -T db psql -U hindsight -d hindsight -tAc \
  "select nspname from pg_namespace where nspname like 'user_%' order by 1" 2>/dev/null | tr -d ' \r')
echo "$SCHEMAS" | grep -q user_hermes_agent && pass "schema user_hermes_agent" || bad "schema user_hermes_agent" "missing"
echo "$SCHEMAS" | grep -q user_deepseek_harness && pass "schema user_deepseek_harness" || bad "schema user_deepseek_harness" "missing"

docker compose -f "$DIR/docker-compose.yml" exec -T worker curl -fsS http://localhost:8889/health >/dev/null 2>&1 \
  && pass "worker health" || bad "worker health" "unreachable"

[ "$(code "$CP")" = "200" ] && pass "control plane" || bad "control plane" "unexpected status"
[ "$(code "http://localhost:8087/")" = "200" ] && pass "webhook sink" || bad "webhook sink" "unexpected status"

[ "$fail" -eq 0 ] && echo "All checks passed." || { echo "$fail check(s) failed"; exit 1; }
