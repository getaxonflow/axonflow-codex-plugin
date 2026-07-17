#!/usr/bin/env bash
# Codex runtime E2E: per-user authorization token OUTCOME test
# (axonflow-enterprise#2944, epic #2919 — codex port of the claude
# plugin's #2935).
#
# Drives the plugin's REAL hook scripts (pre-tool-check.sh + post-tool-audit.sh)
# — the runtime components that attach X-User-Token on every governed tool call
# — against a LIVE AxonFlow agent (no mocks), then asserts the resulting
# canonical `audit_logs` rows attribute to the token's VALIDATED identity, that
# a tampered token fails CLOSED (exit 2, structured stderr deny), and that the
# MCP plane's env_http_headers contract holds against the live agent.
#
# Legs:
#   0. Unconfigured (the common fleet state today): no token anywhere → rows
#      attribute to the shared tenant identity exactly as pre-1.6 (the codex
#      plugin has no X-User-Email label mechanism; additive-only proof
#      against ANY platform version).
#   1. Validated identity (needs a platform with enterprise#2929+): a real
#      minted token → rows on BOTH planes attribute to the token's canonical
#      email, NOT the shared client identity. Env leg on the pre-tool plane,
#      0600-file leg on the post-tool plane — covering both resolution
#      sources against the live stack.
#   2. Unhappy path: a tampered token → the platform rejects (HTTP 401) and
#      pre-tool-check.sh BLOCKS (exit 2) with a stderr deny naming the
#      per-user token as a likely cause. No silent fall-open on a bad
#      credential, and no token-value leak anywhere.
#   3. MCP plane: install-mcp-with-headers.sh against a scratch CODEX_HOME
#      yields valid TOML with the X-User-Token env mapping (real codex CLI;
#      skips without it), and the env-var header contract is proven with
#      explicit HTTP codes against the live agent: minted → 200,
#      tampered → 401, omitted → 200.
#
# Capability probe: pre-#2929 platforms IGNORE X-User-Token. The harness sends
# a garbage token on a bare tools/list request — acceptance means the token
# legs cannot run (SKIP with a notice), rejection means the platform validates.
#
# Enterprise auth (cite feedback-runtime-e2e-must-support-enterprise-auth): the
# harness reads AXONFLOW_AUTH / AXONFLOW_E2E_ENTERPRISE_AUTH (Basic) so it works
# against a real in-VPC Enterprise agent.
#
# Prereqs (skips cleanly otherwise): see README.md next to this file.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRE_HOOK="$PLUGIN_DIR/scripts/pre-tool-check.sh"
POST_HOOK="$PLUGIN_DIR/scripts/post-tool-audit.sh"

ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"

for bin in jq curl psql python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "SKIP: $bin not on PATH"; exit 0; }
done
if ! curl -sSf -o /dev/null --max-time 5 "$ENDPOINT/health"; then
  echo "SKIP: AxonFlow agent not reachable at $ENDPOINT/health"
  exit 0
fi

# Resolve enterprise Basic auth (support all three env shapes).
AUTH="${AXONFLOW_AUTH:-}"
if [ -z "$AUTH" ] && [ -n "${AXONFLOW_E2E_ENTERPRISE_AUTH:-}" ]; then
  AUTH="$AXONFLOW_E2E_ENTERPRISE_AUTH"
fi
if [ -z "$AUTH" ] && [ -n "${AXONFLOW_E2E_ORG_ID:-}" ] && [ -n "${AXONFLOW_E2E_LICENSE_KEY:-}" ]; then
  AUTH="$(printf '%s:%s' "$AXONFLOW_E2E_ORG_ID" "$AXONFLOW_E2E_LICENSE_KEY" | base64 | tr -d '\n')"
fi
if [ -z "$AUTH" ]; then
  echo "SKIP: no agent credential (set AXONFLOW_AUTH / AXONFLOW_E2E_ENTERPRISE_AUTH / AXONFLOW_E2E_ORG_ID+LICENSE_KEY)"
  exit 0
fi
DB_URL="${AXONFLOW_E2E_DB_URL:-}"
if [ -z "$DB_URL" ]; then
  echo "SKIP: AXONFLOW_E2E_DB_URL not set (needed to read back audit_logs attribution)"
  exit 0
fi

query() { psql "$DB_URL" -tAc "$1" 2>/dev/null; }

# wait_count <count-sql> <min> — poll (1s interval, up to 30s) until the
# scalar count query returns >= min (audit writers are async, batched).
wait_count() {
  local sql="$1" min="$2" n=0 c=0
  while [ "$n" -lt 30 ]; do
    c=$(query "$sql")
    c="${c:-0}"
    [ "$c" -ge "$min" ] && break
    n=$((n + 1))
    sleep 1
  done
  printf '%s' "$c"
}

sha256_of() { printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# All hook stdout/stderr goes here for the final no-leak grep.
OUT_DIR="$WORK/outputs"
mkdir -p "$OUT_DIR"

# run_pre / run_post <home> <input-json> <out-tag> [extra env pairs...]
# Hermetic: fresh HOME, no inherited token/license/cache; live agent + auth.
HOOK_EXIT=0
run_hook() {
  local hook="$1" home="$2" input="$3" tag="$4"; shift 4
  local -a extra_env=()
  while [ "$#" -gt 0 ]; do extra_env+=("$1"); shift; done
  ( cd "$WORK" && printf '%s' "$input" | env -u AXONFLOW_USER_TOKEN -u AXONFLOW_LICENSE_TOKEN -u XDG_CACHE_HOME \
      HOME="$home" AXONFLOW_ENDPOINT="$ENDPOINT" AXONFLOW_AUTH="$AUTH" \
      AXONFLOW_CODEX_CONFIG=/nonexistent-axonflow-toml AXONFLOW_TELEMETRY=off \
      ${extra_env[@]+"${extra_env[@]}"} \
      "$hook" >"$OUT_DIR/$tag.out" 2>"$OUT_DIR/$tag.err" )
  HOOK_EXIT=$?
}

errors=0

# ---------------------------------------------------------------------------
# Leg 0 — UNCONFIGURED (the common fleet state): no token env, no token file
# (fresh HOME). Rows must be written and attribute exactly as pre-1.6: the
# shared tenant identity (mcp-client:<org>), since codex hooks send no
# per-user identity at all.
# ---------------------------------------------------------------------------
UNIQ0="e2e-notok-$(date +%s)-$RANDOM"
STMT0="rm -rf / --no-preserve-root # $UNIQ0"
HASH0="$(sha256_of "$STMT0")"
HOME0="$WORK/home0"; mkdir -p "$HOME0"
echo "--- Leg 0: unconfigured (shared-identity attribution, key=$UNIQ0) ---"
run_hook "$PRE_HOOK" "$HOME0" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(jq -Rn --arg s "$STMT0" '$s')}}" "leg0-pre"
if [ "$HOOK_EXIT" -eq 2 ]; then
  echo "PASS: unconfigured pre hook blocked the destructive command (exit 2)"
else
  echo "FAIL: unconfigured pre hook exit=$HOOK_EXIT (expected 2 — is the agent's destructive-fs policy enabled?)"
  errors=$((errors + 1))
fi
run_hook "$POST_HOOK" "$HOME0" "{\"tool_name\":\"$UNIQ0\",\"tool_input\":{\"q\":\"x\"},\"tool_response\":{\"success\":true}}" "leg0-post"

CHK0=$(wait_count "SELECT count(*) FROM audit_logs WHERE request_type='mcp_check_policy' AND query_hash='$HASH0';" 1)
AUD0=$(wait_count "SELECT count(*) FROM audit_logs WHERE request_type='tool_call_audit' AND query='Tool: $UNIQ0';" 1)
if [ "${CHK0:-0}" -ge 1 ] && [ "${AUD0:-0}" -ge 1 ]; then
  echo "PASS: unconfigured plugin — governed rows written on both planes"
else
  echo "FAIL: unconfigured rows missing (check_policy=$CHK0 audit=$AUD0)"
  errors=$((errors + 1))
fi
SHARED0=$(query "SELECT count(*) FROM audit_logs WHERE (query_hash='$HASH0' OR query='Tool: $UNIQ0') AND user_email LIKE 'mcp-client:%';")
TOTAL0=$(query "SELECT count(*) FROM audit_logs WHERE (query_hash='$HASH0' OR query='Tool: $UNIQ0');")
if [ -n "$SHARED0" ] && [ "$SHARED0" = "$TOTAL0" ] && [ "${TOTAL0:-0}" -ge 2 ]; then
  echo "PASS: every unconfigured row attributes to the shared tenant identity (pre-1.6 behavior unchanged)"
else
  echo "FAIL: unconfigured attribution drifted (shared=$SHARED0 total=$TOTAL0):"
  query "SELECT request_type, user_email FROM audit_logs WHERE (query_hash='$HASH0' OR query='Tool: $UNIQ0');"
  errors=$((errors + 1))
fi

# ---------------------------------------------------------------------------
# Capability probe: does this platform VALIDATE X-User-Token? (enterprise#2929)
# A garbage token on a bare tools/list: pre-#2929 ignores the header (HTTP
# 200), post-#2929 enterprise rejects it (HTTP 401).
# ---------------------------------------------------------------------------
PROBE_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -X POST "$ENDPOINT/api/v1/mcp-server" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -H "Authorization: Basic $AUTH" \
  -H "X-User-Token: e2e-garbage-token-probe" \
  -d '{"jsonrpc":"2.0","id":"probe","method":"tools/list"}')
if [ "$PROBE_CODE" != "401" ]; then
  echo "SKIP: platform at $ENDPOINT does not validate X-User-Token yet (probe HTTP $PROBE_CODE; needs enterprise#2929+) — token legs skipped."
  echo ""
  if [ "$errors" -ne 0 ]; then echo "FAILED: $errors error(s)"; exit 1; fi
  echo "user-token runtime E2E: leg 0 passed (token legs skipped: platform pre-#2929)"
  exit 0
fi
echo "--- Platform validates X-User-Token (probe HTTP 401) — running token legs ---"

# ---------------------------------------------------------------------------
# Resolve a REAL minted token: operator-supplied, else sign one with the
# agent's JWT_SECRET using the exact mint-API claims contract
# (platform/shared/identity: iss=axonflow-user-token-mint, email, role,
# org_id, jti, iat, exp). The platform performs its full validation
# (signature, issuer, expiry, org binding, revocation) — nothing is stubbed.
# ---------------------------------------------------------------------------
TOKEN="${AXONFLOW_E2E_USER_TOKEN:-}"
TOKEN_EMAIL="${AXONFLOW_E2E_USER_TOKEN_EMAIL:-}"
if [ -z "$TOKEN" ]; then
  if [ -z "${AXONFLOW_E2E_JWT_SECRET:-}" ] || [ -z "${AXONFLOW_E2E_ORG_ID:-}" ]; then
    echo "SKIP: no minted token (set AXONFLOW_E2E_USER_TOKEN+AXONFLOW_E2E_USER_TOKEN_EMAIL, or AXONFLOW_E2E_JWT_SECRET+AXONFLOW_E2E_ORG_ID) — token legs skipped."
    if [ "$errors" -ne 0 ]; then echo "FAILED: $errors error(s)"; exit 1; fi
    exit 0
  fi
  TOKEN_EMAIL="e2e-token-dev-$(date +%s)-$RANDOM@example.com"
  TOKEN=$(TOKEN_EMAIL="$TOKEN_EMAIL" ORG_ID="$AXONFLOW_E2E_ORG_ID" JWT_SECRET="$AXONFLOW_E2E_JWT_SECRET" python3 - <<'PY'
import base64, hashlib, hmac, json, os, time, uuid
def b64url(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
header = {"alg": "HS256", "typ": "JWT"}
now = int(time.time())
claims = {
    "iss": "axonflow-user-token-mint",
    "email": os.environ["TOKEN_EMAIL"],
    "role": "developer",
    "org_id": os.environ["ORG_ID"],
    "jti": str(uuid.uuid4()),
    "iat": now,
    "exp": now + 3600,
}
signing_input = b64url(json.dumps(header, separators=(",", ":")).encode()) + "." + \
    b64url(json.dumps(claims, separators=(",", ":")).encode())
sig = hmac.new(os.environ["JWT_SECRET"].encode(), signing_input.encode(), hashlib.sha256).digest()
print(signing_input + "." + b64url(sig))
PY
)
  if [ -z "$TOKEN" ]; then
    echo "FAIL: could not sign a mint-contract token"
    exit 1
  fi
fi
if [ -z "$TOKEN_EMAIL" ]; then
  echo "SKIP: AXONFLOW_E2E_USER_TOKEN set without AXONFLOW_E2E_USER_TOKEN_EMAIL (needed for the attribution assertion) — token legs skipped."
  if [ "$errors" -ne 0 ]; then echo "FAILED: $errors error(s)"; exit 1; fi
  exit 0
fi
# The validator canonicalizes (lowercase+trim) the email — assert on that
# (platform lowercases audit user_email since enterprise#2929).
TOKEN_EMAIL_CANON=$(printf '%s' "$TOKEN_EMAIL" | tr '[:upper:]' '[:lower:]')

# ---------------------------------------------------------------------------
# Leg 1 — VALIDATED IDENTITY replaces the shared fallback. The audit rows
# must carry the token's canonical email on BOTH planes — and NOT the shared
# mcp-client:<org> identity those rows would otherwise get (leg 0 proved
# that baseline). Env leg for the pre-tool plane, 0600-file leg for the
# post-tool plane — covering both resolution sources against the live stack.
# ---------------------------------------------------------------------------
UNIQ1="e2e-tok-$(date +%s)-$RANDOM"
STMT1="rm -rf / --no-preserve-root # $UNIQ1"
HASH1="$(sha256_of "$STMT1")"
HOME1="$WORK/home1"; mkdir -p "$HOME1"
echo "--- Leg 1: validated identity (token=$TOKEN_EMAIL_CANON, key=$UNIQ1) ---"
run_hook "$PRE_HOOK" "$HOME1" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(jq -Rn --arg s "$STMT1" '$s')}}" "leg1-pre" AXONFLOW_USER_TOKEN="$TOKEN"

mkdir -p "$HOME1/.config/axonflow"
printf '{"token":"%s"}' "$TOKEN" > "$HOME1/.config/axonflow/user-token.json"
chmod 600 "$HOME1/.config/axonflow/user-token.json"
run_hook "$POST_HOOK" "$HOME1" "{\"tool_name\":\"$UNIQ1\",\"tool_input\":{\"q\":\"x\"},\"tool_response\":{\"success\":true}}" "leg1-post"

CHK1=$(wait_count "SELECT count(*) FROM audit_logs WHERE request_type='mcp_check_policy' AND query_hash='$HASH1' AND LOWER(user_email)='$TOKEN_EMAIL_CANON';" 1)
if [ "${CHK1:-0}" -ge 1 ]; then
  echo "PASS: check_policy row attributes to the token's validated email (env leg, pre-tool plane)"
else
  echo "FAIL: no mcp_check_policy row with user_email=$TOKEN_EMAIL_CANON query_hash=$HASH1"
  errors=$((errors + 1))
fi
AUD1=$(wait_count "SELECT count(*) FROM audit_logs WHERE request_type='tool_call_audit' AND query='Tool: $UNIQ1' AND LOWER(user_email)='$TOKEN_EMAIL_CANON';" 1)
if [ "${AUD1:-0}" -ge 1 ]; then
  echo "PASS: audit_tool_call row attributes to the token's validated email (0600-file leg, post-tool plane)"
else
  echo "FAIL: no tool_call_audit row with user_email=$TOKEN_EMAIL_CANON for 'Tool: $UNIQ1'"
  errors=$((errors + 1))
fi
SHARED1=$(query "SELECT count(*) FROM audit_logs WHERE (query_hash='$HASH1' OR query='Tool: $UNIQ1') AND user_email LIKE 'mcp-client:%';")
if [ "${SHARED1:-1}" -eq 0 ]; then
  echo "PASS: with the token present, ZERO rows attribute to the shared client identity"
else
  echo "FAIL: $SHARED1 row(s) attributed to the shared identity despite a valid token"
  errors=$((errors + 1))
fi
echo "--- audit_logs rows for leg 1 ---"
query "SELECT request_type, policy_decision, user_email FROM audit_logs WHERE query_hash='$HASH1' OR query='Tool: $UNIQ1' ORDER BY timestamp;" || true

# ---------------------------------------------------------------------------
# Leg 2 — UNHAPPY PATH: a tampered token (bit-flipped signature) must fail
# CLOSED: the platform 401s, pre-tool-check.sh exits 2 with a stderr deny
# naming the per-user token — never the value, never a silent fall-open.
# ---------------------------------------------------------------------------
# Flip the last signature character; pick a replacement that differs from
# the original so the tamper is guaranteed even when the token ends in "x".
case "$TOKEN" in
  *x) TAMPERED="${TOKEN%?}A" ;;
  *)  TAMPERED="${TOKEN%?}x" ;;
esac
HOME2="$WORK/home2"; mkdir -p "$HOME2"
echo "--- Leg 2: tampered token fail-closed ---"
run_hook "$PRE_HOOK" "$HOME2" '{"tool_name":"Bash","tool_input":{"command":"echo benign"}}' "leg2-pre" AXONFLOW_USER_TOKEN="$TAMPERED"
if [ "$HOOK_EXIT" -eq 2 ]; then
  echo "PASS: tampered token → tool call BLOCKED (exit 2, fail-closed — no silent fall-open)"
else
  echo "FAIL: tampered token did not block: exit=$HOOK_EXIT stderr=$(cat "$OUT_DIR/leg2-pre.err")"
  errors=$((errors + 1))
fi
if grep -q "per-user token" "$OUT_DIR/leg2-pre.err"; then
  echo "PASS: deny diagnostic names the per-user token as a likely cause"
else
  echo "FAIL: deny diagnostic does not mention the per-user token: $(cat "$OUT_DIR/leg2-pre.err")"
  errors=$((errors + 1))
fi

# ---------------------------------------------------------------------------
# Leg 3 — MCP PLANE. (a) install-mcp-with-headers.sh against a scratch
# CODEX_HOME must produce valid TOML carrying the X-User-Token env mapping
# (real codex CLI; sub-leg skips without it). (b) The env_http_headers
# contract — header sent with the env var's value when set, omitted when
# unset (pinned empirically by runtime-e2e/mcp-session-headers) — proven
# against the LIVE agent with explicit HTTP codes.
# ---------------------------------------------------------------------------
echo "--- Leg 3: MCP plane (env-only contract) ---"
if command -v codex >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null; then
  MCP_HOME="$WORK/mcp-home"; mkdir -p "$MCP_HOME/.codex"
  ( env HOME="$MCP_HOME" CODEX_HOME="$MCP_HOME/.codex" AXONFLOW_ENDPOINT="$ENDPOINT" \
      bash "$PLUGIN_DIR/scripts/install-mcp-with-headers.sh" >"$OUT_DIR/leg3-install.out" 2>"$OUT_DIR/leg3-install.err" )
  INSTALL_EXIT=$?
  TOML_CHECK="$(CONFIG="$MCP_HOME/.codex/config.toml" python3 - <<'PY' 2>&1
import os, tomllib
with open(os.environ["CONFIG"], "rb") as f:
    data = tomllib.load(f)
envh = data["mcp_servers"]["axonflow"]["env_http_headers"]
assert envh["X-User-Token"] == "AXONFLOW_USER_TOKEN", envh
print("ok")
PY
)" || TOML_CHECK="parse-failed"
  if [ "$INSTALL_EXIT" -eq 0 ] && [ "$TOML_CHECK" = "ok" ]; then
    echo "PASS: real codex CLI + installer → valid config.toml with the X-User-Token env mapping"
  else
    echo "FAIL: installer leg broken (exit=$INSTALL_EXIT toml=$TOML_CHECK): $(cat "$OUT_DIR/leg3-install.err")"
    errors=$((errors + 1))
  fi
else
  echo "SKIP: codex CLI or python3 tomllib not available — config.toml sub-leg skipped (pinned by tests/test-install-mcp-headers.sh)"
fi

# Env-var contract against the live agent — explicit HTTP codes, never pass
# on transport errors (curl failure yields code 000 → FAIL).
mcp_code() { # [token]
  local -a hdr=()
  if [ "$#" -ge 1 ]; then hdr=(-H "X-User-Token: $1"); fi
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -X POST "$ENDPOINT/api/v1/mcp-server" \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    -H "Authorization: Basic $AUTH" \
    ${hdr[@]+"${hdr[@]}"} \
    -d '{"jsonrpc":"2.0","id":"leg3","method":"tools/list"}'
}
CODE_MINTED=$(mcp_code "$TOKEN")
CODE_TAMPERED=$(mcp_code "$TAMPERED")
CODE_OMITTED=$(mcp_code)
if [ "$CODE_MINTED" = "200" ]; then
  echo "PASS: MCP tools/list with the minted token in X-User-Token → HTTP 200"
else
  echo "FAIL: minted-token tools/list returned HTTP $CODE_MINTED (expected 200)"
  errors=$((errors + 1))
fi
if [ "$CODE_TAMPERED" = "401" ]; then
  echo "PASS: MCP tools/list with a tampered token → HTTP 401 (platform fails closed)"
else
  echo "FAIL: tampered-token tools/list returned HTTP $CODE_TAMPERED (expected 401)"
  errors=$((errors + 1))
fi
if [ "$CODE_OMITTED" = "200" ]; then
  echo "PASS: MCP tools/list with the header omitted (env var unset ⇒ Codex omits it) → HTTP 200"
else
  echo "FAIL: no-header tools/list returned HTTP $CODE_OMITTED (expected 200)"
  errors=$((errors + 1))
fi

# ---------------------------------------------------------------------------
# No-leak sweep: neither the minted nor the tampered token value may appear
# in ANY hook/installer stdout/stderr captured above.
# ---------------------------------------------------------------------------
if grep -rqF "$TOKEN" "$OUT_DIR" || grep -rqF "$TAMPERED" "$OUT_DIR"; then
  echo "FAIL: a token value leaked into hook/installer output:"
  grep -rlF -e "$TOKEN" -e "$TAMPERED" "$OUT_DIR"
  errors=$((errors + 1))
else
  echo "PASS: no token value in any captured hook/installer stdout/stderr"
fi

echo ""
if [ "$errors" -ne 0 ]; then
  echo "FAILED: $errors error(s)"
  exit 1
fi
echo "user-token runtime E2E: ALL legs passed"
exit 0
