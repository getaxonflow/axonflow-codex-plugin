#!/usr/bin/env bash
# hook-failure-posture: runtime E2E for the Codex plugin hooks' failure posture.
#
# Fires the plugin's REAL hook scripts (scripts/pre-tool-check.sh and
# scripts/post-tool-audit.sh) with Codex's hook JSON on stdin, the way Codex
# runs them, against a REAL AxonFlow stack and against an endpoint nothing
# listens on. No mocks, no stubs. See README.md.
#
# Usage: AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/hook-failure-posture/test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRE_HOOK="$PLUGIN_DIR/scripts/pre-tool-check.sh"
POST_HOOK="$PLUGIN_DIR/scripts/post-tool-audit.sh"

ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
EVIDENCE="${AXONFLOW_E2E_EVIDENCE_DIR:-$(mktemp -d -t hook-failure-posture.XXXXXX)}"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== Hook failure posture (Codex hooks) ==="
echo "Endpoint: $ENDPOINT"
echo "Evidence: $EVIDENCE"
mkdir -p "$EVIDENCE" || exit 1

for tool in curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool not on PATH"
    exit 0
  fi
done
if ! curl -sSf -o /dev/null --max-time 5 "$ENDPOINT/health"; then
  echo "SKIP: AxonFlow stack not reachable at $ENDPOINT"
  exit 0
fi

# A port nothing listens on: bind one, then release it.
DEAD_PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
DEAD_ENDPOINT="http://127.0.0.1:${DEAD_PORT}"

SANDBOX="$EVIDENCE/sandbox"
mkdir -p "$SANDBOX/home/.config/axonflow" || exit 1

# fire <hook> <tag> <endpoint> <hook JSON> [NAME=VALUE ...]: runs the hook the
# way Codex does, as a subprocess with the hook JSON on stdin, in a sandbox home
# with its own cache, and keeps what it saw.
fire() {
  local hook="$1" tag="$2" endpoint="$3" json="$4"
  shift 4
  printf '%s' "$json" > "$EVIDENCE/$tag.stdin.json"
  (
    cd "$PLUGIN_DIR" || exit 97
    env -u AXONFLOW_USER_TOKEN -u AXONFLOW_LICENSE_TOKEN -u AXONFLOW_PEP_AUDIENCE -u AXONFLOW_MODE -u AXONFLOW_FAIL_MODE \
      HOME="$SANDBOX/home" AXONFLOW_CONFIG_DIR="$SANDBOX/home/.config/axonflow" XDG_CACHE_HOME="$SANDBOX/cache-$tag" \
      AXONFLOW_ENDPOINT="$endpoint" AXONFLOW_AUTH="" \
      AXONFLOW_TELEMETRY=off AXONFLOW_PLUGIN_VERSION_CHECK=off AXONFLOW_IDENTITY_NOTICE=off \
      "$@" bash "$hook"
  ) < "$EVIDENCE/$tag.stdin.json" > "$EVIDENCE/$tag.stdout" 2> "$EVIDENCE/$tag.stderr"
  echo "$?" > "$EVIDENCE/$tag.rc"
}

pre_json() { jq -nc --arg c "$1" '{tool_name: "exec_command", tool_input: {cmd: $c}}'; }
post_json() { jq -nc --arg o "$1" '{tool_name: "exec_command", tool_input: {cmd: "cat notes.txt"}, tool_response: {stdout: $o, exitCode: 0}}'; }
rc() { cat "$EVIDENCE/$1.rc"; }
has() { grep -qF "$2" "$EVIDENCE/$1.$3"; }

NOTICE="GOVERNANCE UNAVAILABLE"

echo ""
echo "--- 1. the platform decides: an allow and a deny ---"
fire "$PRE_HOOK" pre-allow "$ENDPOINT" "$(pre_json "echo hook-failure-posture")"
if [ "$(rc pre-allow)" = 0 ] && ! has pre-allow "$NOTICE" stderr; then
  pass "an allowed command runs (exit 0), with no governance notice"
else
  fail "an allowed command: exit $(rc pre-allow), stderr: $(cat "$EVIDENCE/pre-allow.stderr")"
fi
fire "$PRE_HOOK" pre-deny "$ENDPOINT" "$(pre_json "rm -rf / --no-preserve-root")"
if [ "$(rc pre-deny)" = 2 ] && has pre-deny "AxonFlow policy violation" stderr; then
  pass "a destructive command is blocked (exit 2): $(grep -F 'AxonFlow policy violation' "$EVIDENCE/pre-deny.stderr" | head -1)"
else
  fail "a destructive command: exit $(rc pre-deny), stderr: $(cat "$EVIDENCE/pre-deny.stderr")"
fi

echo ""
echo "--- 2. no answer, AXONFLOW_FAIL_MODE unset: the tool call runs, and says so ---"
fire "$PRE_HOOK" pre-down "$DEAD_ENDPOINT" "$(pre_json "echo hook-failure-posture down")"
if [ "$(rc pre-down)" = 0 ] && has pre-down "$NOTICE" stderr && has pre-down "This tool call runs UNGOVERNED" stderr; then
  pass "unreachable: exit 0 with the notice: $(grep -F "$NOTICE" "$EVIDENCE/pre-down.stderr" | head -1)"
else
  fail "unreachable, fail mode unset: exit $(rc pre-down), stderr: $(cat "$EVIDENCE/pre-down.stderr")"
fi
fire "$POST_HOOK" post-down "$DEAD_ENDPOINT" "$(post_json "total 0")"
if [ "$(rc post-down)" = 0 ] && [ ! -s "$EVIDENCE/post-down.stdout" ] && has post-down "This tool output was NOT checked" stderr; then
  pass "unreachable (post): the output passes with the notice, and no alert"
else
  fail "unreachable (post): exit $(rc post-down), stdout: $(cat "$EVIDENCE/post-down.stdout"), stderr: $(cat "$EVIDENCE/post-down.stderr")"
fi

echo ""
echo "--- 3. no answer, AXONFLOW_FAIL_MODE=closed: blocked ---"
fire "$PRE_HOOK" pre-down-closed "$DEAD_ENDPOINT" "$(pre_json "echo hook-failure-posture closed")" AXONFLOW_FAIL_MODE=closed
if [ "$(rc pre-down-closed)" = 2 ] && has pre-down-closed 'AXONFLOW_FAIL_MODE is "closed"' stderr; then
  pass "unreachable under closed: blocked (exit 2): $(grep -F 'AXONFLOW_FAIL_MODE' "$EVIDENCE/pre-down-closed.stderr" | head -1)"
else
  fail "unreachable under closed: exit $(rc pre-down-closed), stderr: $(cat "$EVIDENCE/pre-down-closed.stderr")"
fi
fire "$POST_HOOK" post-down-closed "$DEAD_ENDPOINT" "$(post_json "total 0")" AXONFLOW_FAIL_MODE=closed
if [ "$(rc post-down-closed)" = 0 ] && jq -r '.hookSpecificOutput.additionalContext // empty' "$EVIDENCE/post-down-closed.stdout" 2>/dev/null | grep -qF "could not check this tool output"; then
  pass "unreachable under closed (post): the governance alert withholds the output"
else
  fail "unreachable under closed (post): stdout: $(cat "$EVIDENCE/post-down-closed.stdout")"
fi

echo ""
echo "--- 4. the switch never loosens a decision ---"
fire "$PRE_HOOK" pre-deny-open "$ENDPOINT" "$(pre_json "rm -rf / --no-preserve-root")" AXONFLOW_FAIL_MODE=open
if [ "$(rc pre-deny-open)" = 2 ] && has pre-deny-open "AxonFlow policy violation" stderr; then
  pass "a deny under AXONFLOW_FAIL_MODE=open is still blocked (exit 2)"
else
  fail "a deny under open: exit $(rc pre-deny-open), stderr: $(cat "$EVIDENCE/pre-deny-open.stderr")"
fi

echo ""
echo "=== Hook failure posture (Codex hooks): $PASS passed, $FAIL failed ==="
echo "Evidence: $EVIDENCE"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
