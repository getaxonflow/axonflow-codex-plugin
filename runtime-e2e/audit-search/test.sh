#!/usr/bin/env bash
# Codex runtime E2E: audit-search OUTCOME TEST (W2 — rule #1)
#
# Outcome verification, not just dispatch. Mints a real blocked decision through
# the same unauthenticated MCP path Codex uses (so it lands in the tenant Codex
# searches), drives a real Codex agent through search_audit_events, and asserts
# the agent's own final message reports the seeded decision.
#
# The seed is found by its decision_id. On AxonFlow v11.0.0 an audit entry's
# query field is a summary ("mcp check_policy: codex.Bash"), not the statement,
# so a marker placed in the statement cannot be found by text (measured).
#
# The prompt names the decision_id, so an agent could echo it back without
# searching. The outcome is therefore the entry's timestamp, which only the
# search result carries, compared exactly with the entry the suite finds itself.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

trap codex_cleanup_mcp EXIT
codex_register_mcp
echo "--- Registered Codex MCP server: $MCP_SERVER_NAME -> $AXONFLOW_ENDPOINT/api/v1/mcp-server"

SEED_TAG="w2-runtime-e2e-audit-$(date +%s)-$RANDOM"
echo "--- Seeding a blocked decision via the MCP path (same tenant codex sees): $SEED_TAG ---"
DECISION_ID=$(mcp_seed_block "$SEED_TAG")
if [ -z "$DECISION_ID" ]; then
  echo "FAIL: could not mint a blocked decision to search for"
  echo "      mcp_seed_block returned no decision_id for tag $SEED_TAG (it returns one only for a block)"
  echo "      endpoint: $AXONFLOW_ENDPOINT"
  exit 1
fi
echo "--- Seeded decision_id: $DECISION_ID ---"
sleep 2

# The seeded decision, found directly through the same tool the agent will call.
DIRECT_ENTRY=$(mcp_tool_call search_audit_events '{"limit":50}' \
  | jq -r '.result.content[0].text // ""' \
  | jq -c --arg d "$DECISION_ID" '[.entries[]? | select(.policy_details.decision_id == $d or .id == ("audit_" + $d))][0] // empty' 2>/dev/null)
DIRECT_TIMESTAMP=$(printf '%s' "$DIRECT_ENTRY" | jq -r '.timestamp // empty' 2>/dev/null)
if [ -z "$DIRECT_ENTRY" ] || [ -z "$DIRECT_TIMESTAMP" ]; then
  # Previously "SKIP:" + exit 0 (#87): success reported for precisely the
  # condition that makes the rest of this suite meaningless. If the seeded
  # decision never reaches the audit log, the agent-driven search below has
  # nothing to find, and a green result would say the audit trail works when
  # it does not.
  echo "FAIL: the seeded decision never landed in the audit log"
  echo "      decision_id: $DECISION_ID"
  echo "      endpoint:    $AXONFLOW_ENDPOINT"
  echo ""
  echo "      search_audit_events (limit 50) returned no entry for it, so the audit"
  echo "      write path or the search path is broken. Either is a finding; neither"
  echo "      is a reason to exit 0."
  exit 1
fi
echo "--- search_audit_events finds the seeded decision directly (timestamp $DIRECT_TIMESTAMP) ---"

PROMPT="Call the mcp__${MCP_SERVER_NAME}__search_audit_events tool with limit=50 to fetch recent audit events. Find the entry whose policy_details.decision_id is \"$DECISION_ID\" and report it. Output exactly the literal text SMOKE_RESULT: followed by a single-line JSON: SMOKE_RESULT: {\"decision_found\":<true or false>,\"timestamp\":\"<that entry's timestamp field, copied exactly, or empty>\",\"policy_decision\":\"<that entry's policy_decision, or empty>\"}."

OUTPUT_FILE=$(mktemp -t axonflow-codex-audit.XXXXXX)
trap 'codex_cleanup_mcp; rm -f "$OUTPUT_FILE"' EXIT

echo "--- Running codex exec ... ---"
codex_exec_capture "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_mcp_started "$OUTPUT_FILE" "search_audit_events"; then
  echo "PASS: Codex started the MCP tool call"
else
  echo "FAIL: Codex did not start the MCP tool call"
  errors=$((errors + 1))
fi

if assert_mcp_completed "$OUTPUT_FILE" "search_audit_events"; then
  echo "PASS: Codex MCP tool call completed"
elif assert_mcp_failed "$OUTPUT_FILE" "search_audit_events"; then
  echo "FAIL: Codex MCP tool call failed"
  errors=$((errors + 1))
fi

if assert_smoke_result "$OUTPUT_FILE"; then
  echo "PASS: agent emitted SMOKE_RESULT marker"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  errors=$((errors + 1))
fi

SMOKE_LINE=$(smoke_line "$OUTPUT_FILE")
FOUND=$(printf '%s' "$SMOKE_LINE" | jq -r '.decision_found // empty' 2>/dev/null)
FOUND_TIMESTAMP=$(printf '%s' "$SMOKE_LINE" | jq -r '.timestamp // empty' 2>/dev/null)
FOUND_DECISION=$(printf '%s' "$SMOKE_LINE" | jq -r '.policy_decision // empty' 2>/dev/null)
if [ "$FOUND" = "true" ] && [ "$FOUND_TIMESTAMP" = "$DIRECT_TIMESTAMP" ]; then
  echo "PASS: the agent's audit search found the seeded decision (timestamp $FOUND_TIMESTAMP, $FOUND_DECISION): a value only the search result carries — outcome verified"
else
  tail -10 "$OUTPUT_FILE" | sed 's/^/      /'
  echo "FAIL: the agent did NOT report the seeded decision's timestamp $DIRECT_TIMESTAMP (SMOKE_RESULT: ${SMOKE_LINE:-none})"
  errors=$((errors + 1))
fi
if [ "$FOUND_DECISION" = "blocked" ]; then
  echo "PASS: the agent reports the seeded decision as blocked"
else
  echo "FAIL: the agent reports policy_decision '${FOUND_DECISION}' for the seeded block"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors outcome-test assertion(s) failed"
  exit 1
fi
echo ""
echo "PASS: audit-search outcome — Codex agent found a real seeded decision end-to-end"
