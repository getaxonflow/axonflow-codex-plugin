#!/usr/bin/env bash
# Unit tests for scripts/user-token.sh (the per-user authorization token
# resolver, axonflow-enterprise#2944 — port of the claude plugin's #2935)
# and its consumption by the mcp-auth-headers.sh reference impl.
#
# Pins the canonical resolution order (env AXONFLOW_USER_TOKEN wins →
# 0600-guarded ~/.config/axonflow/user-token.json), the 0600 rejection, the
# wire-safety guard (whitespace/control/quote/backslash candidates are DROPPED
# — the platform fails closed on a presented-but-invalid token, so a mangled
# credential must never reach the wire), and that diagnostics never leak the
# token value. The hook wire behavior is pinned by
# tests/test-user-token-header-wire.sh; the LIVE MCP-plane env mapping by
# tests/test-install-mcp-headers.sh.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH"
  exit 0
fi

GOOD_TOKEN='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJlbWFpbCI6ImRldkBleGFtcGxlLmNvbSJ9.abc123-_sig'

# resolve <home> <env-token> — source the helper in a clean subshell and print
# the resolved AXONFLOW_USER_TOKEN (stdout) so assertions stay hermetic.
# Stderr passes through to the caller's capture.
resolve() {
  local home="$1" envtok="$2" cfgdir="${3:-}"
  (
    export HOME="$home"
    # Hermetic: a host AXONFLOW_CONFIG_DIR must not bleed into legs that
    # exercise the $HOME default; the config-dir leg passes it explicitly.
    if [ -n "$cfgdir" ]; then export AXONFLOW_CONFIG_DIR="$cfgdir"; else unset AXONFLOW_CONFIG_DIR; fi
    if [ -n "$envtok" ]; then export AXONFLOW_USER_TOKEN="$envtok"; else unset AXONFLOW_USER_TOKEN; fi
    # shellcheck disable=SC1091
    . "$ROOT/scripts/user-token.sh"
    resolve_user_token
    printf '%s' "${AXONFLOW_USER_TOKEN:-}"
  )
}

echo "== user-token.sh resolver unit tests =="

# 1) Nothing configured → empty (the common fleet state).
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$(resolve "$WORK/no-home" "" 2>/dev/null)"
[ -z "$OUT" ] && pass "unconfigured → no token resolved" \
  || fail "unconfigured resolved to something: $OUT"

# 2) Env var wins outright (even when a file exists with a different token).
mkdir -p "$WORK/home1/.config/axonflow"
printf '{"token":"file.tok.value"}' > "$WORK/home1/.config/axonflow/user-token.json"
chmod 600 "$WORK/home1/.config/axonflow/user-token.json"
OUT="$(resolve "$WORK/home1" "$GOOD_TOKEN" 2>/dev/null)"
[ "$OUT" = "$GOOD_TOKEN" ] && pass "env token wins over file" \
  || fail "env precedence broken: $OUT"

# 3) File fallback loads a 0600 file.
OUT="$(resolve "$WORK/home1" "" 2>/dev/null)"
[ "$OUT" = "file.tok.value" ] && pass "0600 file token loads when env unset" \
  || fail "0600 file load broken: $OUT"

# 4) Non-0600 file is REJECTED with a stderr warning that names the file.
chmod 644 "$WORK/home1/.config/axonflow/user-token.json"
ERR="$(resolve "$WORK/home1" "" 2>&1 >/dev/null)"
OUT="$(resolve "$WORK/home1" "" 2>/dev/null)"
if [ -z "$OUT" ]; then
  pass "0644 file rejected (no token resolved)"
else
  fail "0644 file was loaded: $OUT"
fi
printf '%s' "$ERR" | grep -q "unsafe permissions" \
  && pass "0644 rejection warns on stderr" \
  || fail "no unsafe-permissions warning on stderr: $ERR"
printf '%s' "$ERR" | grep -qF "file.tok.value" \
  && fail "0644 rejection warning leaked the token value" \
  || pass "0644 rejection warning does not leak the token value"
chmod 600 "$WORK/home1/.config/axonflow/user-token.json"

# 5) Wire-safety guard: env token with embedded space / quote / backslash /
#    newline / CRLF is dropped (never mangled-and-sent), and the diagnostic
#    NEVER contains the value.
for bad in 'tok with space' 'tok"quote' 'tok\backslash' "$(printf 'tok\nnewline')" "$(printf 'tok\r\nEvil: hdr')"; do
  ERR="$(resolve "$WORK/no-home" "$bad" 2>&1 >/dev/null)"
  OUT="$(resolve "$WORK/no-home" "$bad" 2>/dev/null)"
  if [ -n "$OUT" ]; then
    fail "malformed env token was resolved: $OUT"
    continue
  fi
  if printf '%s' "$ERR" | grep -qF "tok"; then
    fail "diagnostic leaked the token value: $ERR"
  else
    pass "malformed env token dropped without leaking its value"
  fi
done

# 6) Same guard on the FILE path (a mis-pasted multi-line token in the json).
#    The malformed FILE token must be dropped, NOT silently replaced by some
#    other source — and never fall back to mangling.
mkdir -p "$WORK/home2/.config/axonflow"
jq -n '{token: "line1\nline2"}' > "$WORK/home2/.config/axonflow/user-token.json"
chmod 600 "$WORK/home2/.config/axonflow/user-token.json"
ERR="$(resolve "$WORK/home2" "" 2>&1 >/dev/null)"
OUT="$(resolve "$WORK/home2" "" 2>/dev/null)"
if [ -z "$OUT" ]; then
  pass "malformed file token dropped"
else
  fail "malformed file token was resolved: $OUT"
fi
printf '%s' "$ERR" | grep -qF "line1" \
  && fail "file diagnostic leaked the token value" \
  || pass "file diagnostic does not leak the token value"

# 7) Malformed ENV token does NOT fall through to a mangled send, but the
#    resolver DOES continue to the file fallback (env candidate is unset,
#    file is the next source) — matches resolve_user_token exactly.
OUT="$(resolve "$WORK/home1" 'bad token with spaces' 2>/dev/null)"
[ "$OUT" = "file.tok.value" ] \
  && pass "malformed env token dropped THEN 0600 file fallback used" \
  || fail "malformed-env→file fallback broken: $OUT"

# 8) An env var exported with a literal trailing space must be dropped,
#    not silently "fixed" — a stripped token would fail HS256 verification
#    server-side anyway and turn every call into a fail-closed denial.
OUT="$(resolve "$WORK/no-home" "${GOOD_TOKEN} " 2>/dev/null)"
[ -z "$OUT" ] && pass "trailing-space env token dropped (never mangled-and-sent)" \
  || fail "trailing-space env token resolved: $OUT"

# 9) AXONFLOW_CONFIG_DIR parity: the resolver honors the relocated config
#    dir (matching recover.sh's try-registration read and the claude
#    plugin's resolver), with the SAME 0600 discipline.
CFGDIR="$WORK/cfgdir-9"
mkdir -p "$CFGDIR"
printf '{"token":"cfgdir.tok.value"}' > "$CFGDIR/user-token.json"
chmod 600 "$CFGDIR/user-token.json"
OUT="$(resolve "$WORK/no-home" '' "$CFGDIR" 2>/dev/null)"
[ "$OUT" = "cfgdir.tok.value" ] && pass "AXONFLOW_CONFIG_DIR override: 0600 token file resolves from the relocated dir" \
  || fail "AXONFLOW_CONFIG_DIR token file did not resolve: '$OUT'"
chmod 644 "$CFGDIR/user-token.json"
OUT="$(resolve "$WORK/no-home" '' "$CFGDIR" 2>/dev/null)"
[ -z "$OUT" ] && pass "AXONFLOW_CONFIG_DIR override: 0644 token file still refused" \
  || fail "AXONFLOW_CONFIG_DIR 0644 file resolved: '$OUT'"

echo ""
echo "== mcp-auth-headers.sh reference impl =="

# Hermetic: the resolver honors AXONFLOW_CONFIG_DIR — scrub a host value so
# the reference-impl legs below (which only override HOME) stay hermetic.
unset AXONFLOW_CONFIG_DIR

# Hermetic invocation: AXONFLOW_ENDPOINT+AXONFLOW_AUTH pin self-hosted mode
# (no Community-SaaS bootstrap network traffic); AXONFLOW_CODEX_CONFIG points
# at a nonexistent file so a dev machine's real license token can't leak in.
run_ref() { # <home> [extra env pairs...]
  local home="$1"; shift
  env -u AXONFLOW_USER_TOKEN -u AXONFLOW_LICENSE_TOKEN \
    HOME="$home" AXONFLOW_CODEX_CONFIG=/nonexistent-axonflow-toml \
    AXONFLOW_ENDPOINT='http://selfhosted.local' AXONFLOW_AUTH='dGVzdA==' \
    "$@" bash "$ROOT/scripts/mcp-auth-headers.sh" 2>/dev/null
}

# 9) Configured → X-User-Token present in the emitted JSON.
OUT="$(run_ref "$WORK/no-home" AXONFLOW_USER_TOKEN="$GOOD_TOKEN")"
[ "$(printf '%s' "$OUT" | jq -r '."X-User-Token" // empty')" = "$GOOD_TOKEN" ] \
  && pass "reference impl emits X-User-Token when configured" \
  || fail "reference impl missing X-User-Token: $OUT"

# 10) Unconfigured → the emitted JSON has NO X-User-Token key AND the raw
#     bytes equal the configured output minus the inserted fragment (proves
#     strictly-additive: no reordering, no other drift).
BASE="$(run_ref "$WORK/no-home")"
if [ "$(printf '%s' "$BASE" | jq 'has("X-User-Token")')" = "false" ]; then
  pass "reference impl omits X-User-Token when unconfigured"
else
  fail "unconfigured run emitted X-User-Token: $BASE"
fi
EXPECTED_MINUS_FRAG="${OUT/\"X-User-Token\": \"$GOOD_TOKEN\", /}"
[ "$EXPECTED_MINUS_FRAG" = "$BASE" ] \
  && pass "configured output == unconfigured output + X-User-Token fragment (byte-identical otherwise)" \
  || fail "byte drift beyond the token fragment: configured-minus-frag=$EXPECTED_MINUS_FRAG unconfigured=$BASE"

# 11) File-token via the reference impl (0600) → present; 0644 → absent.
OUT="$(run_ref "$WORK/home1")"
[ "$(printf '%s' "$OUT" | jq -r '."X-User-Token" // empty')" = "file.tok.value" ] \
  && pass "reference impl loads the 0600 file token" \
  || fail "reference impl file token broken: $OUT"
chmod 644 "$WORK/home1/.config/axonflow/user-token.json"
OUT="$(run_ref "$WORK/home1")"
[ "$(printf '%s' "$OUT" | jq 'has("X-User-Token")')" = "false" ] \
  && pass "reference impl rejects the 0644 file token" \
  || fail "reference impl loaded a 0644 file token: $OUT"
chmod 600 "$WORK/home1/.config/axonflow/user-token.json"

# 12) No-auth shape (community self-hosted): token still emitted alongside
#     X-Axonflow-Client and the JSON stays valid.
OUT="$(env -u AXONFLOW_USER_TOKEN -u AXONFLOW_LICENSE_TOKEN \
  HOME="$WORK/no-home" AXONFLOW_CODEX_CONFIG=/nonexistent-axonflow-toml \
  AXONFLOW_ENDPOINT='http://selfhosted.local' AXONFLOW_AUTH='' \
  AXONFLOW_USER_TOKEN="$GOOD_TOKEN" bash "$ROOT/scripts/mcp-auth-headers.sh" 2>/dev/null)"
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 \
   && [ "$(printf '%s' "$OUT" | jq -r '."X-User-Token" // empty')" = "$GOOD_TOKEN" ]; then
  pass "no-auth branch emits valid JSON with X-User-Token"
else
  fail "no-auth branch broken: $OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
