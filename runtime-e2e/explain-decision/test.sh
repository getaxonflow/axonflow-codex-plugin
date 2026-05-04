#!/usr/bin/env bash
# Codex runtime E2E: explain-decision OUTCOME TEST (W2 — rule #1)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

trap codex_cleanup_mcp EXIT
codex_register_mcp

SEED_TAG="explain-runtime-e2e-$(date +%s)-$RANDOM"
echo "--- Triggering platform block via MCP path (same tenant codex sees) ---"

DECISION_ID=$(mcp_seed_block "$SEED_TAG")
if [ -z "$DECISION_ID" ]; then
  echo "SKIP: MCP seed block did not return a decision_id"
  exit 0
fi
echo "--- Minted decision_id: $DECISION_ID ---"
sleep 2

PROMPT="Call the mcp__${MCP_SERVER_NAME}__explain_decision tool with decision_id=\"$DECISION_ID\". From the tool result, extract the policy name. Output exactly the literal text SMOKE_RESULT: followed by a single-line JSON like SMOKE_RESULT: {\"explanation_present\":true,\"policy_name\":\"...\"} or SMOKE_RESULT: {\"explanation_present\":false}."

OUTPUT_FILE=$(mktemp -t axonflow-codex-explain.XXXXXX)
trap 'codex_cleanup_mcp; rm -f "$OUTPUT_FILE"' EXIT

echo "--- Running codex exec ... ---"
codex_exec_capture "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_mcp_started "$OUTPUT_FILE" "explain_decision"; then
  echo "PASS: Codex started the MCP tool call"
else
  echo "FAIL: Codex did not start the MCP tool call"
  errors=$((errors + 1))
fi

if assert_smoke_result "$OUTPUT_FILE"; then
  echo "PASS: agent emitted SMOKE_RESULT marker"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  errors=$((errors + 1))
fi

if assert_output_contains "$OUTPUT_FILE" "Authentication Bypass" \
  || assert_output_contains "$OUTPUT_FILE" "sys_sqli_admin_bypass"; then
  echo "PASS: agent's reply names the policy that fired — outcome verified"
else
  tail -10 "$OUTPUT_FILE" | sed 's/^/      /'
  echo "FAIL: agent did not name the policy from the explanation"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors outcome-test assertion(s) failed"
  exit 1
fi
echo ""
echo "PASS: explain-decision outcome — Codex agent fetched + surfaced a real platform decision end-to-end"
