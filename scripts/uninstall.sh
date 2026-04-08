#!/usr/bin/env bash
# AxonFlow Codex plugin uninstall helper.
#
# Codex CLI's built-in `/plugins` uninstall only removes the registration
# from ~/.codex/config.toml and leaves the local-source plugin directory
# on disk. This helper cleans up the leftover:
#
#   - ~/.codex/plugins/cache/axonflow-local/        (cache from local source)
#   - ~/.codex/plugins/installed/axonflow-codex-plugin/ (if installed via marketplace)
#
# It does NOT remove ~/.codex/config.toml entries — run `/plugins` uninstall
# inside Codex CLI first. This script is the second half of the cleanup.
#
# Usage:
#   ./scripts/uninstall.sh
#   ./scripts/uninstall.sh --dry-run

set -euo pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
fi

remove_if_exists() {
    local path="$1"
    if [ -e "$path" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            echo "[DRY RUN] Would remove: $path"
        else
            rm -rf "$path"
            echo "Removed: $path"
        fi
    fi
}

echo "AxonFlow Codex plugin cleanup"
echo "============================="
echo

remove_if_exists "$HOME/.codex/plugins/cache/axonflow-local"
remove_if_exists "$HOME/.codex/plugins/cache/axonflow-codex-plugin"
remove_if_exists "$HOME/.codex/plugins/installed/axonflow-codex-plugin"

# Also strip AxonFlow entries from hooks.json if present.
HOOKS_FILE="$HOME/.codex/hooks.json"
if [ -f "$HOOKS_FILE" ] && grep -q "axonflow" "$HOOKS_FILE" 2>/dev/null; then
    if [ "$DRY_RUN" = "1" ]; then
        echo "[DRY RUN] Would prune AxonFlow entries from $HOOKS_FILE"
    else
        echo "Found AxonFlow entries in $HOOKS_FILE — edit manually to remove"
        echo "  (diff preview: grep -i axonflow $HOOKS_FILE)"
    fi
fi

# Also strip AxonFlow MCP server from config.toml if present.
CONFIG_FILE="$HOME/.codex/config.toml"
if [ -f "$CONFIG_FILE" ] && grep -qi "axonflow" "$CONFIG_FILE" 2>/dev/null; then
    if [ "$DRY_RUN" = "1" ]; then
        echo "[DRY RUN] Would report AxonFlow references in $CONFIG_FILE"
    else
        echo "Found AxonFlow references in $CONFIG_FILE — run '/plugins uninstall' in Codex CLI first"
        echo "  (diff preview: grep -i axonflow $CONFIG_FILE)"
    fi
fi

echo
echo "Done. Restart Codex CLI to complete the uninstall."
