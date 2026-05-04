---
name: pro-tier-status
description: Report the user's current AxonFlow tier (free or Pro), endpoint, and whether a license token is configured. Use when the user asks "am I on Pro?", "what tier am I on?", "is my license active?", or wants to know which AxonFlow they're talking to.
---

The Codex plugin runs in one of two tiers:

- **Free.** No `AXONFLOW_LICENSE_TOKEN` env var and no `license_token = "..."` line in `~/.codex/axonflow.toml`. The plugin omits the `X-License-Token` HTTP header on every governed request, and the agent applies free-tier quota / retention defaults.
- **Pro tier active.** Either `AXONFLOW_LICENSE_TOKEN` is exported in the Codex environment (operator override; CI use) or `~/.codex/axonflow.toml` contains a `license_token = "AXON-..."` line. The plugin sends `X-License-Token: <token>` on every governed request, and the agent's `PluginClaimMiddleware` validates the Ed25519 signature + DB row, then stamps a Pro-tier context on the request.

Invoke the status surface via `exec_command`:

```bash
bash $PLUGIN_DIR/scripts/recover.sh status
```

The output reports:

- the active endpoint (`AXONFLOW_ENDPOINT` or the community-saas default)
- whether `~/.codex/axonflow.toml` exists
- whether a license token is currently resolvable
- the tier (`Pro tier active` or `Free tier (no AXON- license token configured)`)

If the user is on Free and asks about upgrading, tell them: a Pro license token arrives by email after Stripe Checkout completes, and they install it with `scripts/recover.sh apply-token` (or by setting `AXONFLOW_LICENSE_TOKEN`). Don't paste the token into chat — the script reads from stdin or env.

For richer governance activity (policy hits, override usage, audit volume), point the user to the `governance-status` skill, which calls the platform's `get_policy_stats` MCP tool.
