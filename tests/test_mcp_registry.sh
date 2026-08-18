#!/usr/bin/env bash
# Unit tests for MCP registry integration (P1.mcp-3).
#
# Exercises auto-registration of MCP tools as agentic proxy tools in
# REGISTERED_TOOLS, definition translation (Anthropic-style), handler dispatch
# back through mcp_call_tool, and unregistration. All offline against
# tests/fixtures/mcp_stub_server.sh.
#
# Run: bash tests/test_mcp_registry.sh

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

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        _pass "$label"
    else
        _fail "$label (needle='$needle' should be absent)"
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

# Helper: returns 0 if $1 ∈ REGISTERED_TOOLS, 1 otherwise.
in_registry() {
    local needle="$1" t
    [ "${#REGISTERED_TOOLS[@]}" -gt 0 ] || return 1
    for t in "${REGISTERED_TOOLS[@]}"; do
        [ "$t" = "$needle" ] && return 0
    done
    return 1
}

# Helper: reset REGISTERED_TOOLS + proxy state between sections.
reset_registry() {
    REGISTERED_TOOLS=()
    _MCP_PROXY_FN_NAMES=()
    _MCP_PROXY_CONNS=()
    _MCP_PROXY_ORIG_NAMES=()
    _MCP_PROXY_DEFINITIONS=()
}

chmod +x "$STUB"
export CODER_MCP_TIMEOUT=5
# P1.mcp-4b: prevent _register_agentic_tools from auto-connecting any
# user-configured MCP servers (the test only exercises the registry layer
# against manually-spawned stub connections).
export CODER_MCP_AUTOCONNECT=0

# shellcheck disable=SC1091
source "$REPO_DIR/lib/agent/tool_calling.sh"
# shellcheck disable=SC1091
source "$REPO_DIR/lib/agent/mcp_client.sh"

echo "=== module wiring ==="
for fn in _mcp_sanitize_name _mcp_proxy_index _mcp_proxy_definition _mcp_proxy_handler _mcp_register_proxy mcp_register_tools_for_connection mcp_register_all_tools mcp_unregister_tools_for_connection; do
    if declare -f "$fn" >/dev/null 2>&1; then
        _pass "$fn defined"
    else
        _fail "$fn defined"
    fi
done

echo
echo "=== _mcp_sanitize_name ==="
assert_eq "sanitize: clean ident untouched" "tool_a" "$(_mcp_sanitize_name "tool_a")"
assert_eq "sanitize: dashes -> _" "do_thing" "$(_mcp_sanitize_name "do-thing")"
assert_eq "sanitize: dots -> _" "x_y" "$(_mcp_sanitize_name "x.y")"
assert_eq "sanitize: spaces -> _" "a_b" "$(_mcp_sanitize_name "a b")"
assert_eq "sanitize: digits ok" "tool9" "$(_mcp_sanitize_name "tool9")"
assert_eq "sanitize: mixed special" "my_server_v2_0" "$(_mcp_sanitize_name "my-server.v2/0")"
assert_eq "sanitize: empty input" "" "$(_mcp_sanitize_name "")"
assert_eq "sanitize: underscore preserved" "_x_y_" "$(_mcp_sanitize_name "_x_y_")"

echo
echo "=== _mcp_register_proxy: input validation ==="
reset_registry
_mcp_register_proxy "" '{"name":"x"}' 2>/dev/null
assert_exit "register: missing conn -> rc 2" "2" "$?"

_mcp_register_proxy "myconn" "" 2>/dev/null
assert_exit "register: missing tool_def -> rc 2" "2" "$?"

_mcp_register_proxy "myconn" '{}' 2>/dev/null
assert_exit "register: missing .name -> rc 1" "1" "$?"

echo
echo "=== _mcp_register_proxy: happy path ==="
reset_registry
_mcp_register_proxy "myconn" '{"name":"foo","description":"does foo","inputSchema":{"type":"object","properties":{"x":{"type":"integer"}},"required":["x"]}}'
assert_exit "register: happy -> rc 0" "0" "$?"
assert_eq "register: REGISTERED_TOOLS count" "1" "${#REGISTERED_TOOLS[@]}"
assert_eq "register: proxy fn_name" "mcp__myconn__foo" "${REGISTERED_TOOLS[0]}"
in_registry "mcp__myconn__foo"
assert_exit "register: fn name in registry" "0" "$?"

# Definition translation
def=$(_mcp_proxy_definition "mcp__myconn__foo")
assert_eq "register: definition name" "mcp__myconn__foo" "$(printf '%s' "$def" | jq -r '.name')"
assert_eq "register: definition description" "does foo" "$(printf '%s' "$def" | jq -r '.description')"
assert_eq "register: definition input_schema.type" "object" "$(printf '%s' "$def" | jq -r '.input_schema.type')"
assert_eq "register: definition input_schema preserved" "integer" "$(printf '%s' "$def" | jq -r '.input_schema.properties.x.type')"
# inputSchema renamed to input_schema -> .inputSchema must NOT exist at top
has_input_schema_camel=$(printf '%s' "$def" | jq -r 'has("inputSchema")')
assert_eq "register: no camelCase inputSchema at top" "false" "$has_input_schema_camel"

# Generated fns exist
declare -f tool_mcp__myconn__foo_definition >/dev/null 2>&1
assert_exit "register: tool_<n>_definition exists" "0" "$?"
declare -f tool_mcp__myconn__foo_handler >/dev/null 2>&1
assert_exit "register: tool_<n>_handler exists" "0" "$?"

# get_all_tool_definitions_json includes the proxy.
defs=$(get_all_tool_definitions_json)
assert_eq "register: get_all_tool_definitions_json sees proxy" "mcp__myconn__foo" "$(printf '%s' "$defs" | jq -r '.[0].name')"

echo
echo "=== _mcp_register_proxy: missing description / inputSchema defaults ==="
reset_registry
_mcp_register_proxy "c1" '{"name":"bare"}'
assert_exit "register bare: rc 0" "0" "$?"
def=$(_mcp_proxy_definition "mcp__c1__bare")
assert_eq "register bare: description defaults to empty" "" "$(printf '%s' "$def" | jq -r '.description')"
assert_eq "register bare: input_schema defaults to object" "object" "$(printf '%s' "$def" | jq -r '.input_schema.type')"

echo
echo "=== _mcp_register_proxy: sanitization of conn / tool names ==="
reset_registry
_mcp_register_proxy "my-server.v2" '{"name":"do-thing"}'
assert_exit "register dashed names: rc 0" "0" "$?"
assert_eq "register dashed names: fn_name sanitized" "mcp__my_server_v2__do_thing" "${REGISTERED_TOOLS[0]}"

echo
echo "=== _mcp_register_proxy: dedup (idempotent) ==="
reset_registry
_mcp_register_proxy "dup" '{"name":"x","description":"first"}'
_mcp_register_proxy "dup" '{"name":"x","description":"second"}'
assert_eq "dedup: only 1 entry in REGISTERED_TOOLS" "1" "${#REGISTERED_TOOLS[@]}"
def=$(_mcp_proxy_definition "mcp__dup__x")
assert_eq "dedup: first registration wins (description preserved)" "first" "$(printf '%s' "$def" | jq -r '.description')"

echo
echo "=== _mcp_proxy_definition / _mcp_proxy_handler: unknown lookup ==="
reset_registry
_mcp_proxy_definition "ghost" 2>/dev/null
assert_exit "proxy_definition ghost: rc 1" "1" "$?"
_mcp_proxy_handler "ghost" '{}' 2>/dev/null
assert_exit "proxy_handler ghost: rc 1" "1" "$?"

echo
echo "=== mcp_register_tools_for_connection: validation ==="
reset_registry
mcp_register_tools_for_connection "" 2>/dev/null
assert_exit "register_for_conn empty name: rc 2" "2" "$?"
mcp_register_tools_for_connection "ghost" 2>/dev/null
assert_exit "register_for_conn unknown conn: rc 2" "2" "$?"

echo
echo "=== mcp_register_tools_for_connection: happy path (default stub) ==="
reset_registry
mcp_connect "reg_simple" bash "$STUB"
assert_exit "connect reg_simple: rc 0" "0" "$?"
mcp_register_tools_for_connection "reg_simple"
assert_exit "register_for_conn happy: rc 0" "0" "$?"
assert_eq "register_for_conn: 2 proxies registered" "2" "${#REGISTERED_TOOLS[@]}"
in_registry "mcp__reg_simple__tool_a"
assert_exit "register_for_conn: tool_a present" "0" "$?"
in_registry "mcp__reg_simple__tool_b"
assert_exit "register_for_conn: tool_b present" "0" "$?"

# Inspect translated definition for tool_a
def_a=$(_mcp_proxy_definition "mcp__reg_simple__tool_a")
assert_eq "register_for_conn: tool_a definition name" "mcp__reg_simple__tool_a" "$(printf '%s' "$def_a" | jq -r '.name')"
assert_eq "register_for_conn: tool_a description" "first tool" "$(printf '%s' "$def_a" | jq -r '.description')"
assert_eq "register_for_conn: tool_a input_schema property type" "integer" "$(printf '%s' "$def_a" | jq -r '.input_schema.properties.x.type')"

echo
echo "=== dispatch + handler proxy: happy path ==="
# Use dispatch_tool to exercise the full proxy chain (definition + handler).
out=$(dispatch_tool "mcp__reg_simple__tool_a" '{"x":42}')
rc=$?
assert_exit "dispatch proxy: rc 0" "0" "$rc"
# Stub echoes "called <name> with <args>" as text content. _mcp_proxy_handler
# extracts the text from the content array since all blocks are type=text.
assert_contains "dispatch proxy: emitted text contains tool name" "tool_a" "$out"
assert_contains "dispatch proxy: emitted text contains args" '"x":42' "$out"
assert_not_contains "dispatch proxy: should NOT emit raw JSON content array" '[{"type"' "$out"

mcp_close "reg_simple"

echo
echo "=== handler proxy: isError -> rc 1 with content emitted ==="
reset_registry
mcp_connect "err_conn" bash "$STUB"
# Register a synthetic proxy that targets 'error_tool' on the stub.
_mcp_register_proxy "err_conn" '{"name":"error_tool","description":"fails"}'
assert_exit "register error_tool proxy: rc 0" "0" "$?"
out=$(dispatch_tool "mcp__err_conn__error_tool" '{}')
rc=$?
assert_exit "dispatch error_tool: rc 1" "1" "$rc"
assert_contains "dispatch error_tool: content still emitted" "tool reported failure" "$out"
mcp_close "err_conn"

echo
echo "=== handler proxy: server JSON-RPC error envelope -> rc 1 ==="
reset_registry
mcp_connect "rpc_err_conn" bash "$STUB"
_mcp_register_proxy "rpc_err_conn" '{"name":"server_error","description":"will fail"}'
err_out=$(dispatch_tool "mcp__rpc_err_conn__server_error" '{}' 2>&1 >/dev/null)
rc=$?
assert_exit "dispatch server_error: rc 1" "1" "$rc"
assert_contains "dispatch server_error: stderr has error message" "Invalid params" "$err_out"
mcp_close "rpc_err_conn"

echo
echo "=== handler proxy: connection gone -> rc 1 ==="
reset_registry
mcp_connect "ghost_conn" bash "$STUB"
mcp_register_tools_for_connection "ghost_conn"
mcp_close "ghost_conn"
# Proxies are still in registry; calling them should fail gracefully because
# mcp_is_connected returns false now.
err_out=$(dispatch_tool "mcp__ghost_conn__tool_a" '{"x":1}' 2>&1 >/dev/null)
rc=$?
assert_exit "dispatch on closed conn: rc 1" "1" "$rc"
assert_contains "dispatch on closed conn: stderr mentions inactive" "no longer active" "$err_out"

echo
echo "=== mcp_register_all_tools: no connections is no-op ==="
reset_registry
# Close any lingering conns from prior sections (defensive).
mcp_register_all_tools
assert_exit "register_all (no conns): rc 0" "0" "$?"
assert_eq "register_all (no conns): registry stays empty" "0" "${#REGISTERED_TOOLS[@]}"

echo
echo "=== mcp_register_all_tools: multiple connections ==="
reset_registry
mcp_connect "alpha" bash "$STUB"
mcp_connect "beta" bash "$STUB"
mcp_register_all_tools
assert_exit "register_all multi: rc 0" "0" "$?"
# Each conn contributes 2 tools => 4 total.
assert_eq "register_all multi: 4 proxies total" "4" "${#REGISTERED_TOOLS[@]}"
in_registry "mcp__alpha__tool_a"
assert_exit "register_all multi: alpha tool_a" "0" "$?"
in_registry "mcp__beta__tool_b"
assert_exit "register_all multi: beta tool_b" "0" "$?"

echo
echo "=== mcp_unregister_tools_for_connection: validation ==="
mcp_unregister_tools_for_connection "" 2>/dev/null
assert_exit "unregister empty conn: rc 2" "2" "$?"

# Unknown conn (no proxies for it) is no-op rc 0.
mcp_unregister_tools_for_connection "nonexistent"
assert_exit "unregister unknown conn: rc 0" "0" "$?"
# Registry unchanged.
assert_eq "unregister unknown: registry unchanged" "4" "${#REGISTERED_TOOLS[@]}"

echo
echo "=== mcp_unregister_tools_for_connection: removes alpha only ==="
mcp_unregister_tools_for_connection "alpha"
assert_exit "unregister alpha: rc 0" "0" "$?"
assert_eq "unregister alpha: 2 proxies left (beta only)" "2" "${#REGISTERED_TOOLS[@]}"
in_registry "mcp__alpha__tool_a"
assert_exit "unregister alpha: tool_a gone" "1" "$?"
in_registry "mcp__beta__tool_a"
assert_exit "unregister alpha: beta tool_a still present" "0" "$?"
declare -f tool_mcp__alpha__tool_a_handler >/dev/null 2>&1
assert_exit "unregister alpha: handler fn unset" "1" "$?"
declare -f tool_mcp__alpha__tool_a_definition >/dev/null 2>&1
assert_exit "unregister alpha: definition fn unset" "1" "$?"
# beta's proxies still callable
out=$(dispatch_tool "mcp__beta__tool_a" '{"x":7}')
rc=$?
assert_exit "post-unregister: beta still dispatches rc 0" "0" "$rc"
assert_contains "post-unregister: beta result contains x" '"x":7' "$out"

# Cleanup
mcp_close "alpha" 2>/dev/null || true
mcp_close "beta" 2>/dev/null || true

echo
echo "=== _register_agentic_tools integration: picks up MCP tools ==="
reset_registry
mcp_connect "agentic" bash "$STUB"
# Source check: _register_agentic_tools should see mcp_register_all_tools and call it.
_register_agentic_tools "test_mcp_registry" >/dev/null 2>&1
rc=$?
assert_exit "_register_agentic_tools: rc 0" "0" "$rc"
# Should now have 8 native (read/write/edit/bash/web/grep/glob/subagent) + 2 MCP = 10 tools.
total="${#REGISTERED_TOOLS[@]}"
assert_eq "_register_agentic_tools: 10 tools total (8 native + 2 MCP)" "10" "$total"
in_registry "read_file"
assert_exit "_register_agentic_tools: native read_file present" "0" "$?"
in_registry "mcp__agentic__tool_a"
assert_exit "_register_agentic_tools: MCP tool_a present" "0" "$?"
in_registry "mcp__agentic__tool_b"
assert_exit "_register_agentic_tools: MCP tool_b present" "0" "$?"

# get_all_tool_definitions_json should include the MCP proxies with internal format.
defs=$(get_all_tool_definitions_json)
mcp_in_defs=$(printf '%s' "$defs" | jq -r '[.[] | select(.name | startswith("mcp__"))] | length')
assert_eq "_register_agentic_tools: 2 MCP defs in get_all" "2" "$mcp_in_defs"
# Each MCP def in get_all_tool_definitions_json must use input_schema (snake_case).
has_snake=$(printf '%s' "$defs" | jq -r '[.[] | select(.name | startswith("mcp__")) | has("input_schema")] | all')
assert_eq "_register_agentic_tools: MCP defs use input_schema" "true" "$has_snake"

mcp_close "agentic"

echo
echo "=== summary ==="
echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
