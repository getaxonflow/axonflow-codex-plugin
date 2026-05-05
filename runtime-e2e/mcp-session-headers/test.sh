#!/usr/bin/env bash
# Runtime test for codex#47: Codex MCP-session forwards
# X-Axonflow-Client + X-License-Token (env-resolved) on every probe to
# the AxonFlow agent.
#
# Per CLAUDE.md HARD RULE #0 — exercises the actual codex CLI's MCP
# config + HTTP client. No mocks.

set -uo pipefail

PROXY_LOG="${PROXY_LOG:-/tmp/axonflow-e2e/proxy.log}"

if [ ! -f "$PROXY_LOG" ]; then
  echo "SKIP: $PROXY_LOG not found — start the logging proxy first (see runtime-e2e/README.md)."
  exit 0
fi
if ! command -v codex >/dev/null 2>&1; then
  echo "SKIP: codex CLI not on PATH."
  exit 0
fi

# Snapshot user's existing codex config.toml so we can restore it.
RESTORE=$(mktemp)
trap 'cp "$RESTORE" "$HOME/.codex/config.toml"; rm -f "$RESTORE"' EXIT
cp "$HOME/.codex/config.toml" "$RESTORE"

# Point AxonFlow at the logging proxy and run the install helper from this PR.
export AXONFLOW_ENDPOINT=http://localhost:8181
"$(cd "$(dirname "$0")/../../scripts" && pwd)/install-mcp-with-headers.sh" >/dev/null

LINES_BEFORE=$(wc -l < "$PROXY_LOG")

# Trigger codex to probe the MCP server. `codex mcp list` fires the health
# probe + OAuth-discovery against each enabled URL, which is enough for
# the proxy to capture the headers codex is sending.
codex mcp list >/dev/null 2>&1 || true
sleep 3

LINES_AFTER=$(wc -l < "$PROXY_LOG")
NEW_LINES=$((LINES_AFTER - LINES_BEFORE))
RECENT=$(tail -n "$NEW_LINES" "$PROXY_LOG")

CLIENT_HITS=$(echo "$RECENT" | grep -c 'X-Axonflow-Client=codex-plugin/' || true)
if [ "$CLIENT_HITS" -lt 1 ]; then
  echo "FAIL: no proxy hit carrying X-Axonflow-Client=codex-plugin/* in the new $NEW_LINES proxy lines"
  echo "Last 5 proxy lines:"
  tail -5 "$PROXY_LOG" >&2
  exit 1
fi

echo "PASS: $CLIENT_HITS proxy hit(s) with X-Axonflow-Client=codex-plugin/* — codex injects the static header"

# If a Pro-tier license token was provided in the env, also assert
# X-License-Token landed in the proxy.
if [ -n "${AXONFLOW_E2E_PLUGIN_TOKEN:-}" ]; then
  AXONFLOW_LICENSE_TOKEN="$AXONFLOW_E2E_PLUGIN_TOKEN"
  export AXONFLOW_LICENSE_TOKEN
  > "$PROXY_LOG"
  codex mcp list >/dev/null 2>&1 || true
  sleep 3
  TOKEN_HITS=$(grep -c 'X-License-Token' "$PROXY_LOG" || true)
  if [ "$TOKEN_HITS" -lt 1 ]; then
    echo "FAIL: AXONFLOW_E2E_PLUGIN_TOKEN was set but no proxy hit carried X-License-Token"
    exit 1
  fi
  echo "PASS: $TOKEN_HITS proxy hit(s) with X-License-Token — env_http_headers resolves correctly"
fi
