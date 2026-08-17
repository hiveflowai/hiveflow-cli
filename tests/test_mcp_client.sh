#!/usr/bin/env bash
# Unit tests for lib/mcp_client.sh (P1.mcp-1).
#
# Pure helpers (build_request / build_notification / parse_message) are tested
# without spawning a server. Transport (connect/send/close) is exercised
# against tests/fixtures/mcp_stub_server.sh — a tiny bash dispatcher that
# emits canned JSON-RPC responses.
#
# Run: bash tests/test_mcp_client.sh

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

# Make the stub executable in case the fs lost the bit.
chmod +x "$STUB"

# Snug timeout so test runs don't hang for a minute if something stalls.
export CODER_MCP_TIMEOUT=5

# shellcheck disable=SC1091
source "$REPO_DIR/lib/agent/mcp_client.sh"
# shellcheck disable=SC1091
source "$REPO_DIR/lib/agent/mcp_client.sh"  # double-source idempotency check

echo "=== module wiring ==="
for fn in _mcp_build_request _mcp_build_notification _mcp_parse_message \
          _mcp_conn_index _mcp_alloc_fds _mcp_registry_remove _mcp_next_id \
          _mcp_write_line _mcp_read_line \
          mcp_connect mcp_send_request mcp_send_notification mcp_close \
          mcp_list_connections mcp_is_connected; do
    if declare -f "$fn" >/dev/null 2>&1; then
        _pass "$fn defined"
    else
        _fail "$fn defined"
    fi
done

echo
echo "=== _mcp_build_request ==="
out=$(_mcp_build_request 1 "ping")
assert_eq "request no params: jsonrpc 2.0" "2.0" "$(printf '%s' "$out" | jq -r '.jsonrpc')"
assert_eq "request no params: id" "1" "$(printf '%s' "$out" | jq -r '.id')"
assert_eq "request no params: method" "ping" "$(printf '%s' "$out" | jq -r '.method')"
assert_eq "request no params: no params key" "false" "$(printf '%s' "$out" | jq -r 'has("params")')"

out=$(_mcp_build_request 42 "echo" '{"hi":"there"}')
assert_eq "request with params: id" "42" "$(printf '%s' "$out" | jq -r '.id')"
assert_eq "request with params: params.hi" "there" "$(printf '%s' "$out" | jq -r '.params.hi')"

_mcp_build_request 1 "" >/dev/null 2>&1
assert_exit "request without method: rc 2" "2" "$?"

echo
echo "=== _mcp_build_notification ==="
out=$(_mcp_build_notification "notifications/initialized")
assert_eq "notif: jsonrpc 2.0" "2.0" "$(printf '%s' "$out" | jq -r '.jsonrpc')"
assert_eq "notif: method" "notifications/initialized" "$(printf '%s' "$out" | jq -r '.method')"
assert_eq "notif: no id key" "false" "$(printf '%s' "$out" | jq -r 'has("id")')"

out=$(_mcp_build_notification "log/info" '{"msg":"hi"}')
assert_eq "notif with params: params.msg" "hi" "$(printf '%s' "$out" | jq -r '.params.msg')"

_mcp_build_notification "" >/dev/null 2>&1
assert_exit "notif without method: rc 2" "2" "$?"

echo
echo "=== _mcp_parse_message ==="
parsed=$(_mcp_parse_message '{"jsonrpc":"2.0","id":7,"result":{"x":1}}')
IFS=$'\x1f' read -r p_type p_id _p_body <<<"$parsed"
assert_eq "parse: response type" "response" "$p_type"
assert_eq "parse: response id" "7" "$p_id"

parsed=$(_mcp_parse_message '{"jsonrpc":"2.0","method":"server/tick","params":{}}')
IFS=$'\x1f' read -r p_type p_id _p_body <<<"$parsed"
assert_eq "parse: notification type" "notification" "$p_type"
assert_eq "parse: notification id empty" "" "$p_id"

parsed=$(_mcp_parse_message '{"jsonrpc":"2.0","id":9,"method":"server/ask","params":{}}')
IFS=$'\x1f' read -r p_type p_id _p_body <<<"$parsed"
assert_eq "parse: server->client request type" "request" "$p_type"
assert_eq "parse: server->client request id" "9" "$p_id"

parsed=$(_mcp_parse_message '{"jsonrpc":"2.0","id":5,"error":{"code":-32601,"message":"x"}}')
IFS=$'\x1f' read -r p_type p_id _p_body <<<"$parsed"
assert_eq "parse: error response type" "response" "$p_type"
assert_eq "parse: error response id" "5" "$p_id"

parsed=$(_mcp_parse_message 'not json at all')
IFS=$'\x1f' read -r p_type p_id _p_body <<<"$parsed"
assert_eq "parse: invalid (non-json) type" "invalid" "$p_type"

parsed=$(_mcp_parse_message '{"foo":"bar"}')
IFS=$'\x1f' read -r p_type p_id _p_body <<<"$parsed"
assert_eq "parse: invalid (no jsonrpc) type" "invalid" "$p_type"

echo
echo "=== mcp_connect: validation ==="
mcp_connect "" bash 2>/dev/null
assert_exit "connect empty name: rc 2" "2" "$?"

mcp_connect "noargs" 2>/dev/null
assert_exit "connect no cmd: rc 2" "2" "$?"

echo
echo "=== mcp_connect: handshake against stub ==="
mcp_connect "stub1" bash "$STUB"
rc=$?
assert_exit "connect stub1: rc 0" "0" "$rc"
assert_eq "is_connected stub1" "0" "$(mcp_is_connected stub1; echo $?)"

# list_connections includes the name.
list=$(mcp_list_connections)
assert_contains "list shows stub1" "stub1" "$list"

# Duplicate connect refuses.
mcp_connect "stub1" bash "$STUB" 2>/dev/null
assert_exit "connect duplicate: rc 2" "2" "$?"

echo
echo "=== mcp_send_request: happy paths ==="
resp=$(mcp_send_request "stub1" "ping")
rc=$?
assert_exit "ping: rc 0" "0" "$rc"
assert_eq "ping: jsonrpc 2.0" "2.0" "$(printf '%s' "$resp" | jq -r '.jsonrpc')"
assert_eq "ping: result is {}" "{}" "$(printf '%s' "$resp" | jq -c '.result')"

resp=$(mcp_send_request "stub1" "echo" '{"k":"v","n":3}')
assert_eq "echo: result.k" "v" "$(printf '%s' "$resp" | jq -r '.result.k')"
assert_eq "echo: result.n" "3" "$(printf '%s' "$resp" | jq -r '.result.n')"

echo
echo "=== mcp_send_request: id auto-increments ==="
resp1=$(mcp_send_request "stub1" "echo" '{"i":"a"}')
resp2=$(mcp_send_request "stub1" "echo" '{"i":"b"}')
id1=$(printf '%s' "$resp1" | jq -r '.id')
id2=$(printf '%s' "$resp2" | jq -r '.id')
# Initial id=1 was consumed by `initialize` during connect, then ping, echo, ...
# So ids are strictly increasing.
if [ "$id2" -gt "$id1" ]; then _pass "id increments ($id1 -> $id2)"; else _fail "id increments ($id1 -> $id2)"; fi

echo
echo "=== mcp_send_request: error envelope passthrough ==="
resp=$(mcp_send_request "stub1" "error_method")
rc=$?
assert_exit "error_method: rc 0 (transport ok)" "0" "$rc"
assert_eq "error_method: has error" "true" "$(printf '%s' "$resp" | jq -r 'has("error")')"
assert_eq "error_method: code -32601" "-32601" "$(printf '%s' "$resp" | jq -r '.error.code')"

echo
echo "=== mcp_send_request: validation ==="
mcp_send_request "" "ping" 2>/dev/null
assert_exit "send_request empty name: rc 2" "2" "$?"

mcp_send_request "stub1" "" 2>/dev/null
assert_exit "send_request empty method: rc 2" "2" "$?"

mcp_send_request "ghost" "ping" 2>/dev/null
assert_exit "send_request unknown conn: rc 2" "2" "$?"

echo
echo "=== mcp_send_notification ==="
mcp_send_notification "stub1" "log/info" '{"msg":"hello"}'
assert_exit "send_notification: rc 0" "0" "$?"

mcp_send_notification "" "x" 2>/dev/null
assert_exit "send_notification empty name: rc 2" "2" "$?"

mcp_send_notification "stub1" "" 2>/dev/null
assert_exit "send_notification empty method: rc 2" "2" "$?"

mcp_send_notification "ghost" "x" 2>/dev/null
assert_exit "send_notification unknown conn: rc 2" "2" "$?"

echo
echo "=== stray notification (server emits notification BEFORE response) ==="
resp=$(mcp_send_request "stub1" "stray_notification" 2>/dev/null)
assert_eq "stray: result.after_stray" "true" "$(printf '%s' "$resp" | jq -r '.result.after_stray')"

echo
echo "=== mcp_close ==="
mcp_close "stub1"
assert_exit "close stub1: rc 0" "0" "$?"
mcp_is_connected "stub1"
assert_exit "is_connected stub1 after close: rc 1" "1" "$?"

# After close, list is empty.
list=$(mcp_list_connections)
assert_eq "list empty after close" "" "$list"

mcp_close "ghost" 2>/dev/null
assert_exit "close unknown conn: rc 2" "2" "$?"

echo
echo "=== two concurrent connections (fd alloc) ==="
mcp_connect "a" bash "$STUB"
rc_a=$?
mcp_connect "b" bash "$STUB"
rc_b=$?
assert_exit "connect a: rc 0" "0" "$rc_a"
assert_exit "connect b: rc 0" "0" "$rc_b"

# They must have distinct fds.
idx_a=$(_mcp_conn_index "a")
idx_b=$(_mcp_conn_index "b")
fd_a_in="${_MCP_CONN_FD_IN[$idx_a]}"
fd_b_in="${_MCP_CONN_FD_IN[$idx_b]}"
if [ "$fd_a_in" != "$fd_b_in" ]; then _pass "distinct fd_in ($fd_a_in vs $fd_b_in)"; else _fail "distinct fd_in"; fi

# Both can answer independent pings.
resp_a=$(mcp_send_request "a" "echo" '{"who":"a"}')
resp_b=$(mcp_send_request "b" "echo" '{"who":"b"}')
assert_eq "ping a: who=a" "a" "$(printf '%s' "$resp_a" | jq -r '.result.who')"
assert_eq "ping b: who=b" "b" "$(printf '%s' "$resp_b" | jq -r '.result.who')"

# Closing one does not affect the other.
mcp_close "a"
mcp_is_connected "b"
assert_exit "b still connected after closing a: rc 0" "0" "$?"
resp=$(mcp_send_request "b" "ping")
assert_eq "b ping after a closed: result={}" "{}" "$(printf '%s' "$resp" | jq -c '.result')"

mcp_close "b"
list=$(mcp_list_connections)
assert_eq "list empty after closing both" "" "$list"

echo
echo "=== timeout when server is slow ==="
CODER_MCP_TIMEOUT=1 mcp_connect "slowconn" bash "$STUB"
assert_exit "connect slowconn: rc 0 (handshake fast)" "0" "$?"
# Ask for a 3s sleep with a 1s timeout — must rc 1.
out=$(CODER_MCP_TIMEOUT=1 mcp_send_request "slowconn" "slow" '{"seconds":3}' 2>&1)
rc=$?
assert_exit "slow with 1s timeout: rc 1" "1" "$rc"
assert_contains "slow: timeout msg" "timeout" "$out"
mcp_close "slowconn"

echo
echo "=== _mcp_alloc_fds: returns distinct pairs ==="
_MCP_TEST_BACKUP_NAMES=("${_MCP_CONN_NAMES[@]:-}")
# Force a registry with a fake entry occupying fd_base..fd_base+1.
_MCP_CONN_NAMES=("dummy")
_MCP_CONN_PIDS=("0")
_MCP_CONN_FD_IN=("$CODER_MCP_FD_BASE")
_MCP_CONN_FD_OUT=("$((CODER_MCP_FD_BASE + 1))")
_MCP_CONN_FIFO_IN=("/tmp/nope")
_MCP_CONN_FIFO_OUT=("/tmp/nope")
_MCP_CONN_TMPDIR=("/tmp/nope")
_MCP_CONN_NEXT_ID_FILE=("/tmp/nope")
fds_next=$(_mcp_alloc_fds)
fd_in_next=${fds_next%% *}
fd_out_next=${fds_next##* }
if [ "$fd_in_next" -ge "$((CODER_MCP_FD_BASE + 2))" ]; then
    _pass "alloc skips used pair (fd_in=$fd_in_next)"
else
    _fail "alloc skips used pair (fd_in=$fd_in_next, base=$CODER_MCP_FD_BASE)"
fi
if [ "$fd_out_next" = "$((fd_in_next + 1))" ]; then
    _pass "alloc returns adjacent pair"
else
    _fail "alloc returns adjacent pair (in=$fd_in_next out=$fd_out_next)"
fi
# Restore registry to empty for any subsequent tests.
_MCP_CONN_NAMES=()
_MCP_CONN_PIDS=()
_MCP_CONN_FD_IN=()
_MCP_CONN_FD_OUT=()
_MCP_CONN_FIFO_IN=()
_MCP_CONN_FIFO_OUT=()
_MCP_CONN_TMPDIR=()
_MCP_CONN_NEXT_ID_FILE=()

echo
echo "=========================================="
echo "Resultado: $PASS pass, $FAIL fail"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
