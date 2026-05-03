#!/usr/bin/env bash
# Codex runtime E2E: full W2 governance lifecycle (rule #1 + integration)
#
# Read-only subset (no license required): chains search_audit_events +
# list_overrides in one Codex session. Full lifecycle gated on
# AXONFLOW_LICENSE.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

trap codex_cleanup_mcp EXIT
codex_register_mcp

HAVE_LICENSE=0
if [ -n "${AXONFLOW_LICENSE:-}" ]; then
  HAVE_LICENSE=1
fi
if [ "$HAVE_LICENSE" -ne 1 ]; then
  echo "INFO: AXONFLOW_LICENSE not set — running read-only lifecycle subset"
fi

PROMPT_RO="Step 1: Call mcp__${MCP_SERVER_NAME}__search_audit_events with limit=3.
Step 2: Call mcp__${MCP_SERVER_NAME}__list_overrides with no arguments.
Step 3: Output exactly 'SMOKE_RESULT: ' followed by a one-line JSON summary like SMOKE_RESULT: {\"audit_total\":N,\"override_count\":N}."

OUTPUT_FILE=$(mktemp -t axonflow-codex-lifecycle.XXXXXX)
trap 'rm -f "$OUTPUT_FILE"; codex_cleanup_mcp' EXIT

echo "--- Running read-only lifecycle (search_audit_events + list_overrides chained) ---"
codex_exec_capture "$PROMPT_RO" "$OUTPUT_FILE"

errors=0

if assert_mcp_started "$OUTPUT_FILE" "search_audit_events"; then
  echo "PASS: Codex started search_audit_events"
else
  echo "FAIL: Codex did not start search_audit_events in step 1"
  errors=$((errors + 1))
fi

if assert_mcp_started "$OUTPUT_FILE" "list_overrides"; then
  echo "PASS: Codex started list_overrides"
else
  echo "FAIL: Codex did not start list_overrides in step 2"
  errors=$((errors + 1))
fi

if assert_smoke_result "$OUTPUT_FILE"; then
  echo "PASS: agent emitted SMOKE_RESULT marker"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  errors=$((errors + 1))
fi

if [ "$HAVE_LICENSE" -eq 1 ]; then
  echo ""
  echo "FAIL: full lifecycle (create→list→explain→revoke→list) is not yet implemented"
  echo "      Filed as followup; needs a seeded override-able policy via the license-gated /api/v1/policies path."
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors lifecycle assertion(s) failed"
  tail -20 "$OUTPUT_FILE"
  exit 1
fi

echo ""
if [ "$HAVE_LICENSE" -eq 1 ]; then
  echo "PASS: governance-lifecycle (full)"
else
  echo "PASS: governance-lifecycle (read-only subset; mutation lifecycle SKIPPED — no license)"
fi
