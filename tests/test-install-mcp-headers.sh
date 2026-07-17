#!/usr/bin/env bash
# Unit test for scripts/install-mcp-with-headers.sh (axonflow-enterprise#2944):
# the LIVE MCP-plane header path. Runs the installer against a temp HOME with
# a fake `codex` shim on PATH and asserts the resulting ~/.codex/config.toml:
#   1. is valid TOML (python3 tomllib),
#   2. maps "X-User-Token" → AXONFLOW_USER_TOKEN in env_http_headers
#      (alongside the pre-existing X-License-Token + Authorization mappings),
#   3. pins http_headers X-Axonflow-Client to codex-plugin/<plugin.json ver>,
#   4. is idempotent (re-run leaves exactly one of each block).
#
# Codex resolves env_http_headers itself at MCP-session time and OMITS a
# header whose env var is unset — so this mapping is byte-identical for
# unconfigured users (contract exercised live by runtime-e2e/user-token/).

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

for bin in jq python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "SKIP: $bin not on PATH"; exit 0; }
done
python3 -c 'import tomllib' 2>/dev/null || { echo "SKIP: python3 tomllib unavailable (needs 3.11+)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fake codex shim: emulates the two subcommands the installer uses.
# `codex mcp add <name> --url <url>` writes the basic [mcp_servers.<name>]
# block the way the real CLI does; `codex mcp remove` strips it.
mkdir -p "$WORK/bin" "$WORK/home/.codex"
cat > "$WORK/bin/codex" <<'SH'
#!/usr/bin/env bash
# Emulates the real CLI's semantics closely enough for the installer:
# `mcp remove <name>` drops the base [mcp_servers.<name>] section (but —
# adversarially — NOT the child header tables the installer appends; the
# installer must strip those itself for idempotency); `mcp add <name>
# --url <url>` appends a fresh base section.
CONFIG="$HOME/.codex/config.toml"
case "$1 $2" in
  "mcp remove")
    NAME="$3"
    if [ -f "$CONFIG" ]; then
      NAME="$NAME" CONFIG="$CONFIG" python3 - <<'PY'
import os, re
path = os.environ["CONFIG"]
name = re.escape(os.environ["NAME"])
text = open(path).read()
# Remove the base section only (header + keys up to the next section header).
text = re.sub(r'\n?\[mcp_servers\.' + name + r'\][^\[]*', '', text)
open(path, "w").write(text)
PY
    fi
    exit 0
    ;;
  "mcp add")
    NAME="$3"; URL="$5"
    touch "$CONFIG"
    printf '\n[mcp_servers.%s]\nurl = "%s"\n' "$NAME" "$URL" >> "$CONFIG"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "$WORK/bin/codex"

PLUGIN_VERSION="$(jq -r '.version' "$ROOT/.codex-plugin/plugin.json")"

run_installer() {
  env PATH="$WORK/bin:$PATH" HOME="$WORK/home" \
    AXONFLOW_ENDPOINT="http://agent.test:8080" \
    bash "$ROOT/scripts/install-mcp-with-headers.sh" >/dev/null 2>&1
}

echo "== install-mcp-with-headers.sh header-mapping test (#2944) =="

run_installer || { echo "  FAIL: installer exited non-zero"; exit 1; }
CONFIG="$WORK/home/.codex/config.toml"
[ -f "$CONFIG" ] || { echo "  FAIL: $CONFIG not written"; exit 1; }

# 1) Valid TOML + the three env mappings + the pinned client header.
CHECK_OUT="$(CONFIG="$CONFIG" EXPECTED_CLIENT="codex-plugin/${PLUGIN_VERSION}" python3 - <<'PY'
import os, tomllib
with open(os.environ["CONFIG"], "rb") as f:
    data = tomllib.load(f)
srv = data["mcp_servers"]["axonflow"]
envh = srv["env_http_headers"]
assert envh["X-User-Token"] == "AXONFLOW_USER_TOKEN", envh
assert envh["X-License-Token"] == "AXONFLOW_LICENSE_TOKEN", envh
assert envh["Authorization"] == "AXONFLOW_AUTH", envh
assert srv["http_headers"]["X-Axonflow-Client"] == os.environ["EXPECTED_CLIENT"], srv["http_headers"]
assert srv["url"] == "http://agent.test:8080/api/v1/mcp-server", srv["url"]
print("ok")
PY
)" || CHECK_OUT="parse-failed"
if [ "$CHECK_OUT" = "ok" ]; then
  pass "config.toml is valid TOML with X-User-Token→AXONFLOW_USER_TOKEN + existing mappings + aligned client header"
else
  fail "config.toml assertions failed: $CHECK_OUT"
  echo "---- config.toml ----"; cat "$CONFIG"; echo "---------------------"
fi

# 2) Idempotency: re-running must not duplicate the header blocks.
run_installer || fail "second installer run exited non-zero"
N_ENV_BLOCKS=$(grep -c '^\[mcp_servers\.axonflow\.env_http_headers\]' "$CONFIG" || true)
N_UT_LINES=$(grep -c '"X-User-Token" = "AXONFLOW_USER_TOKEN"' "$CONFIG" || true)
if [ "$N_ENV_BLOCKS" = "1" ] && [ "$N_UT_LINES" = "1" ]; then
  pass "re-run is idempotent (1 env_http_headers block, 1 X-User-Token mapping)"
else
  fail "re-run duplicated blocks: env_http_headers=$N_ENV_BLOCKS X-User-Token lines=$N_UT_LINES"
fi
CHECK2="$(CONFIG="$CONFIG" python3 -c 'import os,tomllib; tomllib.load(open(os.environ["CONFIG"],"rb")); print("ok")' 2>&1)" || true
[ "$CHECK2" = "ok" ] && pass "config.toml still valid TOML after re-run" \
  || fail "config.toml invalid after re-run: $CHECK2"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
