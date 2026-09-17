#!/usr/bin/env bash
# Codex runtime E2E: list-overrides OUTCOME TEST.
#
# list_overrides is a read, unchanged on AxonFlow v11.0.0. From v11.0.0 no
# override can be created, so none is seeded: the agent's reported count must
# equal the count the platform answers directly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

IDENTITY=(-H "X-User-Email: $AXONFLOW_E2E_USER_EMAIL")
OUTPUT_FILE=$(mktemp -t axonflow-codex-list.XXXXXX)
trap 'codex_cleanup_mcp; rm -f "$OUTPUT_FILE"' EXIT
codex_register_mcp_with_identity

errors=0

SERVER_COUNT=$(mcp_override_count "${IDENTITY[@]}")
if [ -z "$SERVER_COUNT" ]; then
  echo "FAIL: list_overrides answered no count when called directly (is the orchestrator up?)"
  exit 1
fi
echo "--- Server-side override count: $SERVER_COUNT ---"

PROMPT="Call the mcp__${MCP_SERVER_NAME}__list_overrides tool with include_revoked=true. Output exactly the literal text SMOKE_RESULT: followed by a single-line JSON with the count field from the response: SMOKE_RESULT: {\"count\":<the count>}."

echo "--- Running codex exec ... ---"
codex_exec_capture "$PROMPT" "$OUTPUT_FILE"

if assert_mcp_started "$OUTPUT_FILE" "list_overrides"; then
  echo "PASS: Codex started the list_overrides MCP tool call"
else
  echo "FAIL: Codex did not start the list_overrides MCP tool call"
  errors=$((errors + 1))
fi

if assert_smoke_result "$OUTPUT_FILE"; then
  echo "PASS: agent emitted SMOKE_RESULT marker"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  errors=$((errors + 1))
fi

SMOKE_LINE=$(smoke_line "$OUTPUT_FILE")
AGENT_COUNT=$(printf '%s' "$SMOKE_LINE" | jq -r '.count // empty' 2>/dev/null)
if [ -n "$AGENT_COUNT" ] && [ "$AGENT_COUNT" = "$SERVER_COUNT" ]; then
  echo "PASS: the agent's list_overrides count ($AGENT_COUNT) equals the server's ($SERVER_COUNT) — outcome verified"
else
  tail -10 "$OUTPUT_FILE" | sed 's/^/      /'
  echo "FAIL: the agent reported count '${AGENT_COUNT}', the server answers $SERVER_COUNT"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors outcome-test assertion(s) failed"
  exit 1
fi
echo ""
echo "PASS: list-overrides — the Codex agent read the recorded overrides end-to-end"
