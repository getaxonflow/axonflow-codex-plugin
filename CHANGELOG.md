# Changelog

## [Unreleased]

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
