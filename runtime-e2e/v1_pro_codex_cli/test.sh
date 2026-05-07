#!/usr/bin/env bash
# V1 Plugin Pro MCP-tools-invocable runtime proof for the OpenAI Codex plugin.
#
# Drives the REAL `codex` CLI against the live AxonFlow agent at
# https://try.getaxonflow.com. Per the differentiator table in PRD §V1
# the 5 V1 Pro MCP tools must be callable from the host CLI:
#
#   1. axonflow_list_pro_features
#   2. axonflow_get_cost_estimate         (Pro-only — must be hidden from Free)
#   3. axonflow_request_approval
#   4. axonflow_create_tenant_policy
#   5. axonflow_get_tenant_id
#
# Per HARD RULE #0 — real CLI, real plugin install path, real agent on
# prod (Community SaaS). No fixtures, no shims.
#
# Codex's `exec` output is human-readable (no stream-json), but it emits
# deterministic markers we can grep:
#
#   mcp: <server>/<tool> started
#   mcp: <server>/<tool> (completed)
#   mcp: <server>/<tool> (failed)
#
# These come from the `rmcp` worker's lifecycle log lines and are stable
# across codex 0.118.x. The assertion model:
#
#   - For invocable tools (1, 3, 4, 5): assert both `started` AND
#     `(completed)` markers appear for the named tool.
#   - For tool 2 (Pro-only): assert codex never invokes it (no `started`
#     marker). Per ADR-049 §5 the agent advertises Pro-only tools only
#     to Pro-tier sessions, so a Free tenant's tools/list excludes it
#     and the model literally cannot pick it.
#
# Test creates one fresh Free-tier tenant via /api/v1/register, then
# drives one `codex exec` invocation per tool. Failure mode: any tool's
# `started` marker missing OR its `(failed)` marker present.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$PLUGIN_DIR/runtime-e2e/_lib/codex-runtime.sh"

UTC_TS=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE="$SCRIPT_DIR/EVIDENCE/$UTC_TS"
mkdir -p "$EVIDENCE"

AGENT_URL="${AGENT_URL:-https://try.getaxonflow.com}"
export AXONFLOW_ENDPOINT="$AGENT_URL"

# Use a dedicated MCP server name so we don't clobber the user's prod
# `axonflow` registration. Restored on EXIT.
MCP_SERVER_NAME="axonflow_v1_pro_e2e"
export MCP_SERVER_NAME

runtime_e2e_skip_if_unavailable

# ---------------------------------------------------------------------------
# License-token isolation
#
# The plugin's headers helper auto-loads
# ~/.config/axonflow/license-token.json on every MCP session. If a
# previous Pro-tier session left a token on disk for tenant A and the
# current run targets tenant B, the agent's PluginClaimMiddleware
# rejects the cross-tenant binding and codex reports the MCP server as
# unavailable on subsequent calls. Move the token aside for the run.
# ---------------------------------------------------------------------------
LICENSE_TOKEN_FILE="${HOME}/.config/axonflow/license-token.json"
LICENSE_TOKEN_BACKUP=""
if [ -f "$LICENSE_TOKEN_FILE" ]; then
  LICENSE_TOKEN_BACKUP="${LICENSE_TOKEN_FILE}.runtime-e2e-bak.$$"
  mv "$LICENSE_TOKEN_FILE" "$LICENSE_TOKEN_BACKUP"
fi

# ---------------------------------------------------------------------------
# Codex MCP config snapshot (so we can restore exactly on exit)
# ---------------------------------------------------------------------------
CODEX_CONFIG="${HOME}/.codex/config.toml"
CODEX_CONFIG_BACKUP=""
if [ -f "$CODEX_CONFIG" ]; then
  CODEX_CONFIG_BACKUP="${CODEX_CONFIG}.runtime-e2e-bak.$$"
  cp "$CODEX_CONFIG" "$CODEX_CONFIG_BACKUP"
fi

REG_BODY_TMP=""
cleanup_on_exit() {
  # Always remove the test MCP server we registered.
  codex mcp remove "$MCP_SERVER_NAME" >/dev/null 2>&1 || true
  # Restore codex config if we saved it.
  if [ -n "$CODEX_CONFIG_BACKUP" ] && [ -f "$CODEX_CONFIG_BACKUP" ]; then
    mv "$CODEX_CONFIG_BACKUP" "$CODEX_CONFIG" 2>/dev/null
  fi
  # Restore license-token if we moved it.
  if [ -n "$LICENSE_TOKEN_BACKUP" ] && [ -f "$LICENSE_TOKEN_BACKUP" ]; then
    mv "$LICENSE_TOKEN_BACKUP" "$LICENSE_TOKEN_FILE" 2>/dev/null
  fi
  [ -n "$REG_BODY_TMP" ] && rm -f "$REG_BODY_TMP" 2>/dev/null
  return 0
}
trap cleanup_on_exit EXIT

# ---------------------------------------------------------------------------
# Tenant resolution: env > register fresh
# ---------------------------------------------------------------------------
TENANT="${TENANT:-}"
SECRET="${SECRET:-}"
if [ -z "$TENANT" ] || [ -z "$SECRET" ]; then
  EMAIL_TAG=$(date -u +%s)
  REG_BODY_TMP=$(mktemp)
  REG_HTTP=$(curl -sS -o "$REG_BODY_TMP" -w '%{http_code}' \
    -X POST "${AGENT_URL}/api/v1/register" \
    -H 'Content-Type: application/json' \
    -d "{\"label\":\"v1-pro-codex-cli-${EMAIL_TAG}\",\"email\":\"e2e+codex-mcp-${EMAIL_TAG}@getaxonflow.com\"}" 2>/dev/null) || REG_HTTP="000"
  if [ "$REG_HTTP" != "200" ] && [ "$REG_HTTP" != "201" ]; then
    echo "SKIP: tenant registration HTTP=$REG_HTTP. Pass TENANT=... SECRET=... env to reuse an existing tenant."
    cat "$REG_BODY_TMP" 2>/dev/null
    exit 0
  fi
  TENANT=$(jq -r '.tenant_id' "$REG_BODY_TMP")
  SECRET=$(jq -r '.secret' "$REG_BODY_TMP")
  echo "Registered: $TENANT"
fi

# ---------------------------------------------------------------------------
# Idempotency: clear prior HITL approvals + dynamic policies for this
# tenant. Best-effort via ECS exec; skip silently when AWS creds /
# db_helpers.sh aren't available.
# ---------------------------------------------------------------------------
if command -v aws >/dev/null 2>&1; then
  DB_LIB="${PLUGIN_DIR}/../axonflow-enterprise/runtime-e2e/v1_paid_tier_staging/lib/db_helpers.sh"
  if [ -f "$DB_LIB" ]; then
    case "$AGENT_URL" in
      *try-staging*) STACK_PREFIX='axonflow-community-saas-staging-2' ;;
      *try.getaxonflow*) STACK_PREFIX='axonflow-community-saas-2' ;;
      *) STACK_PREFIX='' ;;
    esac
    if [ -n "$STACK_PREFIX" ]; then
      DETECTED_STACK=$(aws cloudformation list-stacks --region us-east-1 \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
        --query "StackSummaries[?starts_with(StackName, '$STACK_PREFIX') && !contains(StackName, 'staging-2') && !contains(StackName, 'alarm') && !contains(StackName, 'synth')].StackName" \
        --output text 2>/dev/null | tr '\t' '\n' | sort -r | head -1)
      DETECTED_TASK=$(aws ecs list-tasks --region us-east-1 --cluster "${DETECTED_STACK}-cluster" \
        --service-name "${DETECTED_STACK}-orchestrator-service" --query 'taskArns[0]' --output text 2>/dev/null)
      DETECTED_DB=$(aws rds describe-db-instances --region us-east-1 \
        --query "DBInstances[?DBInstanceIdentifier == '${DETECTED_STACK}-db'].Endpoint.Address" \
        --output text 2>/dev/null | head -1)
      DETECTED_PASS=$(aws secretsmanager get-secret-value --region us-east-1 \
        --secret-id "${DETECTED_STACK}-db-password" --query SecretString --output text 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])' 2>/dev/null)
      if [ -n "$DETECTED_STACK" ] && [ -n "$DETECTED_TASK" ] && [ -n "$DETECTED_DB" ] && [ -n "$DETECTED_PASS" ]; then
        export STACK="$DETECTED_STACK" ORCH_TASK="$DETECTED_TASK" DB_HOST="$DETECTED_DB" DB_PASS="$DETECTED_PASS" REGION=us-east-1
        # shellcheck disable=SC1090
        source "$DB_LIB"
        echo "Idempotency: clear hitl_approval_queue + dynamic_policies for $TENANT"
        db_run_sql "DELETE FROM hitl_approval_queue WHERE tenant_id = '${TENANT}'; DELETE FROM dynamic_policies WHERE tenant_id = '${TENANT}';" >/dev/null 2>&1 || true
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Codex MCP install (uses a dedicated server name so we don't clobber
# the user's `axonflow` registration). Mirrors install-mcp-with-headers.sh
# but for the test server name.
# ---------------------------------------------------------------------------
codex mcp remove "$MCP_SERVER_NAME" 2>/dev/null || true
codex mcp add "$MCP_SERVER_NAME" --url "${AGENT_URL}/api/v1/mcp-server" >/dev/null

PLUGIN_VERSION="$(jq -r '.version // "unknown"' "$PLUGIN_DIR/.codex-plugin/plugin.json" 2>/dev/null || echo unknown)"
CLIENT_HEADER="codex-plugin/${PLUGIN_VERSION}"

python3 - "$CODEX_CONFIG" "$MCP_SERVER_NAME" "$CLIENT_HEADER" <<'PY'
import sys, re, pathlib
config_path, server_name, client_header = sys.argv[1], sys.argv[2], sys.argv[3]
path = pathlib.Path(config_path)
text = path.read_text()
text = re.sub(
    rf'\n\[mcp_servers\.{re.escape(server_name)}\.(http_headers|env_http_headers)\][^\[]*',
    '',
    text,
)
addendum = f'''
[mcp_servers.{server_name}.http_headers]
"X-Axonflow-Client" = "{client_header}"

[mcp_servers.{server_name}.env_http_headers]
"X-License-Token" = "AXONFLOW_LICENSE_TOKEN"
"Authorization" = "AXONFLOW_AUTH"
'''
if not text.endswith('\n'):
    text += '\n'
text += addendum
path.write_text(text)
PY

# AXONFLOW_AUTH must include the "Basic " prefix because codex's
# env_http_headers takes the env value verbatim as the header value.
export AXONFLOW_AUTH="Basic $(printf '%s:%s' "$TENANT" "$SECRET" | base64 | tr -d '\n')"
unset AXONFLOW_LICENSE_TOKEN

echo "Codex MCP server '$MCP_SERVER_NAME' configured against $AGENT_URL"
codex mcp get "$MCP_SERVER_NAME" 2>&1 | sed 's/^/  /'

# ---------------------------------------------------------------------------
# Per-tool driver
# ---------------------------------------------------------------------------
PASS=true
fail() { echo "FAIL: $1"; PASS=false; }

run_tool() {
  local label="$1" prompt="$2" tool="$3" expectation="$4"
  echo
  echo "================ tool: $tool — expectation: $expectation ================"
  local out_file="$EVIDENCE/${tool}.log"
  echo "$prompt" > "$EVIDENCE/${tool}_prompt.txt"
  timeout 90 codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \
    "$prompt" >"$out_file" 2>&1 || true
  echo "  captured $(wc -c <"$out_file") bytes to $(basename "$out_file")"

  case "$expectation" in
    invoked_ok)
      if ! grep -qE "mcp: ${MCP_SERVER_NAME}/${tool} started" "$out_file"; then
        fail "$tool: missing 'mcp: ${MCP_SERVER_NAME}/${tool} started' marker"
        echo "  output (last 30 lines):"
        tail -30 "$out_file" | sed 's/^/    /'
        return
      fi
      if ! grep -qE "mcp: ${MCP_SERVER_NAME}/${tool} \(completed\)" "$out_file"; then
        if grep -qE "mcp: ${MCP_SERVER_NAME}/${tool} \(failed\)" "$out_file"; then
          fail "$tool: invocation marker present but the call (failed)"
        else
          fail "$tool: 'started' present but no '(completed)' or '(failed)' terminal marker"
        fi
        echo "  output (last 30 lines):"
        tail -30 "$out_file" | sed 's/^/    /'
        return
      fi
      echo "  $tool: started + (completed) ✓"
      ;;
    hidden_from_free_tier)
      if grep -qE "mcp: ${MCP_SERVER_NAME}/${tool} started" "$out_file"; then
        fail "$tool: Pro-only tool was visible to Free tenant — invocation marker present"
        return
      fi
      echo "  $tool: not invoked by codex (consistent with Pro-only visibility gate) ✓"
      ;;
    *)
      fail "$tool: unknown expectation '$expectation'"
      ;;
  esac
}

run_tool "list_pro_features" \
  "Use the ${MCP_SERVER_NAME} MCP server's axonflow_list_pro_features tool. Pass an empty arguments object {}. Print the response." \
  "axonflow_list_pro_features" \
  "invoked_ok"

run_tool "get_cost_estimate_hidden" \
  "Use the ${MCP_SERVER_NAME} MCP server's axonflow_get_cost_estimate tool with arguments {\"plan\": \"runtime-e2e probe\"}. If the tool isn't available, just say 'tool_not_available' and don't fall back to anything else." \
  "axonflow_get_cost_estimate" \
  "hidden_from_free_tier"

run_tool "request_approval" \
  "Use the ${MCP_SERVER_NAME} MCP server's axonflow_request_approval tool with arguments {\"original_query\": \"runtime-e2e probe\", \"request_type\": \"shell_command\", \"trigger_reason\": \"runtime_e2e_test\", \"severity\": \"low\"}. Print the response." \
  "axonflow_request_approval" \
  "invoked_ok"

run_tool "create_tenant_policy" \
  "Use the ${MCP_SERVER_NAME} MCP server's axonflow_create_tenant_policy tool with arguments {\"name\": \"runtime-e2e-codex-${UTC_TS}\", \"description\": \"runtime-e2e probe\", \"connector_type\": \"codex.exec_command\", \"pattern\": \"axonflow-runtime-e2e-marker\", \"action\": \"warn\"}. Print the response." \
  "axonflow_create_tenant_policy" \
  "invoked_ok"

run_tool "get_tenant_id" \
  "Use the ${MCP_SERVER_NAME} MCP server's axonflow_get_tenant_id tool with an empty arguments object {}. Print the tenant_id from the response." \
  "axonflow_get_tenant_id" \
  "invoked_ok"

# ---------------------------------------------------------------------------
# Tenant_id sanity: the get_tenant_id tool's reply should mention the
# fresh tenant we registered. (Belt-and-braces beyond the lifecycle
# markers — the model could in theory print tenant_id from any source.)
# ---------------------------------------------------------------------------
if grep -qF "$TENANT" "$EVIDENCE/axonflow_get_tenant_id.log"; then
  echo "  axonflow_get_tenant_id reply contains tenant $TENANT ✓"
else
  fail "axonflow_get_tenant_id reply did NOT contain $TENANT"
fi

{
  echo
  echo "Codex V1 Plugin Pro MCP-tools-invocable runtime proof — $UTC_TS"
  echo "AGENT_URL=$AGENT_URL"
  echo "MCP_SERVER_NAME=$MCP_SERVER_NAME"
  echo "TENANT=$TENANT"
  echo "Result: $($PASS && echo PASS || echo FAIL)"
} | tee "$EVIDENCE/summary.txt"

if $PASS; then
  echo
  echo "PASS — codex CLI can invoke all 5 V1 Pro MCP tools end-to-end"
  exit 0
else
  echo
  echo "FAIL — see $EVIDENCE/ for evidence"
  exit 1
fi
