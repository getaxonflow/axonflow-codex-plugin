#!/usr/bin/env bash
# Codex runtime E2E: explain-decision (W2 — rule #1)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

trap codex_cleanup_mcp EXIT
codex_register_mcp

PROMPT="Call the mcp__${MCP_SERVER_NAME}__explain_decision tool with decision_id=\"runtime-e2e-fabricated-id-12345\". The platform will return a not-found / negative response because that decision does not exist. After receiving the tool result, output exactly 'SMOKE_RESULT: ' followed by a one-line JSON summary like SMOKE_RESULT: {\"dispatched\":true,\"not_found\":true}. Nothing else."

OUTPUT_FILE=$(mktemp -t axonflow-codex-explain.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"; codex_cleanup_mcp' EXIT

echo "--- Running codex exec (explain_decision, fabricated id) ---"
codex_exec_capture "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_mcp_started "$OUTPUT_FILE" "explain_decision"; then
  echo "PASS: Codex started the MCP tool call ($MCP_SERVER_NAME/explain_decision)"
else
  echo "FAIL: Codex did not start any MCP tool call to $MCP_SERVER_NAME/explain_decision"
  errors=$((errors + 1))
fi

if assert_mcp_completed "$OUTPUT_FILE" "explain_decision"; then
  echo "PASS: Codex MCP tool call completed (live stack answered with explanation)"
elif assert_mcp_failed "$OUTPUT_FILE" "explain_decision"; then
  # The fabricated decision_id triggers a 404, which Codex marks as
  # `(failed)`. That's still a successful runtime-path test — the call
  # was dispatched and the platform answered with a structured negative.
  # Only treat it as a real failure when the SMOKE_RESULT marker is
  # also missing (handled by the next assertion).
  echo "INFO: Codex marked the call (failed) — platform returned 404 for fabricated decision_id"
fi

if assert_smoke_result "$OUTPUT_FILE"; then
  echo "PASS: agent emitted SMOKE_RESULT marker (full pipeline executed)"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors runtime-path assertion(s) failed"
  echo "--- raw output ---"
  tail -20 "$OUTPUT_FILE"
  exit 1
fi
echo ""
echo "PASS: explain-decision — Codex agent dispatched explain_decision through MCP runtime end-to-end"
