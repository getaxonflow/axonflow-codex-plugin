# recovery — W3 free-tier email-recovery surface

**Asserts:** the plugin's `scripts/recover.sh` user surface drives the W3 recovery flow against a real `/api/v1/recover[/verify]` endpoint, persists the returned credentials atomically into `~/.codex/axonflow.toml` (mode 0600), and preserves an existing `license_token` line across credential re-recovery.

**Runtime path under test:** `scripts/recover.sh request|verify|apply-token|status` → curl POST → AxonFlow recovery handlers (`platform/agent/community_saas_recovery.go`). A local fake agent stands in so the test runs without external dependencies; the live agent at `$AGENT_URL` is also probed when reachable AND when the agent advertises the `community_saas_recovery` capability.

**Prereqs:**

- `bash`, `curl`, `jq`, `python3` on `$PATH`
- Plugin checkout (this repo)

**Run:**

```bash
DO_NOT_TRACK=1 bash runtime-e2e/recovery/test.sh
```

**Assertions:**

| # | Test |
|---|---|
| 1 | `recover.sh request` POSTs `/api/v1/recover` and gets 202 |
| 2 | `recover.sh verify` POSTs `/api/v1/recover/verify` and persists `tenant_id`, `secret`, `endpoint`, `email` into `~/.codex/axonflow.toml` (mode 0600) |
| 3 | replay rejection — a "consumed" token is rejected and existing creds are NOT overwritten |
| 4 | re-verifying credentials preserves an existing `license_token` line (no Pro-tier downgrade) |
| 5 | `recover.sh status` reads the persisted `license_token` and reports Pro tier active |
| 6 | live agent recovery endpoint returns 202 (skipped unless `/health` advertises `community_saas_recovery` or `AXONFLOW_ASSERT_LIVE_RECOVERY=1`) |

**Live-agent test 6** is gated on the agent advertising the `community_saas_recovery` capability (axonflow-enterprise PR #1850, v7.7+). Older agents return 404 on the endpoint and the test would falsely fail.
