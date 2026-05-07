# Runtime E2E — codex CLI can invoke each V1 Plugin Pro MCP tool

Drives the **real `codex` CLI** (Codex 0.118.x) against the **real
hosted AxonFlow agent** at `https://try.getaxonflow.com` and asserts
that the model can actually invoke each of the 5 V1 Plugin Pro MCP
tools end-to-end. Per HARD RULE #0
(`feedback_runtime_proof_is_definition_of_done.md`) — every byte that
flows through the test came from the real CLI, real plugin install
path, real agent on prod (Community SaaS).

## What this test exercises

For each tool in the V1 PRD §V1 differentiator table, the test:

1. Registers a dedicated MCP server `axonflow_v1_pro_e2e` in
   `~/.codex/config.toml` (does **not** clobber the user's existing
   `axonflow` server — restored on `EXIT`).
2. Patches the same TOML with `[mcp_servers.axonflow_v1_pro_e2e.http_headers]`
   for `X-Axonflow-Client` and `[mcp_servers.axonflow_v1_pro_e2e.env_http_headers]`
   for `Authorization=AXONFLOW_AUTH` + `X-License-Token=AXONFLOW_LICENSE_TOKEN`.
   Per memory `feedback_cursor_codex_mcp_headers_field_empirical_truths.md`
   the env_http_headers field is undocumented in `codex mcp add --help`
   but verified by direct config-file edit + `codex mcp get`.
3. Spawns `codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox`
   one invocation per tool, capturing combined stdout/stderr.
4. Greps for the deterministic markers codex emits via the `rmcp` worker:

   ```
   mcp: axonflow_v1_pro_e2e/<tool> started
   mcp: axonflow_v1_pro_e2e/<tool> (completed)
   mcp: axonflow_v1_pro_e2e/<tool> (failed)
   ```

## Per-tool expectations

| # | Tool                              | Free-tier expectation                                                                              |
|---|-----------------------------------|----------------------------------------------------------------------------------------------------|
| 1 | `axonflow_list_pro_features`      | `started` + `(completed)` markers present                                                          |
| 2 | `axonflow_get_cost_estimate`      | Tool **not invoked** (no `started` marker) — Pro-only per ADR-049 §5, hidden from Free tools/list  |
| 3 | `axonflow_request_approval`       | `started` + `(completed)` markers present                                                          |
| 4 | `axonflow_create_tenant_policy`   | `started` + `(completed)` markers present (uses benign `pattern` to dodge static policy gate)      |
| 5 | `axonflow_get_tenant_id`          | `started` + `(completed)` markers present, **and** the response text contains the test tenant ID   |

## Why test 2 asserts not-invoked, not envelope shape

`axonflow_get_cost_estimate` is the V1 Pro paywall tool. The agent only
advertises it to Pro-tier sessions; a Free `tools/list` excludes it,
so the model literally cannot pick it. The locked V1 envelope shape
(`limit_type=feature_pro_only` + buy URL) is already proven end-to-end
against the wire by
[`axonflow-openclaw-plugin#110`](https://github.com/getaxonflow/axonflow-openclaw-plugin/pull/110)'s
`runtime-e2e/v1_pro_proxy_tools/test.sh` which calls the MCP tool
directly via JSON-RPC and bypasses tier gating.

## Pre-conditions

The test handles all of these automatically and SKIPs cleanly when
unavailable:

- `codex` and `jq` on `PATH`.
- `${AGENT_URL}/health` reachable (defaults to `https://try.getaxonflow.com`).
- Either `TENANT=` and `SECRET=` env vars (re-use an existing tenant)
  or `/api/v1/register` lets us register a fresh one. The endpoint has
  a per-IP 5/hour rate limit; reuse env if you're iterating.
- Optional: AWS credentials + `db_helpers.sh` from
  `axonflow-enterprise/runtime-e2e/v1_paid_tier_staging/lib/`. When
  available, the test cleans the tenant's `hitl_approval_queue` +
  `dynamic_policies` rows before the run so the Free-tier 1/7d HITL
  window and 2-active-policy max don't trip spuriously.

## License-token + codex-config isolation

The plugin's headers helper auto-loads
`~/.config/axonflow/license-token.json` on every MCP session and
stamps its bytes into the `X-License-Token` header. If a previous
Pro-tier session left a token on disk for tenant A and the current run
targets tenant B, the agent's `PluginClaimMiddleware` rejects the
cross-tenant binding and codex reports the MCP server as unavailable.
The test moves any pre-existing token aside (`<file>.runtime-e2e-bak.<pid>`)
and restores it via the `EXIT` trap.

The same `EXIT` trap also:

- backs up `~/.codex/config.toml` on entry and restores it on exit
  (so the user's existing `[mcp_servers.*]` table isn't disturbed);
- removes the test's dedicated `axonflow_v1_pro_e2e` server registration.

## Usage

```bash
# Default — register a fresh tenant against try.getaxonflow.com:
bash runtime-e2e/v1_pro_codex_cli/test.sh

# Re-use an existing tenant (avoids the per-IP /register rate limit):
TENANT=cs_xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
  SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
  bash runtime-e2e/v1_pro_codex_cli/test.sh

# Self-hosted:
AGENT_URL=http://localhost:8080 \
  TENANT=demo-client SECRET=demo-secret \
  bash runtime-e2e/v1_pro_codex_cli/test.sh
```

Captured evidence lands under
`runtime-e2e/v1_pro_codex_cli/EVIDENCE/<utc-ts>/`:

- `<tool>.log` — combined stdout/stderr from each `codex exec` run
- `<tool>_prompt.txt` — the prompt that drove that invocation
- `summary.txt` — top-line PASS/FAIL with tenant ID + MCP server name

The evidence dir contains tenant_id values (public identifiers) but
**never** the `secret` Basic-auth credential or any license token —
both are scrubbed by the assertion paths and only ever flow on the
wire as `Authorization: Basic <base64>` headers.
