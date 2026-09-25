#!/usr/bin/env bash
# Codex runtime E2E: explain-decision OUTCOME TEST (W2 — rule #1)
#
# Mints a real blocked decision (a destructive shell command, which the
# platform's shipped sys_dangerous_destructive_fs control blocks on
# check_policy), drives a real Codex agent through explain_decision, and asserts
# the agent's own final message names the policy that fired.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../_lib/codex-runtime.sh
source "$SCRIPT_DIR/../_lib/codex-runtime.sh"

runtime_e2e_skip_if_unavailable

trap codex_cleanup_mcp EXIT
codex_register_mcp

SEED_TAG="explain-runtime-e2e-$(date +%s)-$RANDOM"
echo "--- Triggering platform block via MCP path (same tenant codex sees) ---"

DECISION_ID=$(mcp_seed_block "$SEED_TAG")
if [ -z "$DECISION_ID" ]; then
  # Previously "SKIP:" + exit 0 (#87). That is the wrong outcome twice over:
  # a governance stack that does NOT block (and record a decision for) an
  # obvious destructive command through check_policy is a finding, and a
  # missing decision_id means explain_decision has nothing to explain. Skipping
  # here reported success for exactly the conditions this suite exists to detect.
  echo "FAIL: could not mint a blocked decision to explain"
  echo "      mcp_seed_block returned no decision_id for tag $SEED_TAG"
  echo "      endpoint: $AXONFLOW_ENDPOINT"
  echo ""
  echo "      Expected the MCP check_policy path to BLOCK the seeded destructive"
  echo "      command (the shipped sys_dangerous_destructive_fs control) and return"
  echo "      a decision_id. mcp_seed_block returns one only for a block: if the"
  echo "      command was allowed, the stack is not enforcing that control; if it"
  echo "      was blocked without a decision_id, the platform is below the floor"
  echo "      that returns one (7.1.0+). Either is a finding; neither is a reason"
  echo "      to exit 0."
  exit 1
fi
echo "--- Minted decision_id: $DECISION_ID ---"
sleep 2

PROMPT="Call the mcp__${MCP_SERVER_NAME}__explain_decision tool with decision_id=\"$DECISION_ID\". From the tool result, extract the name of the policy that matched. Output exactly the literal text SMOKE_RESULT: followed by a single-line JSON: SMOKE_RESULT: {\"explanation_present\":<true or false>,\"policy_name\":\"<the matched policy's name>\"}."

OUTPUT_FILE=$(mktemp -t axonflow-codex-explain.XXXXXX)
trap 'codex_cleanup_mcp; rm -f "$OUTPUT_FILE"' EXIT

echo "--- Running codex exec ... ---"
codex_exec_capture "$PROMPT" "$OUTPUT_FILE"

errors=0

if assert_mcp_started "$OUTPUT_FILE" "explain_decision"; then
  echo "PASS: Codex started the MCP tool call"
else
  echo "FAIL: Codex did not start the MCP tool call"
  errors=$((errors + 1))
fi

if assert_smoke_result "$OUTPUT_FILE"; then
  echo "PASS: agent emitted SMOKE_RESULT marker"
else
  echo "FAIL: agent did not emit SMOKE_RESULT marker"
  errors=$((errors + 1))
fi

# The policy explain_decision names for this block, measured on AxonFlow
# v11.0.0: policy_name "Destructive Filesystem Operations", policy_id
# "corpus:static_policies:sys__dangerous__destructive__fs".
if assert_output_contains "$OUTPUT_FILE" "Destructive Filesystem Operations" \
  || assert_output_contains "$OUTPUT_FILE" "sys__dangerous__destructive__fs"; then
  echo "PASS: agent's reply names the policy that fired — outcome verified"
else
  tail -10 "$OUTPUT_FILE" | sed 's/^/      /'
  echo "FAIL: agent did not name the policy from the explanation"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "FAIL: $errors outcome-test assertion(s) failed"
  exit 1
fi
echo ""
echo "PASS: explain-decision outcome — Codex agent fetched + surfaced a real platform decision end-to-end"
