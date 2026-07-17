#!/usr/bin/env bash
# PreToolUse hook — evaluate tool inputs against AxonFlow governance policies.
# Adapted for OpenAI Codex from the Claude Code plugin.
#
# Reads tool_name and tool_input from stdin (JSON).
# Calls AxonFlow check_policy via the MCP server endpoint.
#
# Codex hook exit codes:
#   Exit 0 = allow (no opinion)
#   Exit 2 = block (tool execution prevented)
#   Other non-zero = non-blocking error (tool proceeds)
#
# Fail-open: network failures → exit 0 (allow)
# Fail-closed: auth/config errors → exit 2 (block)

# Fail-open: if dependencies missing, allow the tool call
if ! command -v jq &>/dev/null; then
  exit 0
fi
if ! command -v curl &>/dev/null; then
  exit 0
fi

# Endpoint resolution per ADR-048: default to AxonFlow Community SaaS only when
# the user has not set explicit config. Any user-supplied AXONFLOW_ENDPOINT or
# AXONFLOW_AUTH is honoured untouched — no silent override.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${AXONFLOW_ENDPOINT:-}" ] && [ -z "${AXONFLOW_AUTH:-}" ]; then
  ENDPOINT="https://try.getaxonflow.com"
  AXONFLOW_MODE="community-saas"
  # Test-harness override (tests/heartbeat-real-stack/). Production code
  # paths leave AXONFLOW_HARNESS unset and the endpoint stays pinned.
  if [ "${AXONFLOW_HARNESS:-}" = "1" ] && [ -n "${AXONFLOW_HARNESS_AGENT_ENDPOINT:-}" ]; then
    ENDPOINT="$AXONFLOW_HARNESS_AGENT_ENDPOINT"
  fi
else
  ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
  AXONFLOW_MODE="self-hosted"
fi
AUTH="${AXONFLOW_AUTH:-}"
REQUEST_TIMEOUT_SECONDS="${AXONFLOW_TIMEOUT_SECONDS:-8}"
export AXONFLOW_MODE

# Mode-clarity canary on stderr (NEVER stdout — stdout is the hook protocol).
# CI's mode-clarity gate parses this line and asserts it matches the actual
# outbound destination. Users can never be misled about which AxonFlow they're
# talking to.
echo "[AxonFlow] Connected to AxonFlow at ${ENDPOINT} (mode=${AXONFLOW_MODE})" >&2

# Community-SaaS bootstrap: register with try.getaxonflow.com on first run and
# load the resulting Basic-auth credential into AXONFLOW_AUTH. No-op when the
# user has set explicit config (AXONFLOW_MODE != community-saas).
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/community-saas-bootstrap.sh"
AUTH="${AXONFLOW_AUTH:-}"

# ADR-050 §4: every governed request to the agent carries X-Axonflow-Client
# so the agent can derive request scope (plugin) and validate it against the
# token's aud.scope via HasScope().
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/client-header.sh"

# V1 Plugin Pro upgrade-prompt envelope handling (umbrella
# axonflow-enterprise#1958). Provides axonflow_throttle_active +
# axonflow_handle_envelope_response. See scripts/upgrade-prompt.sh.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/upgrade-prompt.sh"

# Build auth header array safely (avoids word-splitting)
AUTH_HEADER=()
if [ -n "$AUTH" ]; then
  AUTH_HEADER=(-H "Authorization: Basic $AUTH")
fi
AUTH_HEADER+=(-H "X-Axonflow-Client: ${AXONFLOW_CLIENT_HEADER}")

# V1 paid Pro tier (PR #1850): if a Pro-tier license token is present,
# forward it on every governed request. The agent's PluginClaimMiddleware
# (platform/agent/plugin_claim_middleware.go) reads the X-License-Token
# header, validates Ed25519 signature + DB row, and stamps a Pro-tier
# context that downstream handlers branch on for quota / retention /
# capability enforcement. Token absence = free tier (no header sent).
# shellcheck source=./lib/license-token.sh
. "${SCRIPT_DIR}/lib/license-token.sh"
axonflow_resolve_license_token
if [ -n "${AXONFLOW_LICENSE_TOKEN_RESOLVED:-}" ]; then
  AUTH_HEADER+=(-H "X-License-Token: ${AXONFLOW_LICENSE_TOKEN_RESOLVED}")
fi

# Per-user authorization token (axonflow-enterprise#2944, epic #2919).
# Resolve the admin-minted per-user token from env (AXONFLOW_USER_TOKEN —
# wins) or ~/.config/axonflow/user-token.json (0600-guarded, cross-plugin
# provisioning path) and, when present, ship it as X-User-Token so the
# platform resolves a VALIDATED {identity, role} for this developer instead
# of the least-privilege attribution-only fallback. Appended to AUTH_HEADER
# so it ships on every governed curl below (check_policy + the blocked
# audit_tool_call POST). Omitted entirely when unconfigured (no empty
# header) — requests are then byte-identical to a pre-token plugin. The
# token value is never logged.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/user-token.sh"
resolve_user_token
if [ -n "${AXONFLOW_USER_TOKEN:-}" ]; then
  AUTH_HEADER+=(-H "X-User-Token: ${AXONFLOW_USER_TOKEN}")
fi

# #2944: shared stderr hint used by every auth-failure branch below when a
# per-user token was sent — the platform fails closed on a presented-but-
# invalid X-User-Token (expired, revoked, wrong org), and the generic "fix
# AXONFLOW_AUTH" guidance would send the operator down the wrong path.
# Names the token's config surfaces, NEVER its value.
USER_TOKEN_HINT="A per-user token is configured (AXONFLOW_USER_TOKEN / user-token.json) and was sent as X-User-Token — if it is expired, revoked, or minted for a different org, the platform rejects the request; ask your admin to rotate it, or remove it to fall back to shared-credential attribution."

# One-time positive disclosure when first connecting to Community SaaS. Stamp
# is separate from telemetry so the disclosure fires exactly once per install,
# independent of the 7-day heartbeat cadence.
DISCLOSURE_STAMP="${HOME}/.cache/axonflow/codex-plugin-disclosure-shown"
if [ "$AXONFLOW_MODE" = "community-saas" ] && [ ! -f "$DISCLOSURE_STAMP" ]; then
  mkdir -p "$(dirname "$DISCLOSURE_STAMP")" 2>/dev/null && chmod 0700 "$(dirname "$DISCLOSURE_STAMP")" 2>/dev/null
  cat <<'EOF' >&2
[AxonFlow] Connected to AxonFlow Community SaaS at https://try.getaxonflow.com.
Intended for basic testing and evaluation. For real workflows, real systems,
or sensitive data, we recommend self-hosting AxonFlow from day one:
  https://docs.getaxonflow.com/quickstart
Anonymous telemetry: weekly heartbeat. Opt out: AXONFLOW_TELEMETRY=off
EOF
  : >"$DISCLOSURE_STAMP" 2>/dev/null
fi

# Telemetry heartbeat (7-day cadence; stamp-on-delivery; in-flight gate).
# Backgrounded so it never blocks the hook protocol.
"${SCRIPT_DIR}/telemetry-ping.sh" </dev/null &
# Plugin/platform version compatibility check — fire-and-forget, runs once
# per install, warns to stderr if the plugin is below the platform's
# min_plugin_version (axonflow-enterprise#1764). Same fire-and-forget shape
# as telemetry-ping; never blocks the hook hot path.
"${SCRIPT_DIR}/version-check.sh" </dev/null &

# Read hook input from stdin
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')

# Skip if no tool name
if [ -z "$TOOL_NAME" ]; then
  exit 0
fi

# Derive connector type: codex.{ToolName}
CONNECTOR_TYPE="codex.${TOOL_NAME}"

# Extract the statement to evaluate based on tool type
case "$TOOL_NAME" in
  Bash|exec_command|shell)
    STATEMENT=$(echo "$TOOL_INPUT" | jq -r '.cmd // .command // empty')
    ;;
  Write)
    FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')
    CONTENT=$(echo "$TOOL_INPUT" | jq -r '.content // empty' | cut -c1-2000)
    STATEMENT="${FILE_PATH}"$'\n'"${CONTENT}"
    ;;
  Edit)
    FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty')
    NEW_STRING=$(echo "$TOOL_INPUT" | jq -r '.new_string // empty' | cut -c1-2000)
    STATEMENT="${FILE_PATH}"$'\n'"${NEW_STRING}"
    ;;
  NotebookEdit)
    STATEMENT=$(echo "$TOOL_INPUT" | jq -r '.cell_content // .content // empty')
    ;;
  mcp__*)
    STATEMENT=$(echo "$TOOL_INPUT" | jq -r '.query // .statement // .command // .url // empty')
    if [ -z "$STATEMENT" ] || [ "$STATEMENT" = "null" ]; then
      STATEMENT=$(echo "$TOOL_INPUT" | jq -c '.')
    fi
    ;;
  *)
    STATEMENT=$(echo "$TOOL_INPUT" | jq -c '.')
    ;;
esac

# Skip if no statement to evaluate
if [ -z "$STATEMENT" ] || [ "$STATEMENT" = "null" ] || [ "$STATEMENT" = "{}" ]; then
  exit 0
fi

# V1 Plugin Pro back-off: when a recent governed call returned a 429/403
# envelope, the throttle-until stamp suppresses outbound traffic until the
# envelope's resets_at deadline. Fall open immediately so the user's tool
# calls aren't held up while we wait out the cap.
#
# #2944 exception — auth_failure throttle with a per-user token configured
# fails CLOSED: the 401 that stamped the throttle is the platform rejecting
# the presented X-User-Token (fail-closed contract, enterprise#2929). If we
# fell open here, setting a garbage AXONFLOW_USER_TOKEN would turn
# governance OFF for the whole cooldown window — a trivial bypass. Denying
# locally (no network round-trip) preserves the back-off AND the fail-closed
# posture. Unconfigured behavior is unchanged (fall open, as always).
if axonflow_throttle_active; then
  if [ -n "${AXONFLOW_USER_TOKEN:-}" ] && [ "$(axonflow_throttle_reason)" = "auth_failure" ]; then
    echo "AxonFlow governance blocked: the AxonFlow agent rejected authentication (HTTP 401) and an auth-failure cooldown is active. ${USER_TOKEN_HINT}" >&2
    exit 2
  fi
  exit 0
fi

# Call AxonFlow check_policy via MCP server.
#
# Issue #1545 Direction 3: fail OPEN on any network-level failure (timeout,
# DNS failure, connection refused, 5xx). Only auth/config errors reported
# by AxonFlow fail closed (see the JSONRPC_ERROR handling below).
#
# V1 Plugin Pro: capture HTTP status + headers + body separately so the
# envelope handler can detect 429 / 403 and stamp the throttle deadline
# before we fall through to the JSON-RPC parser.
PRECHECK_BODY=$(mktemp)
PRECHECK_HEADERS=$(mktemp)
trap 'rm -f "$PRECHECK_BODY" "$PRECHECK_HEADERS"' EXIT
HTTP_CODE=$(curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" \
  -D "$PRECHECK_HEADERS" -o "$PRECHECK_BODY" -w '%{http_code}' \
  -X POST "${ENDPOINT}/api/v1/mcp-server" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  "${AUTH_HEADER[@]}" \
  -d "$(jq -n \
    --arg ct "$CONNECTOR_TYPE" \
    --arg stmt "$STATEMENT" \
    '{
      jsonrpc: "2.0",
      id: "hook-pre",
      method: "tools/call",
      params: {
        name: "check_policy",
        arguments: {
          connector_type: $ct,
          statement: $stmt,
          operation: "execute"
        }
      }
    }')" 2>/dev/null)
CURL_EXIT=$?

# Any curl-level failure (exit != 0) means the network call failed —
# timeout, DNS failure, connection refused, TCP reset. Fail open.
if [ "$CURL_EXIT" -ne 0 ]; then
  exit 0
fi

# V1 Plugin Pro: detect the structured envelope on 429 / 403 responses.
# The helper stamps throttle-until + emits the upgrade prompt to stderr;
# fall open here so the user's tool isn't blocked while the cap clears.
if axonflow_handle_envelope_response "$HTTP_CODE" "$PRECHECK_BODY" "$PRECHECK_HEADERS"; then
  exit 0
fi

# axonflow-enterprise#2275: stamp a 5-minute throttle on HTTP 401 so a
# tight retry loop can't fire 716 × 401 in 24h (the production incident
# that motivated this). Caller falls open so the user's tool isn't held
# up while they refresh credentials.
#
# #2944 exception — when a per-user token was SENT, the 401 is the platform
# failing closed on a presented-but-invalid X-User-Token. Fail CLOSED (block
# the tool call) instead of falling open: a fall-open here would let anyone
# bypass governance by exporting a garbage token. The throttle stamp above
# still short-circuits subsequent calls locally (they deny via the
# auth_failure-throttle guard, no retry storm).
if axonflow_handle_auth_failure "$HTTP_CODE" "$PRECHECK_BODY" "$PRECHECK_HEADERS"; then
  if [ -n "${AXONFLOW_USER_TOKEN:-}" ]; then
    echo "AxonFlow governance blocked: the AxonFlow agent at ${ENDPOINT} rejected authentication (HTTP 401), so this tool call is blocked. ${USER_TOKEN_HINT}" >&2
    exit 2
  fi
  exit 0
fi

RESPONSE=$(cat "$PRECHECK_BODY")

# Empty body from an otherwise-successful curl should also fail open
# (ambiguous: could be 204 No Content, could be a weird proxy).
if [ -z "$RESPONSE" ]; then
  exit 0
fi

# Check for JSON-RPC error responses and apply the fail-open / fail-closed
# policy from issue #1545 Direction 3:
#
#   Fail CLOSED only on auth/config errors — where the operator can actually
#   fix the problem — so a broken governance setup can never be silently
#   bypassed. Network errors, server-internal errors, parse errors, and
#   timeouts all fail OPEN to avoid blocking legitimate dev workflows on
#   transient infrastructure issues.
#
#   Auth errors (-32001):       BLOCK — operator must fix AXONFLOW_AUTH
#   Method not found (-32601):  BLOCK — plugin version mismatch with agent
#   Invalid params (-32602):    BLOCK — plugin bug, operator should upgrade
#   Parse errors (-32700):      ALLOW — transient
#   Internal errors (-32603):   ALLOW — server-side fault, not operator's
#   Everything else:            ALLOW — unknown failure, default to allow
JSONRPC_ERROR=$(echo "$RESPONSE" | jq -r '.error.message // empty' 2>/dev/null || echo "")
if [ -n "$JSONRPC_ERROR" ]; then
  JSONRPC_CODE=$(echo "$RESPONSE" | jq -r '.error.code // 0' 2>/dev/null || echo "0")
  case "$JSONRPC_CODE" in
    -32001|-32601|-32602)
      # #2944: on the auth error (-32001), name a configured per-user token
      # as a likely cause — the platform fails closed on a presented-but-
      # invalid X-User-Token, and "fix AxonFlow configuration" alone would
      # send the operator down the wrong path. Never the token value.
      HINT_SUFFIX=""
      if [ "$JSONRPC_CODE" = "-32001" ] && [ -n "${AXONFLOW_USER_TOKEN:-}" ]; then
        HINT_SUFFIX=" ${USER_TOKEN_HINT}"
      fi
      echo "AxonFlow governance blocked: ${JSONRPC_ERROR} (code ${JSONRPC_CODE}). Fix AxonFlow configuration to restore tool access.${HINT_SUFFIX}" >&2
      exit 2
      ;;
    *)
      # Transient or server-side — fail open.
      exit 0
      ;;
  esac
fi

# Parse the MCP response to get the tool result
TOOL_RESULT=$(echo "$RESPONSE" | jq -r '.result.content[0].text // empty' 2>/dev/null || echo "")
if [ -z "$TOOL_RESULT" ]; then
  exit 0
fi

# Note: jq's // operator treats false as falsy, so .allowed // true returns
# true even when .allowed is false. Use explicit if/else instead.
ALLOWED=$(echo "$TOOL_RESULT" | jq -r 'if .allowed == false then "false" else "true" end' 2>/dev/null || echo "true")
BLOCK_REASON=$(echo "$TOOL_RESULT" | jq -r '.block_reason // empty' 2>/dev/null || echo "")
POLICIES_EVALUATED=$(echo "$TOOL_RESULT" | jq -r '.policies_evaluated // 0' 2>/dev/null || echo "0")

# Plugin Batch 1 (ADR-042 + ADR-043): richer block context surfaced when
# the platform is v7.1.0+. All fields are optional; absent on older platforms.
DECISION_ID=$(echo "$TOOL_RESULT" | jq -r '.decision_id // empty' 2>/dev/null || echo "")
RISK_LEVEL=$(echo "$TOOL_RESULT" | jq -r '.risk_level // empty' 2>/dev/null || echo "")
OVERRIDE_AVAILABLE=$(echo "$TOOL_RESULT" | jq -r '.override_available // false' 2>/dev/null || echo "false")
OVERRIDE_EXISTING_ID=$(echo "$TOOL_RESULT" | jq -r '.override_existing_id // empty' 2>/dev/null || echo "")

if [ "$ALLOWED" = "false" ]; then
  # Record the blocked attempt in the audit trail (fire-and-forget)
  curl -s --max-time "$REQUEST_TIMEOUT_SECONDS" -X POST "${ENDPOINT}/api/v1/mcp-server" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "${AUTH_HEADER[@]}" \
    -d "$(jq -n \
      --arg tn "$TOOL_NAME" \
      --arg stmt "$STATEMENT" \
      --arg reason "$BLOCK_REASON" \
      --arg policies "$POLICIES_EVALUATED" \
      '{
        jsonrpc: "2.0",
        id: "hook-audit-blocked",
        method: "tools/call",
        params: {
          name: "audit_tool_call",
          arguments: {
            tool_name: $tn,
            caller_name: "codex",
            input: {statement: $stmt},
            output: {policy_decision: "blocked", block_reason: $reason, policies_evaluated: $policies},
            success: false,
            error_message: ("Blocked by policy: " + $reason)
          }
        }
      }')" > /dev/null 2>&1 &

  # Codex: exit 2 = block tool execution. Reason on stderr.
  # Plugin Batch 1: append richer context when the platform surfaces it.
  CONTEXT_SUFFIX=""
  if [ -n "$DECISION_ID" ]; then
    CONTEXT_SUFFIX=" [decision: $DECISION_ID"
    if [ -n "$RISK_LEVEL" ]; then
      CONTEXT_SUFFIX="$CONTEXT_SUFFIX, risk: $RISK_LEVEL"
    fi
    if [ "$OVERRIDE_AVAILABLE" = "true" ]; then
      if [ -n "$OVERRIDE_EXISTING_ID" ]; then
        CONTEXT_SUFFIX="$CONTEXT_SUFFIX, active override: $OVERRIDE_EXISTING_ID"
      else
        CONTEXT_SUFFIX="$CONTEXT_SUFFIX, override available via explain_decision MCP tool"
      fi
    fi
    CONTEXT_SUFFIX="$CONTEXT_SUFFIX]"
  fi
  echo "AxonFlow policy violation: ${BLOCK_REASON} (${POLICIES_EVALUATED} policies evaluated)${CONTEXT_SUFFIX}" >&2
  exit 2
fi

# Allowed — exit 0
exit 0
# CI re-trigger: 1777491398
