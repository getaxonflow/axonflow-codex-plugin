#!/usr/bin/env bash
# Unit test for scripts/client-header.sh — ADR-050 §4.
#
# Asserts the helper sets AXONFLOW_CLIENT_HEADER to "codex-plugin/<version>"
# where <version> matches .codex-plugin/plugin.json's `version` field.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="${PLUGIN_DIR}/scripts/client-header.sh"
PLUGIN_JSON="${PLUGIN_DIR}/.codex-plugin/plugin.json"

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH"
  exit 0
fi

EXPECTED_VERSION=$(jq -r '.version' "$PLUGIN_JSON")
EXPECTED_HEADER="codex-plugin/${EXPECTED_VERSION}"

ACTUAL=$(unset AXONFLOW_CLIENT_HEADER; . "$SCRIPT_PATH"; echo "$AXONFLOW_CLIENT_HEADER")
if [ "$ACTUAL" = "$EXPECTED_HEADER" ]; then
  pass "client-header.sh sets AXONFLOW_CLIENT_HEADER=$EXPECTED_HEADER"
else
  fail "expected '$EXPECTED_HEADER', got '$ACTUAL'"
fi

if [[ "$ACTUAL" =~ ^codex-plugin/[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  pass "header format matches <client-id>/<semver>"
else
  fail "header '$ACTUAL' does not match <client-id>/<semver>"
fi

ACTUAL2=$(unset AXONFLOW_CLIENT_HEADER
          . "$SCRIPT_PATH"
          . "$SCRIPT_PATH"
          echo "$AXONFLOW_CLIENT_HEADER")
if [ "$ACTUAL2" = "$EXPECTED_HEADER" ]; then
  pass "double-source is idempotent"
else
  fail "double-source changed value to '$ACTUAL2'"
fi

if (set -u; unset AXONFLOW_CLIENT_HEADER; . "$SCRIPT_PATH"; echo "$AXONFLOW_CLIENT_HEADER" >/dev/null) 2>/dev/null; then
  pass "client-header.sh works under set -u"
else
  fail "client-header.sh trips set -u"
fi

echo ""
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
