# hook-failure-posture: runtime E2E

**Asserts**, by firing the plugin's real hook scripts (`scripts/pre-tool-check.sh` and `scripts/post-tool-audit.sh`) with Codex's hook JSON on stdin, against a real AxonFlow stack and against an endpoint nothing listens on, with no mocks or stubs:

1. **The platform decides.** An allowed command runs (exit 0) with no governance notice; a destructive command is blocked (exit 2, `AxonFlow policy violation` on stderr).
2. **No answer, `AXONFLOW_FAIL_MODE` unset.** The pre hook lets the tool call run (exit 0) and prints the `GOVERNANCE UNAVAILABLE` notice saying it runs ungoverned; the post hook passes the output with the notice and no alert.
3. **No answer, `AXONFLOW_FAIL_MODE=closed`.** The pre hook blocks (exit 2) naming the switch; the post hook raises the governance alert that withholds the output.
4. **The switch never loosens a decision.** A deny under `AXONFLOW_FAIL_MODE=open` is still blocked.
5. **A live 401 from the agent.** The pre hook blocks (exit 2) with the platform's words and stamps the `auth_failure` cooldown; the next call is blocked by the cooldown without a request, naming the seconds left and the stamp file; `AXONFLOW_FAIL_MODE=open` does not loosen it; the post hook raises the governance alert.

## The live 401, and its side effect

A community AxonFlow v11.0.0 agent checks no client secret: a client id it has admitted gets a decision with any secret. Its one 401 is the MCP server's answer to a client id the organization has not admitted, once the organization has admitted its service-principal ceiling (5 on the community edition): `401 -32001 "Authentication required"`, where the REST routes answer the same refusal `402 ERR_TIER_LIMIT_SERVICE_PRINCIPAL` (a platform defect: getaxonflow/axonflow-enterprise#4249, comment 5682255301).

Leg 5 therefore sends one request as this suite's own client (no credential), which keeps that client admitted, then new client ids until the MCP server refuses one: at most 5 requests. **On a community stack below its ceiling, those requests admit new client ids, and a later suite that presents a client id the organization has not yet admitted is refused.** Run it on a stack you can reset, or last.

## What this leg cannot reach

A credential the platform rejects as wrong (an Enterprise or Community SaaS stack), a request limit without the Free-tier envelope (429), a server error (5xx) and a 4xx without a decision body are not produced here: a community agent checks no secret, and nothing makes it answer 429 or 5xx on demand. Those rows are asserted against the hooks in `tests/test-hooks.sh`, through its local test server. The Free-tier limit is `free-tier-cap-deny` (a Community SaaS stack).

## Method

Codex runs each hook as a subprocess, passes the hook JSON on stdin, and blocks on exit code 2 with the reason on stderr. This leg runs the shipped scripts exactly that way, headless: it does not launch the Codex CLI.

## Run

    AXONFLOW_ENDPOINT=http://localhost:8080 bash runtime-e2e/hook-failure-posture/test.sh

`AXONFLOW_E2E_EVIDENCE_DIR` keeps each hook call's stdin, stdout, stderr and exit code (default: a new temporary directory, printed at the start). The leg skips cleanly when `curl` or `jq` is missing or the endpoint is unreachable.
