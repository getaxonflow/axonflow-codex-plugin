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

# Seed an override via the SAME unauthenticated MCP path codex uses, so the
# tenant resolves to the same value (community in community-mode docker).
# Direct REST seeds via /api/v1/overrides resolve to a different tenant
# (demo-client) under community-mode auth, which would invisibly break
# tenant-scoped lookups (revoke / explain) the agent later issues.
# Echoes the override id on stdout, or empty string on failure.
mcp_seed_override() {
  local policy_id="${1:-sys_pii_email}"
  local reason="${2:-mcp-seed}"
  local ttl="${3:-300}"
  local payload
  payload=$(jq -n --arg pid "$policy_id" --arg r "$reason" --argjson ttl "$ttl" \
    '{jsonrpc:"2.0",id:"1",method:"tools/call",params:{name:"create_override",arguments:{policy_id:$pid,policy_type:"static",override_reason:$r,ttl_seconds:$ttl}}}')
  curl -s -X POST -H "Content-Type: application/json" -d "$payload" \
    "$AXONFLOW_ENDPOINT/api/v1/mcp-server" \
    | jq -r '.result.content[0].text // ""' \
    | jq -r '.id // ""' 2>/dev/null
}

# Trigger a SQLi-block decision through the unauth MCP path so the resulting
# decision_id + audit row land in the same tenant codex sees. Echoes the
# decision_id on stdout.
mcp_seed_block() {
  local marker="${1:-mcp-block-$(date +%s)}"
  local payload
  payload=$(jq -n --arg m "SELECT * FROM users WHERE id=1 OR 1=1; -- $marker" \
    '{jsonrpc:"2.0",id:"1",method:"tools/call",params:{name:"check_policy",arguments:{connector_type:"sql",statement:$m,operation:"query"}}}')
  curl -s -X POST -H "Content-Type: application/json" -d "$payload" \
    "$AXONFLOW_ENDPOINT/api/v1/mcp-server" \
    | jq -r '.result.content[0].text // ""' \
    | jq -r '.decision_id // ""' 2>/dev/null
}

# Revoke-by-id via unauth MCP for cleanup. Quiet on failure.
mcp_cleanup_override() {
  local id="$1"
  [ -z "$id" ] && return
  local payload
  payload=$(jq -n --arg id "$id" \
    '{jsonrpc:"2.0",id:"1",method:"tools/call",params:{name:"delete_override",arguments:{override_id:$id}}}')
  curl -s -X POST -H "Content-Type: application/json" -d "$payload" \
    "$AXONFLOW_ENDPOINT/api/v1/mcp-server" >/dev/null 2>&1 || true
}
