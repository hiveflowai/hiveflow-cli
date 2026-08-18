#!/usr/bin/env bash
# Unit tests for mcp_list_tools / mcp_call_tool (P1.mcp-2).
#
# Exercises tool discovery and invocation against
# tests/fixtures/mcp_stub_server.sh — the same stub used by P1.mcp-1 tests,
# extended in P1.mcp-2 with `tools/list` and `tools/call` handlers.
#
# Run: bash tests/test_mcp_tools.sh

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
STUB="$SCRIPT_DIR/fixtures/mcp_stub_server.sh"

PASS=0
FAIL=0

_pass() { printf '  ok  %s\n' "$1"; PASS=$((PASS + 1)); }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        _pass "$label"
    else
        _fail "$label (expected='$expected' actual='$actual')"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        _pass "$label"
    else
        _fail "$label (needle='$needle' missing)"
    fi
}

assert_exit() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        _pass "$label"
    else
        _fail "$label (expected exit=$expected actual=$actual)"
    fi
}

chmod +x "$STUB"
export CODER_MCP_TIMEOUT=5

# shellcheck disable=SC1091
source "$REPO_DIR/lib/agent/mcp_client.sh"

echo "=== module wiring ==="
for fn in mcp_list_tools mcp_call_tool; do
    if declare -f "$fn" >/dev/null 2>&1; then
        _pass "$fn defined"
    else
        _fail "$fn defined"
    fi
done

echo
echo "=== mcp_list_tools: validation ==="
mcp_list_tools "" 2>/dev/null
assert_exit "list_tools empty name: rc 2" "2" "$?"

mcp_list_tools "ghost" 2>/dev/null
assert_exit "list_tools unknown conn: rc 2" "2" "$?"

echo
echo "=== mcp_list_tools: single-page (default stub) ==="
mcp_connect "tools_single" bash "$STUB"
assert_exit "connect tools_single: rc 0" "0" "$?"

out=$(mcp_list_tools "tools_single")
rc=$?
assert_exit "list_tools single-page: rc 0" "0" "$rc"
count=$(printf '%s' "$out" | jq -r 'length')
assert_eq "list_tools single-page: 2 tools" "2" "$count"
name_a=$(printf '%s' "$out" | jq -r '.[0].name')
name_b=$(printf '%s' "$out" | jq -r '.[1].name')
assert_eq "list_tools single-page: first name" "tool_a" "$name_a"
assert_eq "list_tools single-page: second name" "tool_b" "$name_b"
desc_a=$(printf '%s' "$out" | jq -r '.[0].description')
assert_eq "list_tools single-page: description present" "first tool" "$desc_a"
schema_type=$(printf '%s' "$out" | jq -r '.[0].inputSchema.type')
assert_eq "list_tools single-page: inputSchema preserved" "object" "$schema_type"

mcp_close "tools_single"

echo
echo "=== mcp_list_tools: paginated ==="
# Spawn the stub with MCP_STUB_PAGINATE=1 so tools/list emits two pages.
MCP_STUB_PAGINATE=1 mcp_connect "tools_paged" bash "$STUB"
assert_exit "connect tools_paged: rc 0" "0" "$?"

out=$(mcp_list_tools "tools_paged")
rc=$?
assert_exit "list_tools paginated: rc 0" "0" "$rc"
count=$(printf '%s' "$out" | jq -r 'length')
assert_eq "list_tools paginated: total 2 across pages" "2" "$count"
n0=$(printf '%s' "$out" | jq -r '.[0].name')
n1=$(printf '%s' "$out" | jq -r '.[1].name')
assert_eq "list_tools paginated: page1 first" "tool_a" "$n0"
assert_eq "list_tools paginated: page2 second" "tool_b" "$n1"

mcp_close "tools_paged"

echo
echo "=== mcp_list_tools: server error envelope ==="
MCP_STUB_TOOLS_LIST_FAIL=1 mcp_connect "tools_fail" bash "$STUB"
assert_exit "connect tools_fail: rc 0" "0" "$?"

out=$(mcp_list_tools "tools_fail" 2>&1 >/dev/null)
rc=$?
assert_exit "list_tools server error: rc 1" "1" "$rc"
assert_contains "list_tools server error: stderr msg" "tools listing disabled" "$out"

mcp_close "tools_fail"

echo
echo "=== mcp_call_tool: validation ==="
mcp_call_tool "" "x" 2>/dev/null
assert_exit "call_tool empty name: rc 2" "2" "$?"

mcp_call_tool "anything" "" 2>/dev/null
assert_exit "call_tool empty tool: rc 2" "2" "$?"

mcp_call_tool "ghost" "x" 2>/dev/null
assert_exit "call_tool unknown conn: rc 2" "2" "$?"

mcp_connect "call_validation" bash "$STUB"
assert_exit "connect call_validation: rc 0" "0" "$?"

mcp_call_tool "call_validation" "x" "not json" 2>/dev/null
assert_exit "call_tool non-json input: rc 2" "2" "$?"

mcp_call_tool "call_validation" "x" "[]" 2>/dev/null
assert_exit "call_tool non-object input: rc 2" "2" "$?"

mcp_close "call_validation"

echo
echo "=== mcp_call_tool: happy path ==="
mcp_connect "call_ok" bash "$STUB"
assert_exit "connect call_ok: rc 0" "0" "$?"

out=$(mcp_call_tool "call_ok" "tool_a" '{"x":1}')
rc=$?
assert_exit "call_tool happy: rc 0" "0" "$rc"
type0=$(printf '%s' "$out" | jq -r '.[0].type')
text0=$(printf '%s' "$out" | jq -r '.[0].text')
assert_eq "call_tool happy: content type text" "text" "$type0"
assert_contains "call_tool happy: text contains tool name" "tool_a" "$text0"
assert_contains "call_tool happy: text contains args" '"x":1' "$text0"

# Default input: omitted arg should become {}.
out=$(mcp_call_tool "call_ok" "tool_a")
rc=$?
assert_exit "call_tool default input: rc 0" "0" "$rc"
text_default=$(printf '%s' "$out" | jq -r '.[0].text')
assert_contains "call_tool default input: text contains {}" "{}" "$text_default"

# Empty-string input is also treated as default.
out=$(mcp_call_tool "call_ok" "tool_a" "")
rc=$?
assert_exit "call_tool empty-string input: rc 0" "0" "$rc"
text_empty=$(printf '%s' "$out" | jq -r '.[0].text')
assert_contains "call_tool empty-string input: text contains {}" "{}" "$text_empty"

mcp_close "call_ok"

echo
echo "=== mcp_call_tool: tool isError=true ==="
mcp_connect "call_err" bash "$STUB"
assert_exit "connect call_err: rc 0" "0" "$?"

out=$(mcp_call_tool "call_err" "error_tool" '{}')
rc=$?
assert_exit "call_tool isError: rc 1" "1" "$rc"
# Content is still emitted on stdout so the caller can show it to the LLM.
text_err=$(printf '%s' "$out" | jq -r '.[0].text')
assert_eq "call_tool isError: content emitted" "tool reported failure" "$text_err"

mcp_close "call_err"

echo
echo "=== mcp_call_tool: server JSON-RPC error envelope ==="
mcp_connect "call_srv_err" bash "$STUB"
assert_exit "connect call_srv_err: rc 0" "0" "$?"

out=$(mcp_call_tool "call_srv_err" "server_error" '{}' 2>&1 >/dev/null)
rc=$?
assert_exit "call_tool server error: rc 1" "1" "$rc"
assert_contains "call_tool server error: stderr msg" "Invalid params" "$out"
assert_contains "call_tool server error: stderr names tool" "server_error" "$out"

mcp_close "call_srv_err"

echo
echo "=== mcp_call_tool: arguments threaded to server ==="
mcp_connect "call_args" bash "$STUB"
assert_exit "connect call_args: rc 0" "0" "$?"

# Use a non-trivial input with nested object + special chars.
out=$(mcp_call_tool "call_args" "tool_b" '{"q":"hello \"world\"","n":42,"sub":{"a":1}}')
rc=$?
assert_exit "call_tool nested args: rc 0" "0" "$rc"
text_nested=$(printf '%s' "$out" | jq -r '.[0].text')
assert_contains "call_tool nested args: arg q preserved" 'hello \"world\"' "$text_nested"
assert_contains "call_tool nested args: arg n preserved" '"n":42' "$text_nested"
assert_contains "call_tool nested args: nested arg preserved" '"a":1' "$text_nested"

mcp_close "call_args"

echo
echo "=========================================="
echo "Resultado: $PASS pass, $FAIL fail"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
