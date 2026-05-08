# list-recent-decisions — runtime E2E

V1.1 (axonflow-enterprise#1982).

**Asserts:** Codex dispatches `mcp__axonflow_w2_e2e__list_recent_decisions` through its MCP runtime against a live AxonFlow stack:

1. The platform's MCP server advertises `list_recent_decisions` (`tools/list`).
2. Happy-path `tools/call` returns the decisions array shape.
3. Free-tier cap-hit (`limit=10` over Community max page=5) returns the wrapped V1 upgrade envelope with `upgrade.compare_url` + `upgrade.buy_url` intact — locks in `feedback_429_no_upgrade_hint_is_conversion_gap.md`.

The runtime path is wire-level (curl against the MCP server, no LLM-in-the-loop) so it runs deterministically. The codex-driven proof — Codex dispatching the tool through `codex exec` against the registered MCP server — is captured during release validation.

**Prereqs:** `jq`; live AxonFlow stack reachable at `$AXONFLOW_ENDPOINT` (default `http://localhost:8080`). The Codex CLI is NOT required for this gate; the wire-level proof exercises the same MCP transport.

**Run:**

```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
AXONFLOW_CLIENT_ID=demo-client \
AXONFLOW_CLIENT_SECRET=demo-secret \
  bash runtime-e2e/list-recent-decisions/test.sh
```

The test gracefully `SKIP`s if the stack is unavailable.
