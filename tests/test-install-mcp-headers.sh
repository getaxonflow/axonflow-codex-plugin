#!/usr/bin/env bash
# Unit test for scripts/install-mcp-with-headers.sh (axonflow-enterprise#2944):
# the LIVE MCP-plane header path. Runs the installer against a temp HOME with
# a fake `codex` shim on PATH and asserts the resulting ~/.codex/config.toml:
#   1. is valid TOML (python3 tomllib),
#   2. maps "X-User-Token" → AXONFLOW_USER_TOKEN in env_http_headers
#      (alongside X-License-Token and Authorization → AXONFLOW_MCP_AUTHORIZATION),
#   3. pins http_headers X-Axonflow-Client to codex-plugin/<plugin.json ver>,
#   4. is idempotent (re-run leaves exactly one of each block),
#   5. makes Codex send Authorization with the Basic scheme, from config.toml
#      and from .mcp.json, and prints the export line that needs (legs 4-6).
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
CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
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
  # -u CODEX_HOME: legs 1-3 exercise the $HOME default; a host CODEX_HOME
  # would redirect both the shim and the patcher elsewhere. Leg 4 sets it
  # explicitly.
  env -u CODEX_HOME PATH="$WORK/bin:$PATH" HOME="$WORK/home" \
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
assert envh["Authorization"] == "AXONFLOW_MCP_AUTHORIZATION", envh
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

# 3) CODEX_HOME override: the real codex CLI writes wherever CODEX_HOME
#    points — the patcher must edit the SAME file, and the $HOME default
#    must stay untouched (previously the patcher hardcoded ~/.codex and
#    edited a config codex never reads).
mkdir -p "$WORK/codex-home"
rm -f "$WORK/home/.codex/config.toml"
env PATH="$WORK/bin:$PATH" HOME="$WORK/home" CODEX_HOME="$WORK/codex-home" \
  AXONFLOW_ENDPOINT="http://agent.test:8080" \
  bash "$ROOT/scripts/install-mcp-with-headers.sh" >/dev/null 2>&1 \
  || fail "installer exited non-zero under CODEX_HOME"
CH_CONFIG="$WORK/codex-home/config.toml"
CHECK3="$(CONFIG="$CH_CONFIG" python3 -c '
import os, tomllib
data = tomllib.load(open(os.environ["CONFIG"], "rb"))
assert data["mcp_servers"]["axonflow"]["env_http_headers"]["X-User-Token"] == "AXONFLOW_USER_TOKEN"
print("ok")' 2>&1)" || true
if [ "$CHECK3" = "ok" ] && [ ! -f "$WORK/home/.codex/config.toml" ]; then
  pass "CODEX_HOME override: patcher edits \$CODEX_HOME/config.toml and leaves ~/.codex untouched"
else
  fail "CODEX_HOME override broken (check=$CHECK3, stray-home-config=$([ -f "$WORK/home/.codex/config.toml" ] && echo yes || echo no))"
fi

# 4) + 5) The Authorization header Codex actually SENDS carries the Basic
#    scheme. Codex builds MCP request headers in rmcp-client's
#    build_default_headers (openai/codex rust-v0.132.0,
#    codex-rs/rmcp-client/src/utils.rs:60): http_headers values verbatim;
#    env_http_headers values read verbatim from the named variable, and a
#    header whose variable is unset or blank is omitted. Nothing expands
#    ${...}. effective.py applies that rule to a header config and an
#    environment. The hooks add "Basic " themselves, so AXONFLOW_AUTH stays
#    bare base64 (README Step 3).
AUTH_B64="$(printf '%s' 'client-id:client-secret' | base64 | tr -d '\n')"
cat > "$WORK/effective.py" <<'PY'
import json, os, sys, tomllib
source, kind = sys.argv[1], sys.argv[2]
if kind == "toml":
    with open(source, "rb") as f:
        srv = tomllib.load(f)["mcp_servers"]["axonflow"]
else:
    with open(source) as f:
        srv = json.load(f)["mcpServers"]["axonflow"]
headers = {}
for name, value in (srv.get("http_headers") or {}).items():
    headers[name.lower()] = value
for name, var in (srv.get("env_http_headers") or {}).items():
    value = os.environ.get(var)
    if value is not None and value.strip():
        headers[name.lower()] = value
print(headers.get("authorization", "<absent>"))
PY
effective_auth() {  # <file> <toml|json> [VAR=value ...]: the Authorization Codex would send
  local file="$1" kind="$2"; shift 2
  env -i PATH="$PATH" "$@" python3 "$WORK/effective.py" "$file" "$kind"
}
shape() {  # describe a header value without printing it
  case "$1" in
    "<absent>") echo "no header" ;;
    "Basic $AUTH_B64") echo "Basic + the base64 of id:secret" ;;
    "Basic "*) echo "Basic + some other ${#1}-character value" ;;
    *) echo "a value with no scheme (${#1} characters)" ;;
  esac
}
install_with() {  # [VAR=value ...]: run the installer into a fresh HOME with this environment
  rm -rf "$WORK/auth-home"; mkdir -p "$WORK/auth-home/.codex"
  env -u CODEX_HOME -u AXONFLOW_AUTH -u AXONFLOW_MCP_AUTHORIZATION PATH="$WORK/bin:$PATH" HOME="$WORK/auth-home" \
    AXONFLOW_ENDPOINT="http://agent.test:8080" "$@" \
    bash "$ROOT/scripts/install-mcp-with-headers.sh" >"$WORK/install.out" 2>&1
}
README_ENV=(AXONFLOW_AUTH="$AUTH_B64" AXONFLOW_MCP_AUTHORIZATION="Basic $AUTH_B64")
AUTH_ONLY_ENV=(AXONFLOW_AUTH="$AUTH_B64")
AUTH_CONFIG="$WORK/auth-home/.codex/config.toml"

install_with "${README_ENV[@]}" || fail "installer exited non-zero (the README's environment)"
cp "$WORK/install.out" "$WORK/install-readme.out"
GOT="$(effective_auth "$AUTH_CONFIG" toml "${README_ENV[@]}")"
if [ "$GOT" = "Basic $AUTH_B64" ]; then
  pass "config.toml: with the README's exports, Codex sends Authorization: Basic <base64 of id:secret>"
else
  fail "config.toml: with the README's exports, Codex sends $(shape "$GOT")"
fi
install_with "${AUTH_ONLY_ENV[@]}" || fail "installer exited non-zero (AXONFLOW_AUTH only)"
cp "$WORK/install.out" "$WORK/install-auth-only.out"
GOT="$(effective_auth "$AUTH_CONFIG" toml "${AUTH_ONLY_ENV[@]}")"
case "$GOT" in
  "<absent>"|"Basic $AUTH_B64") pass "config.toml: with AXONFLOW_AUTH alone, Codex never sends the credential without its scheme ($(shape "$GOT"))" ;;
  *) fail "config.toml: with AXONFLOW_AUTH alone, Codex sends $(shape "$GOT")" ;;
esac

GOT="$(effective_auth "$ROOT/.mcp.json" json "${README_ENV[@]}")"
if [ "$GOT" = "Basic $AUTH_B64" ]; then
  pass ".mcp.json: with the README's exports, Codex sends Authorization: Basic <base64 of id:secret>"
else
  fail ".mcp.json: with the README's exports, Codex sends $(shape "$GOT")"
fi
GOT="$(effective_auth "$ROOT/.mcp.json" json "${AUTH_ONLY_ENV[@]}")"
case "$GOT" in
  "<absent>"|"Basic $AUTH_B64") pass ".mcp.json: with AXONFLOW_AUTH alone, Codex never sends the credential without its scheme ($(shape "$GOT"))" ;;
  *) fail ".mcp.json: with AXONFLOW_AUTH alone, Codex sends $(shape "$GOT")" ;;
esac

# 6) The installer tells a user with AXONFLOW_AUTH alone how to set the MCP
#    variable, and prints the line rather than the credential.
EXPORT_LINE='export AXONFLOW_MCP_AUTHORIZATION="Basic $AXONFLOW_AUTH"'
if grep -qF "$EXPORT_LINE" "$WORK/install-auth-only.out" && ! grep -qF "$AUTH_B64" "$WORK/install-auth-only.out"; then
  pass "installer with AXONFLOW_AUTH alone prints the AXONFLOW_MCP_AUTHORIZATION export line, not the credential"
else
  fail "installer with AXONFLOW_AUTH alone did not print the export line, or printed the credential"
fi
if ! grep -qF "AXONFLOW_MCP_AUTHORIZATION" "$WORK/install-readme.out"; then
  pass "installer with both variables set prints no export hint"
else
  fail "installer printed the export hint although AXONFLOW_MCP_AUTHORIZATION was set"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
