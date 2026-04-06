# AxonFlow Plugin for OpenAI Codex

Policy enforcement, PII detection, and audit trails for OpenAI Codex. Enforces governance on Bash tool calls via hooks, provides advisory governance for other tools via skills, and records compliance-grade audit trails.

## How It Works

**Terminal tool calls** (Bash, exec_command, shell) are governed automatically via hooks:

```
Codex selects terminal tool (Bash / exec_command / shell)
    │
    ▼
PreToolUse hook fires automatically
    │ → check_policy("codex.exec_command", "rm -rf /")
    │
    ├─ BLOCKED (exit 2) → Codex receives denial, command never runs
    │
    └─ ALLOWED (exit 0) → Command executes normally
                      │
                      ▼
                 PostToolUse hook fires automatically
                      │ → audit_tool_call(tool, input, output)
                      │ → check_output(result for PII/secrets)
```

**Other tool calls** (Write, Edit, MCP tools) are governed via advisory skills that instruct the agent to call AxonFlow MCP tools before and after execution. Skills support implicit activation — Codex invokes them automatically when the task matches the skill description.

## Prerequisites

- [AxonFlow](https://github.com/getaxonflow/axonflow) v6.0.0+ running locally (`docker compose up -d`)
- [OpenAI Codex CLI](https://developers.openai.com/codex/cli)
- `jq` and `curl` installed

## Install

```bash
git clone https://github.com/getaxonflow/axonflow-codex-plugin.git
```

## Configure

```bash
export AXONFLOW_ENDPOINT=http://localhost:8080
export AXONFLOW_AUTH=""  # empty for community mode
export CODEX_PLUGIN_ROOT=/path/to/axonflow-codex-plugin
```

### Hooks Setup

The `hooks/hooks.json` file uses relative paths (`./scripts/...`). To activate hooks, copy the file to your Codex config directory and update the paths to point to your clone location:

```bash
# Option 1: Copy and update paths to absolute
cp hooks/hooks.json ~/.codex/hooks.json
# Then edit ~/.codex/hooks.json to replace ./scripts/ with /full/path/to/axonflow-codex-plugin/scripts/

# Option 2: Symlink so Codex runs from the plugin directory
ln -sf "$(pwd)/hooks/hooks.json" ~/.codex/hooks.json
```

Load via `@plugin-creator` or the Codex plugin system when marketplace opens.

In community mode, no auth is needed.

## Governance Model

| Governance Type | Tool | Mechanism | Enforcement |
|---|---|---|---|
| **Enforcement** | Bash, exec_command, shell | PreToolUse hook | Yes — exit code 2 blocks execution |
| **Advisory** | Write, Edit, MCP tools | Skills instruct agent to call check_policy | Agent decides — skills guide but cannot force |
| **Audit** | All governed tools | PostToolUse hook (terminal) + skills (others) | Automatic for terminal tools, skill-guided for others |

## MCP Tools

| Tool | Purpose |
|------|---------|
| `check_policy` | Evaluate specific inputs against policies |
| `check_output` | Scan specific content for PII/secrets |
| `audit_tool_call` | Record additional audit entries |
| `list_policies` | List active governance policies |
| `get_policy_stats` | Get governance activity summary |
| `search_audit_events` | Search individual audit records |

## Skills

| Skill | When Used |
|-------|-----------|
| `pre-execute-check` | Before non-Bash tool calls that modify state |
| `post-execute-audit` | After non-Bash tool calls complete |
| `pii-scan` | After tool calls that return data |
| `governance-status` | When checking overall governance posture |
| `audit-search` | When searching compliance evidence |
| `policy-list` | When listing active policies |

Skills are activated implicitly when the task matches the description, or explicitly via `@axonflow`.

## What Gets Checked

AxonFlow ships with 80+ built-in system policies:

- **Dangerous commands** — destructive filesystem operations, remote code execution, credential access, cloud metadata SSRF, path traversal
- **SQL injection** — 30+ patterns including UNION injection, stacked queries, auth bypass
- **PII detection** — SSN, credit card, email, phone, Aadhaar, PAN, NRIC/FIN
- **Code security** — API keys, connection strings, hardcoded secrets
- **Prompt injection** — instruction override and context manipulation

## Plugin Structure

```
axonflow-codex-plugin/
├── .codex-plugin/
│   └── plugin.json          # Plugin metadata
├── .mcp.json                # MCP server connection (6 governance tools)
├── hooks/
│   └── hooks.json           # PreToolUse + PostToolUse for Bash
├── skills/
│   ├── pre-execute-check/   # Check policy before tool calls
│   ├── post-execute-audit/  # Record audit after tool calls
│   ├── pii-scan/            # Scan output for PII
│   ├── governance-status/   # Governance activity summary
│   ├── audit-search/        # Search audit trail
│   └── policy-list/         # List active policies
├── scripts/
│   ├── pre-tool-check.sh    # Policy evaluation (PreToolUse)
│   ├── post-tool-audit.sh   # Audit + PII scan (PostToolUse)
│   └── mcp-auth-headers.sh  # MCP auth header generation
├── tests/
│   └── test-hooks.sh        # Regression tests (mock + live)
└── .github/workflows/test.yml
```

## Links

- [AxonFlow Documentation](https://docs.getaxonflow.com)
- [Codex Integration Guide](https://docs.getaxonflow.com/docs/integration/codex/)
- [Codex Plugins](https://developers.openai.com/codex/plugins)
- [Claude Code Plugin](https://github.com/getaxonflow/axonflow-claude-plugin) — sister plugin
- [Cursor Plugin](https://github.com/getaxonflow/axonflow-cursor-plugin) — sister plugin
- [OpenClaw Plugin](https://github.com/getaxonflow/axonflow-openclaw-plugin)

## License

MIT
