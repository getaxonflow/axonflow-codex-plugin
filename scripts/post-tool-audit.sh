#!/usr/bin/env bash
# PostToolUse hook — audit logging and output scanning.
# Adapted for OpenAI Codex from the Claude Code plugin.
#
# 1. Records tool execution in AxonFlow audit trail (fire-and-forget, background)
# 2. Scans tool output for PII/secrets (synchronous — returns context to Codex)
#
# Codex PostToolUse always exits 0 — it never blocks; the tool already ran.
# When the output could not be checked it says so, one of two ways:
#   - an answer that refused the check (a 401 or its cooldown, a 429 or a
#     Free-tier limit, another 4xx without a decision body, a result without
#     a decision) -> a GOVERNANCE ALERT telling the model not to use the output;
#   - no usable answer (unreachable, timeout, 5xx, JSON-RPC -32603 / -32700, an
#     empty or unreadable body, jq or curl missing) -> AXONFLOW_FAIL_MODE
#     decides: "open" (the default) passes the output with a notice on stderr;
#     anything else raises the same GOVERNANCE ALERT.

# Emit a PostToolUse governance alert and stop. Without jq the JSON is written
# by hand; the message is this script's own text, and double quotes and
# backslashes are dropped from it so the document stays valid.
axonflow_post_alert() {
  if command -v jq &>/dev/null; then
    jq -n --arg m "$1" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$(printf '%s' "$1" | tr -d '"\\')"
  fi
  exit 0
}

# The output could not be checked because no usable answer arrived.
# AXONFLOW_FAIL_MODE decides: "open" (the default, case-insensitive) passes the
# output and says so on stderr; any other value tells the model not to use it.
axonflow_post_ungoverned() {
  local mode
  mode=$(printf '%s' "${AXONFLOW_FAIL_MODE:-open}" | tr '[:upper:]' '[:lower:]')
  if [ "$mode" != "open" ]; then
    axonflow_post_alert "GOVERNANCE ALERT: AxonFlow could not check this tool output ($1, and AXONFLOW_FAIL_MODE is not open). Do not use or reference the output in your response until it can be checked."
  fi
  echo "[AxonFlow] GOVERNANCE UNAVAILABLE: $1. This tool output was NOT checked. Set AXONFLOW_FAIL_MODE=closed to withhold unchecked output from the model." >&2
  exit 0
}

# The hook cannot read the tool call or reach AxonFlow without these.
if ! command -v jq &>/dev/null; then
  axonflow_post_ungoverned "the AxonFlow hook needs jq, which is not installed"
fi
if ! command -v curl &>/dev/null; then
  axonflow_post_ungoverned "the AxonFlow hook needs curl, which is not installed"
fi

# Endpoint resolution per ADR-048: default to AxonFlow Community SaaS only when
# the user has not set explicit config. Mirrors pre-tool-check.sh exactly so the
# two hooks always agree on which AxonFlow they're talking to.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${AXONFLOW_ENDPOINT:-}" ] && [ -z "${AXONFLOW_AUTH:-}" ]; then
  ENDPOINT="https://try.getaxonflow.com"
  AXONFLOW_MODE="community-saas"
else
  ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
  AXONFLOW_MODE="self-hosted"
fi
export AXONFLOW_MODE
REQUEST_TIMEOUT_SECONDS="${AXONFLOW_TIMEOUT_SECONDS:-5}"

# Bootstrap the Community-SaaS credential if needed. No-op in self-hosted mode.
# Pre-tool-check ran first and likely already wrote the registration file; this
# is just loading it. Mode-clarity log line is intentionally NOT repeated here —
# pre-tool-check fires it once per hook invocation.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/community-saas-bootstrap.sh"
AUTH="${AXONFLOW_AUTH:-}"

# ADR-050 §4: X-Axonflow-Client identifies the calling plugin so the agent
# can derive request scope (plugin) and validate against the token's aud.scope.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/client-header.sh"

# V1 Plugin Pro upgrade-prompt envelope handling (umbrella
# axonflow-enterprise#1958).
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/upgrade-prompt.sh"

AUTH_ALERT="GOVERNANCE ALERT: AxonFlow could not check this tool output (the AxonFlow agent rejected authentication, HTTP 401). Do not use or reference the output in your response until the credential is fixed and it can be checked."

# A recent governed call stamped the throttle-until file, and the hook answers
# locally until the deadline passes. The output cannot be checked while either
# stamp holds, so the model is told not to use it: a hosted Free-tier limit
# (ruled 2026-09-14) or the 401 cooldown (auth_failure).
if axonflow_throttle_active; then
  if [ "$(axonflow_throttle_reason)" = "auth_failure" ]; then
    axonflow_post_alert "$AUTH_ALERT"
  fi
  axonflow_post_alert "$AXONFLOW_LIMIT_POST_ALERT"
fi

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

# V1 paid Pro tier (PR #1850): forward X-License-Token on the audit + scan
# requests too — the agent's PluginClaimMiddleware applies to /api/v1/mcp-server
# regardless of which MCP method is being invoked, so audit_tool_call and
# check_output also need the header to land in the Pro-tier code path
# (longer audit retention, larger payload caps, …).
# shellcheck source=./lib/license-token.sh
. "${SCRIPT_DIR}/lib/license-token.sh"
axonflow_resolve_license_token
if [ -n "${AXONFLOW_LICENSE_TOKEN_RESOLVED:-}" ]; then
  AUTH_HEADER+=(-H "X-License-Token: ${AXONFLOW_LICENSE_TOKEN_RESOLVED}")
fi

# Per-user authorization token (axonflow-enterprise#2944, epic #2919) —
# mirror pre-tool-check.sh so the audit_tool_call POST AND the check_output
# scan below (both reuse AUTH_HEADER) carry X-User-Token and the platform
# resolves a VALIDATED {identity, role} for this developer. Omitted entirely
# when unconfigured (no empty header); the token value is never logged.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/user-token.sh"
resolve_user_token
if [ -n "${AXONFLOW_USER_TOKEN:-}" ]; then
  AUTH_HEADER+=(-H "X-User-Token: ${AXONFLOW_USER_TOKEN}")
fi

# Read hook input from stdin
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null || echo "{}")
TOOL_RESPONSE=$(echo "$INPUT" | jq -c '.tool_response // {}' 2>/dev/null || echo "{}")

# Skip if no tool name
if [ -z "$TOOL_NAME" ]; then
  exit 0
fi

CONNECTOR_TYPE="codex.${TOOL_NAME}"

# Determine success from tool response
SUCCESS=$(echo "$TOOL_RESPONSE" | jq 'if .exitCode != null then (.exitCode == 0) elif .success != null then .success else true end' 2>/dev/null || echo "true")
ERROR_MSG=$(echo "$TOOL_RESPONSE" | jq -r '.stderr // empty' 2>/dev/null || echo "")

# Truncate large outputs for audit (character-safe, not byte-safe)
TRUNCATED_OUTPUT=$(echo "$TOOL_RESPONSE" | jq -c '.' 2>/dev/null | cut -c1-500 || echo "{}")

# 1. Record audit entry (fire-and-forget, background)
(
  curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" -X POST "${ENDPOINT}/api/v1/mcp-server" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "${AUTH_HEADER[@]}" \
    -d "$(jq -n \
      --arg tn "$TOOL_NAME" \
      --arg ti "$TOOL_INPUT" \
      --arg out "$TRUNCATED_OUTPUT" \
      --argjson success "$SUCCESS" \
      --arg err "$ERROR_MSG" \
      '{
        jsonrpc: "2.0",
        id: "hook-audit",
        method: "tools/call",
        params: {
          name: "audit_tool_call",
          arguments: {
            tool_name: $tn,
            caller_name: "codex",
            tool_type: "codex",
            input: ($ti | fromjson? // {}),
            output: {summary: $out},
            success: $success,
            error_message: $err
          }
        }
      }')" > /dev/null 2>&1
) &

# 2. Scan tool output for PII/secrets (synchronous — returns context if PII found)
OUTPUT_TEXT=""
case "$TOOL_NAME" in
  Bash|exec_command|shell)
    OUTPUT_TEXT=$(echo "$TOOL_RESPONSE" | jq -r '.stdout // .output // empty' 2>/dev/null || echo "")
    # If stdout is empty but command contains a redirect (echo ... > file),
    # scan the command itself — the PII is in the input, not the output.
    if [ -z "$OUTPUT_TEXT" ] || [ "$OUTPUT_TEXT" = "null" ]; then
      COMMAND=$(echo "$TOOL_INPUT" | jq -r '.cmd // .command // empty' 2>/dev/null || echo "")
      if echo "$COMMAND" | grep -qE '>>?\s*\S' ; then
        OUTPUT_TEXT="$COMMAND"
      fi
    fi
    ;;
  Write)
    OUTPUT_TEXT=$(echo "$TOOL_INPUT" | jq -r '.content // empty' 2>/dev/null || echo "")
    ;;
  Edit)
    OUTPUT_TEXT=$(echo "$TOOL_INPUT" | jq -r '.new_string // empty' 2>/dev/null || echo "")
    ;;
  NotebookEdit)
    OUTPUT_TEXT=$(echo "$TOOL_INPUT" | jq -r '.cell_content // .content // empty' 2>/dev/null || echo "")
    ;;
  mcp__*)
    OUTPUT_TEXT=$(echo "$TOOL_RESPONSE" | jq -c '.' 2>/dev/null || echo "")
    ;;
esac

if [ -n "$OUTPUT_TEXT" ] && [ "$OUTPUT_TEXT" != "null" ]; then
  SCAN_BODY=$(mktemp)
  SCAN_HEADERS=$(mktemp)
  trap 'rm -f "$SCAN_BODY" "$SCAN_HEADERS"' EXIT
  SCAN_HTTP=$(curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" \
    -D "$SCAN_HEADERS" -o "$SCAN_BODY" -w '%{http_code}' \
    -X POST "${ENDPOINT}/api/v1/mcp-server" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "${AUTH_HEADER[@]}" \
    -d "$(jq -n \
      --arg ct "$CONNECTOR_TYPE" \
      --arg msg "$OUTPUT_TEXT" \
      '{
        jsonrpc: "2.0",
        id: "hook-scan",
        method: "tools/call",
        params: {
          name: "check_output",
          arguments: {
            connector_type: $ct,
            message: $msg
          }
        }
      }')" 2>/dev/null)
  SCAN_CURL_EXIT=$?

  # No answer arrived: timeout, DNS failure, connection refused, TCP reset.
  if [ "$SCAN_CURL_EXIT" -ne 0 ]; then
    axonflow_post_ungoverned "the AxonFlow agent at ${ENDPOINT} could not be reached (curl exit ${SCAN_CURL_EXIT})"
  fi

  # V1 Plugin Pro: stamp throttle + show the upgrade prompt on envelope
  # responses, and tell the model the output could not be checked.
  if axonflow_handle_envelope_response "$SCAN_HTTP" "$SCAN_BODY" "$SCAN_HEADERS"; then
    axonflow_post_alert "$AXONFLOW_LIMIT_POST_ALERT"
  fi
  # axonflow-enterprise#2275: a 401 stamps a 5-minute cooldown (the helper) so a
  # tight retry loop can't keep firing the same auth-failing scan request, and
  # the model is told not to use the unchecked output.
  if axonflow_handle_auth_failure "$SCAN_HTTP" "$SCAN_BODY" "$SCAN_HEADERS"; then
    axonflow_post_alert "$AUTH_ALERT"
  fi
  SCAN_RESPONSE=$(cat "$SCAN_BODY" 2>/dev/null || echo "")

  # The status of an answer the lines above did not settle, judged the way
  # pre-tool-check.sh judges it: a JSON-RPC answer (a result or an error) is the
  # platform's answer whatever the status; only a body without one is judged by
  # its status.
  SCAN_TEXT=$(printf '%s' "$SCAN_RESPONSE" | jq -r 'if type == "object" then (.error.message? // (.error | strings?) // .message? // empty) else empty end' 2>/dev/null | tr '\n' ' ' | sed -e 's/[[:space:]]*$//' | cut -c1-300)
  SCAN_IS_JSONRPC=$(printf '%s' "$SCAN_RESPONSE" | jq -r 'if type == "object" and has("jsonrpc") and (has("result") or has("error")) then "true" else "false" end' 2>/dev/null || echo "false")
  if [ "$SCAN_HTTP" = "429" ]; then
    axonflow_post_alert "GOVERNANCE ALERT: AxonFlow could not check this tool output (the AxonFlow agent answered HTTP 429, a request limit${SCAN_TEXT:+: $SCAN_TEXT}). Do not use or reference the output in your response until it can be checked."
  fi
  case "$SCAN_HTTP" in
    2??) ;;
    *)
      if [ "$SCAN_IS_JSONRPC" != "true" ]; then
        case "$SCAN_HTTP" in
          4??)
            axonflow_post_alert "GOVERNANCE ALERT: AxonFlow could not check this tool output (the AxonFlow agent refused the request, HTTP ${SCAN_HTTP}${SCAN_TEXT:+: $SCAN_TEXT}). Do not use or reference the output in your response until it can be checked."
            ;;
          *)
            axonflow_post_ungoverned "the AxonFlow agent answered HTTP ${SCAN_HTTP}${SCAN_TEXT:+ ($SCAN_TEXT)}"
            ;;
        esac
      fi
      ;;
  esac

  if [ -z "$SCAN_RESPONSE" ]; then
    axonflow_post_ungoverned "the AxonFlow agent answered HTTP ${SCAN_HTTP} with an empty body"
  fi

  # A JSON-RPC error is not a check. Server-internal and parse errors are no
  # usable answer; every other code (auth, method, params, unknown) refused it.
  SCAN_RPC_ERROR=$(echo "$SCAN_RESPONSE" | jq -r '.error.message // empty' 2>/dev/null || echo "")
  if [ -n "$SCAN_RPC_ERROR" ]; then
    SCAN_RPC_CODE=$(echo "$SCAN_RESPONSE" | jq -r '.error.code // 0' 2>/dev/null || echo "0")
    case "$SCAN_RPC_CODE" in
      -32603|-32700)
        axonflow_post_ungoverned "the AxonFlow agent answered a server error (${SCAN_RPC_ERROR}, code ${SCAN_RPC_CODE})"
        ;;
      *)
        axonflow_post_alert "GOVERNANCE ALERT: AxonFlow could not check this tool output (${SCAN_RPC_ERROR}, code ${SCAN_RPC_CODE}). Do not use or reference the output in your response until it can be checked."
        ;;
    esac
  fi

  SCAN_RESULT=$(echo "$SCAN_RESPONSE" | jq -r '.result.content[0].text // empty' 2>/dev/null || echo "")
  if [ -z "$SCAN_RESULT" ]; then
    # A JSON-RPC result with no tool result carries no decision.
    if echo "$SCAN_RESPONSE" | jq -e 'has("result")' >/dev/null 2>&1; then
      axonflow_post_alert "GOVERNANCE ALERT: AxonFlow could not check this tool output (the AxonFlow agent returned no decision). Do not use or reference the output in your response until it can be checked."
    fi
    axonflow_post_ungoverned "the AxonFlow agent's answer (HTTP ${SCAN_HTTP}) was not a check result"
  fi

  # A result flagged isError, or one without a boolean `allowed`, is not a
  # decision (ruled 2026-09-14). The Free-tier cap answers this way with its
  # upgrade envelope as the text: the handler still shows the prompt.
  SCAN_IS_ERROR=$(echo "$SCAN_RESPONSE" | jq -r 'if .result.isError == true then "true" else "false" end' 2>/dev/null || echo "false")
  SCAN_HAS_DECISION=$(echo "$SCAN_RESULT" | jq -r 'if (.allowed | type) == "boolean" then "true" else "false" end' 2>/dev/null || echo "false")
  if [ "$SCAN_IS_ERROR" = "true" ] || [ "$SCAN_HAS_DECISION" != "true" ]; then
    if axonflow_handle_envelope_text "$SCAN_RESULT"; then
      axonflow_post_alert "$AXONFLOW_LIMIT_POST_ALERT"
    fi
    SCAN_ERROR=$(echo "$SCAN_RESULT" | jq -r '.error // empty' 2>/dev/null || echo "")
    axonflow_post_alert "GOVERNANCE ALERT: AxonFlow could not check this tool output (${SCAN_ERROR:-the AxonFlow agent returned no decision}). Do not use or reference the output in your response until it can be checked."
  fi
  REDACTED=$(echo "$SCAN_RESULT" | jq -r '.redacted_message // empty' 2>/dev/null || echo "")
  POLICIES_FOUND=$(echo "$SCAN_RESULT" | jq -r '.policies_evaluated // 0' 2>/dev/null || echo "0")
  ALLOWED=$(echo "$SCAN_RESULT" | jq -r 'if .allowed == false then "false" else "true" end' 2>/dev/null || echo "true")

  if [ -n "$REDACTED" ] && [ "$REDACTED" != "null" ]; then
    jq -n \
      --arg redacted "$REDACTED" \
      --arg policies "$POLICIES_FOUND" \
      '{
        hookSpecificOutput: {
          hookEventName: "PostToolUse",
          additionalContext: ("GOVERNANCE ALERT: PII/sensitive data detected in tool output (" + $policies + " policies evaluated). You MUST use this redacted version instead of the original: " + $redacted)
        }
      }'
    exit 0
  elif [ "$ALLOWED" = "false" ]; then
    BLOCK_REASON=$(echo "$SCAN_RESULT" | jq -r '.block_reason // "Policy violation in tool output"' 2>/dev/null || echo "")
    jq -n \
      --arg reason "$BLOCK_REASON" \
      '{
        hookSpecificOutput: {
          hookEventName: "PostToolUse",
          additionalContext: ("GOVERNANCE ALERT: Tool output blocked by policy: " + $reason + ". Do not use or reference the blocked output in your response.")
        }
      }'
    exit 0
  fi
fi

# No issues — exit silently
exit 0
