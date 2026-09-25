#!/usr/bin/env bash
# Plugin runtime E2E: agent-callable MCP tools (W2)
#
# Exercises the governance tools the plugin exposes through `mcp.json` ->
# /api/v1/mcp-server: the read-side tools, and the override writes AxonFlow
# v11.0.0 retired (create_override and delete_override answer a tool error
# beginning "LEGACY_POLICY_WRITE_FROZEN: "). Drives the platform's MCP server
# directly via JSON-RPC tools/list + tools/call — the same protocol the
# Codex runtime speaks when an agent invokes one of these tools. Does
# NOT import any AxonFlow client code.
#
# This satisfies the W2 runtime-test gate: the test must invoke each
# tool through the runtime path, not by importing the SDK class.
#
# Usage:
#   AXONFLOW_ENDPOINT=http://localhost:8080 \
#   AXONFLOW_CLIENT_ID=demo-client \
#   AXONFLOW_CLIENT_SECRET=demo-secret \
#     bash tests/e2e/runtime-mcp-tools.sh

set -uo pipefail

: "${AXONFLOW_ENDPOINT:=http://localhost:8080}"
: "${AXONFLOW_CLIENT_ID:=demo-client}"
: "${AXONFLOW_CLIENT_SECRET:=demo-secret}"
# The override writes refuse a session with no per-user identity before they
# answer the retirement, so the session presents one. The agent keeps it only
# when AXONFLOW_TRUST_IDENTITY_HEADERS=true is set on it (a test posture).
: "${AXONFLOW_E2E_USER_EMAIL:=codex-runtime-e2e@axonflow-test.invalid}"
OVERRIDE_FROZEN_PREFIX="LEGACY_POLICY_WRITE_FROZEN: "

AUTH="Basic $(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)"
MCP_URL="$AXONFLOW_ENDPOINT/api/v1/mcp-server"

if ! curl -sSf -o /dev/null --max-time 5 "$AXONFLOW_ENDPOINT/health"; then
  echo "SKIP: AxonFlow stack not reachable at $AXONFLOW_ENDPOINT/health"
  echo "      Start one via axonflow-enterprise scripts/setup-e2e-testing.sh"
  exit 0
fi

# Initialize MCP session
INIT_RESP=$(curl -s -D /tmp/axonflow-mcp-headers.txt -X POST -H "Authorization: $AUTH" \
  -H "X-User-Email: $AXONFLOW_E2E_USER_EMAIL" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -H "MCP-Protocol-Version: 2025-06-18" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"axonflow-codex-runtime-e2e","version":"1.0.0"},"capabilities":{}}}' \
  "$MCP_URL")

SESSION_ID=$(grep -i "^mcp-session-id" /tmp/axonflow-mcp-headers.txt | awk '{print $2}' | tr -d '\r\n')
if [ -z "$SESSION_ID" ]; then
  echo "FAIL: MCP initialize did not return Mcp-Session-Id header"
  echo "      response: $INIT_RESP"
  exit 1
fi
echo "Session: $SESSION_ID"

call_mcp() {
  local id="$1"
  local body="$2"
  curl -s -X POST -H "Authorization: $AUTH" \
    -H "X-User-Email: $AXONFLOW_E2E_USER_EMAIL" \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    -H "MCP-Protocol-Version: 2025-06-18" \
    -H "Mcp-Session-Id: $SESSION_ID" \
    -d "$body" "$MCP_URL"
}

errors=0

# assert_override_frozen <label> <response>: the retired write answered a tool
# error beginning OVERRIDE_FROZEN_PREFIX. Any other answer, including one that
# merely carries "jsonrpc", fails.
assert_override_frozen() {
  local label="$1" response="$2" is_error text
  is_error=$(printf '%s' "$response" | jq -r '.result.isError // false' 2>/dev/null)
  text=$(printf '%s' "$response" | jq -r '.result.content[0].text // ""' 2>/dev/null)
  if [ "$is_error" = "true" ] && [ "${text#"$OVERRIDE_FROZEN_PREFIX"}" != "$text" ]; then
    echo "PASS: $label answered the retired write: $(printf '%s' "$text" | cut -c1-100)..."
    return 0
  fi
  echo "FAIL: $label did not answer a tool error beginning \"$OVERRIDE_FROZEN_PREFIX\" (isError=$is_error)"
  echo "      response: $(printf '%s' "$response" | cut -c1-600)"
  case "$text" in
    *"scoped to an individual user"*)
      echo "      The session reached the platform with no per-user identity: set"
      echo "      AXONFLOW_TRUST_IDENTITY_HEADERS=true on the agent (a test posture)."
      ;;
  esac
  errors=$((errors + 1))
  return 1
}

# 1) tools/list — verify W2 governance tools + V1.1 list_recent_decisions
# are advertised by the MCP server.
echo "--- 1/7 tools/list ---"
LIST_RESP=$(call_mcp 2 '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
for tool in search_audit_events explain_decision list_recent_decisions create_override delete_override list_overrides; do
  if echo "$LIST_RESP" | grep -q "\"name\":\"$tool\""; then
    echo "PASS: tools/list advertises $tool"
  else
    echo "FAIL: tools/list missing $tool"
    errors=$((errors + 1))
  fi
done

# 2) search_audit_events — empty audit log path
echo "--- 2/7 tools/call search_audit_events ---"
RESP=$(call_mcp 3 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_audit_events","arguments":{"limit":5}}}')
if echo "$RESP" | grep -q '"error"'; then
  echo "FAIL: search_audit_events returned error: $RESP"
  errors=$((errors + 1))
else
  echo "PASS: search_audit_events returned ok"
fi

# 3) list_overrides — empty list expected on fresh stack
echo "--- 3/7 tools/call list_overrides ---"
RESP=$(call_mcp 4 '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_overrides","arguments":{}}}')
if echo "$RESP" | grep -q '"error"'; then
  echo "FAIL: list_overrides returned error: $RESP"
  errors=$((errors + 1))
else
  echo "PASS: list_overrides returned ok"
fi

# 4) explain_decision — unknown decision_id, expect ok response (server returns
#    structured "no data" rather than RPC error)
echo "--- 4/7 tools/call explain_decision (unknown id) ---"
RESP=$(call_mcp 5 '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"explain_decision","arguments":{"decision_id":"runtime-e2e-no-such-decision"}}}')
if echo "$RESP" | grep -q '"jsonrpc"'; then
  echo "PASS: explain_decision dispatched (response shape valid)"
else
  echo "FAIL: explain_decision response malformed: $RESP"
  errors=$((errors + 1))
fi

# 5) create_override — retired from AxonFlow v11.0.0: a complete request
#    answers the tool error beginning "LEGACY_POLICY_WRITE_FROZEN: ".
echo "--- 5/7 tools/call create_override (retired) ---"
RESP=$(call_mcp 6 '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"create_override","arguments":{"policy_id":"sys_dangerous_destructive_fs","policy_type":"static","override_reason":"runtime-e2e retirement check"}}}')
assert_override_frozen "create_override" "$RESP"

# 6) delete_override — retired as well, whatever the id.
echo "--- 6/7 tools/call delete_override (retired) ---"
RESP=$(call_mcp 7 '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"delete_override","arguments":{"override_id":"runtime-e2e-no-such-override"}}}')
assert_override_frozen "delete_override" "$RESP"

# 7) list_recent_decisions (V1.1 #1982) — assert the over-cap path returns
# the wrapped V1 envelope with upgrade.buy_url. Locks in
# feedback_429_no_upgrade_hint_is_conversion_gap.md at the wire level.
echo "--- 7/7 tools/call list_recent_decisions (over-cap envelope) ---"
RESP=$(call_mcp 8 '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"list_recent_decisions","arguments":{"limit":10}}}')
RESP_TEXT=$(echo "$RESP" | jq -r '.result.content[0].text // empty')
if echo "$RESP_TEXT" | jq -e '.upgrade_required==true and .envelope.limit_type=="decision_list_size" and .envelope.upgrade.buy_url != null' >/dev/null 2>&1; then
  echo "PASS: list_recent_decisions over-cap returned wrapped V1 envelope"
else
  echo "FAIL: list_recent_decisions over-cap envelope shape wrong: $RESP_TEXT"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo "FAIL: $errors scenario(s) failed"
  exit 1
fi
echo "PASS: runtime-mcp-tools — the tools are advertised, the read-side tools dispatch, the retired writes answer LEGACY_POLICY_WRITE_FROZEN"
