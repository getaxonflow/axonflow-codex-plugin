# audit-search — runtime E2E

**Asserts:** Codex registers the AxonFlow MCP server via `codex mcp add` (the same step a user runs after installing this plugin), `codex exec` non-interactively dispatches the `mcp__<name>__search_audit_events` tool through Codex's MCP runtime against a live AxonFlow stack, the call completes (not failed/cancelled), and the agent emits a `SMOKE_RESULT:` marker carrying the `entries[]` response.

**Prereqs:** `codex` CLI on PATH and authenticated; `jq`; live AxonFlow stack reachable at `$AXONFLOW_ENDPOINT` (default `http://localhost:8080`). Note: Codex HTTP MCP support is bearer-token-only — Basic-auth AxonFlow endpoints work in community mode but enterprise mode is a known gap.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
  bash runtime-e2e/audit-search/test.sh
```
