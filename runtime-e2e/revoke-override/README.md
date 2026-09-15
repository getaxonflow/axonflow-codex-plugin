# revoke-override — runtime E2E

**Asserts:** session overrides are retired from AxonFlow v11.0.0, so no override can be seeded to revoke. A real Codex agent calls `delete_override`. The same call made directly answers a tool error (`isError: true`) whose text begins `LEGACY_POLICY_WRITE_FROZEN: `; the agent surfaces `LEGACY_POLICY_WRITE_FROZEN`; the server-side `list_overrides` count is unchanged.

**Measured contract** (AxonFlow v11.0.0 community, `AXONFLOW_TRUST_IDENTITY_HEADERS=true`): `delete_override` answers the frozen tool error with or without a per-user identity on the session.

**Prereqs:** `codex` CLI on PATH and authenticated; `jq`; `python3`; a live AxonFlow v11.0.0+ stack with its orchestrator (for the `list_overrides` count), reachable at `$AXONFLOW_ENDPOINT` (default `http://localhost:8080`).

**Required deployment posture:** the test presents `X-User-Email` on the MCP session (see `create-override/README.md`); the agent honours it only with:

```bash
AXONFLOW_TRUST_IDENTITY_HEADERS=true   # on the AGENT, then restart it
```

Only enable it when every hop that can reach the agent asserts end-user identity from a validated source — see `docs/security/identity-header-trust.md` in axonflow-enterprise.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
  bash runtime-e2e/revoke-override/test.sh
```
