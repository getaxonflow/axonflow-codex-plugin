#!/usr/bin/env bash
# Unit test for scripts/pep-handshake.sh — the ADR-065 capability handshake
# (getaxonflow/axonflow-enterprise#3763).
#
# THE GOLDEN VECTOR IS THE POINT. This repository is public and the wire
# contract lives in a private one, so pep-handshake.sh is a HAND TRANSCRIPTION
# of a wire format - the drift class that bit five SDKs in
# axonflow-enterprise#3603. The expected string below was captured from the
# PLATFORM's own shipped encoder (contract.PEPHandshake.Encode), not
# regenerated from this script's output, so the two implementations are
# compared with each other rather than one with itself.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="${PLUGIN_DIR}/scripts/pep-handshake.sh"
HELPER_PATH="${PLUGIN_DIR}/scripts/install-mcp-with-headers.sh"

GOLDEN="eyJwcm9maWxlX3ZlcnNpb24iOjEsInBlcF9pZCI6ImNvZGV4LXBsdWdpbiIsImF1ZGllbmNlIjoiYXhvbmZsb3ctZGVjaXNpb24tcHJvb2YiLCJjYXBhYmlsaXRpZXMiOltdfQ"

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

# --- the encoding matches the platform's own encoder, byte for byte ---------
ACTUAL=$(
  unset AXONFLOW_PEP_HANDSHAKE
  export AXONFLOW_PEP_AUDIENCE="axonflow-decision-proof"
  . "$SCRIPT_PATH"
  echo "${AXONFLOW_PEP_HANDSHAKE:-}"
)
if [ "$ACTUAL" = "$GOLDEN" ]; then
  pass "the encoding matches the platform's own encoder byte for byte"
else
  fail "encoding disagrees with the platform encoder; a mismatch here is a plugin the platform will refuse in the field. got '$ACTUAL' want '$GOLDEN'"
fi

# --- the decoded document declares [] and carries no identity claim ---------
if command -v python3 >/dev/null 2>&1; then
  DOC=$(printf '%s' "$ACTUAL" | python3 -c 'import sys,base64;s=sys.stdin.read().strip();print(base64.urlsafe_b64decode(s+"="*(-len(s)%4)).decode())')
  # An OMITTED capabilities member is MALFORMED to the platform and refuses the
  # request; [] is the declaration "I discharge nothing". Different facts.
  if [[ "$DOC" == *'"capabilities":[]'* ]]; then
    pass "an empty declaration serialises as [], never as an absent member"
  else
    fail "capabilities is not an empty array: $DOC"
  fi
  # A PEP may declare what it CAN DO, never who it is or what it is entitled to.
  if [[ "$DOC" != *'"edition"'* && "$DOC" != *'"tier"'* && "$DOC" != *'"license"'* && "$DOC" != *'"realm"'* ]]; then
    pass "no identity or entitlement member reaches the wire"
  else
    fail "the document carries an identity or entitlement member: $DOC"
  fi
else
  echo "  SKIP: python3 not on PATH (decoded-shape assertions)"
fi

# --- unset audience presents nothing at all --------------------------------
ACTUAL_UNSET=$(
  unset AXONFLOW_PEP_HANDSHAKE AXONFLOW_PEP_AUDIENCE
  . "$SCRIPT_PATH"
  echo "${AXONFLOW_PEP_HANDSHAKE:-}"
)
if [ -z "$ACTUAL_UNSET" ]; then
  pass "an unconfigured install builds no handshake at all"
else
  fail "expected empty, got '$ACTUAL_UNSET'"
fi

# --- a malformed audience refuses to build, loudly -------------------------
for BAD in "has spaces" "-leading-hyphen" "$(printf 'a%.0s' {1..129})"; do
  OUT=$(
    unset AXONFLOW_PEP_HANDSHAKE
    export AXONFLOW_PEP_AUDIENCE="$BAD"
    . "$SCRIPT_PATH" 2>/dev/null
    echo "${AXONFLOW_PEP_HANDSHAKE:-}"
  )
  if [ -z "$OUT" ]; then
    pass "a malformed audience builds no handshake ('${BAD:0:20}')"
  else
    fail "malformed audience '${BAD:0:20}' produced '$OUT'; the platform would 400 every governed call"
  fi
done

# --- the installer writes the header only when configured ------------------
# Codex omits an env_http_headers header whose variable is unset. The static
# equivalent here is that the KEY IS NOT WRITTEN AT ALL when no audience is
# configured, which is what keeps an unconfigured install byte-identical. A
# key written with an empty value would be PRESENT-but-empty, which is
# MALFORMED to the platform and refuses every governed call.
INSTALLER="${PLUGIN_DIR}/scripts/install-mcp-with-headers.sh"
if grep -q 'pep_line = f' "$INSTALLER" && grep -q 'if pep_handshake else ""' "$INSTALLER"; then
  pass "the installer writes the handshake key only when a declaration exists"
else
  fail "the installer no longer guards the handshake key on a non-empty declaration"
fi
if grep -q 'X-Axonflow-PEP-Handshake' "$INSTALLER"; then
  pass "the installer knows the handshake header name"
else
  fail "the installer does not mention the handshake header"
fi

# --- the per-call hooks append the header only when non-empty --------------
for HOOK in pre-tool-check post-tool-audit; do
  if grep -q 'if \[ -n "${AXONFLOW_PEP_HANDSHAKE:-}" \]; then' "${PLUGIN_DIR}/scripts/${HOOK}.sh"; then
    pass "${HOOK}.sh appends the handshake header only when non-empty"
  else
    fail "${HOOK}.sh appends the handshake header unconditionally; an unconfigured install would 400 every governed call"
  fi
done

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
