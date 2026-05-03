#!/usr/bin/env bash
# Plugin runtime E2E: real Codex agent invokes MCP tools (W2 — rule #1).
#
# This is the runtime-path test the W2 work has been missing. It registers
# the AxonFlow MCP server in Codex's global config (the same step a user
# would do — Codex doesn't auto-load plugin .mcp.json files), runs `codex
# exec` non-interactively with a prompt that should trigger the new MCP
# tool, captures the output, and asserts the agent invoked the tool
# end-to-end against the live stack.
#
# Why this matters
#
# Rule #1 (no user-facing feature merges without one runtime-path test):
# the user surface here is "agent picks an MCP tool from natural-language
# context and invokes it." Direct JSON-RPC tools/call tests the wire under
# the surface. This script tests the surface.
#
# Known product gap: Codex's HTTP MCP support is bearer-token-only and shows
# `Auth: Unsupported` for our Basic-auth MCP server. In enterprise mode this
# means Codex cannot authenticate. In community mode the agent is permissive
# enough that calls still succeed for demo-client/demo-secret. Documenting
# this honestly in the plugin README is the followup.
#
# Usage:
#   AXONFLOW_ENDPOINT=http://localhost:8080 \
#     bash tests/e2e/runtime-real-agent.sh
#
# Requirements:
#   - `codex` CLI on PATH and authenticated
#   - jq on PATH
#   - Live AxonFlow stack reachable at AXONFLOW_ENDPOINT
#
# Exits 0 with SKIP when codex isn't authenticated or the stack isn't up.

set -uo pipefail

: "${AXONFLOW_ENDPOINT:=http://localhost:8080}"
MCP_SERVER_NAME="axonflow_w2_e2e"

if ! command -v codex >/dev/null 2>&1; then
  echo "SKIP: codex CLI not on PATH"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH"
  exit 0
fi
if ! curl -sSf -o /dev/null --max-time 5 "$AXONFLOW_ENDPOINT/health"; then
  echo "SKIP: AxonFlow stack not reachable at $AXONFLOW_ENDPOINT/health"
  echo "      Start one via axonflow-enterprise scripts/setup-e2e-testing.sh"
  exit 0
fi

cleanup() {
  codex mcp remove "$MCP_SERVER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Register the AxonFlow MCP server in Codex's global config. This is the
# same step a real Codex user would run after installing the plugin.
codex mcp remove "$MCP_SERVER_NAME" >/dev/null 2>&1 || true
codex mcp add "$MCP_SERVER_NAME" --url "$AXONFLOW_ENDPOINT/api/v1/mcp-server" >/dev/null
echo "--- Registered Codex MCP server: $MCP_SERVER_NAME -> $AXONFLOW_ENDPOINT/api/v1/mcp-server"

# Drive a real Codex agent session non-interactively. --dangerously-bypass-
# approvals-and-sandbox is required because Codex prompts for approval
# before MCP calls otherwise, and there's no interactive TTY in CI.
PROMPT="Call the mcp__${MCP_SERVER_NAME}__search_audit_events tool with limit=5 and report the result. Output starting with the literal text 'SMOKE_RESULT: ' followed by the JSON tool result on one line. Do nothing else."

echo "--- Running codex exec ... ---"
RAW_OUTPUT=$(codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox "$PROMPT" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
echo "--- codex exit: $EXIT_CODE ---"

errors=0

# Assertion 1: Codex's MCP layer reports the tool call started + completed.
# Codex prints diagnostic lines like:
#   `mcp: <server>/<tool> started`
#   `mcp: <server>/<tool> (completed)`
# A failed call prints `(failed)` instead. We grep for the started+completed
# pair to prove the agent actually dispatched.
if printf '%s' "$RAW_OUTPUT" | grep -qE "mcp: $MCP_SERVER_NAME/search_audit_events started"; then
  echo "PASS: Codex started the MCP tool call ($MCP_SERVER_NAME/search_audit_events)"
else
  echo "FAIL: Codex did not start any MCP tool call to $MCP_SERVER_NAME/search_audit_events"
  echo "      (this is the rule-#1 evidence — without this, we shipped wiring not a feature)"
  errors=$((errors + 1))
fi

if printf '%s' "$RAW_OUTPUT" | grep -qE "mcp: $MCP_SERVER_NAME/search_audit_events \(completed\)"; then
  echo "PASS: Codex MCP tool call completed (not failed/cancelled)"
elif printf '%s' "$RAW_OUTPUT" | grep -qE "mcp: $MCP_SERVER_NAME/search_audit_events \(failed\)"; then
  echo "FAIL: Codex MCP tool call failed (server-side error or auth rejection)"
  errors=$((errors + 1))
elif printf '%s' "$RAW_OUTPUT" | grep -qE "user cancelled MCP tool call"; then
  echo "FAIL: Codex prompted for approval and was cancelled — re-run with --dangerously-bypass-approvals-and-sandbox"
  errors=$((errors + 1))
fi

# Assertion 2: SMOKE_RESULT marker appears in agent output, proving the
# agent consumed the tool result and produced a downstream response.
if printf '%s' "$RAW_OUTPUT" | grep -q "SMOKE_RESULT:"; then
  echo "PASS: agent emitted SMOKE_RESULT marker (full pipeline executed)"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  errors=$((errors + 1))
fi

# Assertion 3: the response shape includes the entries field. This proves
# the platform actually answered (not a malformed response or auth-stub),
# AND validates the entries:[] (not null) fix on the audit/search endpoint.
if printf '%s' "$RAW_OUTPUT" | grep -qE 'SMOKE_RESULT:.*"entries"\s*:\s*\[' ; then
  echo "PASS: response includes entries[] (audit/search nil-fix is in place)"
else
  echo "FAIL: response missing entries[] field — server returned unexpected shape"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors runtime-path assertion(s) failed"
  echo "--- raw output ---"
  printf '%s\n' "$RAW_OUTPUT" | tail -20
  exit 1
fi
echo ""
echo "PASS: runtime-real-agent — Codex agent dispatched search_audit_events end-to-end against the live stack"
