#!/usr/bin/env bash
# Plugin smoke E2E: install-and-use sanity check against a live AxonFlow
# stack. Feeds a SQLi-bearing Bash tool invocation into pre-tool-check.sh
# and asserts the hook exits 2 with stderr containing the Codex deny
# prefix and Plugin Batch 1 richer-context markers.
#
# Scope: smoke-only — install wiring + one local deny UX. The full
# install-and-use matrix (explain, override lifecycle, audit filter
# parity, cache invalidation) lives alongside the platform in
# axonflow-enterprise/tests/e2e/plugin-batch-1/codex-install/.
#
# Usage:
#   AXONFLOW_ENDPOINT=http://localhost:8080 \
#   AXONFLOW_CLIENT_ID=demo-client \
#   AXONFLOW_CLIENT_SECRET=demo-secret \
#     bash tests/e2e/smoke-block-context.sh
#
# CI trigger: workflow_dispatch only (GitHub-hosted runners have no
# local stack; PR gating needs a self-hosted runner).
# -uo pipefail (no -e) so the errors=$((errors+1)) accumulator + FAIL
# diagnostics always print.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_SCRIPT="$REPO_ROOT/scripts/pre-tool-check.sh"

: "${AXONFLOW_ENDPOINT:=http://localhost:8080}"
: "${AXONFLOW_CLIENT_ID:=demo-client}"
: "${AXONFLOW_CLIENT_SECRET:=demo-secret}"

export AXONFLOW_ENDPOINT
export AXONFLOW_AUTH="$(printf '%s:%s' "$AXONFLOW_CLIENT_ID" "$AXONFLOW_CLIENT_SECRET" | base64)"

if ! curl -sSf -o /dev/null --max-time 5 "$AXONFLOW_ENDPOINT/health"; then
  echo "SKIP: AxonFlow stack not reachable at $AXONFLOW_ENDPOINT/health"
  echo "      Start one via axonflow-enterprise scripts/setup-e2e-testing.sh"
  exit 0
fi

INPUT='{"tool_name":"Bash","tool_input":{"command":"psql -c \"SELECT * FROM users WHERE id='"'"'1'"'"' OR 1=1--\""}}'

STDERR_OUT=$(echo "$INPUT" | bash "$HOOK_SCRIPT" 2>&1 >/dev/null)
EXIT_CODE=$?
echo "--- exit code: $EXIT_CODE ---"
echo "--- stderr ---"
echo "$STDERR_OUT"
echo "---"

errors=0
if [ "$EXIT_CODE" != "2" ]; then
  echo "FAIL: expected exit 2 (Codex deny semantics), got $EXIT_CODE"
  errors=$((errors + 1))
fi
if ! echo "$STDERR_OUT" | grep -qE "AxonFlow policy violation"; then
  echo "FAIL: stderr missing 'AxonFlow policy violation' prefix"
  errors=$((errors + 1))
fi
if ! echo "$STDERR_OUT" | grep -qE "decision:"; then
  echo "FAIL: stderr missing 'decision:' marker (Plugin Batch 1 richer context)"
  errors=$((errors + 1))
fi
if ! echo "$STDERR_OUT" | grep -qE "risk:"; then
  echo "FAIL: stderr missing 'risk:' marker (Plugin Batch 1 richer context)"
  errors=$((errors + 1))
fi

if [ $errors -gt 0 ]; then
  echo "FAIL: smoke scenario failed with $errors error(s)"
  exit 1
fi
echo "PASS: smoke — Codex hook denies SQLi Bash with exit 2 + richer context"
