---
name: pre-execute-check
description: Check AxonFlow governance policy before executing commands or modifying files. Use before any tool call that modifies state.
---

Before using tools that modify state (terminal commands, file writes, file edits, MCP operations), call the `check_policy` MCP tool with:

- `connector_type`: `codex.Bash` (for commands), `codex.Write` (for file writes), or the appropriate tool type
- `statement`: the command or content to check
- `operation`: `execute`

If the response shows `allowed: false`, do NOT proceed with the tool call. Report the block reason to the user.

If the response shows `allowed: true`, proceed normally.

This check takes 2-5ms and protects against dangerous commands, SQL injection, credential access, SSRF, and path traversal.
