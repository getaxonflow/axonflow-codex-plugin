#!/usr/bin/env bash
# Runtime E2E: W3 free email-recovery flow, exercised through the Codex
# plugin's recover.sh user surface.
#
# The platform side ships /api/v1/recover and /api/v1/recover/verify in
# axonflow-enterprise PR #1850. The plugin side adds scripts/recover.sh
# (this PR) so users can drive the flow without leaving Codex.
#
# Two independent paths under test:
#
#   1. Against a LIVE community-saas agent at $AGENT_URL — when reachable
#      AND the agent advertises the recovery endpoint via /health. The
#      runtime-e2e harness from axonflow-enterprise (runtime-e2e/recovery
#      /test.sh) covers the full magic-link → verify → credentials path
#      with email capture; here we just assert recover.sh hits the live
#      endpoint and gets a 202.
#
#   2. Against a LOCAL fake agent — always runs. A tiny python http
#      server stands in for the agent; the test drives recover.sh
#      programmatically (AXONFLOW_RECOVER_EMAIL + AXONFLOW_RECOVER_TOKEN
#      via env so no TTY prompts) and asserts the plugin persists the
#      returned credentials atomically into ~/.codex/axonflow.toml with
#      mode 0600.
#
# Per FEATURE_RUNTIME_COVERAGE.md methodology: this is the runtime-path
# test the recovery surface ships with. README claims aren't proof.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RECOVER="$PLUGIN_DIR/scripts/recover.sh"

AGENT_URL="${AGENT_URL:-${AXONFLOW_AGENT_URL:-http://localhost:8080}}"

pass=0
fail=0
PASS() { printf '  PASS: %s\n' "$1"; pass=$((pass+1)); }
FAIL() { printf '  FAIL: %s\n' "$1"; fail=$((fail+1)); }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "SKIP: $1 not on PATH"; exit 0; }
}
require curl
require jq
require python3

echo "=== runtime-e2e: recovery surface (Codex plugin) ==="
echo "Agent URL:   $AGENT_URL"
echo "Plugin dir:  $PLUGIN_DIR"
echo ""

# -----------------------------------------------------------------------------
# Local fake agent: minimal /api/v1/recover[/verify] implementation. Returns
# 202 on /api/v1/recover and a recovery-shaped JSON on POST /api/v1/recover/verify.
# Token is whatever the test passes in; the fake is just a contract recorder.
# -----------------------------------------------------------------------------
PORT=18298
SERVER_LOG=$(mktemp -t axonflow-recovery-server.XXXXXX)
SERVER_SCRIPT=$(mktemp -t axonflow-recovery-server.XXXXXX.py)
TMP_HOME=$(mktemp -d -t axonflow-recovery-home.XXXXXX)

cat >"$SERVER_SCRIPT" <<'PYEOF'
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer
port = int(sys.argv[1])
class H(BaseHTTPRequestHandler):
    def log_message(self, *a, **kw): return
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok"); return
        self.send_response(404); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(n) if n else b""
        try:
            req = json.loads(body or b"{}")
        except Exception:
            req = {}
        if self.path == "/api/v1/recover":
            # Anti-enum: always 202.
            self.send_response(202); self.end_headers(); return
        if self.path == "/api/v1/recover/verify":
            tok = req.get("token", "")
            if not tok:
                self.send_response(400); self.end_headers(); return
            # Simulate a one-shot consume: any token starting with
            # "consumed_" is rejected so we can drive the replay-rejected
            # assertion. Anything else issues a fresh credential pair.
            if tok.startswith("consumed_"):
                self.send_response(401)
                self.send_header("Content-Type", "application/json"); self.end_headers()
                self.wfile.write(b'{"error":"already been used"}')
                return
            resp = {
                "tenant_id": "tenant-abc-recovered-" + tok[:8],
                "secret": "secret-xyz-" + tok[:8],
                "secret_prefix": "sk_test_",
                "expires_at": "2027-01-01T00:00:00Z",
                "endpoint": "http://127.0.0.1:%d" % port,
                "email": "user@axonflow-test.invalid",
                "note": "fake recovery agent — for plugin runtime-e2e only"
            }
            self.send_response(200)
            self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(json.dumps(resp).encode())
            return
        self.send_response(404); self.end_headers()
HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF

python3 "$SERVER_SCRIPT" "$PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null; rm -rf "$TMP_HOME" "$SERVER_LOG" "$SERVER_SCRIPT"' EXIT

for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
if ! curl -sS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  echo "FAIL: fake recovery agent failed to start. Log:"
  cat "$SERVER_LOG"
  exit 1
fi
echo "  fake agent up at http://127.0.0.1:$PORT"

FAKE_AGENT="http://127.0.0.1:$PORT"

# -----------------------------------------------------------------------------
# Test 1: scripts/recover.sh request → 202.
# -----------------------------------------------------------------------------
echo ""
echo "Test 1: recover.sh request hits /api/v1/recover and gets 202"
OUT=$(AXONFLOW_ENDPOINT="$FAKE_AGENT" \
      AXONFLOW_RECOVER_EMAIL="recovery-e2e@axonflow-test.invalid" \
      bash "$RECOVER" request 2>&1) && rc=0 || rc=$?
if [ "$rc" = "0" ] && echo "$OUT" | grep -q "Magic link requested"; then
  PASS "request subcommand reached the agent and reported 202"
else
  FAIL "request subcommand failed (rc=$rc). Output: $OUT"
fi

# -----------------------------------------------------------------------------
# Test 2: scripts/recover.sh verify with a valid-shaped token.
# -----------------------------------------------------------------------------
echo ""
echo "Test 2: recover.sh verify hits /api/v1/recover/verify and persists creds"
TOKEN="abcdef1234567890fedcba0987654321abcdef1234567890fedcba0987654321"
OUT=$(AXONFLOW_ENDPOINT="$FAKE_AGENT" \
      AXONFLOW_RECOVER_TOKEN="$TOKEN" \
      AXONFLOW_CODEX_CONFIG="$TMP_HOME/.codex/axonflow.toml" \
      bash "$RECOVER" verify 2>&1) && rc=0 || rc=$?
if [ "$rc" != "0" ]; then
  FAIL "verify subcommand failed (rc=$rc). Output: $OUT"
fi

if [ -f "$TMP_HOME/.codex/axonflow.toml" ]; then
  PASS "TOML config file written"
else
  FAIL "TOML config file NOT written"
fi

# Each persisted key.
for k in tenant_id secret endpoint email; do
  if grep -q "^$k = \"" "$TMP_HOME/.codex/axonflow.toml" 2>/dev/null; then
    PASS "TOML contains $k"
  else
    FAIL "TOML missing $k. File contents:"
    cat "$TMP_HOME/.codex/axonflow.toml" 2>/dev/null | sed 's/^/      /'
  fi
done

# Mode is 0600.
PERMS=$(stat -c '%a' "$TMP_HOME/.codex/axonflow.toml" 2>/dev/null || stat -f '%Lp' "$TMP_HOME/.codex/axonflow.toml" 2>/dev/null || echo "")
if [ "$PERMS" = "600" ] || [ "$PERMS" = "0600" ]; then
  PASS "TOML written with mode 0600"
else
  FAIL "TOML mode was '$PERMS', expected 600"
fi

# Persisted tenant_id matches what the fake agent returned.
EXPECTED_TENANT="tenant-abc-recovered-${TOKEN:0:8}"
ACTUAL_TENANT=$(grep '^tenant_id = ' "$TMP_HOME/.codex/axonflow.toml" 2>/dev/null | head -1 | sed 's/tenant_id = "\(.*\)"/\1/')
if [ "$ACTUAL_TENANT" = "$EXPECTED_TENANT" ]; then
  PASS "persisted tenant_id matches verify response"
else
  FAIL "persisted tenant_id '$ACTUAL_TENANT' != expected '$EXPECTED_TENANT'"
fi

# -----------------------------------------------------------------------------
# Test 3: replay rejection — recover.sh verify with a "consumed_" token gets
# a non-zero exit and does NOT clobber the previously-persisted creds.
# -----------------------------------------------------------------------------
echo ""
echo "Test 3: replay rejection — consumed token does NOT overwrite creds"
SAVED=$(cat "$TMP_HOME/.codex/axonflow.toml")
OUT=$(AXONFLOW_ENDPOINT="$FAKE_AGENT" \
      AXONFLOW_RECOVER_TOKEN="consumed_replayed_token_xyz" \
      AXONFLOW_CODEX_CONFIG="$TMP_HOME/.codex/axonflow.toml" \
      bash "$RECOVER" verify 2>&1) && rc=0 || rc=$?
if [ "$rc" != "0" ]; then
  PASS "consumed token rejected with non-zero exit"
else
  FAIL "consumed token was accepted (rc=0). Output: $OUT"
fi
if [ "$(cat "$TMP_HOME/.codex/axonflow.toml")" = "$SAVED" ]; then
  PASS "previously-persisted creds were NOT overwritten by failed verify"
else
  FAIL "failed verify CLOBBERED previously-persisted creds"
fi

# -----------------------------------------------------------------------------
# Test 4: license_token preservation — apply-token, then re-verify, ensure
# the license_token line survives the credential rewrite.
# -----------------------------------------------------------------------------
echo ""
echo "Test 4: re-verifying credentials preserves an existing license_token"
AXONFLOW_CODEX_CONFIG="$TMP_HOME/.codex/axonflow.toml" \
  AXONFLOW_LICENSE_TOKEN="AXON-existing-paid-token" \
  bash "$RECOVER" apply-token >/dev/null 2>&1
TOKEN2="ffffffff1111222233334444555566667777888899990000aaaabbbbccccdddd"
AXONFLOW_ENDPOINT="$FAKE_AGENT" \
  AXONFLOW_RECOVER_TOKEN="$TOKEN2" \
  AXONFLOW_CODEX_CONFIG="$TMP_HOME/.codex/axonflow.toml" \
  bash "$RECOVER" verify >/dev/null 2>&1
if grep -q '^license_token = "AXON-existing-paid-token"' "$TMP_HOME/.codex/axonflow.toml" 2>/dev/null; then
  PASS "existing license_token preserved through credential re-recovery"
else
  FAIL "license_token was lost across credential re-recovery. File:"
  cat "$TMP_HOME/.codex/axonflow.toml" 2>/dev/null | sed 's/^/      /'
fi

# -----------------------------------------------------------------------------
# Test 5: status surface picks up the persisted license token.
# -----------------------------------------------------------------------------
echo ""
echo "Test 5: status surface reports Pro tier active after apply-token"
STATUS_OUT=$(AXONFLOW_CODEX_CONFIG="$TMP_HOME/.codex/axonflow.toml" \
             bash "$RECOVER" status 2>&1)
if echo "$STATUS_OUT" | grep -q "Pro tier active"; then
  PASS "status reports Pro tier active from persisted TOML"
else
  FAIL "status did not report Pro tier from persisted TOML. Output: $STATUS_OUT"
fi

# -----------------------------------------------------------------------------
# Test 6: live agent at $AGENT_URL — only assert when the agent advertises
# the recovery capability via /health (PR #1850 marker).
# -----------------------------------------------------------------------------
echo ""
echo "Test 6: live agent recovery endpoint (optional)"
if curl -sS --max-time 3 "$AGENT_URL/health" >/dev/null 2>&1; then
  HEALTH=$(curl -sS --max-time 3 "$AGENT_URL/health" 2>/dev/null || echo '{}')
  HAS_REC="no"
  if echo "$HEALTH" | jq -e '.capabilities[]? | select(.name == "community_saas_recovery")' >/dev/null 2>&1; then
    HAS_REC="yes"
  fi
  if [ "$HAS_REC" != "yes" ] && [ "${AXONFLOW_ASSERT_LIVE_RECOVERY:-0}" != "1" ]; then
    echo "  SKIP: live agent at $AGENT_URL does not advertise community_saas_recovery capability."
    echo "        Set AXONFLOW_ASSERT_LIVE_RECOVERY=1 to force the assertion against a custom build."
  else
    LIVE_EMAIL="codex-runtime-e2e-$$-$(date +%s)@axonflow-test.invalid"
    OUT=$(AXONFLOW_ENDPOINT="$AGENT_URL" \
          AXONFLOW_RECOVER_EMAIL="$LIVE_EMAIL" \
          bash "$RECOVER" request 2>&1) && rc=0 || rc=$?
    if [ "$rc" = "0" ] && echo "$OUT" | grep -q "Magic link requested"; then
      PASS "live agent /api/v1/recover returned 202 for a fresh email"
    else
      FAIL "live agent recovery request failed (rc=$rc). Output: $OUT"
    fi
  fi
else
  echo "  SKIP: no live agent at $AGENT_URL"
fi

echo ""
if [ "$fail" -gt 0 ]; then
  echo "FAIL: $fail test(s) failed, $pass passed"
  exit 1
fi
echo "PASS: $pass tests passed — recovery surface verified end-to-end"
exit 0
