#!/usr/bin/env bash
# Shared helper: resolve the AxonFlow Pro-tier license token (V1 paid tier).
#
# Resolution order:
#   1. AXONFLOW_LICENSE_TOKEN environment variable (operator override; CI use).
#   2. license_token = "..." key from ~/.codex/axonflow.toml (canonical
#      surface per the V1 launch email — same ~/.codex/ root the rest of
#      the Codex plugin uses for config.toml + hooks.json).
#
# Sets AXONFLOW_LICENSE_TOKEN_RESOLVED on success; leaves it empty on miss.
# Never errors out — a missing token just means free tier.
#
# Sourced by pre-tool-check.sh, post-tool-audit.sh, mcp-auth-headers.sh,
# status.sh, and the recovery script. Pure shell, no jq required for the
# happy path (TOML parsing is a single regex on one well-formed line).
#
# Token shape contract (enforced by the agent middleware in PR #1850):
#   Tokens issued by axonflow-billing start with the literal prefix "AXON-".
#   We don't validate further here — the agent does the cryptographic check.
#   We DO refuse to forward an obviously-malformed value so the agent never
#   sees garbage on the X-License-Token header.

# Path to the canonical config file. Override AXONFLOW_CODEX_CONFIG for tests.
_axonflow_codex_config_path() {
  printf '%s' "${AXONFLOW_CODEX_CONFIG:-$HOME/.codex/axonflow.toml}"
}

# Read a single string-valued top-level TOML key from the config file.
# Usage: _axonflow_toml_get_string <key>
# Echoes the value (without surrounding quotes) on stdout, empty on miss.
#
# Format accepted: key = "value"   or   key = 'value'   (single line, top-level).
# Whitespace around = is tolerated. # comment lines are ignored. The value
# itself MUST NOT contain unescaped quotes — the recovery writer enforces
# this at write time so reading is safe.
_axonflow_toml_get_string() {
  local key="$1"
  local file
  file=$(_axonflow_codex_config_path)
  [ -f "$file" ] || return 0
  # Match: ^<key> = "value" or ^<key> = 'value', allowing optional leading ws
  # for tolerance with hand-edited files. Strip comments after the value.
  # Portable across BSD awk (macOS) and gawk (Linux): use sub() rather than
  # gawk's match()-with-array form which BSD awk doesn't support.
  awk -v k="$key" '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*\[.*\]/ {in_section=1; next}
    in_section {next}
    {
      line=$0
      # Try double-quoted first.
      pattern_dq="^[[:space:]]*" k "[[:space:]]*=[[:space:]]*\"[^\"]*\"[[:space:]]*$"
      if (line ~ pattern_dq) {
        sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*\"", "", line)
        sub("\"[[:space:]]*$", "", line)
        print line; exit
      }
      # Then single-quoted.
      pattern_sq="^[[:space:]]*" k "[[:space:]]*=[[:space:]]*'\''[^'\'']*'\''[[:space:]]*$"
      if (line ~ pattern_sq) {
        sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*'\''", "", line)
        sub("'\''[[:space:]]*$", "", line)
        print line; exit
      }
    }
  ' "$file" 2>/dev/null
}

# Resolve the license token. Sets AXONFLOW_LICENSE_TOKEN_RESOLVED.
# Caller-friendly: never fails, never prints to stdout, never blocks.
axonflow_resolve_license_token() {
  AXONFLOW_LICENSE_TOKEN_RESOLVED=""

  # 1. Env var wins (operator override + CI).
  if [ -n "${AXONFLOW_LICENSE_TOKEN:-}" ]; then
    AXONFLOW_LICENSE_TOKEN_RESOLVED="$AXONFLOW_LICENSE_TOKEN"
  else
    # 2. Config file fallback.
    local from_file
    from_file=$(_axonflow_toml_get_string "license_token" 2>/dev/null || true)
    if [ -n "$from_file" ]; then
      AXONFLOW_LICENSE_TOKEN_RESOLVED="$from_file"
    fi
  fi

  # Guard against forwarding an obviously-malformed value. Tokens issued by
  # axonflow-billing start with "AXON-". Anything else is either a typo, a
  # leftover placeholder, or a copy-paste mistake — leave it empty so the
  # agent doesn't 401 the request.
  if [ -n "$AXONFLOW_LICENSE_TOKEN_RESOLVED" ]; then
    case "$AXONFLOW_LICENSE_TOKEN_RESOLVED" in
      AXON-*) : ;;
      *) AXONFLOW_LICENSE_TOKEN_RESOLVED="" ;;
    esac
  fi

  export AXONFLOW_LICENSE_TOKEN_RESOLVED
}

# Persist a fresh recovery credential set into ~/.codex/axonflow.toml.
# Atomic write (temp + rename), 0600 mode, 0700 parent dir.
# Usage: axonflow_persist_recovery <tenant_id> <secret> <endpoint> <email>
# Returns 0 on success, 1 on failure (caller surfaces the error).
axonflow_persist_recovery() {
  local tenant_id="$1" secret="$2" endpoint="$3" email="$4"
  local file
  file=$(_axonflow_codex_config_path)
  local dir
  dir=$(dirname "$file")
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 0700 "$dir" 2>/dev/null || true

  # Refuse to write a value containing a double-quote — the reader assumes
  # values don't contain unescaped quotes. axonflow-billing-issued secrets
  # are URL-safe base64 + hex so this should never happen, but defending
  # the invariant prevents silent corruption.
  case "$tenant_id$secret$endpoint$email" in
    *\"*) return 1 ;;
  esac

  local tmp="${file}.tmp.$$"
  {
    printf '# AxonFlow Codex plugin config\n'
    printf '# Written by scripts/recover.sh — safe to hand-edit.\n'
    printf '# Required keys for self-hosted: tenant_id, secret, endpoint.\n'
    printf '# Optional: license_token (Pro tier), email (audit trail).\n'
    printf '\n'
    printf 'tenant_id = "%s"\n' "$tenant_id"
    printf 'secret = "%s"\n' "$secret"
    printf 'endpoint = "%s"\n' "$endpoint"
    printf 'email = "%s"\n' "$email"
    # Preserve any existing license_token so recovery doesn't downgrade
    # a Pro-tier user to free tier just because they re-recovered creds.
    local existing_token
    existing_token=$(_axonflow_toml_get_string "license_token" 2>/dev/null || true)
    if [ -n "$existing_token" ]; then
      printf 'license_token = "%s"\n' "$existing_token"
    fi
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# Persist a fresh license token into ~/.codex/axonflow.toml. Used by the
# `apply-token` recovery sub-flow when a buyer pastes their AXON- token
# into the plugin instead of exporting AXONFLOW_LICENSE_TOKEN by hand.
# Atomic write that preserves all other keys verbatim.
# Usage: axonflow_persist_license_token <token>
axonflow_persist_license_token() {
  local token="$1"
  local file
  file=$(_axonflow_codex_config_path)
  local dir
  dir=$(dirname "$file")
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 0700 "$dir" 2>/dev/null || true
  case "$token" in
    AXON-*) : ;;
    *) return 1 ;;
  esac
  case "$token" in
    *\"*) return 1 ;;
  esac

  local tmp="${file}.tmp.$$"
  if [ -f "$file" ]; then
    # Preserve all existing keys EXCEPT license_token, which we replace.
    awk -v tok="$token" '
      BEGIN {written=0}
      /^[[:space:]]*license_token[[:space:]]*=/ {
        if (!written) { print "license_token = \"" tok "\""; written=1 }
        next
      }
      {print}
      END {
        if (!written) print "license_token = \"" tok "\""
      }
    ' "$file" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  else
    {
      printf '# AxonFlow Codex plugin config\n'
      printf 'license_token = "%s"\n' "$token"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}
