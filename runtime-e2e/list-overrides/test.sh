#!/usr/bin/env bash
# Codex runtime E2E: list-overrides (W2 — rule #1)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

trap codex_cleanup_mcp EXIT
codex_register_mcp

PROMPT="Call the mcp__${MCP_SERVER_NAME}__list_overrides tool with no arguments. After receiving the tool result, output exactly 'SMOKE_RESULT: ' followed by a one-line JSON summary like SMOKE_RESULT: {\"count\":N}."

OUTPUT_FILE=$(mktemp -t axonflow-codex-listov.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"; codex_cleanup_mcp' EXIT

echo "--- Running codex exec (list_overrides) ---"
codex_exec_capture "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_mcp_started "$OUTPUT_FILE" "list_overrides"; then
  echo "PASS: Codex started the MCP tool call ($MCP_SERVER_NAME/list_overrides)"
else
  echo "FAIL: Codex did not start any MCP tool call to $MCP_SERVER_NAME/list_overrides"
  errors=$((errors + 1))
fi

if assert_mcp_completed "$OUTPUT_FILE" "list_overrides"; then
  echo "PASS: Codex MCP tool call completed"
elif assert_mcp_failed "$OUTPUT_FILE" "list_overrides"; then
  echo "FAIL: Codex MCP tool call failed"
  errors=$((errors + 1))
fi

if assert_smoke_result "$OUTPUT_FILE"; then
  echo "PASS: agent emitted SMOKE_RESULT marker"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  errors=$((errors + 1))
fi

# Verify response shape: list_overrides response has a `count` field.
if assert_output_contains "$OUTPUT_FILE" '"count"'; then
  echo "PASS: response carries count field — list_overrides shape verified"
else
  echo "FAIL: response missing count field"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors runtime-path assertion(s) failed"
  tail -20 "$OUTPUT_FILE"
  exit 1
fi
echo ""
echo "PASS: list-overrides — Codex agent dispatched list_overrides end-to-end"
