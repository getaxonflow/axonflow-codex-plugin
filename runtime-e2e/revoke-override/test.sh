#!/usr/bin/env bash
# Codex runtime E2E: revoke-override OUTCOME TEST (W2 — rule #1)
#
# Seeds a real override, drives the Codex agent to revoke it via the
# delete_override MCP tool, then asserts SERVER-SIDE that the override
# is in fact revoked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

trap codex_cleanup_mcp EXIT
codex_register_mcp

REASON_TAG="revoke-runtime-e2e-$(date +%s)-$RANDOM"
echo "--- Seeding override via MCP path (same tenant codex sees) ---"

SEED_ID=$(mcp_seed_override "sys_pii_email" "$REASON_TAG" 300)
if [ -z "$SEED_ID" ]; then
  echo "SKIP: pre-flight MCP create_override returned empty id"
  exit 0
fi
echo "--- Seeded override id: $SEED_ID ---"

OUTPUT_FILE=$(mktemp -t axonflow-codex-revoke.XXXXXX)
cleanup() {
  mcp_cleanup_override "$SEED_ID"
  codex_cleanup_mcp
  rm -f "${OUTPUT_FILE:-}"
}
trap cleanup EXIT

PROMPT="Call the mcp__${MCP_SERVER_NAME}__delete_override tool with override_id=\"$SEED_ID\". After the tool call, output exactly the literal text SMOKE_RESULT: followed by a single-line JSON like SMOKE_RESULT: {\"dispatched\":true,\"revoked\":true} on success."

echo "--- Running codex exec ... ---"
codex_exec_capture "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_mcp_started "$OUTPUT_FILE" "delete_override"; then
  echo "PASS: Codex started the MCP tool call"
else
  echo "FAIL: Codex did not start the MCP tool call"
  errors=$((errors + 1))
fi

# Outcome assertion — server-side state via the same unauth MCP path
# (must query the same tenant the override was created in).
SERVER_STATE=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{"name":"list_overrides","arguments":{"include_revoked":true}}}' \
  "$AXONFLOW_ENDPOINT/api/v1/mcp-server" \
  | jq -r '.result.content[0].text // ""' \
  | jq -r --arg id "$SEED_ID" '.overrides[]? | select(.id == $id) | .revoked_at // ""' 2>/dev/null)

if [ -n "$SERVER_STATE" ] && [ "$SERVER_STATE" != "null" ]; then
  echo "PASS: server-side state shows override $SEED_ID revoked at $SERVER_STATE — outcome verified"
else
  echo "FAIL: server-side state shows override $SEED_ID NOT revoked"
  errors=$((errors + 1))
fi

if assert_smoke_result "$OUTPUT_FILE"; then
  echo "PASS: agent emitted SMOKE_RESULT marker"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors outcome-test assertion(s) failed"
  exit 1
fi
echo ""
echo "PASS: revoke-override outcome — agent dispatched, platform revoked, server state confirmed"
