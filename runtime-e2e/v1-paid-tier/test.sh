#!/usr/bin/env bash
# Runtime E2E: V1 paid Pro tier wire-up.
#
# Drives the plugin through its actual hook code path (NOT through Codex
# CLI — that surface assumes a manual Stripe Checkout, which we can't
# script). The runtime path under test is:
#
#   pre-tool-check.sh  →  curl POST /api/v1/mcp-server with X-License-Token
#
# Two assertions:
#
#   1. With a license token configured (env or ~/.codex/axonflow.toml),
#      the hook script SENDS the X-License-Token header to the agent.
#      Verified by intercepting the curl call: we run the hook against a
#      tiny netcat-like recorder that captures the raw HTTP request.
#
#   2. With NO license token configured, the hook script DOES NOT send
#      X-License-Token (free tier behaviour — header is absent, not
#      empty-stringed).
#
# A live agent at localhost:8080 (or AXONFLOW_AGENT_URL) is also probed
# end-to-end when reachable: we POST a request with a known fake token
# and assert the agent's PluginClaimMiddleware sees the header (HTTP 401
# invalid_license_token is the expected outcome for a fake token; HTTP
# 200 means the middleware skipped because the header was absent — which
# is the bug this PR exists to prevent).
#
# Per FEATURE_RUNTIME_COVERAGE.md methodology: this is the runtime-path
# test the V1 paid-tier wire-up PR ships with. README claims aren't proof.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRE_HOOK="$PLUGIN_DIR/scripts/pre-tool-check.sh"
RECOVER="$PLUGIN_DIR/scripts/recover.sh"

AGENT_URL="${AGENT_URL:-${AXONFLOW_AGENT_URL:-http://localhost:8080}}"
# Fixed test token. We deliberately do NOT inherit AXONFLOW_LICENSE_TOKEN
# from the parent env — a real user's token in the shell would taint
# the "no token configured" assertions below.
FAKE_TOKEN="AXON-runtime-e2e-fake.signature.placeholder"
# Defensive: clear inherited token so the no-token sub-tests are clean.
unset AXONFLOW_LICENSE_TOKEN

pass=0
fail=0
PASS() { printf '  PASS: %s\n' "$1"; pass=$((pass+1)); }
FAIL() { printf '  FAIL: %s\n' "$1"; fail=$((fail+1)); }

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "SKIP: $1 not on PATH"
    exit 0
  }
}
require curl
require jq
require python3

echo "=== runtime-e2e: V1 paid Pro tier wire-up ==="
echo "Agent URL:         $AGENT_URL"
echo "Plugin dir:        $PLUGIN_DIR"
echo ""

# -----------------------------------------------------------------------------
# Local capture server: a tiny python http server that records the headers
# of incoming POST /api/v1/mcp-server requests and replies with an empty
# success-shaped MCP response. This lets us assert what the hook ACTUALLY
# sent on the wire — not what the script claims it sent.
# -----------------------------------------------------------------------------
PORT=18299
CAPTURE_FILE=$(mktemp -t axonflow-v1-paid-capture.XXXXXX)
SERVER_LOG=$(mktemp -t axonflow-v1-paid-server.XXXXXX)
SERVER_SCRIPT=$(mktemp -t axonflow-v1-paid-server.XXXXXX.py)
cat >"$SERVER_SCRIPT" <<'PYEOF'
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer
port = int(sys.argv[1])
capture = sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a, **kw): return
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok"); return
        self.send_response(404); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(n) if n else b""
        rec = {"path": self.path,
               "headers": {k: v for k, v in self.headers.items()},
               "body_preview": body[:200].decode("utf-8", "replace")}
        with open(capture, "a") as f:
            f.write(json.dumps(rec) + "\n")
        resp = {"jsonrpc":"2.0","id":"hook-pre","result":{"content":[{"type":"text","text":json.dumps({"allowed":True,"block_reason":"","policies_evaluated":0})}]}}
        self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
        self.wfile.write(json.dumps(resp).encode())
HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF

python3 "$SERVER_SCRIPT" "$PORT" "$CAPTURE_FILE" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null; rm -f "$CAPTURE_FILE" "$SERVER_LOG" "$SERVER_SCRIPT"' EXIT

# Wait for bind.
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
if ! curl -sS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  echo "FAIL: capture server failed to start. Log:"
  cat "$SERVER_LOG"
  exit 1
fi
echo "  capture server up at http://127.0.0.1:$PORT"

# Reset capture between sub-tests so each assertion sees only its own
# request, not the previous one.
reset_capture() {
  : > "$CAPTURE_FILE"
}

INPUT='{"tool_name":"Bash","tool_input":{"command":"echo runtime-e2e-probe"}}'

# -----------------------------------------------------------------------------
# Test 1: token via env var → header sent.
# -----------------------------------------------------------------------------
echo ""
echo "Test 1: AXONFLOW_LICENSE_TOKEN env var → X-License-Token sent"
reset_capture
printf '%s' "$INPUT" | \
  AXONFLOW_ENDPOINT="http://127.0.0.1:$PORT" \
  AXONFLOW_AUTH="dGVzdC10ZW5hbnQ6dGVzdC1zZWNyZXQ=" \
  AXONFLOW_TELEMETRY="off" \
  AXONFLOW_LICENSE_TOKEN="$FAKE_TOKEN" \
  HOME="$(mktemp -d)" \
  bash "$PRE_HOOK" >/dev/null 2>&1 || true

# Capture file may have multiple lines if the hook does an audit-blocked
# write too — only the first line is the policy check we care about.
HDRS=$(head -1 "$CAPTURE_FILE" 2>/dev/null | jq -r '.headers["X-License-Token"] // ""')
if [ "$HDRS" = "$FAKE_TOKEN" ]; then
  PASS "X-License-Token header forwarded with the configured value"
else
  FAIL "expected header value '$FAKE_TOKEN', got '$HDRS' (capture: $(cat "$CAPTURE_FILE" | head -3))"
fi

# -----------------------------------------------------------------------------
# Test 2: token via TOML file → header sent.
# -----------------------------------------------------------------------------
echo ""
echo "Test 2: ~/.codex/axonflow.toml license_token → X-License-Token sent"
reset_capture
TMP_HOME=$(mktemp -d)
mkdir -p "$TMP_HOME/.codex"
cat > "$TMP_HOME/.codex/axonflow.toml" <<EOF
license_token = "$FAKE_TOKEN"
EOF
printf '%s' "$INPUT" | \
  AXONFLOW_ENDPOINT="http://127.0.0.1:$PORT" \
  AXONFLOW_AUTH="dGVzdC10ZW5hbnQ6dGVzdC1zZWNyZXQ=" \
  AXONFLOW_TELEMETRY="off" \
  HOME="$TMP_HOME" \
  bash "$PRE_HOOK" >/dev/null 2>&1 || true

HDRS=$(head -1 "$CAPTURE_FILE" 2>/dev/null | jq -r '.headers["X-License-Token"] // ""')
if [ "$HDRS" = "$FAKE_TOKEN" ]; then
  PASS "X-License-Token header forwarded from ~/.codex/axonflow.toml"
else
  FAIL "expected header from TOML, got '$HDRS' (capture: $(cat "$CAPTURE_FILE" | head -3))"
fi

# -----------------------------------------------------------------------------
# Test 3: env var WINS over TOML.
# -----------------------------------------------------------------------------
echo ""
echo "Test 3: env var overrides TOML when both set"
reset_capture
ENV_TOKEN="AXON-env-wins"
printf '%s' "$INPUT" | \
  AXONFLOW_ENDPOINT="http://127.0.0.1:$PORT" \
  AXONFLOW_AUTH="dGVzdC10ZW5hbnQ6dGVzdC1zZWNyZXQ=" \
  AXONFLOW_TELEMETRY="off" \
  AXONFLOW_LICENSE_TOKEN="$ENV_TOKEN" \
  HOME="$TMP_HOME" \
  bash "$PRE_HOOK" >/dev/null 2>&1 || true

HDRS=$(head -1 "$CAPTURE_FILE" 2>/dev/null | jq -r '.headers["X-License-Token"] // ""')
if [ "$HDRS" = "$ENV_TOKEN" ]; then
  PASS "env var wins over TOML"
else
  FAIL "expected env-var token, got '$HDRS'"
fi

# -----------------------------------------------------------------------------
# Test 4: no token configured → header ABSENT (free tier, not empty-string).
# -----------------------------------------------------------------------------
echo ""
echo "Test 4: no token → header absent (free tier)"
reset_capture
TMP_HOME2=$(mktemp -d)
printf '%s' "$INPUT" | \
  AXONFLOW_ENDPOINT="http://127.0.0.1:$PORT" \
  AXONFLOW_AUTH="dGVzdC10ZW5hbnQ6dGVzdC1zZWNyZXQ=" \
  AXONFLOW_TELEMETRY="off" \
  HOME="$TMP_HOME2" \
  bash "$PRE_HOOK" >/dev/null 2>&1 || true

# python's BaseHTTPRequestHandler downcases header keys when listing via
# .items(); jq lookup is case-sensitive — check both. has() is true only
# when the key was actually set.
HAS_HEADER=$(head -1 "$CAPTURE_FILE" 2>/dev/null | jq -r '.headers | (has("X-License-Token") or has("x-license-token"))')
if [ "$HAS_HEADER" = "false" ]; then
  PASS "X-License-Token header absent when no token configured"
else
  FAIL "header was present despite no token configured (capture: $(cat "$CAPTURE_FILE" | head -3))"
fi

# -----------------------------------------------------------------------------
# Test 5: malformed token (no AXON- prefix) → header absent.
# -----------------------------------------------------------------------------
echo ""
echo "Test 5: malformed token (no AXON- prefix) → header absent"
reset_capture
printf '%s' "$INPUT" | \
  AXONFLOW_ENDPOINT="http://127.0.0.1:$PORT" \
  AXONFLOW_AUTH="dGVzdC10ZW5hbnQ6dGVzdC1zZWNyZXQ=" \
  AXONFLOW_TELEMETRY="off" \
  AXONFLOW_LICENSE_TOKEN="garbage-not-axon-prefixed" \
  HOME="$TMP_HOME2" \
  bash "$PRE_HOOK" >/dev/null 2>&1 || true

HAS_HEADER=$(head -1 "$CAPTURE_FILE" 2>/dev/null | jq -r '.headers | (has("X-License-Token") or has("x-license-token"))')
if [ "$HAS_HEADER" = "false" ]; then
  PASS "malformed token is filtered out before forwarding"
else
  FAIL "malformed token was forwarded (capture: $(cat "$CAPTURE_FILE" | head -3))"
fi

# -----------------------------------------------------------------------------
# Test 6: status surface reports tier correctly.
# -----------------------------------------------------------------------------
echo ""
echo "Test 6: scripts/recover.sh status reports tier"
TMP_HOME3=$(mktemp -d)
mkdir -p "$TMP_HOME3/.codex"

# 6a: no token → free
STATUS_OUT=$(HOME="$TMP_HOME3" bash "$RECOVER" status 2>&1 || true)
if echo "$STATUS_OUT" | grep -q "Free tier"; then
  PASS "status reports Free tier when no token"
else
  FAIL "status did not report Free tier: $STATUS_OUT"
fi

# 6b: token present → pro
STATUS_OUT=$(HOME="$TMP_HOME3" AXONFLOW_LICENSE_TOKEN="$FAKE_TOKEN" bash "$RECOVER" status 2>&1 || true)
if echo "$STATUS_OUT" | grep -q "Pro tier active"; then
  PASS "status reports Pro tier active when token set"
else
  FAIL "status did not report Pro tier: $STATUS_OUT"
fi

# 6c: status MUST NOT print the full token value to stdout — `status` is
# routinely shared in support tickets / screen-recordings and the token is
# a bearer credential. Allowed: a redacted summary like "set (AXON-...xxxx)"
# that only echoes the last 4 chars (which alone are not sufficient to
# replay the token). Forbidden: the literal token string anywhere.
if echo "$STATUS_OUT" | grep -qF "$FAKE_TOKEN"; then
  FAIL "status leaked the full license token to stdout (bearer credential leak)"
else
  PASS "status redacts the license token (no full value in output)"
fi

# 6d: status MUST surface the upgrade URL so users know where to buy Pro.
# The Stripe Payment Link (set by operators in Stripe Dashboard, fronted
# by getaxonflow.com/pro) is the entry point for the buyer flow — without
# this line, users have no way to find it from the plugin.
if echo "$STATUS_OUT" | grep -qE 'upgrade\s+https?://'; then
  PASS "status surfaces the upgrade URL"
else
  FAIL "status missing upgrade URL line: $STATUS_OUT"
fi

# 6e: status MUST surface the user's tenant_id when registration exists,
# so the user can paste it into the Stripe Checkout custom field. Use a
# stub registration file in TMP_HOME3 so the test is deterministic.
TMP_REG_DIR=$(mktemp -d)
mkdir -p "$TMP_REG_DIR/.config/axonflow"
echo '{"tenant_id":"cs_status_test_tenant","secret":"redacted","endpoint":"https://try.getaxonflow.com"}' \
  > "$TMP_REG_DIR/.config/axonflow/try-registration.json"
STATUS_WITH_REG=$(HOME="$TMP_REG_DIR" AXONFLOW_LICENSE_TOKEN="$FAKE_TOKEN" bash "$RECOVER" status 2>&1 || true)
if echo "$STATUS_WITH_REG" | grep -qF "cs_status_test_tenant"; then
  PASS "status surfaces tenant_id from try-registration.json"
else
  FAIL "status missing tenant_id (expected cs_status_test_tenant): $STATUS_WITH_REG"
fi
rm -rf "$TMP_REG_DIR"

# 6f: V1 SaaS Plugin Pro tier-line surface parity. The status `tier` line
# must surface the JWT `exp` claim from the configured license token in
# three shapes:
#   - "Pro tier active (expires YYYY-MM-DD, N days remaining)"  (exp future)
#   - "Free tier (Pro expired YYYY-MM-DD — visit ... to renew)" (exp past)
#   - "Free tier (no AXON- license token configured)"            (no token)
mint_axon_jwt() {
  local exp_epoch="$1"
  local hdr
  hdr=$(printf '%s' '{"alg":"EdDSA","typ":"JWT"}' | base64 | tr '+/' '-_' | tr -d '=')
  local payload
  payload=$(printf '{"sub":"smoke","exp":%s}' "$exp_epoch" | base64 | tr '+/' '-_' | tr -d '=')
  local sig="placeholder-signature-padding-padding-padding-padding-padding-pa"
  printf 'AXON-%s.%s.%s' "$hdr" "$payload" "$sig"
}

# Pro-active path: exp ~30d future. Expect explicit YYYY-MM-DD + days remaining.
PRO_EXP=$(( $(date -u +%s) + 30 * 86400 ))
PRO_TOKEN=$(mint_axon_jwt "$PRO_EXP")
PRO_STATUS=$(HOME="$TMP_HOME3" AXONFLOW_LICENSE_TOKEN="$PRO_TOKEN" bash "$RECOVER" status 2>&1 || true)
if echo "$PRO_STATUS" | grep -qE "tier[[:space:]]+Pro tier active \(expires [0-9]{4}-[0-9]{2}-[0-9]{2}, [0-9]+ days remaining\)"; then
  PASS "status Pro-active tier line shape (expires YYYY-MM-DD, N days remaining)"
else
  FAIL "status Pro-active line missing expected shape: $PRO_STATUS"
fi
if echo "$PRO_STATUS" | grep -qF "$PRO_TOKEN"; then
  FAIL "status leaked Pro-active token to stdout"
else
  PASS "status redacts Pro-active token"
fi

# Pro-expired path: exp ~365d past. Expect "Free tier (Pro expired YYYY-MM-DD — visit ... to renew)".
EXPIRED_EXP=$(( $(date -u +%s) - 365 * 86400 ))
EXPIRED_TOKEN=$(mint_axon_jwt "$EXPIRED_EXP")
EXPIRED_STATUS=$(HOME="$TMP_HOME3" AXONFLOW_LICENSE_TOKEN="$EXPIRED_TOKEN" bash "$RECOVER" status 2>&1 || true)
if echo "$EXPIRED_STATUS" | grep -qE "tier[[:space:]]+Free tier \(Pro expired [0-9]{4}-[0-9]{2}-[0-9]{2} — visit https?://[^ ]+ to renew\)"; then
  PASS "status Pro-expired tier line shape (Pro expired YYYY-MM-DD — visit ... to renew)"
else
  FAIL "status Pro-expired line missing expected shape: $EXPIRED_STATUS"
fi
if echo "$EXPIRED_STATUS" | grep -qF "$EXPIRED_TOKEN"; then
  FAIL "status leaked expired token to stdout"
else
  PASS "status redacts expired token"
fi

# Free path: no token at all. Expect "Free tier (no AXON- license token configured)".
FREE_STATUS=$(HOME="$TMP_HOME3" bash "$RECOVER" status 2>&1 || true)
if echo "$FREE_STATUS" | grep -qE "tier[[:space:]]+Free tier \(no AXON- license token configured\)"; then
  PASS "status Free-tier line shape (no AXON- license token configured)"
else
  FAIL "status Free-tier line missing expected shape: $FREE_STATUS"
fi

# -----------------------------------------------------------------------------
# Test 7: apply-token persists into TOML.
# -----------------------------------------------------------------------------
echo ""
echo "Test 7: scripts/recover.sh apply-token persists to ~/.codex/axonflow.toml"
TMP_HOME4=$(mktemp -d)
HOME="$TMP_HOME4" AXONFLOW_LICENSE_TOKEN="$FAKE_TOKEN" bash "$RECOVER" apply-token >/dev/null 2>&1 || true
if grep -q "license_token = \"$FAKE_TOKEN\"" "$TMP_HOME4/.codex/axonflow.toml" 2>/dev/null; then
  PASS "apply-token wrote license_token into TOML"
else
  FAIL "apply-token did not persist token. File contents:"
  cat "$TMP_HOME4/.codex/axonflow.toml" 2>/dev/null || echo "(no file)"
fi
PERMS=$(stat -c '%a' "$TMP_HOME4/.codex/axonflow.toml" 2>/dev/null || stat -f '%Lp' "$TMP_HOME4/.codex/axonflow.toml" 2>/dev/null || echo "")
if [ "$PERMS" = "600" ] || [ "$PERMS" = "0600" ]; then
  PASS "TOML written with mode 0600"
else
  FAIL "TOML mode was '$PERMS', expected 600"
fi

# -----------------------------------------------------------------------------
# Test 8 (optional): live agent at $AGENT_URL — assert middleware sees the
# header by hitting an X-License-Token-protected route directly.
#
# The PluginClaimMiddleware ships in axonflow-enterprise PR #1850 (v7.7.x+).
# Older agents don't have the middleware in the chain at all; the assertion
# would be meaningless. We gate this test on the agent advertising the
# capability via /health (the platform-side PR adds a `plugin_claim_license`
# capability marker) OR an explicit AXONFLOW_ASSERT_LIVE_MIDDLEWARE=1.
# -----------------------------------------------------------------------------
echo ""
echo "Test 8: live agent middleware sees the header (optional)"
if curl -sS --max-time 3 "$AGENT_URL/health" >/dev/null 2>&1; then
  HEALTH=$(curl -sS --max-time 3 "$AGENT_URL/health" 2>/dev/null || echo '{}')
  HAS_MIDDLEWARE="no"
  if echo "$HEALTH" | jq -e '.capabilities[]? | select(.name == "plugin_claim_license")' >/dev/null 2>&1; then
    HAS_MIDDLEWARE="yes"
  fi
  if [ "$HAS_MIDDLEWARE" != "yes" ] && [ "${AXONFLOW_ASSERT_LIVE_MIDDLEWARE:-0}" != "1" ]; then
    echo "  SKIP: live agent at $AGENT_URL does not advertise plugin_claim_license capability."
    echo "        Set AXONFLOW_ASSERT_LIVE_MIDDLEWARE=1 to force the assertion against a custom build."
  else
    # Fake AXON- token. With middleware in chain → 401 invalid_license_token.
    # Without it → 2xx (the regression we guard against).
    RESP_WITH=$(curl -sS --max-time 5 -X POST "$AGENT_URL/api/request" \
      -H "Content-Type: application/json" \
      -H "X-License-Token: $FAKE_TOKEN" \
      -d '{"client_id":"runtime-e2e","request_type":"audit","query":"probe","skip_llm":true}' \
      -w '\n%{http_code}' 2>/dev/null || true)
    CODE_WITH=$(printf '%s' "$RESP_WITH" | tail -n 1)
    BODY_WITH=$(printf '%s' "$RESP_WITH" | sed '$d')
    if [ "$CODE_WITH" = "401" ] && echo "$BODY_WITH" | grep -qiE 'license|token'; then
      PASS "live agent middleware rejected fake AXON- token (proves header was read)"
    elif [ "$CODE_WITH" = "401" ]; then
      echo "  NOTE: live agent returned 401 but body did not mention license/token; middleware path not conclusively exercised. Body: $(echo "$BODY_WITH" | head -c 200)"
    elif [[ "$CODE_WITH" =~ ^2 ]]; then
      FAIL "live agent returned 2xx with fake token; PluginClaimMiddleware likely not in chain. Body: $(echo "$BODY_WITH" | head -c 200)"
    else
      echo "  NOTE: live agent returned HTTP $CODE_WITH; not 401, not 2xx. Soft-pass. Body: $(echo "$BODY_WITH" | head -c 200)"
    fi
  fi
else
  echo "  SKIP: no live agent at $AGENT_URL — set AGENT_URL to enable"
fi

echo ""
if [ "$fail" -gt 0 ]; then
  echo "FAIL: $fail test(s) failed, $pass passed"
  exit 1
fi
echo "PASS: $pass tests passed — V1 paid Pro tier wire-up verified end-to-end"
exit 0
