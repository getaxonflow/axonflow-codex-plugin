#!/usr/bin/env bash
# Codex runtime E2E: the override lifecycle on AxonFlow v11.0.0.
#
# The session-override writes are retired from v11.0.0. Drives a real Codex
# agent through list -> create -> list -> delete -> list and asserts the
# retirement at every step: the REST writes answer 409 LEGACY_POLICY_WRITE_FROZEN,
# both MCP writes answer the frozen tool error, and the recorded count never moves.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

AXONFLOW_AUTH_HDR="Authorization: Basic $(printf 'demo-client:demo-secret' | base64)"
IDENTITY=(-H "X-User-Email: $AXONFLOW_E2E_USER_EMAIL")
REASON_TAG="lifecycle-test-$(date +%s)-$RANDOM"
TARGET_ID="00000000-0000-4000-8000-00000000c0df"
OUTPUT_FILE=$(mktemp -t axonflow-codex-lifecycle.XXXXXX)
trap 'codex_cleanup_mcp; rm -f "$OUTPUT_FILE"' EXIT
codex_register_mcp_with_identity

errors=0

# The REST writes, with the per-user identity the override endpoints check
# before they answer anything else.
REST_POST=$(curl -s -X POST -H "$AXONFLOW_AUTH_HDR" -H "Content-Type: application/json" \
  -H "X-Tenant-ID: local-dev-org" -H "X-User-Email: $AXONFLOW_E2E_USER_EMAIL" \
  -d "$(jq -nc --arg r "$REASON_TAG" '{policy_id: "sys_pii_email", policy_type: "static", override_reason: $r, ttl_seconds: 60}')" \
  -w "\nHTTP_STATUS:%{http_code}" "$AXONFLOW_ENDPOINT/api/v1/overrides")
assert_rest_override_frozen "REST POST /api/v1/overrides" \
  "$(printf '%s' "$REST_POST" | sed -n 's/^HTTP_STATUS://p')" "$(printf '%s' "$REST_POST" | sed '$d')" || errors=$((errors + 1))
REST_DELETE=$(curl -s -X DELETE -H "$AXONFLOW_AUTH_HDR" \
  -H "X-Tenant-ID: local-dev-org" -H "X-User-Email: $AXONFLOW_E2E_USER_EMAIL" \
  -w "\nHTTP_STATUS:%{http_code}" "$AXONFLOW_ENDPOINT/api/v1/overrides/$TARGET_ID")
assert_rest_override_frozen "REST DELETE /api/v1/overrides/{id}" \
  "$(printf '%s' "$REST_DELETE" | sed -n 's/^HTTP_STATUS://p')" "$(printf '%s' "$REST_DELETE" | sed '$d')" || errors=$((errors + 1))

BASELINE_COUNT=$(mcp_override_count "${IDENTITY[@]}")
if [ -z "$BASELINE_COUNT" ]; then
  echo "FAIL: list_overrides answered no count before the run (is the orchestrator up?)"
  exit 1
fi
echo "--- Baseline override count: $BASELINE_COUNT ---"

PROMPT="You are running a 5-step governance lifecycle smoke test against the axonflow MCP server. Use the named MCP tools — do not invent tools or reorder. Report what each tool actually answers.

Step 1: Call mcp__${MCP_SERVER_NAME}__list_overrides with include_revoked=true. Note the count value.

Step 2: Call mcp__${MCP_SERVER_NAME}__create_override with policy_id=\"sys_pii_email\", policy_type=\"static\", ttl_seconds=300 and override_reason=\"$REASON_TAG\". Note the tool's answer.

Step 3: Call mcp__${MCP_SERVER_NAME}__list_overrides again with include_revoked=true. Note the count value.

Step 4: Call mcp__${MCP_SERVER_NAME}__delete_override with override_id=\"$TARGET_ID\". Note the tool's answer.

Step 5: Call mcp__${MCP_SERVER_NAME}__list_overrides one more time with include_revoked=true. Note the count value.

Output exactly the literal text SMOKE_RESULT: followed by a single-line JSON: SMOKE_RESULT: {\"baseline_count\":N1,\"after_create_count\":N2,\"after_revoke_count\":N3,\"create_error_text\":\"<first 60 characters of create_override's error text, or empty>\",\"delete_error_text\":\"<first 60 characters of delete_override's error text, or empty>\"}."

echo "--- Running codex exec (override lifecycle) ---"
codex_exec_capture "$PROMPT" "$OUTPUT_FILE"

for tool in list_overrides create_override delete_override; do
  if assert_mcp_started "$OUTPUT_FILE" "$tool"; then
    echo "PASS: Codex started $tool"
  else
    echo "FAIL: Codex did not start $tool"
    errors=$((errors + 1))
  fi
done

if assert_smoke_result "$OUTPUT_FILE"; then
  echo "PASS: agent emitted SMOKE_RESULT marker"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  tail -15 "$OUTPUT_FILE" | sed 's/^/      /'
  errors=$((errors + 1))
fi

SMOKE_LINE=$(smoke_line "$OUTPUT_FILE")
BASE=$(printf '%s' "$SMOKE_LINE" | jq -r '.baseline_count // empty' 2>/dev/null)
AFTER_C=$(printf '%s' "$SMOKE_LINE" | jq -r '.after_create_count // empty' 2>/dev/null)
AFTER_R=$(printf '%s' "$SMOKE_LINE" | jq -r '.after_revoke_count // empty' 2>/dev/null)
CREATE_TEXT=$(printf '%s' "$SMOKE_LINE" | jq -r '.create_error_text // empty' 2>/dev/null)
DELETE_TEXT=$(printf '%s' "$SMOKE_LINE" | jq -r '.delete_error_text // empty' 2>/dev/null)

if [ -n "$BASE" ] && [ "$BASE" = "$BASELINE_COUNT" ] && [ "$AFTER_C" = "$BASE" ] && [ "$AFTER_R" = "$BASE" ]; then
  echo "PASS: the count never moved through create and delete ($BASE -> $AFTER_C -> $AFTER_R)"
else
  echo "FAIL: the counts moved or are missing (server $BASELINE_COUNT; agent $BASE -> $AFTER_C -> $AFTER_R). SMOKE_RESULT: $SMOKE_LINE"
  errors=$((errors + 1))
fi
for pair in "create_override:$CREATE_TEXT" "delete_override:$DELETE_TEXT"; do
  tool="${pair%%:*}"
  text="${pair#*:}"
  case "$text" in
    *"$OVERRIDE_FROZEN_CODE"*) echo "PASS: the agent reports $tool answered $OVERRIDE_FROZEN_CODE" ;;
    *) echo "FAIL: the agent reports $tool answered: '${text}'"; errors=$((errors + 1)) ;;
  esac
done

AFTER_COUNT=$(mcp_override_count "${IDENTITY[@]}")
if [ "$AFTER_COUNT" = "$BASELINE_COUNT" ]; then
  echo "PASS: server-side override count unchanged after the lifecycle ($BASELINE_COUNT)"
else
  echo "FAIL: server-side override count changed ($BASELINE_COUNT -> ${AFTER_COUNT:-no answer})"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors lifecycle assertion(s) failed"
  exit 1
fi
echo ""
echo "PASS: governance-lifecycle — both writes retired on v11 (REST 409 and MCP tool error), the count never moved"
