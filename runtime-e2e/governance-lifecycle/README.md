# governance-lifecycle — runtime E2E

**Asserts:** the override lifecycle on AxonFlow v11.0.0, where the writes are retired.

1. `POST /api/v1/overrides` and `DELETE /api/v1/overrides/{id}`, with a per-user identity, answer HTTP 409 `{"error":{"code":"LEGACY_POLICY_WRITE_FROZEN",...}}`.
2. A real Codex agent runs list → create → list → delete → list through the MCP tools: both writes answer `LEGACY_POLICY_WRITE_FROZEN`, and the count the agent reports never moves and equals the server's.
3. The server-side count is unchanged after the lifecycle.

**Measured contract** (AxonFlow v11.0.0 community, `AXONFLOW_TRUST_IDENTITY_HEADERS=true`): the REST writes answer 409 with the coded envelope once the identity guard passes (without a per-user identity they answer 401 "Authenticated user identity required"); `create_override` and `delete_override` answer a tool error whose text begins `LEGACY_POLICY_WRITE_FROZEN: `; `list_overrides` and `GET /api/v1/overrides` are unchanged reads.

**Prereqs:** `codex` CLI on PATH and authenticated; `jq`; `python3`; a live AxonFlow v11.0.0+ stack with its orchestrator, reachable at `$AXONFLOW_ENDPOINT` (default `http://localhost:8080`).

**Required deployment posture:** the override endpoints check a per-user identity before they answer, so the identity must reach the platform. The test sends `X-User-Email` on the REST calls and on the MCP session (see `create-override/README.md`); the agent drops it unless:

```bash
AXONFLOW_TRUST_IDENTITY_HEADERS=true   # on the AGENT, then restart it
```

Only enable it when every hop that can reach the agent asserts end-user identity from a validated source — see `docs/security/identity-header-trust.md` in axonflow-enterprise.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
  bash runtime-e2e/governance-lifecycle/test.sh
```
