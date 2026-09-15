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
# The per-user identity the override suites present. An override write is
# scoped to an individual user, and the platform refuses a session with no
# per-user identity for that reason before it answers anything else.
: "${AXONFLOW_E2E_USER_EMAIL:=codex-runtime-e2e@axonflow-test.invalid}"

# The session-override writes are retired from AxonFlow v11.0.0. Measured on a
# v11.0.0 community stack with AXONFLOW_TRUST_IDENTITY_HEADERS=true:
#   - MCP create_override / delete_override answer a tool error (isError: true)
#     whose text begins with OVERRIDE_FROZEN_PREFIX. create_override on a
#     session with no per-user identity is refused for its identity first.
#   - REST POST / DELETE /api/v1/overrides with a per-user identity answer
#     HTTP 409 {"error":{"code":"LEGACY_POLICY_WRITE_FROZEN","message":...}}.
#   - list_overrides and GET /api/v1/overrides are unchanged reads.
OVERRIDE_FROZEN_PREFIX="LEGACY_POLICY_WRITE_FROZEN: "
OVERRIDE_FROZEN_CODE="LEGACY_POLICY_WRITE_FROZEN"

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

# The config file `codex mcp add` writes (CODEX_HOME is the codex CLI's own
# config-root override; scripts/install-mcp-with-headers.sh reads it the same way).
_codex_config_file() {
  printf '%s' "${CODEX_HOME:-${HOME}/.codex}/config.toml"
}

# Remove this test server's http_headers table, if a test wrote one.
_codex_strip_test_headers() {
  local config
  config=$(_codex_config_file)
  [ -f "$config" ] || return 0
  python3 - "$config" "$MCP_SERVER_NAME" <<'PY'
import pathlib, re, sys
path, name = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
stripped = re.sub(r'\n?\[mcp_servers\.' + re.escape(name) + r'\.http_headers\][^\[]*', '', text)
if stripped != text:
    path.write_text(stripped)
PY
}

codex_register_mcp() {
  _codex_strip_test_headers
  codex mcp remove "$MCP_SERVER_NAME" >/dev/null 2>&1 || true
  codex mcp add "$MCP_SERVER_NAME" --url "$AXONFLOW_ENDPOINT/api/v1/mcp-server" >/dev/null
}

# Register the test server with a static X-User-Email on every MCP request,
# written the way scripts/install-mcp-with-headers.sh writes its header table.
# The agent honours it only with AXONFLOW_TRUST_IDENTITY_HEADERS=true.
codex_register_mcp_with_identity() {
  codex_register_mcp
  python3 - "$(_codex_config_file)" "$MCP_SERVER_NAME" "$AXONFLOW_E2E_USER_EMAIL" <<'PY'
import pathlib, sys
path, name, email = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
if not text.endswith("\n"):
    text += "\n"
text += f'\n[mcp_servers.{name}.http_headers]\n"X-User-Email" = "{email}"\n'
path.write_text(text)
PY
}

codex_cleanup_mcp() {
  _codex_strip_test_headers
  codex mcp remove "$MCP_SERVER_NAME" >/dev/null 2>&1 || true
}

# The line codex_exec_capture writes before the agent's own final message.
# Codex echoes the prompt into its output, and every prompt here spells out
# the SMOKE_RESULT it asks for, so a check that reads the whole capture passes
# even when the agent never answered. Checks of the agent's answer read only
# what follows this line.
CODEX_LAST_MESSAGE_MARKER="=== codex-runtime: agent final message ==="

codex_exec_capture() {
  local prompt="$1"
  local output_file="$2"
  local last_message
  last_message=$(mktemp -t axonflow-codex-last.XXXXXX)
  # Order matters: `>file 2>&1` first redirects stdout to file, then dups
  # stderr to the same fd (the file). The reverse order — `2>&1 >file` —
  # leaves stderr at the inherited terminal because the dup happens
  # against the pre-redirection stdout. We want both streams in the file
  # so the grep assertions can find Codex's `mcp: started/(completed)`
  # diagnostic lines.
  timeout 90 codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \
    --output-last-message "$last_message" "$prompt" >"$output_file" 2>&1 || true
  # The agent's own final message, and nothing else, after the marker. Empty
  # when the agent produced none (e.g. the model call failed).
  printf '\n%s\n' "$CODEX_LAST_MESSAGE_MARKER" >>"$output_file"
  cat "$last_message" >>"$output_file" 2>/dev/null || true
  rm -f "$last_message"
}

# codex_last_message <output_file>: the agent's final message only.
codex_last_message() {
  local output_file="$1"
  awk -v m="$CODEX_LAST_MESSAGE_MARKER" 'found {print} $0 == m {found = 1}' "$output_file"
}

# smoke_line <output_file>: the JSON after SMOKE_RESULT: in the agent's final
# message, or empty.
smoke_line() {
  codex_last_message "$1" | grep "SMOKE_RESULT:" | tail -1 | sed 's/.*SMOKE_RESULT: *//'
}

# assert_last_message_contains <output_file> <needle>: the agent's own final
# message (not the echoed prompt or a tool transcript) contains the needle.
assert_last_message_contains() {
  codex_last_message "$1" | grep -qF -- "$2"
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
  codex_last_message "$output_file" | grep -q "SMOKE_RESULT:"
}

# The agent's answer only: its final message, never the echoed prompt (which
# spells out what each test asks the agent to write). Codex's own diagnostic
# lines are read from the whole capture by assert_mcp_started / _completed /
# _failed instead.
assert_output_contains() {
  local output_file="$1"
  local needle="$2"
  codex_last_message "$output_file" | grep -q -- "$needle"
}

# mcp_tool_call <tool> <arguments JSON> [extra curl arguments ...]
#   Calls one MCP tool directly (not through codex) and prints the raw JSON-RPC
#   response: the channel-independent check of what the platform answers.
mcp_tool_call() {
  local tool="$1" args="$2"
  shift 2
  local payload
  payload=$(jq -nc --arg t "$tool" --argjson a "$args" '{jsonrpc:"2.0",id:"1",method:"tools/call",params:{name:$t,arguments:$a}}')
  curl -s -X POST -H "Content-Type: application/json" -H "Accept: application/json" "$@" \
    -d "$payload" "$AXONFLOW_ENDPOINT/api/v1/mcp-server"
}

# mcp_override_count [extra curl arguments ...]
#   The count list_overrides reports, or empty when it did not answer a count.
mcp_override_count() {
  mcp_tool_call list_overrides '{"include_revoked":true}' "$@" \
    | jq -r '.result.content[0].text // ""' \
    | jq -r '.count // empty' 2>/dev/null
}

# assert_mcp_override_frozen <label> <raw MCP response>
#   0 when the answer is the retired-write tool error. A test that skips is not
#   a test (#3062): any other answer FAILS, with the response and the likely cause.
assert_mcp_override_frozen() {
  local label="$1" response="$2" is_error text
  is_error=$(printf '%s' "$response" | jq -r '.result.isError // false' 2>/dev/null)
  text=$(printf '%s' "$response" | jq -r '.result.content[0].text // ""' 2>/dev/null)
  if [ "$is_error" = "true" ] && [ "${text#"$OVERRIDE_FROZEN_PREFIX"}" != "$text" ]; then
    echo "PASS: $label answered the retired write: $(printf '%s' "$text" | cut -c1-100)..."
    return 0
  fi
  echo "FAIL: $label did not answer a tool error beginning \"$OVERRIDE_FROZEN_PREFIX\" (isError=$is_error)"
  echo "      Raw MCP response: $(printf '%s' "$response" | cut -c1-600)"
  case "$text" in
    *"scoped to an individual user"*)
      echo "      The session carried no per-user identity, so the platform refused it for"
      echo "      identity first. The test sends X-User-Email; the agent drops it unless"
      echo "      AXONFLOW_TRUST_IDENTITY_HEADERS=true is set on it. Only enable that when"
      echo "      every hop that can reach the agent asserts end-user identity from a"
      echo "      validated source."
      ;;
  esac
  return 1
}

# assert_rest_override_frozen <label> <http status> <body>
#   0 when a REST override write answered 409 LEGACY_POLICY_WRITE_FROZEN.
assert_rest_override_frozen() {
  local label="$1" status="$2" body="${3:-}" code
  code=$(printf '%s' "$body" | jq -r '.error.code? // empty' 2>/dev/null)
  if [ "$status" = "409" ] && [ "$code" = "$OVERRIDE_FROZEN_CODE" ]; then
    echo "PASS: $label answered HTTP 409 $OVERRIDE_FROZEN_CODE"
    return 0
  fi
  echo "FAIL: $label answered HTTP $status (expected 409 $OVERRIDE_FROZEN_CODE)"
  [ -n "$body" ] && echo "      Body: $(printf '%s' "$body" | cut -c1-600)"
  if [ "$status" = "401" ]; then
    echo "      The override endpoints check a per-user identity before they answer the"
    echo "      retirement. The agent removed the X-User-Email this test sent: set"
    echo "      AXONFLOW_TRUST_IDENTITY_HEADERS=true on the AGENT and restart it (only when"
    echo "      every hop that can reach it asserts end-user identity from a validated source)."
  fi
  return 1
}

# Mint a BLOCKED decision through the unauth MCP path so the resulting
# decision_id + audit row land in the same tenant codex sees. The statement is a
# destructive shell command, which the platform's shipped
# sys_dangerous_destructive_fs control blocks on check_policy. The SQL-injection
# statement this used before is ALLOWED by check_policy on AxonFlow v11.0.0, and
# an allowed decision has nothing to explain (explain_decision answers "Decision
# not found"). Echoes the decision_id only when the answer is a block, so a seed
# that was not blocked fails the caller's guard instead of passing an allow on.
mcp_seed_block() {
  local marker="${1:-mcp-block-$(date +%s)}"
  local payload
  payload=$(jq -n --arg m "rm -rf / --no-preserve-root # $marker" \
    '{jsonrpc:"2.0",id:"1",method:"tools/call",params:{name:"check_policy",arguments:{connector_type:"codex.Bash",statement:$m,operation:"execute"}}}')
  curl -s -X POST -H "Content-Type: application/json" -d "$payload" \
    "$AXONFLOW_ENDPOINT/api/v1/mcp-server" \
    | jq -r '.result.content[0].text // ""' \
    | jq -r 'if .allowed == false then (.decision_id // empty) else empty end' 2>/dev/null
}
