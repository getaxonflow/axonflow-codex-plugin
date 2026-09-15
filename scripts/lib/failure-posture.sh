#!/usr/bin/env bash
# The failure posture both hooks read (scripts/pre-tool-check.sh and
# scripts/post-tool-audit.sh), kept in one place so the two cannot drift.
# Sourced, never executed. Each hook maps a class to its own action: the pre
# hook blocks or runs ungoverned, the post hook alerts or passes with a notice.
#
# HTTP 401 and the Free-tier envelope are settled before this table (the
# helpers in scripts/upgrade-prompt.sh). axonflow_status_class then reads the
# status of the answer that is left:
#
#   answer     2xx, or a non-2xx whose body is a JSON-RPC answer (a non-null
#              result, or an error object): read as the platform's answer
#   limit      429, whatever the body
#   refused    3xx (a redirect: the endpoint is misconfigured) and a 4xx other
#              than 408, 413 and 429, without a JSON-RPC answer
#   too_large  413 without a JSON-RPC answer (the request was bigger than the
#              agent or a proxy accepts): refused, with the size named
#   no_answer  408, 5xx and any other status without a JSON-RPC answer
#
# Within a JSON-RPC error, the code decides (axonflow_jsonrpc_error_code):
# -32603 (internal) and -32700 (parse) are no usable answer; every other code,
# and an error object without a numeric code, refused the call.

# axonflow_fail_mode_open
#   Returns 0 when AXONFLOW_FAIL_MODE is unset, empty or "open" (any case):
#   a check that got no usable answer lets the call run with a notice. Any
#   other value blocks it.
axonflow_fail_mode_open() {
  local mode
  mode=$(printf '%s' "${AXONFLOW_FAIL_MODE:-}" | tr '[:upper:]' '[:lower:]')
  [ -z "$mode" ] || [ "$mode" = "open" ]
}

# axonflow_clean_text <text>
#   Text that came from the network, made safe to print and to hand to the
#   model: line breaks and tabs become spaces, every other control character
#   (ESC, BEL, CR ...) is dropped, and it is trimmed and capped at 300
#   characters. Bytes of multi-byte UTF-8 characters are kept.
axonflow_clean_text() {
  printf '%s' "$1" | LC_ALL=C tr '\n\t' '  ' | LC_ALL=C tr -d '\000-\037\177' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | cut -c1-300
}

# axonflow_platform_text <body>
#   The platform's own words for a refusal (a JSON-RPC error message, a coded
#   error envelope's message, or a plain {"error": "..."}), cleaned. Empty when
#   the body carries none or is not JSON.
axonflow_platform_text() {
  local raw
  raw=$(printf '%s' "$1" | jq -r 'if type == "object" then (.error.message? // (.error | strings?) // .message? // empty) else empty end' 2>/dev/null)
  axonflow_clean_text "$raw"
}

# axonflow_is_jsonrpc_answer <body>
#   Prints "true" when the body is a JSON-RPC answer: an object carrying
#   "jsonrpc" and either a non-null result or an error object. A null result
#   or error, or an error that is not an object, is not an answer.
axonflow_is_jsonrpc_answer() {
  local out
  out=$(printf '%s' "$1" | jq -r 'if type == "object" and has("jsonrpc") and ((.result != null) or ((.error | type) == "object")) then "true" else "false" end' 2>/dev/null)
  if [ "$out" = "true" ]; then echo true; else echo false; fi
}

# axonflow_jsonrpc_error_code <body>
#   The code of the body's JSON-RPC error object, "none" when that object has
#   no numeric code, and empty when the body has no error object.
axonflow_jsonrpc_error_code() {
  printf '%s' "$1" | jq -r 'if type == "object" and ((.error | type) == "object") then (if (.error.code | type) == "number" then (.error.code | tostring) else "none" end) else empty end' 2>/dev/null | head -1
}

# axonflow_status_class <http_code> <is_jsonrpc_answer>
#   Prints the row of the table above.
axonflow_status_class() {
  local code="$1" jsonrpc="$2"
  case "$code" in
    429) echo limit; return ;;
    2??) echo answer; return ;;
  esac
  if [ "$jsonrpc" = "true" ]; then
    echo answer
    return
  fi
  case "$code" in
    3??) echo refused ;;
    408) echo no_answer ;;
    413) echo too_large ;;
    4??) echo refused ;;
    *) echo no_answer ;;
  esac
}
