#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
hook_shell=${AXONFLOW_TEST_BASH:-bash}
tmp=$(mktemp -d -t axonflow-hosted-url.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/config" "$tmp/cache"
printf '#!/bin/sh\nexit 7\n' > "$tmp/bin/curl"
chmod +x "$tmp/bin/curl"
printf '%s\n' '{"tenant_id":"cs_12345678-1234-1234-1234-123456789abc","secret":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","expires_at":"2099-01-01T00:00:00Z","endpoint":"https://try.getaxonflow.com"}' > "$tmp/config/hosted-codex.json"
chmod 700 "$tmp/config"
chmod 600 "$tmp/config/hosted-codex.json"

probe() {
  local endpoint=$1 expected_exit=$2 expected_mode=$3 actual_exit
  if printf '%s\n' '{"tool_name":"exec_command","tool_input":{"command":"echo synthetic"}}' |
      env -u AXONFLOW_AUTH -u AXONFLOW_USER_TOKEN -u AXONFLOW_MCP_AUTHORIZATION \
        AXONFLOW_ENDPOINT="$endpoint" AXONFLOW_CONFIG_DIR="$tmp/config" \
        XDG_CACHE_HOME="$tmp/cache" AXONFLOW_TELEMETRY=off \
        AXONFLOW_PLUGIN_VERSION_CHECK=off PATH="$tmp/bin:$PATH" \
        "$hook_shell" "$root/scripts/pre-tool-check.sh" > "$tmp/stdout" 2> "$tmp/stderr"; then
    actual_exit=0
  else
    actual_exit=$?
  fi
  [ "$actual_exit" -eq "$expected_exit" ] || { cat "$tmp/stderr" >&2; exit 1; }
  if [ -n "$expected_mode" ]; then
    grep -q "mode=$expected_mode" "$tmp/stderr"
  else
    grep -q 'invalid Hosted endpoint URL' "$tmp/stderr"
  fi
}

probe 'https://try.getaxonflow.com/' 2 community-saas
probe 'https://try.getaxonflow.com.' 2 community-saas
probe 'https://try.getaxonflow.com:443/' 2 community-saas
probe 'https://try-staging.getaxonflow.com/' 2 community-saas
probe 'https://try.getaxonflow.com/unexpected' 2 ''
probe 'http://try.getaxonflow.com' 2 ''
probe 'https://user:pass@try.getaxonflow.com/' 2 ''
probe 'https://try.getaxonflow.com.evil.test' 0 self-hosted
printf '%s\n' 'PASS Hosted URL spellings block transport failure; lookalike remains self-hosted'
