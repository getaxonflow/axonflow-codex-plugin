# revoke-override — runtime E2E

**Asserts:** Drives the runtime to dispatch delete_override (server-side name) with a fabricated override_id; platform returns 404 and agent surfaces it.

**Prereqs:** runtime CLI on PATH and authenticated; `jq`; live AxonFlow stack reachable at `$AXONFLOW_ENDPOINT` (default `http://localhost:8080`).

**Required deployment posture:** the override endpoints are scoped to an individual user, so a per-user identity must reach the platform. On a default deployment it does not: `AXONFLOW_TRUST_IDENTITY_HEADERS` defaults to **off** (since 9.9.0), so the override seed fails and this test **fails** with the remediation printed (it used to skip silently and report green — #3062).

```bash
AXONFLOW_TRUST_IDENTITY_HEADERS=true   # on the AGENT, then restart it
```

Only enable it when every hop that can reach the agent asserts end-user identity from a validated source — see `docs/security/identity-header-trust.md` in axonflow-enterprise.

**Run:**
```bash
AXONFLOW_ENDPOINT=http://localhost:8080 \
  bash runtime-e2e/revoke-override/test.sh
```
