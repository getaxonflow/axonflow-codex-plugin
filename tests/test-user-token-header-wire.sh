#!/usr/bin/env bash
# Wire test for X-User-Token on the HOOK surfaces (axonflow-enterprise#2944,
# epic #2919: per-user identity + role on the fleet/MCP-server plane —
# codex port of the claude plugin's #2935).
#
# Unlike tests/test-user-token.sh (resolver unit + mcp-auth-headers.sh
# reference impl), this drives the ACTUAL hook scripts against a
# header-capturing mock agent and asserts the outbound requests carry
# X-User-Token when a per-user token is configured (env var AND 0600 file
# legs) — and DON'T when it is not (the common fleet state today), in which
# case every emitted header must be byte-for-byte what an unconfigured 1.5.x
# plugin sends. Covers both hook surfaces, and BOTH request classes on the
# pre-tool plane (check_policy plus the fire-and-forget blocked-audit POST,
# which reuse AUTH_HEADER):
#   - pre-tool-check.sh  → check_policy + audit_tool_call     (PreToolUse)
#   - post-tool-audit.sh → audit_tool_call + check_output     (PostToolUse)
#
# Also pins the #2944 fail-closed contract: with a token configured, an
# HTTP 401 from the agent → exit 2 + a stderr diagnostic naming the per-user
# token (never its value); unconfigured 401 keeps the pre-existing #2275
# cooldown fall-open (exit 0). And pins that the hooks NEVER leak the token
# value to stdout or stderr.
#
# Stdlib-only (bash + python3 + jq).

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRE_HOOK="$PLUGIN_DIR/scripts/pre-tool-check.sh"
POST_HOOK="$PLUGIN_DIR/scripts/post-tool-audit.sh"

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: python3/jq not on PATH"
  exit 0
fi

WORK="$(mktemp -d)"
CAP="$WORK/headers.log"    # one JSON object of request headers per line
: > "$CAP"
cleanup() { [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null; wait 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# Header-capturing mock agent. MOCK_BLOCK=1 returns a BLOCK decision so
# pre-tool-check.sh also fires its backgrounded audit_tool_call POST —
# proving the token rides AUTH_HEADER onto EVERY governed curl, not just the
# first one. MOCK_401=1 answers HTTP 401 with the agent's -32001 body for the
# fail-closed legs.
cat > "$WORK/server.py" <<'PY'
import http.server, json, os, sys
CAP = os.environ["CAP_FILE"]
BLOCK = os.environ.get("MOCK_BLOCK", "") == "1"
DENY401 = os.environ.get("MOCK_401", "") == "1"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok"); return
        self.send_response(404); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        _ = self.rfile.read(n) if n else b''
        with open(CAP, 'a') as f:
            f.write(json.dumps({k: v for k, v in self.headers.items()}) + "\n")
        if DENY401:
            body = {"jsonrpc":"2.0","id":"x","error":{"code":-32001,"message":"Authentication required"}}
            out = json.dumps(body).encode()
            self.send_response(401)
            self.send_header('Content-Type','application/json')
            self.send_header('Content-Length', str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
        if BLOCK:
            result = {"allowed": False, "block_reason": "wire-test block", "policies_evaluated": 1}
        else:
            result = {"allowed": True, "policies_evaluated": 0}
        body = {"jsonrpc":"2.0","id":"x","result":{"content":[{"type":"text","text":json.dumps(result)}]}}
        out = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length', str(len(out)))
        self.end_headers()
        self.wfile.write(out)
server = http.server.HTTPServer(('127.0.0.1', 0), H)
sys.stdout.write(str(server.server_address[1]) + "\n"); sys.stdout.flush()
server.serve_forever()
PY

start_server() { # <block-flag> [deny401-flag]
  if [ -n "${SRV_PID:-}" ]; then kill "$SRV_PID" 2>/dev/null; wait 2>/dev/null; fi
  : > "$WORK/port"
  CAP_FILE="$CAP" MOCK_BLOCK="$1" MOCK_401="${2:-0}" python3 "$WORK/server.py" > "$WORK/port" 2>/dev/null &
  SRV_PID=$!
  for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
  PORT="$(cat "$WORK/port" 2>/dev/null)"
  [ -n "$PORT" ] || { echo "FAIL: mock server did not start"; exit 1; }
  ENDPOINT="http://127.0.0.1:$PORT"
}

TOKEN='eyJhbGciOiJIUzI1NiJ9.eyJlbWFpbCI6ImRldkB4LmNvIiwicm9sZSI6ImRldmVsb3BlciJ9.wire-sig'

# run_hook <hook> <mode> — invokes a hook with a Write tool payload. mode:
#   env    — AXONFLOW_USER_TOKEN exported
#   file   — 0600 ~/.config/axonflow/user-token.json in a fresh HOME
#   none   — no token anywhere (the common fleet state)
# Fresh HOME per run (hermetic: no host credentials/stamps/throttles leak in;
# the file leg's HOME carries ONLY the token file). AXONFLOW_CODEX_CONFIG is
# pinned to a nonexistent path so a dev machine's real license token can't
# leak in. Hook stdout/stderr captured for the no-leak assertions.
HOOK_STDOUT="$WORK/hook-stdout.log"
HOOK_STDERR="$WORK/hook-stderr.log"
RUN_N=0
HOOK_EXIT=0
run_hook() {
  local hook="$1" mode="$2"
  RUN_N=$((RUN_N+1))
  local run_home="$WORK/home-$RUN_N"
  mkdir -p "$run_home"
  local input='{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt","content":"hello world"},"tool_response":{"success":true}}'
  local -a extra_env=()
  case "$mode" in
    env)
      extra_env=(AXONFLOW_USER_TOKEN="$TOKEN")
      ;;
    file)
      mkdir -p "$run_home/.config/axonflow"
      printf '{"token":"%s"}' "$TOKEN" > "$run_home/.config/axonflow/user-token.json"
      chmod 600 "$run_home/.config/axonflow/user-token.json"
      ;;
    none)
      ;;
  esac
  # ${extra_env[@]+...} guards the empty-array expansion under set -u on
  # bash < 4.4 (macOS ships 3.2).
  ( cd "$WORK" && echo "$input" | env -u AXONFLOW_USER_TOKEN -u AXONFLOW_LICENSE_TOKEN -u XDG_CACHE_HOME \
      HOME="$run_home" AXONFLOW_ENDPOINT="$ENDPOINT" AXONFLOW_AUTH="" \
      AXONFLOW_CODEX_CONFIG=/nonexistent-axonflow-toml \
      AXONFLOW_TELEMETRY=off ${extra_env[@]+"${extra_env[@]}"} "$hook" >"$HOOK_STDOUT" 2>"$HOOK_STDERR" )
  HOOK_EXIT=$?
  sleep 0.5  # let any backgrounded audit curl flush to the capture log
}

captured_count() { wc -l < "$CAP" | tr -d ' '; }
# every_captured_has_token — ALL captured requests carry X-User-Token == $TOKEN.
every_captured_has_token() {
  local total with_token
  total="$(captured_count)"
  with_token="$(jq -s --arg w "$TOKEN" '[.[] | select((."X-User-Token" // ."x-user-token") == $w)] | length' "$CAP")"
  [ "$total" -gt 0 ] && [ "$with_token" = "$total" ]
}
any_captured_has_token_key() {
  jq -e 'select(has("X-User-Token") or has("x-user-token"))' "$CAP" >/dev/null 2>&1
}
no_leak_in_hook_output() {
  ! grep -qF "$TOKEN" "$HOOK_STDOUT" "$HOOK_STDERR" 2>/dev/null
}

echo "== X-User-Token hook wire test (#2944) =="

# --- pre-tool-check.sh: env token, BLOCK decision → check_policy AND the
# backgrounded blocked-audit POST must BOTH carry the token ---
start_server 1
: > "$CAP"
run_hook "$PRE_HOOK" env
if [ "$HOOK_EXIT" -eq 2 ]; then
  pass "pre-tool-check.sh block path exits 2"
else
  fail "block path exit code was $HOOK_EXIT (expected 2)"
fi
if [ "$(captured_count)" -ge 2 ]; then
  pass "pre-tool-check.sh (block path) issued check_policy + audit_tool_call ($(captured_count) requests)"
else
  fail "expected >=2 captured requests on the block path, got $(captured_count)"
fi
if every_captured_has_token; then
  pass "pre-tool-check.sh sends X-User-Token on EVERY governed request (env leg)"
else
  fail "a pre-tool-check.sh request was missing X-User-Token: $(cat "$CAP")"
fi
no_leak_in_hook_output && pass "pre-tool-check.sh never leaks the token to stdout/stderr" \
  || fail "token value leaked into hook stdout/stderr"

# --- pre-tool-check.sh: 0600 file token ---
: > "$CAP"
run_hook "$PRE_HOOK" file
if every_captured_has_token; then
  pass "pre-tool-check.sh sends X-User-Token from a 0600 user-token.json"
else
  fail "file-leg request missing X-User-Token: $(cat "$CAP")"
fi

# --- pre-tool-check.sh: UNCONFIGURED (the common fleet state) → the header
# must be absent AND the header set must be byte-identical to pre-#2944
# behavior. Codex hooks send no per-user identity headers at all, so the
# expected set is exactly: transport headers + X-Axonflow-Client. ---
: > "$CAP"
run_hook "$PRE_HOOK" none
if any_captured_has_token_key; then
  fail "pre-tool-check.sh sent X-User-Token with no token configured: $(cat "$CAP")"
else
  pass "pre-tool-check.sh omits X-User-Token when unconfigured"
fi
UNEXPECTED="$(jq -s '[.[] | keys[]] | unique - ["Accept","Accept-Encoding","Content-Length","Content-Type","Host","User-Agent","X-Axonflow-Client"]' "$CAP")"
if [ "$UNEXPECTED" = "[]" ]; then
  pass "unconfigured pre-tool-check.sh header set has no new headers (byte-identical to 1.5.x)"
else
  fail "unconfigured run sent unexpected headers: $UNEXPECTED"
fi
# Set-equality proof: configured header set == unconfigured set + the token.
UNCONF_KEYS="$(jq -s '[.[] | keys[]] | unique' "$CAP")"
: > "$CAP"
run_hook "$PRE_HOOK" env
CONF_KEYS_MINUS_TOKEN="$(jq -s '[.[] | keys[]] | unique - ["X-User-Token"]' "$CAP")"
if [ "$UNCONF_KEYS" = "$CONF_KEYS_MINUS_TOKEN" ]; then
  pass "configured header set == unconfigured set + X-User-Token (no other drift)"
else
  fail "header-set drift beyond the token: unconfigured=$UNCONF_KEYS configured-minus-token=$CONF_KEYS_MINUS_TOKEN"
fi

# --- post-tool-audit.sh: env token → audit_tool_call + check_output carry it ---
start_server 0
: > "$CAP"
run_hook "$POST_HOOK" env
if [ "$(captured_count)" -ge 2 ] && every_captured_has_token; then
  pass "post-tool-audit.sh sends X-User-Token on every governed request (env leg, $(captured_count) requests)"
else
  fail "post-tool-audit.sh missing X-User-Token (got $(captured_count) requests): $(cat "$CAP")"
fi
no_leak_in_hook_output && pass "post-tool-audit.sh never leaks the token to stdout/stderr" \
  || fail "token value leaked into post-hook stdout/stderr"

# --- post-tool-audit.sh: 0600 file token ---
: > "$CAP"
run_hook "$POST_HOOK" file
if [ "$(captured_count)" -ge 1 ] && every_captured_has_token; then
  pass "post-tool-audit.sh sends X-User-Token from a 0600 user-token.json"
else
  fail "post-tool-audit.sh file leg missing X-User-Token: $(cat "$CAP")"
fi

# --- post-tool-audit.sh: unconfigured → absent ---
: > "$CAP"
run_hook "$POST_HOOK" none
if any_captured_has_token_key; then
  fail "post-tool-audit.sh sent X-User-Token with no token configured: $(cat "$CAP")"
else
  pass "post-tool-audit.sh omits X-User-Token when unconfigured"
fi

# --- world-readable file token → REFUSED on the real hook path, and the
# refusal diagnostic names the file without leaking the value ---
start_server 1
: > "$CAP"
RUN_N=$((RUN_N+1))
BAD_HOME="$WORK/home-$RUN_N"
mkdir -p "$BAD_HOME/.config/axonflow"
printf '{"token":"%s"}' "$TOKEN" > "$BAD_HOME/.config/axonflow/user-token.json"
chmod 644 "$BAD_HOME/.config/axonflow/user-token.json"
( cd "$WORK" && echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt","content":"hello"},"tool_response":{"success":true}}' \
  | env -u AXONFLOW_USER_TOKEN -u AXONFLOW_LICENSE_TOKEN -u XDG_CACHE_HOME \
      HOME="$BAD_HOME" AXONFLOW_ENDPOINT="$ENDPOINT" AXONFLOW_AUTH="" \
      AXONFLOW_CODEX_CONFIG=/nonexistent-axonflow-toml \
      AXONFLOW_TELEMETRY=off "$PRE_HOOK" >"$HOOK_STDOUT" 2>"$HOOK_STDERR" )
sleep 0.5
if any_captured_has_token_key; then
  fail "pre-tool-check.sh used a world-readable user-token.json: $(cat "$CAP")"
else
  pass "pre-tool-check.sh refuses a world-readable (0644) user-token.json"
fi
if grep -q "unsafe permissions" "$HOOK_STDERR" && ! grep -qF "$TOKEN" "$HOOK_STDERR"; then
  pass "0644 refusal diagnostic fires on stderr without leaking the value"
else
  fail "0644 refusal diagnostic missing or leaked the token: $(cat "$HOOK_STDERR")"
fi

# --- #2944 fail-closed: token configured + agent 401/-32001 → exit 2 with a
# diagnostic naming the per-user token; NO value leak. Unconfigured 401 keeps
# the pre-existing #2275 cooldown fall-open (exit 0). ---
start_server 0 1
: > "$CAP"
run_hook "$PRE_HOOK" env
if [ "$HOOK_EXIT" -eq 2 ]; then
  pass "401 with a configured token → exit 2 (fail-closed, no silent fall-open)"
else
  fail "401 with a configured token exited $HOOK_EXIT (expected 2)"
fi
if grep -q "per-user token" "$HOOK_STDERR"; then
  pass "fail-closed diagnostic names the per-user token as a likely cause"
else
  fail "fail-closed diagnostic does not mention the per-user token: $(cat "$HOOK_STDERR")"
fi
no_leak_in_hook_output && pass "fail-closed diagnostic does not leak the token value" \
  || fail "token value leaked in the fail-closed diagnostic"

# Cooldown persistence: with the auth-failure throttle now stamped, the NEXT
# call with a token must keep denying locally (exit 2, no new request) —
# not fall open through the throttle short-circuit.
BEFORE_COUNT="$(captured_count)"
THROTTLE_HOME="$WORK/home-$RUN_N"   # reuse the run_hook HOME that owns the stamp
( cd "$WORK" && echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt","content":"hello world"},"tool_response":{"success":true}}' \
  | env -u AXONFLOW_USER_TOKEN -u AXONFLOW_LICENSE_TOKEN -u XDG_CACHE_HOME \
      HOME="$THROTTLE_HOME" AXONFLOW_ENDPOINT="$ENDPOINT" AXONFLOW_AUTH="" \
      AXONFLOW_CODEX_CONFIG=/nonexistent-axonflow-toml \
      AXONFLOW_TELEMETRY=off AXONFLOW_USER_TOKEN="$TOKEN" "$PRE_HOOK" >"$HOOK_STDOUT" 2>"$HOOK_STDERR" )
SECOND_EXIT=$?
sleep 0.3
if [ "$SECOND_EXIT" -eq 2 ] && [ "$(captured_count)" = "$BEFORE_COUNT" ] && grep -q "per-user token" "$HOOK_STDERR"; then
  pass "auth-failure cooldown + token → local deny (exit 2, zero new requests)"
else
  fail "cooldown behavior wrong: exit=$SECOND_EXIT new-requests=$(( $(captured_count) - BEFORE_COUNT ))"
fi

# Unconfigured 401 → unchanged #2275 contract: cooldown stamped, exit 0.
: > "$CAP"
run_hook "$PRE_HOOK" none
if [ "$HOOK_EXIT" -eq 0 ]; then
  pass "401 with NO token configured keeps the pre-existing cooldown fall-open (exit 0)"
else
  fail "unconfigured 401 exited $HOOK_EXIT (expected 0 — behavior change for unconfigured users!)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
