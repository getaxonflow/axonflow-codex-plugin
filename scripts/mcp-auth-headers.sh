#!/usr/bin/env bash
# Generate auth headers for the AxonFlow MCP server connection.
# Called by the Codex CLI's MCP headersHelper at MCP session start.
#
# Resolution order (ADR-048):
#   1. AXONFLOW_AUTH already exported by the user → use it (self-hosted /
#      enterprise / explicit credential).
#   2. No explicit AXONFLOW_AUTH and no AXONFLOW_ENDPOINT → run the
#      Community-SaaS bootstrap to register against try.getaxonflow.com
#      and load the resulting Basic-auth credential.
#   3. AXONFLOW_AUTH still empty after that (bootstrap couldn't run /
#      degraded) → emit empty headers (Community-mode self-hosted, no auth).

# When this script is invoked by the Codex CLI's MCP headersHelper,
# AXONFLOW_MODE is not yet set; resolve it the same way pre-tool-check.sh
# does so the bootstrap helper makes the right call.
if [ -z "${AXONFLOW_MODE:-}" ]; then
  if [ -z "${AXONFLOW_ENDPOINT:-}" ] && [ -z "${AXONFLOW_AUTH:-}" ]; then
    AXONFLOW_MODE="community-saas"
  else
    AXONFLOW_MODE="self-hosted"
  fi
  export AXONFLOW_MODE
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/community-saas-bootstrap.sh"

# Mode-clarity canary on stderr (NEVER stdout — stdout is the headers JSON).
# Mirrors pre-tool-check.sh's canary so MCP-startup-first sessions also get
# the unambiguous endpoint/mode disclosure.
ENDPOINT_FOR_CANARY="${AXONFLOW_ENDPOINT:-https://try.getaxonflow.com}"
if [ "$AXONFLOW_MODE" = "self-hosted" ] && [ -z "${AXONFLOW_ENDPOINT:-}" ]; then
  ENDPOINT_FOR_CANARY="http://localhost:8080"
fi
echo "[AxonFlow] Connected to AxonFlow at ${ENDPOINT_FOR_CANARY} (mode=${AXONFLOW_MODE})" >&2

# One-time positive disclosure — shared stamp with pre-tool-check.sh so
# whichever path fires first owns the disclosure for this install. MCP
# session can begin before any tool runs, so we surface it here too.
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

AUTH="${AXONFLOW_AUTH:-}"

# V1 paid Pro tier (PR #1850): if a license token is resolvable, attach it
# to the MCP-session headers so the long-lived MCP connection lands in the
# Pro-tier code path the same way the per-tool hooks do.
# shellcheck source=./lib/license-token.sh
. "${SCRIPT_DIR}/lib/license-token.sh"
axonflow_resolve_license_token
LICENSE_TOKEN="${AXONFLOW_LICENSE_TOKEN_RESOLVED:-}"

# ADR-050 §4: every governed request to the agent carries X-Axonflow-Client
# so the agent can derive request scope (plugin) and validate it against the
# token's aud.scope via HasScope().
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/client-header.sh"
CLIENT_HEADER="${AXONFLOW_CLIENT_HEADER}"

if [ -n "$AUTH" ] && [ -n "$LICENSE_TOKEN" ]; then
  printf '{"Authorization": "Basic %s", "X-License-Token": "%s", "X-Axonflow-Client": "%s"}\n' "$AUTH" "$LICENSE_TOKEN" "$CLIENT_HEADER"
elif [ -n "$AUTH" ]; then
  printf '{"Authorization": "Basic %s", "X-Axonflow-Client": "%s"}\n' "$AUTH" "$CLIENT_HEADER"
elif [ -n "$LICENSE_TOKEN" ]; then
  printf '{"X-License-Token": "%s", "X-Axonflow-Client": "%s"}\n' "$LICENSE_TOKEN" "$CLIENT_HEADER"
else
  printf '{"X-Axonflow-Client": "%s"}\n' "$CLIENT_HEADER"
fi
