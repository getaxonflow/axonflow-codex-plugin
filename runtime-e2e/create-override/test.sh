#!/usr/bin/env bash
# Codex runtime E2E: create_override is RETIRED from AxonFlow v11.0.0.
#
# Drives a real Codex agent to call create_override on an MCP session that
# presents a per-user identity, and asserts the retirement end to end: the
# platform answers the same call made directly with the LEGACY_POLICY_WRITE_FROZEN
# tool error, the agent surfaces that answer, and no override was created.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

IDENTITY=(-H "X-User-Email: $AXONFLOW_E2E_USER_EMAIL")
REASON_TAG="create-runtime-e2e-$(date +%s)-$RANDOM"
OUTPUT_FILE=$(mktemp -t axonflow-codex-create.XXXXXX)
DIRECT_ID=""
cleanup() {
  # Only a platform that still creates overrides (older than v11.0.0) leaves one.
  if [ -n "$DIRECT_ID" ]; then
    mcp_tool_call delete_override "$(jq -nc --arg id "$DIRECT_ID" '{override_id: $id}')" "${IDENTITY[@]}" >/dev/null 2>&1 || true
  fi
  codex_cleanup_mcp
  rm -f "$OUTPUT_FILE"
}
trap cleanup EXIT
codex_register_mcp_with_identity

errors=0

BASELINE_COUNT=$(mcp_override_count "${IDENTITY[@]}")
if [ -z "$BASELINE_COUNT" ]; then
  echo "FAIL: list_overrides answered no count before the run (is the orchestrator up?)"
  exit 1
fi
echo "--- Baseline override count: $BASELINE_COUNT ---"

# The platform's answer to the same call, made directly: the contract the agent
# has to surface.
DIRECT=$(mcp_tool_call create_override "$(jq -nc --arg r "$REASON_TAG" '{policy_id: "sys_pii_email", policy_type: "static", override_reason: $r, ttl_seconds: 300}')" "${IDENTITY[@]}")
DIRECT_ID=$(printf '%s' "$DIRECT" | jq -r '.result.content[0].text // ""' | jq -r '.id // empty' 2>/dev/null)
assert_mcp_override_frozen "create_override (called directly)" "$DIRECT" || errors=$((errors + 1))

PROMPT="Call the mcp__${MCP_SERVER_NAME}__create_override tool with policy_id=\"sys_pii_email\", policy_type=\"static\", ttl_seconds=300 and override_reason=\"$REASON_TAG\". After the tool result, output exactly the literal text SMOKE_RESULT: followed by a single-line JSON: SMOKE_RESULT: {\"dispatched\":true,\"created_id\":\"<the created override id, or empty if none>\",\"error_text\":\"<the first 60 characters of the tool's error text, or empty>\"}."

echo "--- Running codex exec ... ---"
codex_exec_capture "$PROMPT" "$OUTPUT_FILE"

if assert_mcp_started "$OUTPUT_FILE" "create_override"; then
  echo "PASS: Codex started the create_override MCP tool call"
else
  echo "FAIL: Codex did not start the create_override MCP tool call"
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

SMOKE_LINE=$(smoke_line "$OUTPUT_FILE")
CREATED_ID=$(printf '%s' "$SMOKE_LINE" | jq -r '.created_id // empty' 2>/dev/null)
if [ -z "$CREATED_ID" ]; then
  echo "PASS: the agent reports no created override id"
else
  echo "FAIL: the agent reports a created override id: $CREATED_ID"
  errors=$((errors + 1))
fi

AFTER_COUNT=$(mcp_override_count "${IDENTITY[@]}")
if [ "$AFTER_COUNT" = "$BASELINE_COUNT" ]; then
  echo "PASS: server-side override count unchanged ($BASELINE_COUNT -> $AFTER_COUNT): nothing was created"
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
echo "PASS: create-override — retired on v11: the platform answered $OVERRIDE_FROZEN_CODE, the agent surfaced it, nothing was created"
