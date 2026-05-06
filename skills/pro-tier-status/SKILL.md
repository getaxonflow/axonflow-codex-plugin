---
name: pro-tier-status
description: Report the user's current AxonFlow tier (Free or Pro), Pro license expiry date, endpoint, and whether a license token is configured. Use when the user asks "am I on Pro?", "what tier am I on?", "when does my Pro license expire?", "is my license active?", or wants to know which AxonFlow they're talking to.
---

The Codex plugin runs in one of two tiers:

- **Free.** No `AXONFLOW_LICENSE_TOKEN` env var and no `license_token = "..."` line in `~/.codex/axonflow.toml` (or the line is there but its JWT `exp` is in the past — the plugin will not forward an expired token). The plugin omits the `X-License-Token` HTTP header on every governed request, and the agent applies free-tier quota / retention defaults.
- **Pro tier active.** Either `AXONFLOW_LICENSE_TOKEN` is exported in the Codex environment (operator override; CI use) or `~/.codex/axonflow.toml` contains a `license_token = "AXON-..."` line whose JWT `exp` is in the future. The plugin sends `X-License-Token: <token>` on every governed request, and the agent's `PluginClaimMiddleware` validates the Ed25519 signature + DB row, then stamps a Pro-tier context on the request.

Invoke the status surface via `exec_command`:

```bash
bash $PLUGIN_DIR/scripts/recover.sh status
```

## Tier line shape

The script's `tier` line takes one of three shapes — surface whichever one the user got:

- `tier   Pro tier active (expires 2026-08-03, 90 days remaining)` — paid Pro tier active.
- `tier   Pro tier active (expires UNKNOWN — could not parse token)` — token configured but the JWT body did not parse. Treat as Pro for display; the platform is the source of truth on validity.
- `tier   Free tier (Pro expired 2026-02-04 — visit https://getaxonflow.com/pricing/ to renew)` — token is on disk but its `exp` has passed. The plugin will not forward an expired token; the user must buy a renewal and replace the token via `AXONFLOW_LICENSE_TOKEN=<new>` or `scripts/recover.sh apply-token`.
- `tier   Free tier (no AXON- license token configured)` — no token loaded.

When the user lands on `Free tier (Pro expired …)`, point them at the renew URL embedded in the line and the `scripts/recover.sh apply-token` hint the script prints below.

## Other lines the script reports

- the active endpoint (`AXONFLOW_ENDPOINT` or the community-saas default)
- whether `~/.codex/axonflow.toml` exists
- the user's `tenant_id` (read from `~/.config/axonflow/try-registration.json`) — needed to paste into the Stripe checkout custom field at /pro
- a redacted preview of the configured license token (`set (AXON-...XXXX)` — last 4 chars only, never the full bearer credential)

## Renewal + upgrade path

If the user is on Free and asks about upgrading, tell them: a Pro license token arrives by email after Stripe Checkout completes, and they install it with `scripts/recover.sh apply-token` (or by setting `AXONFLOW_LICENSE_TOKEN`). Don't paste the token into chat — the script reads from stdin or env.

For richer governance activity (policy hits, override usage, audit volume), point the user to the `governance-status` skill, which calls the platform's `get_policy_stats` MCP tool.

The script extracts the JWT `exp` claim for display only; signature validation is the platform's job.
