#!/usr/bin/env bash
# Codex runtime E2E: create_override REJECTION OUTCOME (W2 — rule #1)
#
# Verifies that the platform's allow_override=FALSE enforcement is reachable
# through the Codex MCP runtime path. Pre-platform-fix the create_override
# call on sys_sqli_admin_bypass would silently succeed; post-fix the
# platform returns 403 and the agent surfaces the rejection.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

trap codex_cleanup_mcp EXIT
codex_register_mcp

PROMPT="Call the mcp__${MCP_SERVER_NAME}__create_override tool with policy_id=\"sys_sqli_admin_bypass\", policy_type=\"static\", and override_reason=\"runtime-e2e rejection verification\". The platform should reject because the policy is severity=critical. After the tool result, output exactly the literal text SMOKE_RESULT: followed by a single-line JSON like SMOKE_RESULT: {\"dispatched\":true,\"server_rejected\":true,\"http_status\":403} or SMOKE_RESULT: {\"dispatched\":true,\"server_rejected\":false}."

OUTPUT_FILE=$(mktemp -t axonflow-codex-create.XXXXXX)
trap 'codex_cleanup_mcp; rm -f "$OUTPUT_FILE"' EXIT

echo "--- Running codex exec ... ---"
codex_exec_capture "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_mcp_started "$OUTPUT_FILE" "create_override"; then
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

# Outcome assertion — the agent reply must reflect the platform rejection.
if assert_output_contains "$OUTPUT_FILE" '"server_rejected":true' \
  || assert_output_contains "$OUTPUT_FILE" 'Critical-risk policies cannot be overridden' \
  || assert_output_contains "$OUTPUT_FILE" 'allow_override' \
  || assert_output_contains "$OUTPUT_FILE" '403'; then
  echo "PASS: agent surfaced the platform rejection — outcome verified"
else
  tail -10 "$OUTPUT_FILE" | sed 's/^/      /'
  echo "FAIL: agent did NOT surface the rejection"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors outcome-test assertion(s) failed"
  exit 1
fi
echo ""
echo "PASS: create-override — agent dispatched + platform rejected + agent surfaced rejection"
