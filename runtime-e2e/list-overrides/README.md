# list-overrides — runtime E2E

**Asserts:** a real Codex agent calls `list_overrides` (a read, unchanged on AxonFlow v11.0.0) and reports the count via SMOKE_RESULT; the count equals the count `list_overrides` answers when called directly. No override is seeded: from v11.0.0 none can be created (`create-override`).

**Prereqs:** `codex` CLI on PATH and authenticated; `jq`; `python3`; a live AxonFlow stack with its orchestrator (the tool reads through it), reachable at `$AXONFLOW_ENDPOINT` (default `http://localhost:8080`).

**Deployment posture:** the test presents `X-User-Email` on the MCP session like the other override suites; the read answers with or without it.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
  bash runtime-e2e/list-overrides/test.sh
```
