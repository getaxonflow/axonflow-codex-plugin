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

# #3062: mcp_seed_override runs inside $(...) and cannot return the raw MCP
# response through a variable — a subshell's assignments are lost — so it writes
# the response here for require_mcp_override_seed to report on failure.
#
# Deterministic per-PID path rather than mktemp + an EXIT trap: every test in
# this suite installs its own `trap ... EXIT`, which would silently replace a
# trap set here. One small file per run, overwritten in place across calls, and
# require_mcp_override_seed removes it on both paths.
: "${MCP_SEED_RESPONSE_FILE:=${TMPDIR:-/tmp}/axonflow-codex-mcp-seed.$$}"

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
#
# #3062: the raw MCP response is ALSO written to $MCP_SEED_RESPONSE_FILE so a
# failed seed can be reported instead of vanishing. This function runs inside a
# command substitution ($(...)), so it cannot hand the response back through a
# shell variable — a subshell's assignments are lost. A file survives.
mcp_seed_override() {
  local policy_id="${1:-sys_pii_email}"
  local reason="${2:-mcp-seed}"
  local ttl="${3:-300}"
  local payload response
  payload=$(jq -n --arg pid "$policy_id" --arg r "$reason" --argjson ttl "$ttl" \
    '{jsonrpc:"2.0",id:"1",method:"tools/call",params:{name:"create_override",arguments:{policy_id:$pid,policy_type:"static",override_reason:$r,ttl_seconds:$ttl}}}')
  response=$(curl -s -X POST -H "Content-Type: application/json" -d "$payload" \
    "$AXONFLOW_ENDPOINT/api/v1/mcp-server")
  printf '%s' "$response" > "$MCP_SEED_RESPONSE_FILE" 2>/dev/null || true
  printf '%s' "$response" \
    | jq -r '.result.content[0].text // ""' \
    | jq -r '.id // ""' 2>/dev/null
}

# require_mcp_override_seed <seed_id>
#
# The override lifecycle tests seed state through create_override. When that
# seed failed, list-overrides / revoke-override printed
# `SKIP: pre-flight MCP create_override returned empty id` and exited 0 —
# discarding the response entirely, so the suite reported green while the tools
# it covers were dead, and left nothing to diagnose with (#3062).
#
# A test that skips is not a test. The only legitimate exit-0 here is
# environment unavailability, checked up-front by runtime_e2e_skip_if_unavailable.
require_mcp_override_seed() {
  local seed_id="$1"
  if [ -n "$seed_id" ]; then
    rm -f "$MCP_SEED_RESPONSE_FILE"
    return 0
  fi

  echo "FAIL: pre-flight MCP create_override did not return an override id"
  if [ -s "$MCP_SEED_RESPONSE_FILE" ]; then
    echo "      Raw MCP response:"
    # awk, not sed: a response with no trailing newline would otherwise leave
    # the last line unterminated and swallow the blank line that follows.
    head -20 "$MCP_SEED_RESPONSE_FILE" | awk '{print "        " $0}'
  else
    echo "      (no response captured — the stack may be unreachable)"
  fi
  rm -f "$MCP_SEED_RESPONSE_FILE"
  echo ""
  echo "      Overrides are scoped to an individual user, so this seed needs a"
  echo "      per-user identity on the MCP-server plane. Two things commonly"
  echo "      block it, and the response above says which:"
  echo ""
  echo "        1. The agent drops client-asserted identity unless the"
  echo "           deployment declares its identity source trusted:"
  echo "             AXONFLOW_TRUST_IDENTITY_HEADERS=true   # on the AGENT, then restart"
  echo "           Only enable it when every hop that can reach the agent asserts"
  echo "           end-user identity from a validated source — see"
  echo "           docs/security/identity-header-trust.md in axonflow-enterprise."
  echo ""
  echo "        2. A platform-synthesized SHARED identity (mcp-client:<client-id>)"
  echo "           may not hold an override — one caller's override would flip a"
  echo "           deny for every caller on that client. Present a real per-user"
  echo "           identity or a validated per-user token."
  return 1
}

# require_override_preflight <http_status> <body>
#
# The REST-path equivalent of require_mcp_override_seed, for the tests that
# seed over /api/v1/overrides directly. Same rule: a reachable stack that
# refuses to create an override is a FAILURE, not a skip (#3062).
require_override_preflight() {
  local status="$1"
  local body="${2:-}"

  if [ "$status" = "201" ]; then
    return 0
  fi

  echo "FAIL: pre-flight create_override returned HTTP $status (expected 201)"
  [ -n "$body" ] && echo "      Body: $body"
  echo ""

  case "$status" in
    401)
      echo "      The override endpoints require a per-user identity. This deployment"
      echo "      is not configured to trust client-asserted identity headers, so the"
      echo "      AxonFlow Agent removed the X-User-Email this test sent."
      echo ""
      echo "      Set the posture this test requires, then re-run:"
      echo "        AXONFLOW_TRUST_IDENTITY_HEADERS=true   # on the AGENT, then restart it"
      echo ""
      echo "      Only enable it when every hop that can reach the agent asserts"
      echo "      end-user identity from a validated source — see"
      echo "      docs/security/identity-header-trust.md in axonflow-enterprise."
      ;;
    403)
      echo "      The stack rejected the override on policy grounds. Check the seed"
      echo "      policy is overridable (not critical-risk, allow_override=true)."
      ;;
    404)
      echo "      The seed policy was not found for this tenant. Confirm the stack's"
      echo "      migrations ran and that the tenant matches the seeded one."
      ;;
  esac

  return 1
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
