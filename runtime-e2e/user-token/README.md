# user-token — runtime E2E

**Asserts** (axonflow-enterprise#2944, epic #2919 — codex port of the claude
plugin's #2935), by driving the plugin's real hook scripts
(`pre-tool-check.sh` → `check_policy`, `post-tool-audit.sh` →
`audit_tool_call`) against a live AxonFlow agent and reading the canonical
`audit_logs` rows back from the platform DB — no mocks, no stubs:

1. **Unconfigured (the common fleet state):** with no per-user token anywhere,
   governed rows are written and attribute exactly as before (the shared
   tenant identity, `mcp-client:<org>` — the codex plugin has no
   `X-User-Email` label mechanism) — the plugin's behavior is byte-identical
   to pre-1.6.
2. **Validated identity (platform with enterprise#2929+):** with a REAL minted
   per-user token configured (env on the pre-tool plane, 0600
   `user-token.json` on the post-tool plane), governed rows on BOTH planes
   attribute to the **token's canonical email** — NOT the shared client
   identity. The validated identity replaces the shared fallback; that is the
   whole point of the token.
3. **Unhappy path (fail-closed):** a tampered token → the platform rejects the
   request (HTTP 401) and `pre-tool-check.sh` **blocks the tool call (exit
   2)** with a stderr diagnostic naming the per-user token as the likely
   cause — never the value, and never a silent fall-open (the pre-existing
   #2275 401-cooldown fall-open would otherwise let a garbage token switch
   governance off).
4. **MCP plane (env-only contract):** `install-mcp-with-headers.sh` run
   against a scratch `CODEX_HOME` produces a valid `config.toml` with the
   `"X-User-Token" = "AXONFLOW_USER_TOKEN"` env mapping (needs the real
   `codex` CLI; sub-leg skips without it), and the env-var header contract is
   proven against the LIVE agent with explicit HTTP codes: minted token →
   200, tampered → 401, header omitted → 200.

Legs 2–4's token parts need a platform that validates `X-User-Token`
(`authenticateMCPServerRequest` → `extractPerUserToken`, enterprise#2929). The
harness probes for that capability by presenting a garbage token: a pre-#2929
platform ignores the header (probe succeeds → token legs SKIP with a notice),
a post-#2929 enterprise platform rejects it.

**Prereqs:** `jq`, `curl`, `psql`, `python3` on PATH; a live agent at
`$AXONFLOW_ENDPOINT` (default `http://localhost:8080`); an enterprise Basic
credential (`AXONFLOW_AUTH`, or `AXONFLOW_E2E_ENTERPRISE_AUTH`, or
`AXONFLOW_E2E_ORG_ID` + `AXONFLOW_E2E_LICENSE_KEY`); `AXONFLOW_E2E_DB_URL`
pointing at the platform DB. For the token legs, ONE of:

- `AXONFLOW_E2E_USER_TOKEN` + `AXONFLOW_E2E_USER_TOKEN_EMAIL` — a real token
  minted via the platform admin API
  (`POST /api/v1/admin/organizations/{org_id}/user-tokens`, enterprise#2930)
  and the email it was minted for; or
- `AXONFLOW_E2E_JWT_SECRET` — the agent's `JWT_SECRET`; the harness signs an
  HS256 token with the exact claims contract the mint API produces
  (`iss=axonflow-user-token-mint`, `email`, `role`, `org_id`, `jti`, `iat`,
  `exp`). The platform validates it for real — same signature check, same
  org binding, same revocation lookup — so this is the mint contract, not a
  mock. Requires `AXONFLOW_E2E_ORG_ID` (the org the Basic credential
  authenticates as).

Skips cleanly when any prereq is absent.

**Run (local stack):**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
AXONFLOW_E2E_ORG_ID=<org> AXONFLOW_E2E_LICENSE_KEY=AXON-... \
AXONFLOW_E2E_JWT_SECRET=<agent JWT_SECRET> \
AXONFLOW_E2E_DB_URL='postgres://axonflow:localdev123@localhost:5432/axonflow?sslmode=disable' \
  bash runtime-e2e/user-token/test.sh
```
