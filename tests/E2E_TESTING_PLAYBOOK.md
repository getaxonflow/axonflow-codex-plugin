# OpenAI Codex Plugin — E2E Testing Playbook

Standard operating procedure for testing the AxonFlow Codex plugin.
Covers enforced Bash governance (hooks), advisory governance (skills), and MCP tools.

---

## Prerequisites

1. **AxonFlow running** (community or enterprise mode)
2. **Plugin cloned** to a known location
3. **OpenAI Codex CLI** installed
4. `jq` and `curl` installed

## Setup

### Option A: Use the E2E setup script (recommended)

```bash
cd /Users/saurabhjain/Development/axonflow-enterprise
COMMUNITY_REPO=/Users/saurabhjain/Development/axonflow-enterprise ./scripts/setup-e2e-testing.sh community
source /tmp/axonflow-e2e-env.sh
```

### Option B: Manual setup

```bash
docker compose up -d
curl -s http://localhost:8080/health | jq .status
export AXONFLOW_ENDPOINT=http://localhost:8080
export AXONFLOW_AUTH=""
```

### Load the plugin in Codex

Codex discovers plugins via marketplace.json files. Create one at `~/.agents/plugins/marketplace.json`:

```bash
mkdir -p ~/.agents/plugins
cat > ~/.agents/plugins/marketplace.json << 'EOF'
{
  "name": "axonflow-local",
  "plugins": [
    {
      "name": "axonflow",
      "source": {
        "source": "local",
        "path": "/Users/saurabhjain/Development/axonflow-codex-plugin"
      }
    }
  ]
}
EOF
```

Update `hooks/hooks.json` script paths to match your clone location (hooks use absolute paths since Codex doesn't provide a plugin root env var).

Then restart Codex:

```bash
codex
```

**Verify after launch:**

```
What plugins are loaded?
```

Expected: AxonFlow plugin listed alongside GitHub plugin.

---

## Governance Model

| Type | Tool | How it works |
|------|------|-------------|
| **Enforcement** | Bash | PreToolUse hook blocks (exit 2) before execution |
| **Advisory** | Write, Edit, MCP | Skills instruct agent to call check_policy (implicit activation) |
| **Audit** | All | PostToolUse hook (Bash) + skills (others) |

---

## Test Matrix

### 1. Bash enforcement (hooks — automatic)

| # | What to ask Codex | Expected behavior | What to verify |
|---|---|---|---|
| 1.1 | "Run `echo hello world`" | Allowed, audit logged | Command executes normally. |
| 1.2 | "Run `curl http://169.254.169.254/latest/meta-data/`" | Blocked by SSRF policy | PreToolUse exits 2. Codex shows block reason. |
| 1.3 | "Run `cat /home/user/.ssh/id_rsa`" | Blocked by credential access policy | Exit 2. |
| 1.4 | "Run `cat /etc/passwd`" | Blocked by path traversal policy | Exit 2. |

### 2. Advisory governance (skills — agent-driven)

| # | What to ask Codex | Expected behavior | What to verify |
|---|---|---|---|
| 2.1 | "Write a file with PII content: `Patient SSN is 123-45-6789`" | Skill activates, agent calls check_policy and/or check_output | Agent should check policy before writing. PII flagged. |
| 2.2 | "Write a file with clean content: `Hello world`" | Skill may activate, no violations found | Clean execution. |

**Note:** Advisory tests depend on agent behavior. The agent may or may not follow skill guidance. Document the actual behavior observed.

### 3. MCP tools (explicit)

| # | What to ask Codex | Expected result |
|---|---|---|
| 3.1 | "Use axonflow check_policy to check if `curl http://169.254.169.254` is allowed for connector_type `codex.Bash`" | Returns `allowed: false` with SSRF block reason |
| 3.2 | "Use axonflow check_policy to check if `echo hello` is allowed for connector_type `codex.Bash`" | Returns `allowed: true` |
| 3.3 | "Use axonflow check_output to scan: `Patient SSN is 123-45-6789` with connector_type `codex.Bash`" | Returns PII detection, redacted to `1*********9` |
| 3.4 | "Use axonflow list_policies" | Returns 80+ policies |
| 3.5 | "Use axonflow get_policy_stats" | Returns governance summary |
| 3.6 | "Use axonflow search_audit_events" | Returns recent audit entries |

### 4. Skills (explicit invocation)

| # | What to ask Codex | Expected result |
|---|---|---|
| 4.1 | "@axonflow pre-execute-check" with a Write operation | Skill guides agent to call check_policy |
| 4.2 | "@axonflow audit-search" | Skill guides agent to call search_audit_events |

### 5. Edge cases

| # | Scenario | Expected |
|---|---|---|
| 5.1 | Kill AxonFlow while plugin is connected | Bash hooks fail-open. MCP tools return errors. Skills produce no results. |
| 5.2 | Set invalid auth in enterprise mode | Bash hooks fail-closed (exit 2). MCP tools unavailable. |

---

## Automated tests (no Codex CLI needed)

### Hook regression tests

```bash
cd /Users/saurabhjain/Development/axonflow-codex-plugin
./tests/test-hooks.sh           # Mock server (offline, fast)
./tests/test-hooks.sh --live    # Live AxonFlow (requires running instance)
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Bash not blocked | `CODEX_PLUGIN_ROOT` not set | Export it before launching Codex |
| Skills not activating | Implicit activation requires matching task description | Try explicit `@axonflow` invocation |
| MCP tools not found | Auth or endpoint issue | Check `AXONFLOW_ENDPOINT` |
| Codex marketplace submission | Not yet open for self-serve | Use `@plugin-creator` for local testing |
