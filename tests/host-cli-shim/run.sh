#!/usr/bin/env bash
# Host-CLI shim test for the Codex plugin.
#
# Stages the plugin payload as Codex would, parses .codex-plugin/plugin.json
# and hooks/hooks.json, and drives the discovered hook scripts via Codex's
# JSON-on-stdin contract through a full PreToolUse → tool → PostToolUse
# lifecycle. Captures every agent request to a stdlib stub and asserts the
# X-License-Token forwarding contract across Free / Pro-env / Pro-file
# scenarios + the PreToolUse-deny path.
#
# Differences from the Claude shim:
#   - Codex's hooks.json uses Capitalized event names like Claude (PreToolUse,
#     PostToolUse) but with relative ./scripts/ paths, not ${PLUGIN_ROOT}
#     expansion.
#   - Codex's deny contract is exit code 2 + stderr message (not JSON
#     hookSpecificOutput). Same as Cursor.
#   - License token is read from env OR ~/.codex/axonflow.toml's
#     license_token = "..." key. Override the path via AXONFLOW_CODEX_CONFIG.
#   - .mcp.json has NO headersHelper today (codex#43 — sister bug to
#     claude#56). The MCP-forwarding assertion is XFAIL until that lands.
#
# Stdlib-only: bash + curl + jq + python3 stub. No live AxonFlow stack.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not on PATH"
  exit 0
fi

STAGE_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t host-cli-shim)
LOG_DIR="$STAGE_DIR/.logs"
HOME_DIR="$STAGE_DIR/home"
CAPTURE_FILE="$STAGE_DIR/capture.jsonl"
CODEX_CONFIG="$HOME_DIR/.codex/axonflow.toml"
mkdir -p "$LOG_DIR" "$HOME_DIR/.codex"
chmod 0700 "$HOME_DIR/.codex"

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { [ -n "${PASS_PRINT:-}" ] && echo "  PASS: $1"; PASS=$((PASS+1)); }
xfail() { echo "  XFAIL (expected, tracked): $1"; }

cleanup() {
  if [ -n "${STUB_PID:-}" ]; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
  fi
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Stage the plugin payload
# ---------------------------------------------------------------------------
echo "stage plugin to $STAGE_DIR/plugin"
PLUGIN_STAGE="$STAGE_DIR/plugin"
mkdir -p "$PLUGIN_STAGE/.codex-plugin" "$PLUGIN_STAGE/hooks" \
         "$PLUGIN_STAGE/scripts/lib"

cp -p "$PLUGIN_DIR/.codex-plugin/plugin.json" "$PLUGIN_STAGE/.codex-plugin/" \
  || { fail "missing .codex-plugin/plugin.json"; exit 1; }
cp -p "$PLUGIN_DIR/.mcp.json" "$PLUGIN_STAGE/" \
  || { fail "missing .mcp.json"; exit 1; }
cp -p "$PLUGIN_DIR/hooks/hooks.json" "$PLUGIN_STAGE/hooks/" \
  || { fail "missing hooks/hooks.json"; exit 1; }

cp -p "$PLUGIN_DIR/scripts"/*.sh "$PLUGIN_STAGE/scripts/"
cp -p "$PLUGIN_DIR/scripts/lib"/*.sh "$PLUGIN_STAGE/scripts/lib/"
chmod +x "$PLUGIN_STAGE/scripts/"*.sh
[ -d "$PLUGIN_STAGE/scripts/lib" ] && chmod +x "$PLUGIN_STAGE/scripts/lib/"*.sh 2>/dev/null || true

pass "plugin payload staged"

# ---------------------------------------------------------------------------
# 2. Parse manifests
# ---------------------------------------------------------------------------
PLUGIN_NAME=$(jq -r '.name' "$PLUGIN_STAGE/.codex-plugin/plugin.json")
[ "$PLUGIN_NAME" = "axonflow" ] && pass "plugin name=axonflow" \
  || fail "plugin name mismatch: got '$PLUGIN_NAME'"

# Codex hooks.json: Capitalized event names, nested matcher → hooks.
PRE_HOOK_CMD=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$PLUGIN_STAGE/hooks/hooks.json")
POST_HOOK_CMD=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$PLUGIN_STAGE/hooks/hooks.json")

PRE_HOOK_RESOLVED="$PLUGIN_STAGE/${PRE_HOOK_CMD#./}"
POST_HOOK_RESOLVED="$PLUGIN_STAGE/${POST_HOOK_CMD#./}"

[ -x "$PRE_HOOK_RESOLVED" ] && pass "PreToolUse hook resolves: $(basename "$PRE_HOOK_RESOLVED")" \
  || fail "PreToolUse hook not executable at '$PRE_HOOK_RESOLVED'"
[ -x "$POST_HOOK_RESOLVED" ] && pass "PostToolUse hook resolves: $(basename "$POST_HOOK_RESOLVED")" \
  || fail "PostToolUse hook not executable at '$POST_HOOK_RESOLVED'"

HEADERS_HELPER=$(jq -r '.mcpServers.axonflow.headersHelper // empty' "$PLUGIN_STAGE/.mcp.json")

# ---------------------------------------------------------------------------
# 3. Start the capture stub
# ---------------------------------------------------------------------------
STUB_LOG="$LOG_DIR/stub.log"
CAPTURE_FILE="$CAPTURE_FILE" \
  python3 "$SCRIPT_DIR/capture-stub.py" 0 >"$STUB_LOG" 2>&1 &
STUB_PID=$!

PORT=""
for _ in $(seq 1 50); do
  if grep -q '^PORT=' "$STUB_LOG" 2>/dev/null; then
    PORT=$(grep -oE 'PORT=[0-9]+' "$STUB_LOG" | head -1 | cut -d= -f2)
    break
  fi
  sleep 0.1
done
if [ -z "$PORT" ]; then
  fail "capture-stub failed to start"
  cat "$STUB_LOG"
  exit 1
fi
pass "capture-stub listening on 127.0.0.1:$PORT"
ENDPOINT="http://127.0.0.1:$PORT"

curl -sSf -o /dev/null --max-time 2 "$ENDPOINT/health" \
  && pass "stub /health responds" \
  || { fail "stub /health unreachable"; exit 1; }

# ---------------------------------------------------------------------------
# 4. Lifecycle helpers
# ---------------------------------------------------------------------------
reset_captures() { : > "$CAPTURE_FILE"; }

# Codex pre-tool-check.sh accepts {tool_name, tool_input.command} on stdin
# (same shape as Claude / Cursor) and returns exit 0 (allow) or exit 2
# (deny + stderr message). License token resolution: env wins, then
# ~/.codex/axonflow.toml's license_token key (override path via
# AXONFLOW_CODEX_CONFIG).
fire_pretooluse() {
  local statement="${1:-echo benign}"
  echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$statement\"}}" | \
    HOME="$HOME_DIR" \
    AXONFLOW_ENDPOINT="$ENDPOINT" \
    AXONFLOW_TELEMETRY=off \
    AXONFLOW_LICENSE_TOKEN="${LICENSE_TOKEN:-}" \
    AXONFLOW_AUTH="${AXONFLOW_AUTH:-}" \
    AXONFLOW_CODEX_CONFIG="$CODEX_CONFIG" \
    "$PRE_HOOK_RESOLVED" 2>&1 1>/dev/null
}

pretooluse_exit_code() {
  local statement="${1:-echo benign}"
  echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$statement\"}}" | \
    HOME="$HOME_DIR" \
    AXONFLOW_ENDPOINT="$ENDPOINT" \
    AXONFLOW_TELEMETRY=off \
    AXONFLOW_LICENSE_TOKEN="${LICENSE_TOKEN:-}" \
    AXONFLOW_AUTH="${AXONFLOW_AUTH:-}" \
    AXONFLOW_CODEX_CONFIG="$CODEX_CONFIG" \
    "$PRE_HOOK_RESOLVED" >/dev/null 2>&1
  echo $?
}

fire_posttooluse() {
  local statement="${1:-echo benign}"
  local stdout="${2:-ok}"
  echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$statement\"},\"tool_response\":{\"stdout\":\"$stdout\",\"exitCode\":0}}" | \
    HOME="$HOME_DIR" \
    AXONFLOW_ENDPOINT="$ENDPOINT" \
    AXONFLOW_TELEMETRY=off \
    AXONFLOW_LICENSE_TOKEN="${LICENSE_TOKEN:-}" \
    AXONFLOW_AUTH="${AXONFLOW_AUTH:-}" \
    AXONFLOW_CODEX_CONFIG="$CODEX_CONFIG" \
    "$POST_HOOK_RESOLVED" >/dev/null 2>&1
}

captured_with_license_token() {
  jq -s 'map(select(.headers["x-license-token"] != null)) | length' "$CAPTURE_FILE"
}

# Returns the count of captured requests carrying X-Axonflow-Client (ADR-050 §4).
captured_with_client_header() {
  jq -s 'map(select(.headers["x-axonflow-client"] != null)) | length' "$CAPTURE_FILE"
}

captured_with_tool() {
  local tool="$1"
  jq -s --arg t "$tool" 'map(select(.tool_name == $t)) | length' "$CAPTURE_FILE"
}

invoke_headers_helper() {
  if [ -z "$HEADERS_HELPER" ]; then
    echo ""
    return
  fi
  CODEX_PLUGIN_ROOT="$PLUGIN_STAGE" \
  HOME="$HOME_DIR" \
  AXONFLOW_ENDPOINT="$ENDPOINT" \
  AXONFLOW_LICENSE_TOKEN="${LICENSE_TOKEN:-}" \
  AXONFLOW_AUTH="${AXONFLOW_AUTH:-}" \
  AXONFLOW_CODEX_CONFIG="$CODEX_CONFIG" \
  bash -c "$HEADERS_HELPER" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 5. Scenario A — Free tier
# ---------------------------------------------------------------------------
echo "--- scenario: Free tier ---"
LICENSE_TOKEN=""
rm -f "$CODEX_CONFIG"
reset_captures
fire_pretooluse "echo benign"
fire_posttooluse "echo benign" "ok"

PRE_REQ_COUNT=$(captured_with_tool "check_policy")
[ "$PRE_REQ_COUNT" -ge 1 ] && pass "Free: PreToolUse fired check_policy" \
  || fail "Free: PreToolUse did not call check_policy (got $PRE_REQ_COUNT)"

POST_REQ_COUNT=$(captured_with_tool "audit_tool_call")
[ "$POST_REQ_COUNT" -ge 1 ] && pass "Free: PostToolUse fired audit_tool_call" \
  || fail "Free: PostToolUse did not call audit_tool_call (got $POST_REQ_COUNT)"

LIC_COUNT=$(captured_with_license_token)
[ "$LIC_COUNT" -eq 0 ] && pass "Free: NO captured requests carry X-License-Token" \
  || fail "Free: $LIC_COUNT request(s) carried X-License-Token (should be 0)"

# ADR-050 §4: X-Axonflow-Client ships on EVERY request regardless of tier.
CLIENT_COUNT=$(captured_with_client_header)
TOTAL_COUNT_FREE=$(jq -s 'length' "$CAPTURE_FILE")
if [ "$CLIENT_COUNT" -ge 1 ] && [ "$CLIENT_COUNT" -eq "$TOTAL_COUNT_FREE" ]; then
  pass "Free: ALL $TOTAL_COUNT_FREE captured request(s) carry X-Axonflow-Client"
else
  fail "Free: $CLIENT_COUNT of $TOTAL_COUNT_FREE carried X-Axonflow-Client (expected all)"
fi

# ---------------------------------------------------------------------------
# 6. Scenario B — Pro tier (env)
# ---------------------------------------------------------------------------
echo "--- scenario: Pro tier (env) ---"
LICENSE_TOKEN="AXON-shim-pro-test-token-must-be-32-chars-long-XYZW"
reset_captures
fire_pretooluse "echo benign-pro"
fire_posttooluse "echo benign-pro" "ok"

LIC_COUNT=$(captured_with_license_token)
TOTAL_COUNT=$(jq -s 'length' "$CAPTURE_FILE")
if [ "$LIC_COUNT" -ge 1 ] && [ "$LIC_COUNT" -eq "$TOTAL_COUNT" ]; then
  pass "Pro/env: ALL $TOTAL_COUNT captured request(s) carry X-License-Token"
else
  fail "Pro/env: $LIC_COUNT of $TOTAL_COUNT captured requests carried X-License-Token (expected all)"
fi
# ADR-050 §4: X-Axonflow-Client ships on EVERY request, including Pro/env.
CLIENT_COUNT=$(captured_with_client_header)
if [ "$CLIENT_COUNT" -eq "$TOTAL_COUNT" ]; then
  pass "Pro/env: ALL $TOTAL_COUNT captured request(s) carry X-Axonflow-Client"
else
  fail "Pro/env: $CLIENT_COUNT of $TOTAL_COUNT carried X-Axonflow-Client (expected all)"
fi

TOKEN_OBSERVED=$(jq -s -r '.[0].headers["x-license-token"] // empty' "$CAPTURE_FILE")
[ "$TOKEN_OBSERVED" = "$LICENSE_TOKEN" ] && pass "Pro/env: captured token value matches AXONFLOW_LICENSE_TOKEN" \
  || fail "Pro/env: captured token '$TOKEN_OBSERVED' != env '$LICENSE_TOKEN'"

# Codex MCP shape supports only `--url` + `--bearer-token-env-var` for
# HTTP servers (verified 2026-05-05 via `codex mcp add --help` and a
# real codex MCP probe of an HTTP URL — proxy log showed
# X-Axonflow-Client=<absent>). There is no headersHelper / dynamic-header
# field. MCP-session traffic from Codex → AxonFlow MCP server carries
# zero per-tier headers. Pro-tier customers using MCP-session paths get
# Free-tier enforcement until either
# (a) Codex adds dynamic-header support upstream, or
# (b) we switch to a stdio MCP server that runs as subprocess and can
#     inject headers in the proxy hop.
# Tracked as codex#43.
if [ -z "$HEADERS_HELPER" ]; then
  xfail "Pro/env: .mcp.json has no headersHelper — Codex MCP doesn't support that field (codex#43)"
else
  HEADERS_PRO=$(invoke_headers_helper)
  if echo "$HEADERS_PRO" | jq -e --arg t "$LICENSE_TOKEN" '."X-License-Token" == $t' >/dev/null 2>&1; then
    pass "Pro/env: headersHelper forwards X-License-Token (codex#43 fixed)"
  else
    xfail "Pro/env: headersHelper drops X-License-Token (codex#43). got: $HEADERS_PRO"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Scenario C — Pro tier (~/.codex/axonflow.toml)
# ---------------------------------------------------------------------------
echo "--- scenario: Pro tier (axonflow.toml) ---"
LICENSE_TOKEN=""
TOKEN_VALUE="AXON-shim-pro-toml-token-must-be-32-chars-PQRS"
cat > "$CODEX_CONFIG" <<EOF
# host-cli-shim test config
license_token = "$TOKEN_VALUE"
EOF
chmod 0600 "$CODEX_CONFIG"
reset_captures

fire_pretooluse "echo toml-pro"
fire_posttooluse "echo toml-pro" "ok"

LIC_COUNT=$(captured_with_license_token)
TOTAL_COUNT=$(jq -s 'length' "$CAPTURE_FILE")
if [ "$LIC_COUNT" -ge 1 ] && [ "$LIC_COUNT" -eq "$TOTAL_COUNT" ]; then
  pass "Pro/toml: ALL $TOTAL_COUNT captured request(s) carry X-License-Token"
else
  fail "Pro/toml: $LIC_COUNT of $TOTAL_COUNT captured requests carried X-License-Token (expected all)"
fi

# ADR-050 §4: X-Axonflow-Client ships on EVERY request, including Pro/toml.
CLIENT_COUNT=$(captured_with_client_header)
if [ "$CLIENT_COUNT" -eq "$TOTAL_COUNT" ]; then
  pass "Pro/toml: ALL $TOTAL_COUNT captured request(s) carry X-Axonflow-Client"
else
  fail "Pro/toml: $CLIENT_COUNT of $TOTAL_COUNT carried X-Axonflow-Client (expected all)"
fi

TOKEN_OBSERVED=$(jq -s -r '.[0].headers["x-license-token"] // empty' "$CAPTURE_FILE")
[ "$TOKEN_OBSERVED" = "$TOKEN_VALUE" ] && pass "Pro/toml: captured token value matches license_token in axonflow.toml" \
  || fail "Pro/toml: captured token '$TOKEN_OBSERVED' != toml '$TOKEN_VALUE'"

# Defense-in-depth: an obviously-malformed token (no AXON- prefix) is
# silently dropped by lib/license-token.sh's prefix guard. Verify the wire
# stays clean — agent never sees garbage.
cat > "$CODEX_CONFIG" <<EOF
license_token = "BOGUS-not-a-valid-axonflow-token"
EOF
chmod 0600 "$CODEX_CONFIG"
reset_captures
fire_pretooluse "echo malformed-token"
LIC_COUNT=$(captured_with_license_token)
[ "$LIC_COUNT" -eq 0 ] && pass "Pro/toml: malformed token (no AXON- prefix) is dropped (no X-License-Token on wire)" \
  || fail "Pro/toml: malformed token forwarded in $LIC_COUNT request(s)"

# ---------------------------------------------------------------------------
# 8. Scenario D — PreToolUse deny path (Codex: exit 2 + stderr)
# ---------------------------------------------------------------------------
echo "--- scenario: PreToolUse deny path ---"
LICENSE_TOKEN="AXON-shim-pro-deny-token-must-be-32-chars-DENY"
rm -f "$CODEX_CONFIG"
reset_captures

DENY_STDERR=$(fire_pretooluse "deny-me operation")
DENY_EXIT=$(pretooluse_exit_code "deny-me operation")

[ "$DENY_EXIT" = "2" ] && pass "Deny: PreToolUse exited 2 (block)" \
  || fail "Deny: PreToolUse exit code was $DENY_EXIT (expected 2)"

if echo "$DENY_STDERR" | grep -q "policy violation\|stub-deny"; then
  pass "Deny: PreToolUse stderr surfaced block reason"
else
  fail "Deny: PreToolUse stderr missing block reason: $DENY_STDERR"
fi

# Background fire-and-forget — poll.
AUDIT_BLOCKED=0
for _ in $(seq 1 30); do
  AUDIT_BLOCKED=$(captured_with_tool "audit_tool_call")
  [ "$AUDIT_BLOCKED" -ge 1 ] && break
  sleep 0.1
done
[ "$AUDIT_BLOCKED" -ge 1 ] && pass "Deny: blocked-attempt audit_tool_call captured" \
  || fail "Deny: blocked attempt did not emit audit_tool_call (got $AUDIT_BLOCKED)"

LIC_COUNT=$(captured_with_license_token)
[ "$LIC_COUNT" -ge 2 ] && pass "Deny: X-License-Token forwarded on both check_policy AND audit_tool_call" \
  || fail "Deny: X-License-Token only on $LIC_COUNT request(s) (expected ≥2)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== host-cli-shim summary (codex) ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
