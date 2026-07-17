# caller-name-audit — runtime E2E

**Asserts** (getaxonflow/axonflow-enterprise#2912; platform support in
axonflow-enterprise PR #2953), by driving the plugin's real
`scripts/post-tool-audit.sh` hook with a realistic PostToolUse stdin
payload against a live AxonFlow agent, then reading the canonical
`audit_logs` row back from the platform DB — no mocks, no stubs:

1. The hook's `audit_tool_call` write lands in `audit_logs` for the probed
   tool call (the fire-and-forget POST actually reaches the agent and gets
   persisted, not just dispatched).
2. `policy_details->>'caller_name' = 'codex'` — the hook now sends the
   correctly-named `caller_name` field (previously it sent `tool_type`,
   which was being abused to carry the caller's identity).
3. `policy_details ? 'tool_type'` is **false** — the old field name must be
   absent from newly-written rows; `tool_type` remains only a deprecated
   legacy fallback on the platform side.

**Prereqs:** `jq`, `curl`, `psql` on PATH; a live agent at `$AXONFLOW_ENDPOINT`
(default `http://localhost:8080`); a Basic-auth credential — `AXONFLOW_AUTH`,
or `AXONFLOW_E2E_ENTERPRISE_AUTH`, or `AXONFLOW_E2E_ORG_ID` +
`AXONFLOW_E2E_LICENSE_KEY`, or `AXONFLOW_CLIENT_ID` + `AXONFLOW_CLIENT_SECRET`
(defaults to `demo-client`/`demo-secret` for a community-mode stack); and
`AXONFLOW_E2E_DB_URL` pointing at the platform DB (needed because the
audit-search API does not expose the raw `policy_details` column). Skips
cleanly when any prereq is absent.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
AXONFLOW_CLIENT_ID=demo-client AXONFLOW_CLIENT_SECRET=demo-secret \
AXONFLOW_E2E_DB_URL='postgresql://axonflow:localdev123@localhost:5432/axonflow' \
  bash runtime-e2e/caller-name-audit/test.sh
```

Enterprise stacks: set `AXONFLOW_E2E_ORG_ID` + `AXONFLOW_E2E_LICENSE_KEY` (or
a pre-computed `AXONFLOW_AUTH`) instead of the `AXONFLOW_CLIENT_ID`/`SECRET`
pair.
