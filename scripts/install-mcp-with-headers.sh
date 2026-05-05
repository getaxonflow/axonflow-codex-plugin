#!/usr/bin/env bash
# install-mcp-with-headers.sh
#
# Closes codex#47: Codex's `mcp add` CLI does not accept a `--header` flag,
# but its `~/.codex/config.toml` schema DOES support a `[mcp_servers.<n>.http_headers]`
# table (verified empirically 2026-05-05 via proxy log capture). This
# script registers AxonFlow as a codex MCP server AND patches the toml so
# every MCP-session request carries X-Axonflow-Client + X-License-Token.
#
# Idempotent: safe to re-run; will overwrite existing `axonflow` entry.
#
# Usage:
#   ./install-mcp-with-headers.sh
#
# Env vars (resolved at MCP-session time, not at install time):
#   AXONFLOW_ENDPOINT       — defaults to http://localhost:8080
#   AXONFLOW_AUTH           — Basic-auth credential for the agent (required for Pro paths)
#   AXONFLOW_LICENSE_TOKEN  — Pro-tier license token (optional; Free tier when absent)

set -uo pipefail

if ! command -v codex >/dev/null 2>&1; then
  echo "ERROR: codex CLI not on PATH. Install codex first." >&2
  exit 1
fi

CONFIG="${HOME}/.codex/config.toml"
ENDPOINT="${AXONFLOW_ENDPOINT:-http://localhost:8080}"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Resolve plugin version for X-Axonflow-Client (static at install time)
PLUGIN_VERSION="$(jq -r '.version // "unknown"' "$PLUGIN_DIR/.codex-plugin/plugin.json" 2>/dev/null || echo unknown)"
CLIENT_HEADER="codex-plugin/${PLUGIN_VERSION}"

# Step 1: register URL via codex CLI (this writes the basic [mcp_servers.axonflow] block)
codex mcp remove axonflow 2>/dev/null || true
codex mcp add axonflow --url "${ENDPOINT}/api/v1/mcp-server" >/dev/null

# Step 2: append the http_headers + env_http_headers blocks. Codex's CLI
# doesn't expose this — we edit the toml directly. Use python tomllib for
# safe parsing + serialization (Python 3.11+).
python3 - "$CONFIG" "$CLIENT_HEADER" <<'PY'
import sys, re, pathlib
config_path, client_header = sys.argv[1], sys.argv[2]
path = pathlib.Path(config_path)
text = path.read_text()

# Drop any prior axonflow http_headers / env_http_headers blocks.
text = re.sub(r'\n\[mcp_servers\.axonflow\.(http_headers|env_http_headers)\][^\[]*', '', text)

# Find the [mcp_servers.axonflow] section and append child blocks.
# We append two child tables right after the file ends, since toml allows
# them in any order.
addendum = f'''
[mcp_servers.axonflow.http_headers]
"X-Axonflow-Client" = "{client_header}"

[mcp_servers.axonflow.env_http_headers]
"X-License-Token" = "AXONFLOW_LICENSE_TOKEN"
"Authorization" = "AXONFLOW_AUTH"
'''
if not text.endswith('\n'):
    text += '\n'
text += addendum
path.write_text(text)
print(f"installed http_headers + env_http_headers for axonflow MCP server (client={client_header})")
PY

echo ""
echo "AxonFlow MCP server registered. Verify with:"
echo "  codex mcp get axonflow"
echo ""
echo "Pro tier: export AXONFLOW_LICENSE_TOKEN=AXON-... before launching codex."
