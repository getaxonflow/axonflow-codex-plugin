# Changelog

## [Unreleased]

### Added

- `AXONFLOW_TIMEOUT_SECONDS` environment variable to tune Codex hook HTTP timeouts for remote or high-latency AxonFlow deployments.

### Changed

- README now removes the old `CODEX_PLUGIN_ROOT` setup step and clarifies that the Codex plugin itself does not send direct telemetry pings.

## [0.1.0] - 2026-04-06

### Added

- Hybrid governance model: enforcement via hooks for Bash, advisory via skills for other tools
- PreToolUse hook: evaluates Bash commands against AxonFlow policies before execution (exit code 2 = block)
- PostToolUse hook: records Bash executions in audit trail and scans output for PII/secrets
- MCP server integration with 6 governance tools: `check_policy`, `check_output`, `audit_tool_call`, `list_policies`, `get_policy_stats`, `search_audit_events`
- 6 governance skills for advisory governance: pre-execute-check, post-execute-audit, pii-scan, governance-status, audit-search, policy-list
- Skills support implicit activation when task matches skill description
- Fail-open on network failure, fail-closed on auth/config errors
- Regression tests with mock MCP server (`tests/test-hooks.sh`)
- CI workflow: shellcheck, syntax check, regression tests, plugin structure validation

### Configuration

- `AXONFLOW_ENDPOINT` — AxonFlow Agent URL (default: `http://localhost:8080`)
- `AXONFLOW_AUTH` — Base64-encoded `clientId:clientSecret` for Basic auth
- `AXONFLOW_TIMEOUT_SECONDS` — optional override for hook HTTP timeouts

### Architecture

| Governance Type | Tool | Mechanism |
|---|---|---|
| Enforcement | Bash | PreToolUse hook (exit code 2 = block) |
| Advisory | Write, Edit, MCP tools | Skills instruct agent to call check_policy |
| Audit | All governed tools | PostToolUse hook (Bash) + skills (others) |
