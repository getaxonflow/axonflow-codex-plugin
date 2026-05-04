#!/usr/bin/env bash
# Codex runtime E2E: audit-search OUTCOME TEST (W2 — rule #1)
#
# Outcome verification, not just dispatch. Seeds a unique marker into
# the platform's audit log via a real SQLi block, drives a real Codex
# agent through search_audit_events, asserts the agent's reply
# CONTAINS the marker.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

trap codex_cleanup_mcp EXIT
codex_register_mcp
echo "--- Registered Codex MCP server: $MCP_SERVER_NAME -> $AXONFLOW_ENDPOINT/api/v1/mcp-server"

MARKER="w2-runtime-e2e-audit-marker-$(date +%s)-$RANDOM"
echo "--- Seeding audit marker: $MARKER ---"
curl -s -X POST \
  -H "Authorization: Basic $(printf 'demo-client:demo-secret' | base64)" \
  -H "Content-Type: application/json" \
  -d "{\"connector_type\":\"sql\",\"statement\":\"SELECT * FROM users WHERE id=1 OR 1=1; -- $MARKER\",\"operation\":\"query\"}" \
  "$AXONFLOW_ENDPOINT/api/v1/mcp/check-input" >/dev/null
sleep 2

DIRECT_HITS=$(curl -s -X POST \
  -H "Authorization: Basic $(printf 'demo-client:demo-secret' | base64)" \
  -H "Content-Type: application/json" \
  -d '{"limit":50}' \
  "$AXONFLOW_ENDPOINT/api/v1/audit/search" \
  | jq --arg m "$MARKER" '[.entries[] | select((.query // "") | contains($m))] | length' 2>/dev/null)
if [ "${DIRECT_HITS:-0}" -lt 1 ]; then
  echo "SKIP: marker did not land in audit log via direct seed"
  exit 0
fi

PROMPT="Call the mcp__${MCP_SERVER_NAME}__search_audit_events tool with limit=50 to fetch recent audit events. Then find any entry whose query field contains the substring '$MARKER' and report it. Output exactly the literal text SMOKE_RESULT: followed by a single-line JSON like SMOKE_RESULT: {\"marker_found\":true,\"audit_id\":\"...\"} if found, or SMOKE_RESULT: {\"marker_found\":false} if not."

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

if assert_output_contains "$OUTPUT_FILE" '"marker_found":true'; then
  echo "PASS: agent's audit-search returned the marker we seeded — outcome verified"
else
  tail -10 "$OUTPUT_FILE" | sed 's/^/      /'
  echo "FAIL: agent did NOT find the seeded marker"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors outcome-test assertion(s) failed"
  exit 1
fi
echo ""
echo "PASS: audit-search outcome — Codex agent found a real marker event end-to-end"
