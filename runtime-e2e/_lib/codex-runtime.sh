#!/usr/bin/env bash
# Shared helpers for Codex runtime-e2e tests.
#
# Each per-feature test sources this file, calls codex_register_mcp,
# runs codex_exec with a tool-bearing prompt, and checks for the MCP
# `started` / `(completed)` / `(failed)` markers in Codex's output.
#
# Codex doesn't expose a structured event stream the way Claude Code's
# stream-json does, so we parse the human-readable diagnostic lines
# Codex prints. Brittle if Codex changes that format, but it's the
# only signal available today.

set -uo pipefail

: "${AXONFLOW_ENDPOINT:=http://localhost:8080}"
: "${MCP_SERVER_NAME:=axonflow_w2_e2e}"

runtime_e2e_skip_if_unavailable() {
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
}

codex_register_mcp() {
  codex mcp remove "$MCP_SERVER_NAME" >/dev/null 2>&1 || true
  codex mcp add "$MCP_SERVER_NAME" --url "$AXONFLOW_ENDPOINT/api/v1/mcp-server" >/dev/null
}

codex_cleanup_mcp() {
  codex mcp remove "$MCP_SERVER_NAME" >/dev/null 2>&1 || true
}

codex_exec_capture() {
  local prompt="$1"
  local output_file="$2"
  # Order matters: `>file 2>&1` first redirects stdout to file, then dups
  # stderr to the same fd (the file). The reverse order — `2>&1 >file` —
  # leaves stderr at the inherited terminal because the dup happens
  # against the pre-redirection stdout. We want both streams in the file
  # so the grep assertions can find Codex's `mcp: started/(completed)`
  # diagnostic lines.
  timeout 90 codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox "$prompt" >"$output_file" 2>&1 || true
}

assert_mcp_started() {
  local output_file="$1"
  local tool="$2"
  grep -qE "mcp: $MCP_SERVER_NAME/$tool started" "$output_file"
}

assert_mcp_completed() {
  local output_file="$1"
  local tool="$2"
  grep -qE "mcp: $MCP_SERVER_NAME/$tool \(completed\)" "$output_file"
}

assert_mcp_failed() {
  local output_file="$1"
  local tool="$2"
  grep -qE "mcp: $MCP_SERVER_NAME/$tool \(failed\)" "$output_file"
}

assert_smoke_result() {
  local output_file="$1"
  grep -q "SMOKE_RESULT:" "$output_file"
}

assert_output_contains() {
  local output_file="$1"
  local needle="$2"
  grep -q "$needle" "$output_file"
}
