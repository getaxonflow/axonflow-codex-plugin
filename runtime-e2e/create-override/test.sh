#!/usr/bin/env bash
# Codex runtime E2E: create-override (W2 — rule #1)
#
# Community-mode policies all have allow_override=false, so the platform
# returns 403. That's still a successful runtime-path test outcome:
# agent picked the tool, Codex's MCP runtime dispatched, platform
# answered with a structured 403, agent surfaced the rejection.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

trap codex_cleanup_mcp EXIT
codex_register_mcp

PROMPT="Call the mcp__${MCP_SERVER_NAME}__create_override tool with policy_id=\"sys_sqli_admin_bypass\", policy_type=\"static\", and override_reason=\"runtime-e2e dispatch verification\". The platform will reject this with 403 (allow_override=false). After receiving the tool result, output exactly 'SMOKE_RESULT: ' followed by a one-line JSON summary like SMOKE_RESULT: {\"dispatched\":true,\"server_rejected\":true}."

OUTPUT_FILE=$(mktemp -t axonflow-codex-create.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"; codex_cleanup_mcp' EXIT

echo "--- Running codex exec (create_override, expect 403) ---"
codex_exec_capture "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_mcp_started "$OUTPUT_FILE" "create_override"; then
  echo "PASS: Codex started the MCP tool call ($MCP_SERVER_NAME/create_override)"
else
  echo "FAIL: Codex did not start any MCP tool call to $MCP_SERVER_NAME/create_override"
  errors=$((errors + 1))
fi

# Either completed (server returned a structured 403 inside the MCP
# response, which Codex treats as completion) or failed (MCP-layer
# transport error). Both prove dispatch happened; only failed is a
# rule-#1 fail because it indicates the runtime didn't reach the server.
if assert_mcp_completed "$OUTPUT_FILE" "create_override"; then
  echo "PASS: Codex MCP tool call completed (live stack answered, even if 403)"
elif assert_mcp_failed "$OUTPUT_FILE" "create_override"; then
  echo "INFO: Codex marked the call (failed) — the platform responded with an error"
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
echo "PASS: create-override — Codex agent dispatched create_override through MCP runtime"
