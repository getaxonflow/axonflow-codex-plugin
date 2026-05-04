#!/usr/bin/env bash
# Codex runtime E2E: list-overrides OUTCOME TEST (W2 — rule #1)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

trap codex_cleanup_mcp EXIT
codex_register_mcp

REASON_TAG="list-runtime-e2e-$(date +%s)-$RANDOM"
echo "--- Seeding override via MCP path (same tenant codex sees) ---"

SEED_ID=$(mcp_seed_override "sys_pii_email" "$REASON_TAG" 300)
if [ -z "$SEED_ID" ]; then
  echo "SKIP: pre-flight MCP create_override returned empty id"
  exit 0
fi
echo "--- Seeded override id: $SEED_ID ---"

OUTPUT_FILE=$(mktemp -t axonflow-codex-list.XXXXXX)
cleanup() {
  mcp_cleanup_override "$SEED_ID"
  codex_cleanup_mcp
  rm -f "${OUTPUT_FILE:-}"
}
trap cleanup EXIT

PROMPT="Call the mcp__${MCP_SERVER_NAME}__list_overrides tool with no arguments. Look through the overrides array in the response and find the one whose override_reason field contains the substring '$REASON_TAG'. Output exactly the literal text SMOKE_RESULT: followed by a single-line JSON like SMOKE_RESULT: {\"found\":true,\"id\":\"...\"} if found, or SMOKE_RESULT: {\"found\":false} if not."

echo "--- Running codex exec ... ---"
codex_exec_capture "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_mcp_started "$OUTPUT_FILE" "list_overrides"; then
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

if assert_output_contains "$OUTPUT_FILE" '"found":true'; then
  echo "PASS: agent's list_overrides returned the seeded override — outcome verified"
else
  tail -10 "$OUTPUT_FILE" | sed 's/^/      /'
  echo "FAIL: agent did NOT find the seeded override"
  errors=$((errors + 1))
fi

if assert_output_contains "$OUTPUT_FILE" "$SEED_ID"; then
  echo "PASS: agent's reply contains the exact seeded override id ($SEED_ID)"
else
  echo "WARN: agent reply did not echo the exact UUID"
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors outcome-test assertion(s) failed"
  exit 1
fi
echo ""
echo "PASS: list-overrides outcome — Codex agent found a real seeded override end-to-end"
