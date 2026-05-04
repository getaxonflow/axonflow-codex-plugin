# v1-paid-tier — V1 paid Pro tier wire-up

**Asserts:** the plugin's `pre-tool-check.sh` and `recover.sh` scripts forward an `X-License-Token` header to the AxonFlow agent on every governed request when a token is configured (env or `~/.codex/axonflow.toml`), and never forward a header when one is not configured.

**Runtime path under test:** the Codex plugin's bash hook (`scripts/pre-tool-check.sh`) → `curl POST /api/v1/mcp-server` → AxonFlow agent middleware. A local capture-server stands in for the agent so we can assert what the hook actually put on the wire — not just what the script log says it did.

**Prereqs:**

- `bash`, `curl`, `jq`, `python3` on `$PATH`
- Plugin checkout (this repo)

**Run:**

```bash
DO_NOT_TRACK=1 bash runtime-e2e/v1-paid-tier/test.sh
```

**Assertions:**

| # | Test |
|---|---|
| 1 | `AXONFLOW_LICENSE_TOKEN` env var → header sent with that value |
| 2 | `~/.codex/axonflow.toml` `license_token` → header sent with that value |
| 3 | env var beats TOML when both set |
| 4 | no token → header absent (free tier) |
| 5 | malformed token (no `AXON-` prefix) → header filtered, not forwarded |
| 6 | `recover.sh status` reports correct tier |
| 7 | `recover.sh apply-token` persists into `~/.codex/axonflow.toml` (mode 0600) |
| 8 | live agent middleware sees the header (skipped unless `/health` advertises `plugin_claim_license` capability or `AXONFLOW_ASSERT_LIVE_MIDDLEWARE=1`) |

**Live-agent test 8** is gated on the agent advertising the `plugin_claim_license` capability (axonflow-enterprise PR #1850, v7.7+). Older agents have the route handlers but not the middleware in the chain — running the assertion against them would falsely fail.
