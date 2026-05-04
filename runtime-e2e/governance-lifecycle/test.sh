#!/usr/bin/env bash
# Codex runtime E2E: full W2 governance lifecycle (rule #1 + integration)
#
# Drives a real Codex agent through create→list→revoke→list→search.
# Asserts state transitions: count went up, then back down.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

trap codex_cleanup_mcp EXIT
codex_register_mcp

AXONFLOW_AUTH_HDR="Authorization: Basic $(printf 'demo-client:demo-secret' | base64)"

# Pre-flight probe.
PROBE_RESPONSE=$(curl -s -X POST \
  -H "$AXONFLOW_AUTH_HDR" \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: local-dev-org" \
  -H "X-User-Email: dev@getaxonflow.com" \
  -d '{"policy_id":"sys_pii_email","policy_type":"static","override_reason":"lifecycle-prereq-probe","ttl_seconds":60}' \
  -w "\nHTTP_STATUS:%{http_code}" \
  "$AXONFLOW_ENDPOINT/api/v1/overrides")
PROBE_STATUS=$(printf '%s' "$PROBE_RESPONSE" | sed -n 's/^HTTP_STATUS://p')
PROBE_BODY=$(printf '%s' "$PROBE_RESPONSE" | sed '$d')
case "$PROBE_STATUS" in
  201)
    PROBE_ID=$(printf '%s' "$PROBE_BODY" | jq -r '.id // empty')
    [ -n "$PROBE_ID" ] && curl -s -X DELETE -H "$AXONFLOW_AUTH_HDR" -H "X-Tenant-ID: local-dev-org" -H "X-User-Email: dev@getaxonflow.com" "$AXONFLOW_ENDPOINT/api/v1/overrides/$PROBE_ID" >/dev/null
    ;;
  *)
    echo "SKIP: pre-flight create_override returned HTTP $PROBE_STATUS"
    exit 0
    ;;
esac

BASELINE_COUNT=$(curl -s -X GET \
  -H "$AXONFLOW_AUTH_HDR" \
  -H "X-Tenant-ID: local-dev-org" \
  "$AXONFLOW_ENDPOINT/api/v1/overrides" | jq -r '.count // 0')
echo "--- Baseline override count: $BASELINE_COUNT ---"

REASON_TAG="lifecycle-test-$(date +%s)-$RANDOM"

PROMPT="You are running a 5-step governance lifecycle smoke test against the axonflow MCP server. Use the named MCP tools — do not invent tools or reorder.

Step 1: Call mcp__${MCP_SERVER_NAME}__list_overrides with no arguments. Note the count value.

Step 2: Call mcp__${MCP_SERVER_NAME}__create_override with policy_id=\"sys_pii_email\", policy_type=\"static\", and override_reason=\"$REASON_TAG\". Capture the id from the response — call it CREATED_ID.

Step 3: Call mcp__${MCP_SERVER_NAME}__list_overrides again with no arguments. Note the new count value.

Step 4: Call mcp__${MCP_SERVER_NAME}__delete_override with override_id=CREATED_ID.

Step 5: Call mcp__${MCP_SERVER_NAME}__list_overrides one more time. Note the count value (should be back to baseline).

Output exactly the literal text SMOKE_RESULT: followed by a single-line JSON like SMOKE_RESULT: {\"baseline_count\":N1,\"after_create_count\":N2,\"after_revoke_count\":N3,\"created_id\":\"...\",\"revoke_dispatched\":true|false}."

OUTPUT_FILE=$(mktemp -t axonflow-codex-lifecycle.XXXXXX)
cleanup() {
  if [ -n "${REASON_TAG:-}" ]; then
    LEAKED_IDS=$(curl -s -X GET \
      -H "$AXONFLOW_AUTH_HDR" \
      -H "X-Tenant-ID: local-dev-org" \
      "$AXONFLOW_ENDPOINT/api/v1/overrides" \
      | jq -r --arg t "$REASON_TAG" '.overrides[]? | select(.override_reason == $t) | .id' 2>/dev/null)
    for lid in $LEAKED_IDS; do
      curl -s -X DELETE -H "$AXONFLOW_AUTH_HDR" -H "X-Tenant-ID: local-dev-org" -H "X-User-Email: dev@getaxonflow.com" \
        "$AXONFLOW_ENDPOINT/api/v1/overrides/$lid" >/dev/null 2>&1 || true
    done
  fi
  codex_cleanup_mcp
  rm -f "${OUTPUT_FILE:-}"
}
trap cleanup EXIT

echo "--- Running codex exec (full W2 lifecycle) ---"
codex_exec_capture "$PROMPT" "$OUTPUT_FILE"

errors=0

# All 3 tool families must have started.
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

SMOKE_LINE=$(grep "SMOKE_RESULT:" "$OUTPUT_FILE" | tail -1 | sed 's/.*SMOKE_RESULT: *//')
if [ -z "$SMOKE_LINE" ]; then
  echo "FAIL: SMOKE_RESULT line empty"
  errors=$((errors + 1))
else
  BASE=$(printf '%s' "$SMOKE_LINE" | jq -r '.baseline_count // empty' 2>/dev/null)
  AFTER_C=$(printf '%s' "$SMOKE_LINE" | jq -r '.after_create_count // empty' 2>/dev/null)
  AFTER_R=$(printf '%s' "$SMOKE_LINE" | jq -r '.after_revoke_count // empty' 2>/dev/null)
  CID=$(printf '%s' "$SMOKE_LINE" | jq -r '.created_id // empty' 2>/dev/null)

  if [ -n "$BASE" ] && [ -n "$AFTER_C" ] && [ -n "$AFTER_R" ]; then
    if [ "$AFTER_C" -gt "$BASE" ]; then
      echo "PASS: override count went UP after create ($BASE -> $AFTER_C)"
    else
      echo "FAIL: override count did not increase after create ($BASE -> $AFTER_C)"
      errors=$((errors + 1))
    fi
    if [ "$AFTER_R" -lt "$AFTER_C" ]; then
      echo "PASS: override count went DOWN after revoke ($AFTER_C -> $AFTER_R)"
    else
      echo "FAIL: override count did not decrease after revoke ($AFTER_C -> $AFTER_R)"
      errors=$((errors + 1))
    fi
  else
    echo "FAIL: SMOKE_RESULT missing required fields. Got: $SMOKE_LINE"
    errors=$((errors + 1))
  fi

  if [ -n "$CID" ]; then
    SERVER_HAS_ID=$(curl -s -X GET \
      -H "$AXONFLOW_AUTH_HDR" \
      -H "X-Tenant-ID: local-dev-org" \
      "$AXONFLOW_ENDPOINT/api/v1/overrides" | jq --arg id "$CID" '[.overrides[]? | select(.id == $id)] | length')
    if [ "${SERVER_HAS_ID:-1}" = "0" ]; then
      echo "PASS: server-side list_overrides confirms $CID is revoked"
    else
      echo "FAIL: server-side list_overrides still shows $CID after revoke"
      errors=$((errors + 1))
    fi
  fi
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors lifecycle assertion(s) failed"
  exit 1
fi
echo ""
echo "PASS: governance-lifecycle (full create→list→revoke→list verified end-to-end)"
