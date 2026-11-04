#!/usr/bin/env bash
# Install an exact marketplace archive with the real Codex CLI in an isolated home.
set -euo pipefail

archive=${1:?usage: test-marketplace-install.sh /path/to/archive.tar.gz}
test -f "$archive"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/archive" "$scratch/codex-home"
tar -xzf "$archive" -C "$scratch/archive"
test -f "$scratch/archive/.agents/plugins/marketplace.json"
test -f "$scratch/archive/plugins/axonflow/.codex-plugin/plugin.json"
export CODEX_HOME="$scratch/codex-home"

codex plugin marketplace add "$scratch/archive"
listing=$(codex plugin list --marketplace axonflow)
printf '%s\n' "$listing"
printf '%s\n' "$listing" | grep -q 'axonflow@axonflow'
codex plugin add axonflow@axonflow

installed="$CODEX_HOME/plugins/cache/axonflow/axonflow/1.10.0"
test -f "$installed/.codex-plugin/plugin.json"
test -f "$installed/.mcp.json"
test -f "$installed/hooks/hooks.json"
test -x "$installed/scripts/pre-tool-check.sh"
test -x "$installed/scripts/post-tool-audit.sh"
test -f "$installed/skills/governance-status/SKILL.md"
printf 'PASS: exact archive discovered and installed AxonFlow 1.10.0 with hooks, MCP, and skills\n'
