# Changelog

## [Unreleased]

### Changed

- `DO_NOT_TRACK=1` is no longer treated as a telemetry opt-out in this plugin because the host CLI injects it into hook subprocesses regardless of user intent. Use `AXONFLOW_TELEMETRY=off` to opt out.

### Fixed

- Telemetry ping now actually fires once per install on Codex. The previous behavior silently exited at the `DO_NOT_TRACK=1` check (injected by Codex), so the install ping never reached the stamp-file guard.
- The deprecation warning no longer leaks to stderr on every `PreToolUse` hook invocation. Removing the warning emit also removes the visible noise that was getting concatenated with `AxonFlow policy violation` messages on blocked commands.


## [0.4.2] - 2026-04-22

### Deprecated

- `DO_NOT_TRACK=1` as an AxonFlow telemetry opt-out — scheduled for removal after 2026-05-05 in the next major release. Use `AXONFLOW_TELEMETRY=off` instead. The plugin's `telemetry-ping.sh` emits a one-time stderr warning when `DO_NOT_TRACK=1` is the active control and `AXONFLOW_TELEMETRY=off` is not also set.

## [0.4.1] - 2026-04-19

### Added

- **Smoke E2E scenario** at `tests/e2e/smoke-block-context.sh` — runs
  `pre-tool-check.sh` against a reachable AxonFlow stack and asserts the
  hook exits 2 with `AxonFlow policy violation` + Plugin Batch 1
  richer-context markers on stderr. Exits 0 (`SKIP:`) when no stack is
  reachable.
- **`.github/workflows/smoke-e2e.yml`** — `workflow_dispatch` triggered job running the smoke scenario.
  Requires an operator-supplied endpoint (GitHub-hosted runners have no
  local stack), so not wired to PR events — PR smoke gating needs a
  self-hosted runner with a live stack.

Full install-and-use matrix lives in `axonflow-enterprise/tests/e2e/plugin-batch-1/codex-install/`.

## [0.4.0] - 2026-04-18

### Added

- **Richer block reason surfaced to Codex on exec_command blocks.** When
  the AxonFlow platform is v7.1.0+, the stderr message accompanying the
  `exit 2` block now includes `[decision: <id>, risk: <level>, active
  override: <ov>]` or a pointer to the `explain_decision` MCP tool. Older
  platforms see the prior v0.3.0 message — fields are omitted when not
  returned.
- **Access to platform MCP tools** `explain_decision`, `create_override`,
  `delete_override`, `list_overrides` — available via the agent's MCP
  server when connected to a v7.1.0+ platform. Codex's existing `audit-search`
  skill pattern applies analogously for these new tools.

### Compatibility

Companion to platform v7.1.0 and SDKs v5.4.0 / v6.4.0. Back-compatible.

## [0.3.0] - 2026-04-16

### Added

- **Anonymous telemetry ping** on first hook invocation. Sends plugin version, OS, architecture, bash version, and AxonFlow platform version to `checkpoint.getaxonflow.com`. No PII, no tool arguments, no policy data. Fires once per install (stamp file guard at `$HOME/.cache/axonflow/codex-plugin-telemetry-sent`). Opt out with `DO_NOT_TRACK=1` or `AXONFLOW_TELEMETRY=off`.
- **`marketplace.json`** — marketplace metadata file for plugin distribution readiness.

### Fixed

- **UTF-8 safe content truncation.** Write and Edit content extraction now uses character-level `cut -c1-2000` instead of byte-level `head -c 2000`. Prevents splitting multi-byte UTF-8 sequences at the truncation boundary.
- **Consistent curl error reporting.** `post-tool-audit.sh` now uses `-sS` (silent + show errors) matching `pre-tool-check.sh`.
- **Corrected "Cursor" references in comments** — 5 copy-paste errors from the Cursor plugin that referenced "Cursor" instead of "Codex" in pre-tool-check.sh, post-tool-audit.sh, and mcp-auth-headers.sh.

### Changed

- **Hook timeout increased from 10s to 15s.** Provides sufficient buffer above the 8s default curl timeout for bash overhead and telemetry.

### Security

- Updated SECURITY.md timestamp to April 2026.

## [0.2.1] - 2026-04-10

### Added

- **Decision-matrix regression tests** for the v0.2.0 hook fail-open/fail-closed behavior. The v0.2.0 release only added a single stderr-string assertion update; the 5 new branches introduced (curl timeout, empty body, -32603, -32700, -32601, -32602, unknown code) were completely untested. This release adds mock-server cases for every branch so the decision matrix is now covered end-to-end.

## [0.2.0] - 2026-04-08

### Changed

- **Hook fail-open/fail-closed hardening.** `scripts/pre-tool-check.sh` now distinguishes curl exit code (network failure) from HTTP success with an error body. Fail-closed (exit 2, block tool) only on operator-fixable JSON-RPC errors: auth failures (-32001), method-not-found (-32601), and invalid-params (-32602). Fail-open (exit 0, allow) on everything else: curl timeouts/DNS failures/connection refused, empty response, server-internal errors (-32603), parse errors (-32700), and unknown error codes. Prevents transient governance infrastructure issues from blocking legitimate dev workflows while still catching broken configurations.

### Added

- **`scripts/uninstall.sh` cleanup helper.** Codex CLI's built-in `/plugins` uninstall only removes the registration from `~/.codex/config.toml` and leaves the local-source plugin cache directory on disk. The new helper cleans up `~/.codex/plugins/cache/axonflow-local/`, `~/.codex/plugins/cache/axonflow-codex-plugin/`, and `~/.codex/plugins/installed/axonflow-codex-plugin/`. Supports `--dry-run`. Surfaces but does not modify `~/.codex/config.toml` or `~/.codex/hooks.json` (user-owned configuration).

### Security

- Pinned all GitHub Actions to immutable commit SHAs to prevent supply chain attacks.
- Added Dependabot configuration for weekly GitHub Actions updates.

## [0.1.0] - 2026-04-06

### Added

- `AXONFLOW_TIMEOUT_SECONDS` environment variable to tune Codex hook HTTP timeouts for remote or high-latency AxonFlow deployments.
- Plugin logo for marketplace and directory listings.
- `SECURITY.md` with plugin-specific vulnerability reporting guidance.
- Hybrid governance model: enforcement via hooks for terminal tool calls (`Bash`, `exec_command`, `shell`), advisory via skills for other tools
- PreToolUse hook: evaluates terminal tool calls (`Bash`, `exec_command`, `shell`) against AxonFlow policies before execution (exit code 2 = block)
- PostToolUse hook: records terminal tool executions in the audit trail and scans output for PII/secrets
- MCP server integration with 6 governance tools: `check_policy`, `check_output`, `audit_tool_call`, `list_policies`, `get_policy_stats`, `search_audit_events`
- 6 governance skills for advisory governance: pre-execute-check, post-execute-audit, pii-scan, governance-status, audit-search, policy-list
- Skills support implicit activation when task matches skill description
- PII write detection via improved skill descriptions — skills instruct agent to call `check_output` before file writes
- Fail-open on network failure, fail-closed on auth/config errors
- Regression tests with mock MCP server (`tests/test-hooks.sh`, 22 tests)
- CI workflow: shellcheck, syntax check, regression tests, plugin structure validation
- E2E testing playbook with 10 verified tests

### Changed

- README now removes the old `CODEX_PLUGIN_ROOT` setup step and clarifies that the Codex plugin itself does not send direct telemetry pings.

### Configuration

- `AXONFLOW_ENDPOINT` — AxonFlow Agent URL (default: `http://localhost:8080`)
- `AXONFLOW_AUTH` — Base64-encoded `clientId:clientSecret` for Basic auth
- `AXONFLOW_TIMEOUT_SECONDS` — optional override for hook HTTP timeouts
- MCP server configured in `~/.codex/config.toml` (TOML format, not `.mcp.json`)
- Hooks placed at `~/.codex/hooks.json` (not inside the plugin directory)
- Hooks feature must be enabled: `[features] codex_hooks = true` in `config.toml`
- Plugin discovered via `$CWD/.agents/plugins/marketplace.json`, installed via `/plugins`

### Architecture

| Governance Type | Tool | Mechanism |
|---|---|---|
| Enforcement | `Bash`, `exec_command`, `shell` | PreToolUse hook (exit code 2 = block) |
| Advisory | Write, Edit, MCP tools | Skills instruct agent to call `check_policy` |
| Audit | All governed tools | PostToolUse hook for terminal tools + skills for others |
