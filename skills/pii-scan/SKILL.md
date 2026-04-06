---
name: pii-scan
description: Scan tool output for PII and secrets before including in responses. Use after tool calls that return data.
---

After tool calls that return data (database queries, file reads, API responses), call the `check_output` MCP tool with:

- `connector_type`: the tool type (e.g., `codex.Bash`, `codex.mcp__postgres`)
- `message`: the text content to scan

If the response includes a `redacted_message`, use the redacted version in your response instead of the original.

If the response shows `allowed: false`, do not include the output in your response.

Note: For Bash tool calls, PII scanning is handled automatically by the PostToolUse hook. Use this skill for other tool types.
