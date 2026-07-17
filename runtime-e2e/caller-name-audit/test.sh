#!/usr/bin/env bash
# Codex runtime E2E: caller_name audit-payload OUTCOME test (#2912).
#
# This is an outcome test, not a dispatch test. It drives the plugin's REAL
# post-tool-audit.sh hook — the runtime component that reports every
# governed tool call to the platform's audit_tool_call MCP method — against
# a LIVE AxonFlow agent (no mocks), with the exact PostToolUse stdin JSON
# shape Codex sends, then reads the resulting canonical `audit_logs` row
# back from the platform DB and asserts:
#
#   1. policy_details->>'caller_name' = 'codex'  (the new, correctly-named
#      field the hook now sends — see scripts/post-tool-audit.sh)
#   2. policy_details ? 'tool_type' is FALSE      (the old field name must
#      be absent from newly-written rows; tool_type remains only a
#      deprecated legacy fallback on the platform side)
#
# Ref: getaxonflow/axonflow-enterprise#2912 (platform support landed in
# axonflow-enterprise PR #2953).
#
# Prereqs (skips cleanly otherwise):
#   AXONFLOW_ENDPOINT    self-hosted agent (default http://localhost:8080)
#   AXONFLOW_AUTH        pre-computed base64 Basic credential            [or]
#   AXONFLOW_E2E_ORG_ID + AXONFLOW_E2E_LICENSE_KEY  (enterprise org/license) [or]
#   AXONFLOW_CLIENT_ID + AXONFLOW_CLIENT_SECRET     (community; default
#                                                     demo-client/demo-secret)
#   AXONFLOW_E2E_DB_URL  psql-compatible URL to the platform DB (to read
#                        back audit_logs.policy_details — the audit-search
#                        API does not expose the raw policy_details column)
#   jq, curl, psql on PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
POST_HOOK="$PLUGIN_DIR/scripts/post-tool-audit.sh"

ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"

for bin in jq curl psql; do
  command -v "$bin" >/dev/null 2>&1 || { echo "SKIP: $bin not on PATH"; exit 0; }
done
if [ ! -x "$POST_HOOK" ]; then
  echo "FAIL: post-tool-audit.sh missing or not executable at $POST_HOOK"
  exit 1
fi
if ! curl -sSf -o /dev/null --max-time 5 "$ENDPOINT/health"; then
  echo "SKIP: AxonFlow agent not reachable at $ENDPOINT/health"
  exit 0
fi

# Resolve a Basic-auth credential (support all the shapes the sibling
# runtime-e2e suites use, so this test works against a community-mode
# stack or an enterprise-mode stack without editing the script).
AUTH="${AXONFLOW_AUTH:-}"
if [ -z "$AUTH" ] && [ -n "${AXONFLOW_E2E_ENTERPRISE_AUTH:-}" ]; then
  AUTH="$AXONFLOW_E2E_ENTERPRISE_AUTH"
fi
if [ -z "$AUTH" ] && [ -n "${AXONFLOW_E2E_ORG_ID:-}" ] && [ -n "${AXONFLOW_E2E_LICENSE_KEY:-}" ]; then
  AUTH="$(printf '%s:%s' "$AXONFLOW_E2E_ORG_ID" "$AXONFLOW_E2E_LICENSE_KEY" | base64 | tr -d '\n')"
fi
if [ -z "$AUTH" ]; then
  : "${AXONFLOW_CLIENT_ID:=demo-client}"
  : "${AXONFLOW_CLIENT_SECRET:=demo-secret}"
  AUTH="$(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64 | tr -d '\n')"
fi

DB_URL="${AXONFLOW_E2E_DB_URL:-}"
if [ -z "$DB_URL" ]; then
  echo "SKIP: AXONFLOW_E2E_DB_URL not set (needed to read back audit_logs.policy_details)"
  exit 0
fi

# Unique per-run tool name so the assertion can't collide with a prior row.
TOOL_NAME="e2eCallerNameAuditTool-$(date +%s)-$RANDOM"
echo "--- Driving post-tool-audit.sh for tool_name=$TOOL_NAME against $ENDPOINT ---"

export AXONFLOW_ENDPOINT="$ENDPOINT"
export AXONFLOW_AUTH="$AUTH"
export AXONFLOW_TELEMETRY=off

# Real PostToolUse stdin JSON — the exact shape Codex sends after a Bash
# tool call completes. post-tool-audit.sh reads this, backgrounds a
# fire-and-forget audit_tool_call POST carrying caller_name: "codex"
# (scripts/post-tool-audit.sh), then (separately) may scan the output for
# PII — irrelevant here, "echo hi" has none.
STDIN_JSON=$(jq -n --arg tn "$TOOL_NAME" \
  '{
    tool_name: $tn,
    tool_input: {command: "echo hi"},
    tool_response: {stdout: "hi", exitCode: 0}
  }')

echo "$STDIN_JSON" | "$POST_HOOK" >/dev/null 2>&1

query() { psql "$DB_URL" -tAc "$1" 2>/dev/null; }

# The audit write is fire-and-forget (backgrounded curl inside the hook,
# plus async flush on the platform side) — poll rather than sleep-once so
# a freshly-booted stack whose first flush cycle lands late doesn't flake.
wait_count() {
  local sql="$1" min="$2" n=0 c=0
  while [ "$n" -lt 20 ]; do
    c=$(query "$sql")
    c="${c:-0}"
    [ "$c" -ge "$min" ] && break
    n=$((n + 1))
    sleep 1
  done
  printf '%s' "$c"
}

errors=0

FOUND=$(wait_count "SELECT count(*) FROM audit_logs WHERE policy_details->>'tool_name' = '$TOOL_NAME';" 1)
if [ "${FOUND:-0}" -lt 1 ]; then
  echo "FAIL: no audit_logs row landed for tool_name=$TOOL_NAME within 20s"
  echo "      (either the hook could not authenticate against $ENDPOINT, or"
  echo "       the audit_tool_call write path is not flushing on this stack)"
  errors=$((errors + 1))
else
  echo "PASS: audit_logs row landed for tool_name=$TOOL_NAME (count=$FOUND)"

  CALLER=$(query "SELECT policy_details->>'caller_name' FROM audit_logs WHERE policy_details->>'tool_name' = '$TOOL_NAME' ORDER BY timestamp DESC LIMIT 1;")
  if [ "$CALLER" = "codex" ]; then
    echo "PASS: policy_details->>'caller_name' = 'codex'"
  else
    echo "FAIL: policy_details->>'caller_name' expected 'codex', got '$CALLER'"
    errors=$((errors + 1))
  fi

  HAS_TOOL_TYPE=$(query "SELECT policy_details ? 'tool_type' FROM audit_logs WHERE policy_details->>'tool_name' = '$TOOL_NAME' ORDER BY timestamp DESC LIMIT 1;")
  if [ "$HAS_TOOL_TYPE" = "f" ]; then
    echo "PASS: policy_details does NOT carry the legacy 'tool_type' key"
  else
    echo "FAIL: policy_details still carries 'tool_type' (got '$HAS_TOOL_TYPE') — #2912 regression"
    errors=$((errors + 1))
  fi
fi

echo "--- audit_logs.policy_details for this run ---"
query "SELECT policy_details FROM audit_logs WHERE policy_details->>'tool_name' = '$TOOL_NAME' ORDER BY timestamp DESC LIMIT 1;" || true

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors caller_name-audit assertion(s) failed"
  exit 1
fi

echo ""
echo "PASS: post-tool-audit.sh sends caller_name (not tool_type) end-to-end, verified against the real audit_logs table"
