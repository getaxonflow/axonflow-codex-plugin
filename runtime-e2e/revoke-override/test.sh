#!/usr/bin/env bash
# Codex runtime E2E: revoke-override (W2 — rule #1)
#
# Platform-side tool name is `delete_override`. Fabricated override_id
# returns 404; that proves dispatch.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

trap codex_cleanup_mcp EXIT
codex_register_mcp

PROMPT="Call the mcp__${MCP_SERVER_NAME}__delete_override tool with override_id=\"runtime-e2e-fabricated-override-id-12345\". The platform will return a 404 because that override does not exist. After receiving the tool result, output exactly 'SMOKE_RESULT: ' followed by a one-line JSON summary like SMOKE_RESULT: {\"dispatched\":true,\"not_found\":true}."

OUTPUT_FILE=$(mktemp -t axonflow-codex-revoke.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"; codex_cleanup_mcp' EXIT

echo "--- Running codex exec (delete_override, fabricated id, expect 404) ---"
codex_exec_capture "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_mcp_started "$OUTPUT_FILE" "delete_override"; then
  echo "PASS: Codex started the MCP tool call ($MCP_SERVER_NAME/delete_override)"
else
  echo "FAIL: Codex did not start any MCP tool call to $MCP_SERVER_NAME/delete_override"
  errors=$((errors + 1))
fi

if assert_mcp_completed "$OUTPUT_FILE" "delete_override"; then
  echo "PASS: Codex MCP tool call completed (live stack answered, even if 404)"
elif assert_mcp_failed "$OUTPUT_FILE" "delete_override"; then
  echo "INFO: Codex marked the call (failed) — platform error"
fi

if assert_smoke_result "$OUTPUT_FILE"; then
  echo "PASS: agent emitted SMOKE_RESULT marker"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors runtime-path assertion(s) failed"
  tail -20 "$OUTPUT_FILE"
  exit 1
fi
echo ""
echo "PASS: revoke-override — Codex agent dispatched delete_override through MCP runtime"
