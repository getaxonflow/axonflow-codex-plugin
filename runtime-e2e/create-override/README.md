# create-override — runtime E2E

**Asserts:** session overrides are retired from AxonFlow v11.0.0. A real Codex agent calls `create_override` on an MCP session that presents a per-user identity. The same call made directly answers a tool error (`isError: true`) whose text begins `LEGACY_POLICY_WRITE_FROZEN: `; the agent surfaces `LEGACY_POLICY_WRITE_FROZEN`; the agent reports no created id; the server-side `list_overrides` count is unchanged.

**Measured contract** (AxonFlow v11.0.0 community, `AXONFLOW_TRUST_IDENTITY_HEADERS=true`): with `X-User-Email` on the session, `create_override` answers the frozen tool error. Without a per-user identity it is refused for that first ("Per-user session overrides are scoped to an individual user ..."), and this test fails with that answer printed.

**Prereqs:** `codex` CLI on PATH and authenticated; `jq`; `python3`; a live AxonFlow v11.0.0+ stack with its orchestrator, reachable at `$AXONFLOW_ENDPOINT` (default `http://localhost:8080`).

**Required deployment posture:** the override tools check a per-user identity before they answer, so the identity must reach the platform. The test sends `X-User-Email` (`AXONFLOW_E2E_USER_EMAIL`) on the MCP session by writing a `[mcp_servers.<test server>.http_headers]` table into the Codex config the way `scripts/install-mcp-with-headers.sh` does, and removes it on exit. The agent drops that header unless `AXONFLOW_TRUST_IDENTITY_HEADERS=true`:

```bash
AXONFLOW_TRUST_IDENTITY_HEADERS=true   # on the AGENT, then restart it
```

Only enable it when every hop that can reach the agent asserts end-user identity from a validated source - see `docs/security/identity-header-trust.md` in axonflow-enterprise.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
  bash runtime-e2e/create-override/test.sh
```
