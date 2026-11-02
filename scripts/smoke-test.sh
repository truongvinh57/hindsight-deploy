#!/usr/bin/env bash
# Hindsight deploy - smoke test (Linux / macOS / WSL / Git Bash)
#
#   ./scripts/smoke-test.sh
#
# Reads .env for the tenant keys, then checks health, auth, schema isolation and
# that a retain/recall round trip actually works. Exits non-zero on failure.
set -uo pipefail

API="${API_URL:-http://localhost:8888}"
CP="${CP_URL:-http://localhost:9999}"
SINK="${WEBHOOK_SINK_URL:-http://localhost:8087}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$DIR/.env"
COMPOSE_FILE="$DIR/docker-compose.yml"

fail=0
pass() { printf '  [PASS] %s\n' "$1"; }
bad()  { printf '  [FAIL] %s -> %s\n' "$1" "$2"; fail=$((fail + 1)); }

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (cp .env.example .env, then fill it)"; exit 1; }

# Read a key from .env without sourcing it (values may contain characters bash
# would interpret). Strips CR so a Windows checkout still parses.
env_get() {
  grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\r' \
    | sed -e 's/^"//' -e 's/"$//'
}

# Refuse to run against a stack booted from template placeholders: the :? guards
# in compose only catch a MISSING variable, not one that still says "change-me".
if grep -qE '=(change-me|sk-your-deepseek|sk-di-your|sk-or-v1-your|hk_change|dk_change|whsec_change)' "$ENV_FILE"; then
  echo "ERROR: $ENV_FILE still contains template placeholders - fill it in first."
  exit 1
fi

HERMES="$(env_get HERMES_API_KEY)"
HARNESS="$(env_get DEEPSEEK_HARNESS_API_KEY)"
PGUSER="${POSTGRES_USER:-$(env_get POSTGRES_USER)}"
PGUSER="${PGUSER:-hindsight}"
PGDB="${POSTGRES_DB:-$(env_get POSTGRES_DB)}"
PGDB="${PGDB:-hindsight}"

[ -n "$HERMES" ] && [ -n "$HARNESS" ] || { echo "HERMES_API_KEY / DEEPSEEK_HARNESS_API_KEY missing from .env"; exit 1; }
OPENROUTER="$(env_get OPENROUTER_API_KEY)"
[ -n "$OPENROUTER" ] || { echo "OPENROUTER_API_KEY missing from .env (required: the decision model, Jev, uses it)"; exit 1; }

# http_code <curl args...>
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 60 "$@"; }

echo "API $API - Control Plane $CP"

code="$(http_code "$API/health")"
[ "$code" = "200" ] && pass "GET /health" || bad "GET /health" "status $code"

code="$(http_code -H 'Authorization: Bearer nope' "$API/v1/default/banks")"
[ "$code" = "401" ] && pass "unknown key -> 401" || bad "unknown key -> 401" "expected 401, got $code"

code="$(http_code -H "Authorization: Bearer $HERMES" "$API/v1/default/banks")"
[ "$code" = "200" ] && pass "hermes-agent lists banks" || bad "hermes-agent lists banks" "expected 200, got $code"

DOC="smoke-$(date +%s)"
BODY="{\"items\":[{\"content\":\"The deployment codename is Sea Otter and the owner is hermes-agent.\",\"document_id\":\"$DOC\"}]}"
code="$(http_code -X POST "$API/v1/default/banks/smoke/memories" \
  -H "Authorization: Bearer $HERMES" -H 'Content-Type: application/json' -d "$BODY")"
[ "$code" = "200" ] && pass "hermes-agent retain" || bad "hermes-agent retain" "status $code"

# The bank does not exist in deepseek-harness's schema: 404 is isolation working.
harness_out="$(curl -s --max-time 120 -X POST "$API/v1/default/banks/smoke/memories/recall" \
  -H "Authorization: Bearer $HARNESS" -H 'Content-Type: application/json' \
  -d '{"query":"What is the deployment codename?"}')"
if printf '%s' "$harness_out" | grep -qiE 'Sea Otter|codename'; then
  bad "deepseek-harness is isolated" "leaked hermes-agent memories"
else
  pass "deepseek-harness is isolated"
fi

hermes_out="$(curl -s --max-time 120 -X POST "$API/v1/default/banks/smoke/memories/recall" \
  -H "Authorization: Bearer $HERMES" -H 'Content-Type: application/json' \
  -d '{"query":"What is the deployment codename?"}')"
if printf '%s' "$hermes_out" | grep -qiE 'Sea Otter|codename'; then
  pass "hermes-agent recalls its own memory"
else
  bad "hermes-agent recalls its own memory" "no matching memory returned"
fi

# Docker Desktop can install a "docker" shim in a distro where integration is
# off; the binary exists but fails, so probe the daemon rather than the PATH.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  schemas="$(docker compose -f "$COMPOSE_FILE" exec -T db psql -U "$PGUSER" -d "$PGDB" -tAc \
    "select nspname from pg_namespace where nspname like 'user_%' order by 1" 2>/dev/null | tr -d ' \r')"
  if printf '%s' "$schemas" | grep -q user_hermes_agent; then
    pass "schema user_hermes_agent"
  else
    bad "schema user_hermes_agent" "missing (got: $(printf '%s' "$schemas" | tr '\n' ' '))"
  fi
  if printf '%s' "$schemas" | grep -q user_deepseek_harness; then
    pass "schema user_deepseek_harness"
  else
    bad "schema user_deepseek_harness" "missing"
  fi

  # The runtime image ships no curl.
  if docker compose -f "$COMPOSE_FILE" exec -T worker /app/api/.venv/bin/python -c \
    "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8889/health', timeout=8).status==200 else 1)" \
    >/dev/null 2>&1; then
    pass "worker health"
  else
    bad "worker health" "unreachable"
  fi

  # Full-feature checks. Jev must be configured for the operations only a
  # decision model can do; recall must still rank with the reranker.
  dm="$(docker compose -f "$COMPOSE_FILE" exec -T api /app/api/.venv/bin/python -c \
    "from hindsight_api.config import get_config; d=get_config().decision_model_config('consolidation'); print('none' if d is None else d.provider)" \
    2>/dev/null | tr -d ' \r')"
  [ "$dm" = "typesafe" ] && pass "decision model (Jev) configured" || bad "decision model (Jev) configured" "provider is '$dm', expected typesafe"

  rec="$(docker compose -f "$COMPOSE_FILE" exec -T api /app/api/.venv/bin/python -c \
    "from hindsight_api.config import get_config; c=get_config(); d=c.decision_model_config('recall'); print(('none' if d is None else d.provider) + ' ' + c.reranker_provider)" \
    2>/dev/null | tr -d ' \r')"
  [ "$rec" = "none cohere" ] && pass "recall ranks with the reranker" || bad "recall ranks with the reranker" "got '$rec', expected 'none cohere'"
else
  echo "  [SKIP] schema + worker checks (no docker CLI in this shell; from WSL enable Docker Desktop integration)"
fi

# The control plane answers 307 (redirect to /login) when the UI access key is set.
code="$(http_code -L "$CP")"
[ "$code" = "200" ] && pass "control plane" || bad "control plane" "expected 200 after redirect, got $code"

code="$(http_code "$SINK/")"
[ "$code" = "200" ] && pass "webhook sink" || bad "webhook sink" "status $code"

if [ "$fail" -ne 0 ]; then
  echo "$fail check(s) failed"
  exit 1
fi
echo "All checks passed."
