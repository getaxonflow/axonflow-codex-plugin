# MCP-session header injection (codex#47)

Verifies that Codex's MCP-session HTTP traffic to the AxonFlow agent
carries `X-Axonflow-Client: codex-plugin/<version>` (always) and
`X-License-Token: ${AXONFLOW_LICENSE_TOKEN}` / `Authorization: ${AXONFLOW_AUTH}`
(env-resolved at MCP-session time, not at install time).

## What this asserts

`codex mcp add` does not accept a `--header` flag, but Codex's
`~/.codex/config.toml` schema supports `[mcp_servers.<n>.http_headers]`
(static) and `[mcp_servers.<n>.env_http_headers]` (env-var-resolved).
The plugin's `scripts/install-mcp-with-headers.sh` runs `codex mcp add`
followed by a TOML patch to add both header tables.

Without this, Pro-tier customers using Codex's MCP path get Free-tier
enforcement (the per-call hooks still cover actual policy enforcement,
but the agent's tool-discovery response uses the Free-tier tool list,
so Pro-only tools never appear in the MCP-session tool inventory).

## Prereqs

- Local AxonFlow agent on `localhost:8080` (the install helper points at
  `${AXONFLOW_ENDPOINT}` at install time).
- Logging proxy on `localhost:8181` forwarding to the agent and logging
  to `/tmp/axonflow-e2e/proxy.log`.
- `codex` CLI on PATH.

## How to run

```bash
export AXONFLOW_ENDPOINT=http://localhost:8181  # logging proxy
# Optional: set Pro-tier token to also exercise X-License-Token path
# export AXONFLOW_E2E_PLUGIN_TOKEN=AXON-...
./test.sh
```

## Expected output

```
PASS: <N> proxy hit(s) with X-Axonflow-Client=codex-plugin/* — codex injects the static header
PASS: <M> proxy hit(s) with X-License-Token — env_http_headers resolves correctly  (only if AXONFLOW_E2E_PLUGIN_TOKEN was set)
```

## Why this can't run mocked

Per CLAUDE.md HARD RULE #0: a runtime test for Codex MCP-session
behavior MUST exercise the actual codex CLI's TOML config parser
+ HTTP client. Mocking codex's behavior with our own JSON-loader
proves nothing — the whole point of the test is "does codex
actually honor `http_headers` + `env_http_headers` in
`~/.codex/config.toml`?".

## Restoration

The test snapshots `~/.codex/config.toml` at start and restores it on
exit (via trap), so it's safe to run alongside an active codex
config.
