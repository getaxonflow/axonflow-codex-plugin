#!/usr/bin/env bash
# Codex runtime E2E: delete_override is RETIRED from AxonFlow v11.0.0.
#
# From v11.0.0 no override can be created, so there is none to seed. Drives a
# real Codex agent to call delete_override, and asserts the retirement end to
# end: the platform answers the same call made directly with the
# LEGACY_POLICY_WRITE_FROZEN tool error, the agent surfaces that answer, and the
# recorded overrides are unchanged.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

IDENTITY=(-H "X-User-Email: $AXONFLOW_E2E_USER_EMAIL")
TARGET_ID="00000000-0000-4000-8000-00000000c0de"
OUTPUT_FILE=$(mktemp -t axonflow-codex-revoke.XXXXXX)
trap 'codex_cleanup_mcp; rm -f "$OUTPUT_FILE"' EXIT
codex_register_mcp_with_identity

errors=0

BASELINE_COUNT=$(mcp_override_count "${IDENTITY[@]}")
if [ -z "$BASELINE_COUNT" ]; then
  echo "FAIL: list_overrides answered no count before the run (is the orchestrator up?)"
  exit 1
fi
echo "--- Baseline override count: $BASELINE_COUNT ---"

DIRECT=$(mcp_tool_call delete_override "$(jq -nc --arg id "$TARGET_ID" '{override_id: $id}')" "${IDENTITY[@]}")
assert_mcp_override_frozen "delete_override (called directly)" "$DIRECT" || errors=$((errors + 1))

PROMPT="Call the mcp__${MCP_SERVER_NAME}__delete_override tool with override_id=\"$TARGET_ID\". After the tool call, output exactly the literal text SMOKE_RESULT: followed by a single-line JSON: SMOKE_RESULT: {\"dispatched\":true,\"revoked\":<true or false>,\"error_text\":\"<the first 60 characters of the tool's error text, or empty>\"}."

echo "--- Running codex exec ... ---"
codex_exec_capture "$PROMPT" "$OUTPUT_FILE"

if assert_mcp_started "$OUTPUT_FILE" "delete_override"; then
  echo "PASS: Codex started the delete_override MCP tool call"
else
  echo "FAIL: Codex did not start the delete_override MCP tool call"
  errors=$((errors + 1))
fi

if assert_smoke_result "$OUTPUT_FILE"; then
  echo "PASS: agent emitted SMOKE_RESULT marker"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  errors=$((errors + 1))
fi

if assert_last_message_contains "$OUTPUT_FILE" "$OVERRIDE_FROZEN_CODE"; then
  echo "PASS: the agent's final message surfaces $OVERRIDE_FROZEN_CODE"
else
  tail -10 "$OUTPUT_FILE" | sed 's/^/      /'
  echo "FAIL: the agent's final message does not surface $OVERRIDE_FROZEN_CODE"
  errors=$((errors + 1))
fi

AFTER_COUNT=$(mcp_override_count "${IDENTITY[@]}")
if [ "$AFTER_COUNT" = "$BASELINE_COUNT" ]; then
  echo "PASS: server-side override count unchanged ($BASELINE_COUNT -> $AFTER_COUNT)"
else
  echo "FAIL: server-side override count changed ($BASELINE_COUNT -> ${AFTER_COUNT:-no answer})"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors outcome-test assertion(s) failed"
  exit 1
fi
echo ""
echo "PASS: revoke-override — retired on v11: the platform answered $OVERRIDE_FROZEN_CODE, the agent surfaced it"
