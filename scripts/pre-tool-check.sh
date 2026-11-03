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
# Hosted fails closed when the Agent cannot return a usable decision.
# Self-hosted keeps its historical fail-open behavior for transport/server faults.

# Recognize equivalent Hosted origins before dependency checks or mode selection.
# A malformed URL on the Hosted hostname must not take the self-hosted fail-open
# path. Lookalike hostnames remain self-hosted.
axonflow_canonical_hosted_endpoint() {
  local url="$1" scheme authority authority_host suffix host
  [[ "$url" =~ ^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]+)(.*)$ ]] || return 1
  scheme=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
  authority=$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')
  suffix="${BASH_REMATCH[3]}"
  if [[ "$authority" == *@* ]]; then
    authority_host="${authority##*@}"
    case "$authority_host" in
      try.getaxonflow.com|try.getaxonflow.com.|try.getaxonflow.com:*|try.getaxonflow.com.:*|try-staging.getaxonflow.com|try-staging.getaxonflow.com.|try-staging.getaxonflow.com:*|try-staging.getaxonflow.com.:*) return 2 ;;
    esac
  fi
  case "$authority" in
    try.getaxonflow.com|try.getaxonflow.com.|try.getaxonflow.com:*|try.getaxonflow.com.:*) host=try.getaxonflow.com ;;
    try-staging.getaxonflow.com|try-staging.getaxonflow.com.|try-staging.getaxonflow.com:*|try-staging.getaxonflow.com.:*) host=try-staging.getaxonflow.com ;;
    *) return 1 ;;
  esac
  if [[ "$scheme" != https || ! "$suffix" =~ ^/*$ ]]; then return 2; fi
  case "$authority" in
    "$host"|"$host."|"$host:443"|"$host.:443") printf 'https://%s' "$host" ;;
    *) return 2 ;;
  esac
}
if [ -n "${AXONFLOW_ENDPOINT:-}" ]; then
  hosted_origin=$(axonflow_canonical_hosted_endpoint "$AXONFLOW_ENDPOINT")
  hosted_status=$?
  if [ "$hosted_status" -eq 0 ]; then
    AXONFLOW_ENDPOINT="$hosted_origin"
    export AXONFLOW_ENDPOINT
  elif [ "$hosted_status" -eq 2 ]; then
    echo "[AxonFlow] Governance blocked: invalid Hosted endpoint URL." >&2
    exit 2
  fi
fi

# A Hosted hook without its dependencies cannot check a governed call.
case "${AXONFLOW_ENDPOINT:-}" in
  ""|https://try.getaxonflow.com|https://try-staging.getaxonflow.com)
    if [ -z "${AXONFLOW_AUTH:-}" ] || [ -n "${AXONFLOW_ENDPOINT:-}" ]; then
      if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        echo "[AxonFlow] Governance blocked: install jq and curl before using Hosted." >&2
        exit 2
      fi
    fi
    ;;
esac

# Preserve the existing self-hosted fail behavior when dependencies are absent.
if ! command -v jq &>/dev/null; then
  exit 0
fi
if ! command -v curl &>/dev/null; then
  exit 0
fi

# Endpoint resolution per ADR-048: default to AxonFlow Community SaaS only when
# the user has not set explicit config. Equivalent Hosted URL spellings are
# canonicalized above; self-hosted configuration is honored untouched.
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
case "$ENDPOINT" in
  https://try.getaxonflow.com|https://try-staging.getaxonflow.com) AXONFLOW_MODE="community-saas" ;;
esac
AUTH="${AXONFLOW_AUTH:-}"
REQUEST_TIMEOUT_SECONDS="${AXONFLOW_TIMEOUT_SECONDS:-8}"
export AXONFLOW_MODE

# Mode-clarity canary on stderr (NEVER stdout — stdout is the hook protocol).
# CI's mode-clarity gate parses this line and asserts it matches the actual
# outbound destination. Users can never be misled about which AxonFlow they're
# talking to.
echo "[AxonFlow] Connected to AxonFlow at ${ENDPOINT} (mode=${AXONFLOW_MODE})" >&2

# Load an existing protected Hosted credential. Fresh installations must
# complete Portal verification and explicit device linking first.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/community-saas-bootstrap.sh"
AUTH="${AXONFLOW_AUTH:-}"
if [ "$AXONFLOW_MODE" = "community-saas" ] && [ -z "$AUTH" ]; then
  echo "[AxonFlow] Governance blocked: open https://portal.try.getaxonflow.com/hosted/start, run scripts/hosted-link.mjs, approve the code, then restart Codex." >&2
  exit 2
fi

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

# Block the tool call with the reason on stderr and stop (exit 2 is the
# hook's block).
axonflow_pre_deny() {
  echo "$1" >&2
  exit 2
}

# Build auth header array safely (avoids word-splitting)
AUTH_HEADER=()
if [ -n "$AUTH" ]; then
  AUTH_HEADER=(-H "Authorization: Basic $AUTH")
fi
AUTH_HEADER+=(-H "X-Axonflow-Client: ${AXONFLOW_CLIENT_HEADER}")
# ADR-065 capability handshake (axonflow-enterprise#3763). Declares what this
# enforcement point can discharge, so the platform refuses to hand it a
# mandatory obligation it has said it cannot carry out.
#
# Added ONLY when non-empty. A header that is PRESENT with an empty value is
# MALFORMED to the platform and refuses the request, which an ABSENT header
# does not - so an unconditional -H here would 400 every unconfigured install.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/pep-handshake.sh"
if [ -n "${AXONFLOW_PEP_HANDSHAKE:-}" ]; then
  AUTH_HEADER+=(-H "X-Axonflow-PEP-Handshake: ${AXONFLOW_PEP_HANDSHAKE}")
fi

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
# envelope's resets_at deadline. While a hosted Free-tier limit holds, the
# tool call is BLOCKED with the limit named (the upgrade prompt was surfaced
# when the throttle landed): over the cap is deny, not governance off (ruled
# 2026-09-14; reversible here). An auth-failure cooldown also blocks locally:
# a revoked device credential must never turn governance off for five minutes.
if axonflow_throttle_active; then
  if [ "$(axonflow_throttle_reason)" = "auth_failure" ]; then
    HINT_SUFFIX=""
    if [ -n "${AXONFLOW_USER_TOKEN:-}" ]; then HINT_SUFFIX=" ${USER_TOKEN_HINT}"; fi
    axonflow_pre_deny "AxonFlow governance blocked: the AxonFlow agent rejected authentication (HTTP 401) and an auth-failure cooldown is active.${HINT_SUFFIX}"
  fi
  axonflow_pre_deny "$AXONFLOW_LIMIT_DENY_REASON"
fi

# Call AxonFlow check_policy via MCP server.
#
# Self-hosted retains issue #1545's transport fail-open behavior. Hosted
# requires an observed Agent decision before allowing a governed tool call.
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

# A failed transfer cannot authorize a Hosted tool call.
if [ "$CURL_EXIT" -ne 0 ]; then
  if [ "$AXONFLOW_MODE" = "community-saas" ]; then
    axonflow_pre_deny "AxonFlow governance blocked: the Hosted Agent could not be reached, so this tool call is blocked."
  fi
  exit 0
fi

# V1 Plugin Pro: detect the structured envelope on 429 / 403 responses.
# The helper stamps throttle-until + emits the upgrade prompt to stderr, and
# the tool call is BLOCKED: over a hosted Free-tier limit is deny with the
# visible upgrade prompt, not governance off (ruled 2026-09-14; reversible here).
if axonflow_handle_envelope_response "$HTTP_CODE" "$PRECHECK_BODY" "$PRECHECK_HEADERS"; then
  axonflow_pre_deny "$AXONFLOW_LIMIT_DENY_REASON"
fi

# Stamp a 5-minute cooldown on HTTP 401 to prevent retry storms, then block
# this call. The cooldown branch above blocks subsequent calls locally.
if axonflow_handle_auth_failure "$HTTP_CODE" "$PRECHECK_BODY" "$PRECHECK_HEADERS"; then
  HINT_SUFFIX=""
  if [ -n "${AXONFLOW_USER_TOKEN:-}" ]; then
    HINT_SUFFIX=" ${USER_TOKEN_HINT}"
  fi
  axonflow_pre_deny "AxonFlow governance blocked: the AxonFlow agent at ${ENDPOINT} rejected authentication (HTTP 401), so this tool call is blocked.${HINT_SUFFIX}"
fi

# Payment, quota, and other refusal statuses without a recognized envelope
# still refuse the call. A Hosted server fault also cannot authorize it.
if [ "$HTTP_CODE" != "200" ]; then
  case "$HTTP_CODE" in
    5??) if [ "$AXONFLOW_MODE" != "community-saas" ]; then exit 0; fi ;;
  esac
  axonflow_pre_deny "AxonFlow governance blocked: the AxonFlow agent refused the policy check (HTTP ${HTTP_CODE:-unknown}), so this tool call is blocked."
fi

RESPONSE=$(cat "$PRECHECK_BODY")

# An empty or malformed Hosted response contains no policy decision.
if [ -z "$RESPONSE" ]; then
  if [ "$AXONFLOW_MODE" = "community-saas" ]; then
    axonflow_pre_deny "AxonFlow governance blocked: the Hosted Agent returned no policy decision, so this tool call is blocked."
  fi
  exit 0
fi
if [ "$AXONFLOW_MODE" = "community-saas" ] && ! echo "$RESPONSE" | jq -e 'type == "object"' >/dev/null 2>&1; then
  axonflow_pre_deny "AxonFlow governance blocked: the Hosted Agent returned an invalid policy response, so this tool call is blocked."
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
#   Everything else:            BLOCK — unknown code, fail closed (2026-09-14)
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
    -32603|-32700)
      if [ "$AXONFLOW_MODE" = "community-saas" ]; then
        axonflow_pre_deny "AxonFlow governance blocked: the Hosted Agent returned an error (${JSONRPC_ERROR}, code ${JSONRPC_CODE}), so this tool call is blocked."
      fi
      # Self-hosted preserves its historical fail-open behavior.
      exit 0
      ;;
    *)
      # An unknown code is not a decision: fail closed (ruled 2026-09-14).
      axonflow_pre_deny "AxonFlow governance blocked: the AxonFlow agent answered an unexpected error (${JSONRPC_ERROR}, code ${JSONRPC_CODE}), so this tool call is blocked."
      ;;
  esac
fi

# Hosted accepts only the JSON-RPC reply to this check_policy request. A
# detached result-shaped body must not turn a missing decision into allow.
if [ "$AXONFLOW_MODE" = "community-saas" ] && ! echo "$RESPONSE" | jq -e \
  '.jsonrpc == "2.0" and .id == "hook-pre" and (.result | type) == "object" and (.result.content | type) == "array" and .result.content[0].type == "text"' >/dev/null 2>&1; then
  axonflow_pre_deny "AxonFlow governance blocked: the Hosted Agent returned an invalid policy response, so this tool call is blocked."
fi

# Parse the MCP response to get the tool result
TOOL_RESULT=$(echo "$RESPONSE" | jq -r '.result.content[0].text // empty' 2>/dev/null || echo "")
if [ -z "$TOOL_RESULT" ]; then
  # A JSON-RPC result with no tool result carries no decision: fail closed.
  # A Hosted response without a result is not an authorization.
  if echo "$RESPONSE" | jq -e 'has("result")' >/dev/null 2>&1; then
    axonflow_pre_deny "AxonFlow governance blocked: the AxonFlow agent returned a policy result without a decision, so this tool call is blocked."
  fi
  if [ "$AXONFLOW_MODE" = "community-saas" ]; then
    axonflow_pre_deny "AxonFlow governance blocked: the Hosted Agent returned no policy decision, so this tool call is blocked."
  fi
  exit 0
fi

# A result flagged isError, or one without a boolean `allowed`, is not a
# decision: fail closed (ruled 2026-09-14). The Community SaaS Free-tier cap
# answers exactly this way, with its upgrade envelope as the result text;
# the envelope goes through the handler so the prompt and throttle still apply.
RESULT_IS_ERROR=$(echo "$RESPONSE" | jq -r 'if .result.isError == true then "true" else "false" end' 2>/dev/null || echo "false")
HAS_DECISION=$(echo "$TOOL_RESULT" | jq -r 'if (.allowed | type) == "boolean" then "true" else "false" end' 2>/dev/null || echo "false")
if [ "$RESULT_IS_ERROR" = "true" ] || [ "$HAS_DECISION" != "true" ]; then
  if axonflow_handle_envelope_text "$TOOL_RESULT"; then
    axonflow_pre_deny "$AXONFLOW_LIMIT_DENY_REASON"
  fi
  RESULT_ERROR=$(echo "$TOOL_RESULT" | jq -r '.error // empty' 2>/dev/null || echo "")
  axonflow_pre_deny "AxonFlow governance blocked: ${RESULT_ERROR:-the AxonFlow agent returned a policy result without a decision}, so this tool call is blocked."
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
            tool_type: "codex",
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
