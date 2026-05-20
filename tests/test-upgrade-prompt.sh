#!/usr/bin/env bash
# Unit tests for scripts/upgrade-prompt.sh — V1 Plugin Pro envelope handling.
#
# Exercises every branch of axonflow_handle_envelope_response +
# axonflow_throttle_active using captured envelope shapes that match the
# locked wire contract from
# axonflow-enterprise/platform/agent/community_saas_ratelimit_response.go.
#
# Each fixture body is a verbatim copy of what the agent emits — generated
# from `runtime-e2e/v1_pro_envelope_surface/EVIDENCE/<utc-ts>/envelope_body.json`
# (real wire) and the `community_saas_ratelimit_response_test.go` golden
# files. Edits to the locked envelope shape MUST flow through both that Go
# test and these fixtures.
#
# These run on every PR (`./tests/test-hooks.sh` companion). The runtime-e2e
# harness runs against try.getaxonflow.com but requires AWS access for the
# DB-seed path, so this unit suite is the always-on safety net.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$PLUGIN_DIR/scripts/upgrade-prompt.sh"

if [ ! -f "$HELPER" ]; then
  echo "FAIL: $HELPER not found"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH"
  exit 0
fi

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected to find '$needle' in:)"
    echo "$haystack" | head -5 | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected NOT to find '$needle' in:)"
    echo "$haystack" | head -5 | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
}

# Each test runs in a subshell that emits "PASS_INC=N FAIL_INC=N" on its
# last line; the parent reads that line and increments the running totals.
# Subshell isolation is required because:
#   - upgrade-prompt.sh's _AXONFLOW_UPGRADE_PROMPT_LOADED guard would
#     otherwise short-circuit re-sourcing (functions defined once, never
#     re-bound to a fresh XDG_CACHE_HOME).
#   - Once-per-day stamps live in $XDG_CACHE_HOME and bleed across tests
#     unless each test gets a fresh cache.
run_test() {
  local name="$1"
  shift
  echo
  echo "=== $name ==="
  local out
  out=$(
    (
      PASS=0
      FAIL=0
      "$@"
      echo "TEST_RESULT_PASS=$PASS"
      echo "TEST_RESULT_FAIL=$FAIL"
    )
  )
  # Print everything except the magic trailers so the human sees the
  # PASS/FAIL lines in real-time order.
  echo "$out" | grep -v '^TEST_RESULT_'
  local sub_pass sub_fail
  sub_pass=$(echo "$out" | awk -F= '/^TEST_RESULT_PASS=/{print $2}')
  sub_fail=$(echo "$out" | awk -F= '/^TEST_RESULT_FAIL=/{print $2}')
  PASS=$((PASS + ${sub_pass:-0}))
  FAIL=$((FAIL + ${sub_fail:-0}))
}

mk_tmp_cache() {
  local d
  d=$(mktemp -d -t axonflow-upprompt.XXXXXX)
  echo "$d"
}

mk_body_429_daily_quota() {
  cat <<'EOF'
{
  "error": "Daily request limit reached. Resets at midnight UTC.",
  "limit_type": "daily_quota",
  "tier": "Free",
  "limit": 200,
  "remaining": 0,
  "window": "daily_utc",
  "resets_at": "2099-12-31T23:59:59Z",
  "upgrade": {
    "tier": "Pro",
    "wording": "Daily limit reached on Free tier (200 events). Pro raises this to 2,000/day. Resets at midnight UTC.",
    "compare_url": "https://getaxonflow.com/pricing/",
    "buy_url": "https://buy.stripe.com/bJe28qbztcdVchjdkw8k800"
  }
}
EOF
}

mk_body_403_active_policies() {
  cat <<'EOF'
{
  "error": "Free tier supports 2 active custom policies. Delete one to make room, or Pro removes the cap.",
  "limit_type": "active_policies",
  "tier": "Free",
  "limit": 2,
  "remaining": 0,
  "upgrade": {
    "tier": "Pro",
    "wording": "Free tier supports 2 active custom policies. Delete one to make room, or Pro removes the cap.",
    "compare_url": "https://getaxonflow.com/pricing/",
    "buy_url": "https://buy.stripe.com/bJe28qbztcdVchjdkw8k800"
  }
}
EOF
}

# JSON-RPC wrapped envelope (returned by /api/v1/mcp-server tools/call when
# enforceMCPToolGate fires writeMCPGateError — see mcp_v1_pro_tools.go).
mk_body_jsonrpc_wrapped_envelope() {
  cat <<'EOF'
{
  "jsonrpc": "2.0",
  "id": "call-1",
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\n  \"error\": \"Free tier supports 2 active custom policies. Delete one to make room, or Pro removes the cap.\",\n  \"limit_type\": \"active_policies\",\n  \"tier\": \"Free\",\n  \"limit\": 2,\n  \"remaining\": 0,\n  \"upgrade\": {\n    \"tier\": \"Pro\",\n    \"wording\": \"Free tier supports 2 active custom policies. Delete one to make room, or Pro removes the cap.\",\n    \"compare_url\": \"https://getaxonflow.com/pricing/\",\n    \"buy_url\": \"https://buy.stripe.com/bJe28qbztcdVchjdkw8k800\"\n  }\n}"
      }
    ],
    "isError": true
  }
}
EOF
}

mk_headers_429_with_retry_after() {
  cat <<'EOF'
HTTP/2 429
content-type: application/json
x-axonflow-tier-limit: daily_quota
x-axonflow-upgrade-url: https://getaxonflow.com/pricing/
retry-after: 3600
date: Thu, 07 May 2026 00:25:10 GMT
EOF
}

mk_headers_403_no_retry_after() {
  cat <<'EOF'
HTTP/2 403
content-type: application/json
x-axonflow-tier-limit: active_policies
x-axonflow-upgrade-url: https://getaxonflow.com/pricing/
date: Thu, 07 May 2026 00:25:10 GMT
EOF
}

mk_body_legacy_429_no_envelope() {
  # Legacy / older self-hosted stacks that haven't been updated to the
  # V1 envelope shape — body is a bare error string.
  cat <<'EOF'
{"error": "Rate limit exceeded (20 req/min). Try again shortly."}
EOF
}

# ---------------------------------------------------------------------------
# Test 1: 429 daily-quota envelope is detected, wording surfaced, throttle
# stamped from resets_at.
# ---------------------------------------------------------------------------
test_429_daily_quota() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers stderr_out
  body=$(mktemp); mk_body_429_daily_quota >"$body"
  headers=$(mktemp); mk_headers_429_with_retry_after >"$headers"
  stderr_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_envelope_response "429" "$body" "$headers" 2>"$stderr_out"
  local rc=$?

  assert_eq "rc == 0 (envelope detected)" "0" "$rc"
  assert_contains "stderr carries locked wording" "$(cat "$stderr_out")" "Pro raises this to 2,000/day"
  assert_contains "stderr carries Pro upgrade pointer" "$(cat "$stderr_out")" "https://buy.stripe.com/bJe28qbztcdVchjdkw8k800"

  # Throttle file stamped, deadline in the future.
  local tf="$cache/axonflow/throttle-until"
  assert_eq "throttle file exists" "yes" "$([ -f "$tf" ] && echo yes || echo no)"
  if [ -f "$tf" ]; then
    local epoch; epoch=$(awk 'NR==1 {print $1}' "$tf")
    local now; now=$(date -u +%s)
    if [ -n "$epoch" ] && [ "$epoch" -gt "$now" ]; then
      assert_eq "deadline in the future" "yes" "yes"
    else
      assert_eq "deadline in the future" "yes" "no (epoch=$epoch now=$now)"
    fi
  fi

  rm -f "$body" "$headers" "$stderr_out"
}

# ---------------------------------------------------------------------------
# Test 2: 403 active_policies envelope (no resets_at, no Retry-After) still
# stamps a short throttle deadline so the next call backs off briefly.
# ---------------------------------------------------------------------------
test_403_active_policies() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers stderr_out
  body=$(mktemp); mk_body_403_active_policies >"$body"
  headers=$(mktemp); mk_headers_403_no_retry_after >"$headers"
  stderr_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_envelope_response "403" "$body" "$headers" 2>"$stderr_out"
  local rc=$?

  assert_eq "rc == 0 (envelope detected)" "0" "$rc"
  assert_contains "stderr carries active_policies wording" "$(cat "$stderr_out")" "Free tier supports 2 active custom policies"

  local tf="$cache/axonflow/throttle-until"
  assert_eq "throttle file exists despite no resets_at" "yes" "$([ -f "$tf" ] && echo yes || echo no)"

  rm -f "$body" "$headers" "$stderr_out"
}

# ---------------------------------------------------------------------------
# Test 3: JSON-RPC wrapped envelope (the shape returned on the MCP path
# by writeMCPGateError) is parsed via the dual-shape branch.
# ---------------------------------------------------------------------------
test_jsonrpc_wrapped_envelope() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers stderr_out
  body=$(mktemp); mk_body_jsonrpc_wrapped_envelope >"$body"
  # MCP path returns 200 OK with the gate result inside JSON-RPC; the
  # helper still treats it as envelope-bearing because limit_type is
  # present in the wrapped text. Documented behaviour.
  headers=$(mktemp); mk_headers_403_no_retry_after >"$headers"
  stderr_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_envelope_response "403" "$body" "$headers" 2>"$stderr_out"
  local rc=$?

  assert_eq "rc == 0 (wrapped envelope detected)" "0" "$rc"
  assert_contains "stderr carries wrapped wording" "$(cat "$stderr_out")" "Free tier supports 2 active custom policies"

  rm -f "$body" "$headers" "$stderr_out"
}

# ---------------------------------------------------------------------------
# Test 4: legacy 429 (no envelope, just bare error) — helper returns
# non-zero so caller's existing fall-open path runs unchanged. Critical
# guard: older self-hosted stacks must NOT see new behaviour.
# ---------------------------------------------------------------------------
test_legacy_429_no_envelope_preserves_behaviour() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers stderr_out
  body=$(mktemp); mk_body_legacy_429_no_envelope >"$body"
  headers=$(mktemp); echo "" >"$headers"
  stderr_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_envelope_response "429" "$body" "$headers" 2>"$stderr_out"
  local rc=$?

  assert_eq "rc != 0 (no envelope; caller falls through)" "1" "$rc"

  # Throttle file MUST NOT be stamped — caller's normal path runs.
  local tf="$cache/axonflow/throttle-until"
  assert_eq "throttle file NOT stamped on legacy 429" "no" "$([ -f "$tf" ] && echo yes || echo no)"

  rm -f "$body" "$headers" "$stderr_out"
}

# ---------------------------------------------------------------------------
# Test 5: non-429/403 status (e.g. 200) is rejected immediately — even
# if the body were envelope-shaped, we don't fire on success codes.
# ---------------------------------------------------------------------------
test_non_4xx_status_ignored() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers
  body=$(mktemp); mk_body_429_daily_quota >"$body"
  headers=$(mktemp); mk_headers_429_with_retry_after >"$headers"

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_envelope_response "200" "$body" "$headers" 2>/dev/null
  local rc=$?
  assert_eq "rc != 0 for HTTP 200" "1" "$rc"

  axonflow_handle_envelope_response "500" "$body" "$headers" 2>/dev/null
  rc=$?
  assert_eq "rc != 0 for HTTP 500" "1" "$rc"

  rm -f "$body" "$headers"
}

# ---------------------------------------------------------------------------
# Test 6: once-per-UTC-day stamp suppresses the wording on the second
# invocation against the same envelope.
# ---------------------------------------------------------------------------
test_once_per_day_stamp() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers stderr1 stderr2
  body=$(mktemp); mk_body_429_daily_quota >"$body"
  headers=$(mktemp); mk_headers_429_with_retry_after >"$headers"
  stderr1=$(mktemp)
  stderr2=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_envelope_response "429" "$body" "$headers" 2>"$stderr1"
  axonflow_handle_envelope_response "429" "$body" "$headers" 2>"$stderr2"

  assert_contains "first invocation prints wording" "$(cat "$stderr1")" "Pro raises this to 2,000/day"
  assert_not_contains "second invocation suppresses wording (once-per-day)" \
    "$(cat "$stderr2")" "Pro raises this to 2,000/day"

  rm -f "$body" "$headers" "$stderr1" "$stderr2"
}

# ---------------------------------------------------------------------------
# Test 7: axonflow_throttle_active reflects the stamped deadline.
#   - no stamp → returns 1 (no throttle)
#   - future-epoch stamp → returns 0 (active)
#   - past-epoch stamp → returns 1 + clears the file
# ---------------------------------------------------------------------------
test_throttle_active_states() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  # shellcheck disable=SC1090
  . "$HELPER"

  # Case A: no file
  axonflow_throttle_active
  assert_eq "no stamp → throttle inactive" "1" "$?"

  # Case B: future epoch
  mkdir -p "$cache/axonflow"
  echo "9999999999 daily_quota" >"$cache/axonflow/throttle-until"
  axonflow_throttle_active
  assert_eq "future epoch → throttle active" "0" "$?"

  # Case C: past epoch — should clear the file
  echo "1 daily_quota" >"$cache/axonflow/throttle-until"
  axonflow_throttle_active
  assert_eq "past epoch → throttle inactive" "1" "$?"
  assert_eq "past-epoch stamp file cleared" "no" \
    "$([ -f "$cache/axonflow/throttle-until" ] && echo yes || echo no)"
}

# ---------------------------------------------------------------------------
# Test 8: helper writes nothing to stdout (stdout is reserved for the
# hook protocol; any byte breaks the parser).
# ---------------------------------------------------------------------------
test_no_stdout_bytes() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers stdout_out
  body=$(mktemp); mk_body_429_daily_quota >"$body"
  headers=$(mktemp); mk_headers_429_with_retry_after >"$headers"
  stdout_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_envelope_response "429" "$body" "$headers" >"$stdout_out" 2>/dev/null
  local size; size=$(wc -c <"$stdout_out" | tr -d ' ')
  assert_eq "stdout is empty" "0" "$size"

  rm -f "$body" "$headers" "$stdout_out"
}

# ---------------------------------------------------------------------------
# Test 9: HTTP 401 auth-failure handling — stamps a 5-minute throttle so the
# next hook fire short-circuits locally, emits a credential-refresh nudge,
# and writes nothing to stdout. Closes axonflow-enterprise#2275 (716 × 401
# in 24h from one source IP — a tight retry loop with no back-off).
# ---------------------------------------------------------------------------
test_401_auth_failure_stamps_throttle() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers stderr_out stdout_out
  body=$(mktemp); echo '{"error":"unauthorized"}' >"$body"
  headers=$(mktemp); echo "" >"$headers"
  stderr_out=$(mktemp)
  stdout_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  local before; before=$(date -u +%s)
  axonflow_handle_auth_failure "401" "$body" "$headers" >"$stdout_out" 2>"$stderr_out"
  local rc=$?

  assert_eq "rc == 0 (401 detected)" "0" "$rc"
  assert_eq "stdout is empty" "0" "$(wc -c <"$stdout_out" | tr -d ' ')"
  assert_contains "stderr names HTTP 401 + pause window" "$(cat "$stderr_out")" \
    "Authentication failed (HTTP 401) against the AxonFlow agent. Tool governance is paused for 5 minutes."
  assert_contains "stderr points to dashboard for credential refresh" "$(cat "$stderr_out")" \
    "https://getaxonflow.com/dashboard"

  # Throttle file stamped with auth_failure limit type + deadline ~ now+300.
  local tf="$cache/axonflow/throttle-until"
  assert_eq "throttle file exists" "yes" "$([ -f "$tf" ] && echo yes || echo no)"
  if [ -f "$tf" ]; then
    local epoch limit_type
    epoch=$(awk 'NR==1 {print $1}' "$tf")
    limit_type=$(awk 'NR==1 {print $2}' "$tf")
    assert_eq "limit_type == auth_failure" "auth_failure" "$limit_type"
    # Deadline must be within [before+295, before+305] to allow for clock
    # ticks during the call without admitting drift outside the spec.
    local lower=$((before + 295))
    local upper=$((before + 305))
    if [ -n "$epoch" ] && [ "$epoch" -ge "$lower" ] && [ "$epoch" -le "$upper" ]; then
      assert_eq "deadline ~ now+300s (5min cooldown)" "yes" "yes"
    else
      assert_eq "deadline ~ now+300s (5min cooldown)" "yes" \
        "no (epoch=$epoch lower=$lower upper=$upper)"
    fi
  fi

  # axonflow_throttle_active observes the stamp.
  axonflow_throttle_active
  assert_eq "axonflow_throttle_active picks up the 401 stamp" "0" "$?"

  rm -f "$body" "$headers" "$stderr_out" "$stdout_out"
}

# ---------------------------------------------------------------------------
# Test 10: non-401 status codes do NOT trigger axonflow_handle_auth_failure.
# Confirms the function is scoped to the exact code, not any 4xx. This is
# the boundary that keeps the envelope handler in charge of 403 / 429.
# ---------------------------------------------------------------------------
test_non_401_auth_failure_ignored() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers
  body=$(mktemp); echo '{"error":"unauthorized"}' >"$body"
  headers=$(mktemp); echo "" >"$headers"

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_auth_failure "200" "$body" "$headers" 2>/dev/null
  assert_eq "rc != 0 for HTTP 200" "1" "$?"

  axonflow_handle_auth_failure "403" "$body" "$headers" 2>/dev/null
  assert_eq "rc != 0 for HTTP 403 (envelope handler owns this)" "1" "$?"

  axonflow_handle_auth_failure "429" "$body" "$headers" 2>/dev/null
  assert_eq "rc != 0 for HTTP 429 (envelope handler owns this)" "1" "$?"

  axonflow_handle_auth_failure "500" "$body" "$headers" 2>/dev/null
  assert_eq "rc != 0 for HTTP 500" "1" "$?"

  axonflow_handle_auth_failure "" "$body" "$headers" 2>/dev/null
  assert_eq "rc != 0 for empty http_code" "1" "$?"

  # Throttle file MUST NOT be stamped on any non-401 path.
  local tf="$cache/axonflow/throttle-until"
  assert_eq "throttle file NOT stamped on non-401 paths" "no" \
    "$([ -f "$tf" ] && echo yes || echo no)"

  rm -f "$body" "$headers"
}

# ---------------------------------------------------------------------------
# Test 11: auth-failure prompt is once-per-UTC-day (independent of the
# tier-limit prompt stamp).
# ---------------------------------------------------------------------------
test_401_once_per_day_stamp() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  local body headers stderr1 stderr2
  body=$(mktemp); echo '{"error":"unauthorized"}' >"$body"
  headers=$(mktemp); echo "" >"$headers"
  stderr1=$(mktemp)
  stderr2=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  axonflow_handle_auth_failure "401" "$body" "$headers" 2>"$stderr1"
  axonflow_handle_auth_failure "401" "$body" "$headers" 2>"$stderr2"

  assert_contains "first 401 prints credential-refresh nudge" "$(cat "$stderr1")" \
    "Authentication failed (HTTP 401)"
  assert_not_contains "second 401 suppresses nudge (once-per-day)" \
    "$(cat "$stderr2")" "Authentication failed (HTTP 401)"

  rm -f "$body" "$headers" "$stderr1" "$stderr2"
}

# ---------------------------------------------------------------------------
# Test 12: AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS env override is honored
# (canonical name shared with the cursor + claude plugins). The default
# remains 300s when the env var is unset; this test exercises the override
# path so the codex plugin stays tunable for testing/tuning.
#
# Mutation-test recipe (manual): comment out the
#   cooldown="${AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS:-300}"
# line so cooldown falls back to 300 — this test fails at the deadline
# assertion (deadline lands ~now+300s, not ~now+1s).
# ---------------------------------------------------------------------------
test_401_env_override_cooldown() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"
  export AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS=1

  local body headers stderr_out
  body=$(mktemp); echo '{"error":"unauthorized"}' >"$body"
  headers=$(mktemp); echo "" >"$headers"
  stderr_out=$(mktemp)

  # shellcheck disable=SC1090
  . "$HELPER"

  local before; before=$(date -u +%s)
  axonflow_handle_auth_failure "401" "$body" "$headers" 2>"$stderr_out"
  local rc=$?

  assert_eq "rc == 0 (401 detected with env override)" "0" "$rc"

  local tf="$cache/axonflow/throttle-until"
  assert_eq "throttle file exists" "yes" "$([ -f "$tf" ] && echo yes || echo no)"
  if [ -f "$tf" ]; then
    local epoch
    epoch=$(awk 'NR==1 {print $1}' "$tf")
    # Deadline should be ~ before+1 (allow ±2s for clock ticks during the
    # call). The mutation gate is wide: default-cooldown (300) lands at
    # before+300, far outside any sane tolerance.
    local lower=$((before - 1))
    local upper=$((before + 3))
    if [ -n "$epoch" ] && [ "$epoch" -ge "$lower" ] && [ "$epoch" -le "$upper" ]; then
      assert_eq "deadline ~ now+1s (env override honored)" "yes" "yes"
    else
      assert_eq "deadline ~ now+1s (env override honored)" "yes" \
        "no (epoch=$epoch lower=$lower upper=$upper)"
    fi
  fi

  unset AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS
  rm -f "$body" "$headers" "$stderr_out"
}

# ---------------------------------------------------------------------------
# Test 13: malformed AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS overrides fall
# back to 300s — a typo in the env var must NOT silently disable the
# back-off (which is the bug-class that motivated the 401 throttle in the
# first place). Covers: non-integer, negative, zero.
# ---------------------------------------------------------------------------
test_401_env_override_malformed_falls_back_to_default() {
  local cache; cache=$(mk_tmp_cache)
  trap "rm -rf '$cache'" EXIT
  export XDG_CACHE_HOME="$cache"

  # shellcheck disable=SC1090
  . "$HELPER"

  local body headers
  body=$(mktemp); echo '{"error":"unauthorized"}' >"$body"
  headers=$(mktemp); echo "" >"$headers"

  for bad_value in "abc" "-5" "0"; do
    rm -f "$cache/axonflow/throttle-until"
    export AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS="$bad_value"
    local before; before=$(date -u +%s)
    axonflow_handle_auth_failure "401" "$body" "$headers" 2>/dev/null
    local tf="$cache/axonflow/throttle-until"
    if [ -f "$tf" ]; then
      local epoch
      epoch=$(awk 'NR==1 {print $1}' "$tf")
      local lower=$((before + 295))
      local upper=$((before + 305))
      if [ -n "$epoch" ] && [ "$epoch" -ge "$lower" ] && [ "$epoch" -le "$upper" ]; then
        assert_eq "malformed='$bad_value' falls back to 300s" "yes" "yes"
      else
        assert_eq "malformed='$bad_value' falls back to 300s" "yes" \
          "no (epoch=$epoch lower=$lower upper=$upper)"
      fi
    else
      assert_eq "throttle stamped for malformed='$bad_value'" "yes" "no"
    fi
  done

  unset AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS
  rm -f "$body" "$headers"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
run_test "T1: 429 daily-quota envelope" test_429_daily_quota
run_test "T2: 403 active_policies envelope" test_403_active_policies
run_test "T3: JSON-RPC wrapped envelope" test_jsonrpc_wrapped_envelope
run_test "T4: legacy 429 no envelope (preserve behaviour)" test_legacy_429_no_envelope_preserves_behaviour
run_test "T5: non-4xx status ignored" test_non_4xx_status_ignored
run_test "T6: once-per-day stamp suppresses second wording" test_once_per_day_stamp
run_test "T7: axonflow_throttle_active state machine" test_throttle_active_states
run_test "T8: no stdout bytes" test_no_stdout_bytes
run_test "T9: 401 auth-failure stamps 5min throttle + dashboard nudge" test_401_auth_failure_stamps_throttle
run_test "T10: non-401 status codes ignored by auth-failure helper" test_non_401_auth_failure_ignored
run_test "T11: 401 nudge is once-per-UTC-day" test_401_once_per_day_stamp
run_test "T12: AXONFLOW_AUTH_FAILURE_COOLDOWN_SECONDS env override honored" test_401_env_override_cooldown
run_test "T13: malformed cooldown env override falls back to 300s" test_401_env_override_malformed_falls_back_to_default

echo
echo "==============================="
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
echo "==============================="
[ "$FAIL" -eq 0 ]
