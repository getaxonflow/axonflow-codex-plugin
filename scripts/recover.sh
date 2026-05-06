#!/usr/bin/env bash
# AxonFlow credential recovery — Codex plugin surface.
#
# Two sub-flows for the V1 launch (mirrors the platform endpoints shipped
# in axonflow-enterprise PR #1850):
#
#   request   – prompt for email, POST /api/v1/recover, agent emails a
#               magic link with a one-time hex token.
#   verify    – prompt for the pasted token, POST /api/v1/recover/verify,
#               agent returns { tenant_id, secret, secret_prefix,
#               expires_at, endpoint, email, note }. We persist the new
#               credentials atomically into ~/.codex/axonflow.toml.
#   apply-token – persist a paid Pro-tier AXON- license token (separate
#                 from credential recovery; documented here because users
#                 paste it through the same surface).
#   status    – render current local config + Pro-tier status (used by
#               the pro-tier-status skill and the runtime tests).
#
# Codex doesn't have a first-class "slash command" plugin surface yet, so
# the surface this script gets is: invoked from a skill (Codex calls
# bash scripts via exec_command), invoked manually by users from a
# terminal, and invoked programmatically by the runtime-e2e tests. All
# three paths share this one script, by design — there is one source of
# truth for "what the recovery flow does" and the runtime test exercises
# the same code the user does.
#
# Non-interactive mode for automation / runtime-e2e tests:
#   AXONFLOW_RECOVER_EMAIL=<addr>         skip the prompt for `request`
#   AXONFLOW_RECOVER_TOKEN=<hex>          skip the prompt for `verify`
#   AXONFLOW_LICENSE_TOKEN=<AXON-...>     skip the prompt for `apply-token`
#
# Endpoint resolution mirrors pre-tool-check.sh (ADR-048):
#   AXONFLOW_ENDPOINT set → that. else AXONFLOW_AUTH set → localhost. else
#   try.getaxonflow.com (community-saas; the recovery flow only makes
#   sense against an endpoint that has actually issued the user a token,
#   so community-saas is the realistic default).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/license-token.sh
. "${SCRIPT_DIR}/lib/license-token.sh"

# Endpoint resolution mirrors pre-tool-check.sh (ADR-048):
#   - AXONFLOW_ENDPOINT explicitly set → use it (self-hosted or remote).
#   - else AXONFLOW_AUTH set (self-hosted with creds, no explicit endpoint)
#     → default to localhost:8080.
#   - else → community-saas (try.getaxonflow.com).
ENDPOINT_DEFAULT="https://try.getaxonflow.com"
if [ -n "${AXONFLOW_ENDPOINT:-}" ]; then
  ENDPOINT="$AXONFLOW_ENDPOINT"
elif [ -n "${AXONFLOW_AUTH:-}" ]; then
  ENDPOINT="http://localhost:8080"
else
  ENDPOINT="$ENDPOINT_DEFAULT"
fi
TIMEOUT="${AXONFLOW_TIMEOUT_SECONDS:-15}"

err() {
  printf 'axonflow recover: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage: scripts/recover.sh <subcommand>

Subcommands:
  request        Send a magic link to the email bound to your tenant.
                 Set AXONFLOW_RECOVER_EMAIL=<addr> to skip the prompt.
  verify         Paste the hex token from the magic link to recover
                 credentials. Set AXONFLOW_RECOVER_TOKEN=<hex> to skip.
  apply-token    Persist a paid Pro-tier license token (AXON-...) into
                 ~/.codex/axonflow.toml. Set AXONFLOW_LICENSE_TOKEN=<tok>
                 to skip the prompt.
  status         Print current AxonFlow local config + Pro-tier status.

Endpoint:        $AXONFLOW_ENDPOINT (default: https://try.getaxonflow.com)
Config file:     ~/.codex/axonflow.toml
EOF
}

require_curl() {
  command -v curl >/dev/null 2>&1 || {
    err "curl is required."
    exit 2
  }
  command -v jq >/dev/null 2>&1 || {
    err "jq is required."
    exit 2
  }
}

cmd_request() {
  require_curl
  local email="${AXONFLOW_RECOVER_EMAIL:-}"
  if [ -z "$email" ]; then
    if [ ! -t 0 ]; then
      err "no AXONFLOW_RECOVER_EMAIL and stdin is not a TTY — cannot prompt."
      exit 2
    fi
    printf 'Email bound to your AxonFlow tenant: ' >&2
    IFS= read -r email
  fi
  if [ -z "$email" ]; then
    err "email is required."
    exit 2
  fi

  # POST /api/v1/recover always returns 202 (anti-enumeration: agent does
  # not signal whether the email is registered). The user is told to
  # check inbox regardless.
  # ADR-050 §4: identify ourselves to the agent so it can derive request scope.
  # shellcheck disable=SC1091
  local SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
  . "${SCRIPT_DIR}/client-header.sh"
  local body http_code
  body=$(curl -sS --max-time "$TIMEOUT" -X POST "$ENDPOINT/api/v1/recover" \
    -H "Content-Type: application/json" \
    -H "X-Axonflow-Client: ${AXONFLOW_CLIENT_HEADER}" \
    -d "$(jq -n --arg e "$email" '{email:$e}')" \
    -w '\n%{http_code}' 2>/dev/null) || {
    err "network call to $ENDPOINT/api/v1/recover failed."
    exit 1
  }
  http_code=$(printf '%s' "$body" | tail -n 1)
  if [ "$http_code" != "202" ]; then
    err "expected 202 from /api/v1/recover, got $http_code"
    printf '%s\n' "$body" | sed '$d' >&2
    exit 1
  fi
  cat <<EOF
Magic link requested for $email at $ENDPOINT.

If the email is registered, you'll receive a message with a confirmation
link. Open the link, click Confirm, and copy the hex token shown on the
confirmation page. Then run:

  scripts/recover.sh verify

to paste the token and persist new credentials in ~/.codex/axonflow.toml.

Tokens expire — verify within the window stated in the email.
EOF
}

cmd_verify() {
  require_curl
  local token="${AXONFLOW_RECOVER_TOKEN:-}"
  if [ -z "$token" ]; then
    if [ ! -t 0 ]; then
      err "no AXONFLOW_RECOVER_TOKEN and stdin is not a TTY — cannot prompt."
      exit 2
    fi
    printf 'Paste the recovery token from the magic link: ' >&2
    IFS= read -r token
  fi
  if [ -z "$token" ]; then
    err "token is required."
    exit 2
  fi
  # Defense-in-depth: tokens issued by the agent are URL-safe hex; refuse
  # an obvious paste-mistake before sending it on the wire.
  case "$token" in
    *' '*|*$'\t'*|*$'\n'*)
      err "token contains whitespace — re-paste with no surrounding chars."
      exit 2
      ;;
  esac

  # ADR-050 §4: identify ourselves to the agent so it can derive request scope.
  # shellcheck disable=SC1091
  local SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
  . "${SCRIPT_DIR}/client-header.sh"
  local body http_code
  body=$(curl -sS --max-time "$TIMEOUT" -X POST "$ENDPOINT/api/v1/recover/verify" \
    -H "Content-Type: application/json" \
    -H "X-Axonflow-Client: ${AXONFLOW_CLIENT_HEADER}" \
    -d "$(jq -n --arg t "$token" '{token:$t}')" \
    -w '\n%{http_code}' 2>/dev/null) || {
    err "network call to $ENDPOINT/api/v1/recover/verify failed."
    exit 1
  }
  http_code=$(printf '%s' "$body" | tail -n 1)
  local payload
  payload=$(printf '%s' "$body" | sed '$d')
  if [ "$http_code" != "200" ]; then
    err "verify failed with HTTP $http_code"
    printf '%s\n' "$payload" >&2
    exit 1
  fi

  local tenant_id secret endpoint email expires_at note
  tenant_id=$(printf '%s' "$payload" | jq -r '.tenant_id // empty')
  secret=$(printf '%s' "$payload" | jq -r '.secret // empty')
  endpoint=$(printf '%s' "$payload" | jq -r '.endpoint // empty')
  email=$(printf '%s' "$payload" | jq -r '.email // empty')
  expires_at=$(printf '%s' "$payload" | jq -r '.expires_at // empty')
  note=$(printf '%s' "$payload" | jq -r '.note // empty')

  if [ -z "$tenant_id" ] || [ -z "$secret" ]; then
    err "verify response missing tenant_id or secret"
    printf '%s\n' "$payload" >&2
    exit 1
  fi

  # If the agent didn't echo back an endpoint, fall back to the one we
  # actually called — the credentials are bound to that agent.
  [ -z "$endpoint" ] && endpoint="$ENDPOINT"

  if ! axonflow_persist_recovery "$tenant_id" "$secret" "$endpoint" "$email"; then
    err "could not write credentials to ${AXONFLOW_CODEX_CONFIG:-$HOME/.codex/axonflow.toml}"
    exit 1
  fi

  cat <<EOF
Credentials recovered and saved to ${AXONFLOW_CODEX_CONFIG:-$HOME/.codex/axonflow.toml}.

  tenant_id   $tenant_id
  endpoint    $endpoint
  email       $email
  expires_at  ${expires_at:-(none)}

To use them: export AXONFLOW_AUTH=\$(printf '%s:%s' "$tenant_id" "$secret" | base64 | tr -d '\n')
             export AXONFLOW_ENDPOINT=$endpoint

Then re-run Codex.

${note:-}
EOF
}

cmd_apply_token() {
  local token="${AXONFLOW_LICENSE_TOKEN:-}"
  if [ -z "$token" ]; then
    if [ ! -t 0 ]; then
      err "no AXONFLOW_LICENSE_TOKEN and stdin is not a TTY — cannot prompt."
      exit 2
    fi
    printf 'Paste your AxonFlow Pro-tier license token (starts with AXON-): ' >&2
    IFS= read -r token
  fi
  if [ -z "$token" ]; then
    err "license token is required."
    exit 2
  fi
  case "$token" in
    AXON-*) : ;;
    *)
      err "token does not look like an AxonFlow license token (expected AXON- prefix)."
      exit 2
      ;;
  esac
  if ! axonflow_persist_license_token "$token"; then
    err "could not write license token to ${AXONFLOW_CODEX_CONFIG:-$HOME/.codex/axonflow.toml}"
    exit 1
  fi
  printf 'Pro-tier license token persisted. Restart Codex to pick it up.\n' >&2
}

# extract_jwt_exp <token>  →  prints unix-epoch integer to stdout, exits 0
# on success, non-zero on any parse failure. Pure stdout/stderr; never
# raises. The caller decides how to render a parse failure.
#
# AxonFlow license tokens are formatted `AXON-<JWT>` where <JWT> is a
# standard `header.payload.signature` triple. We base64url-decode the
# middle segment, then look for `"exp":<digits>`. Signature is NEVER
# validated here — display only.
extract_jwt_exp() {
  local tok="$1"
  [ -n "$tok" ] || return 1
  local jwt="${tok#AXON-}"
  local payload
  payload=$(printf '%s' "$jwt" | cut -d. -f2)
  [ -n "$payload" ] || return 1
  payload=$(printf '%s' "$payload" | tr '_-' '/+')
  local pad=$(( 4 - ${#payload} % 4 ))
  if [ "$pad" -ne 4 ]; then
    payload="${payload}$(printf '=%.0s' $(seq 1 "$pad"))"
  fi
  local decoded
  decoded=$(printf '%s' "$payload" | base64 -d 2>/dev/null) \
    || decoded=$(printf '%s' "$payload" | base64 -D 2>/dev/null) \
    || return 1
  [ -n "$decoded" ] || return 1
  local exp
  exp=$(printf '%s' "$decoded" | grep -oE '"exp"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$')
  [ -n "$exp" ] || return 1
  printf '%s' "$exp"
}

# format_unix_to_date <unix-epoch>  →  prints YYYY-MM-DD (UTC) to stdout.
format_unix_to_date() {
  local epoch="$1"
  [ -n "$epoch" ] || return 1
  local out
  out=$(date -u -d "@${epoch}" +%Y-%m-%d 2>/dev/null) \
    || out=$(date -u -r "${epoch}" +%Y-%m-%d 2>/dev/null) \
    || return 1
  printf '%s' "$out"
}

cmd_status() {
  axonflow_resolve_license_token
  local file="${AXONFLOW_CODEX_CONFIG:-$HOME/.codex/axonflow.toml}"
  local cfg_present="no"
  [ -f "$file" ] && cfg_present="yes"

  # Tenant ID — needed by the buyer to paste into Stripe Checkout's
  # custom field at /pro. Source: try-registration.json (the file
  # community-saas-bootstrap.sh writes after auto-registration). If the
  # registration file is missing, the user hasn't bootstrapped yet (or
  # lost the file — the recover flow can re-mint one).
  local tenant_file="${AXONFLOW_CONFIG_DIR:-$HOME/.config/axonflow}/try-registration.json"
  local tenant_id="(not registered yet — first agent call will auto-register, or run \`scripts/recover.sh request\`)"
  if [ -f "$tenant_file" ] && command -v jq >/dev/null 2>&1; then
    local found
    found=$(jq -r '.tenant_id // empty' "$tenant_file" 2>/dev/null || true)
    if [ -n "$found" ]; then
      tenant_id="$found"
    fi
  fi

  local upgrade_url="${AXONFLOW_UPGRADE_URL:-https://getaxonflow.com/pricing/}"

  # Tier-line resolution. Three shapes (V1 SaaS Plugin Pro tier-line
  # surface parity across the AxonFlow plugin set):
  #   - "Pro tier active (expires YYYY-MM-DD, N days remaining)"   exp future
  #   - "Pro tier active (expires UNKNOWN — could not parse token)" parse fail
  #   - "Free tier (Pro expired YYYY-MM-DD — visit <url> to renew)" exp past
  #   - "Free tier (no AXON- license token configured)"            no token
  #
  # The leading "Pro tier active" / "Free tier" preserves the existing
  # contract (runtime-e2e/v1-paid-tier/test.sh greps for "Pro tier active"
  # and "Free tier") so we extend without breaking the older assertions.
  local tier token_display
  local pro_expired_flag=0
  if [ -n "${AXONFLOW_LICENSE_TOKEN_RESOLVED:-}" ]; then
    # Never print the full token to a terminal — it's a bearer credential and
    # `recover.sh status` may be screen-shared, copy-pasted into a support
    # ticket, or logged. Show a fixed prefix + last 4 chars only, padding
    # short tokens defensively so we never leak the middle.
    local tail4="****"
    if [ "${#AXONFLOW_LICENSE_TOKEN_RESOLVED}" -ge 4 ]; then
      tail4="${AXONFLOW_LICENSE_TOKEN_RESOLVED: -4}"
    fi
    token_display="set (AXON-...${tail4})"

    local exp_epoch
    exp_epoch=$(extract_jwt_exp "$AXONFLOW_LICENSE_TOKEN_RESOLVED" 2>/dev/null || true)
    if [ -n "$exp_epoch" ]; then
      local exp_date
      exp_date=$(format_unix_to_date "$exp_epoch" 2>/dev/null || true)
      if [ -n "$exp_date" ]; then
        local now_epoch
        now_epoch=$(date -u +%s)
        if [ "$exp_epoch" -gt "$now_epoch" ]; then
          local secs_left=$(( exp_epoch - now_epoch ))
          local days_left=$(( (secs_left + 86399) / 86400 ))
          tier="Pro tier active (expires ${exp_date}, ${days_left} days remaining)"
        else
          tier="Free tier (Pro expired ${exp_date} — visit ${upgrade_url} to renew)"
          pro_expired_flag=1
        fi
      else
        tier="Pro tier active (expires UNKNOWN — could not parse token)"
      fi
    else
      tier="Pro tier active (expires UNKNOWN — could not parse token)"
    fi
  else
    tier="Free tier (no AXON- license token configured)"
    token_display="unset"
  fi

  cat <<EOF
AxonFlow Codex plugin — status

  endpoint           ${AXONFLOW_ENDPOINT:-${ENDPOINT_DEFAULT}}
  tenant_id          $tenant_id
  config file        $file (present=$cfg_present)
  license token      $token_display
  tier               $tier
  upgrade            $upgrade_url

EOF

  if [ "$pro_expired_flag" -eq 1 ]; then
    cat <<EOF
Your Pro license token is on disk but its 'exp' has passed; the plugin will
not forward an expired token. After buying a renewal, replace the token via:
  AXONFLOW_LICENSE_TOKEN=AXON-... codex …
or persist with:
  scripts/recover.sh apply-token

EOF
  fi

  cat <<EOF
To upgrade to Pro (\$9.99 one-time), copy your tenant_id above, then visit
$upgrade_url, paste the tenant_id into the "Your AxonFlow tenant ID" field,
and complete checkout. The license token arrives by email; set it via:
  AXONFLOW_LICENSE_TOKEN=AXON-... codex …
or persist with:
  scripts/recover.sh apply-token

License token resolution order: AXONFLOW_LICENSE_TOKEN env var, then
license_token = "..." in $file.

Recover lost credentials with:
  scripts/recover.sh request   # email magic link
  scripts/recover.sh verify    # paste token, persist new creds
EOF
}

main() {
  local sub="${1:-}"
  case "$sub" in
    request)      cmd_request ;;
    verify)       cmd_verify ;;
    apply-token)  cmd_apply_token ;;
    status)       cmd_status ;;
    -h|--help|help|"") usage ;;
    *)
      err "unknown subcommand: $sub"
      usage
      exit 2
      ;;
  esac
}

main "$@"
