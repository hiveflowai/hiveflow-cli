#!/usr/bin/env bash
#
# P1.mcp-4b: `mcp_autoconnect_enabled_servers` — unit tests.
#
# Aislamos $CODER_MCP_CONFIG a un tmpfile y usamos tests/fixtures/mcp_stub_server.sh
# como server real (no se mockea la transport layer — eso ya está cubierto en
# test_mcp_client.sh). Cada test parte de cero: rm de la config + close de toda
# conexión MCP previa.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
STUB="$SCRIPT_DIR/fixtures/mcp_stub_server.sh"
chmod +x "$STUB"

TMP_DIR=$(mktemp -d)
export CODER_MCP_CONFIG="$TMP_DIR/mcp.json"
export CODER_MCP_TIMEOUT=5
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# shellcheck source=../lib/tool_calling.sh disable=SC1091
source "$REPO_DIR/lib/agent/tool_calling.sh"
# shellcheck source=../lib/mcp_client.sh disable=SC1091
source "$REPO_DIR/lib/agent/mcp_client.sh"

PASS=0
FAIL=0

_pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
_fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        _pass "$desc"
    else
        _fail "$desc (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        _pass "$desc"
    else
        _fail "$desc (missing '$needle')"
    fi
}

# Close every active MCP connection (idempotent — used between tests).
close_all_connections() {
    local conn_names conn
    conn_names=$(mcp_list_connections 2>/dev/null | awk -F'\t' '{print $1}')
    [ -n "$conn_names" ] || return 0
    while IFS= read -r conn; do
        [ -n "$conn" ] || continue
        mcp_close "$conn" >/dev/null 2>&1 || true
    done <<<"$conn_names"
}

# Reset between tests: wipe config + close all connections + drop REGISTERED_TOOLS.
_reset() {
    close_all_connections
    rm -f "$CODER_MCP_CONFIG"
    REGISTERED_TOOLS=()
    unset CODER_MCP_AUTOCONNECT
}

connection_count() {
    mcp_list_connections 2>/dev/null | awk -F'\t' 'NF>0 {n++} END {print n+0}'
}

write_config() {
    printf '%s\n' "$1" > "$CODER_MCP_CONFIG"
}

# Run `mcp_autoconnect_enabled_servers` in the CURRENT shell (so connection
# state lands in $_MCP_CONN_*) and capture stderr via a tmpfile. Using
# `$(fn 2>&1 >/dev/null)` would spawn a subshell whose connection arrays die
# with it — exactly the bug pattern called out for CODER_AGENTIC_MESSAGES.
run_autoconnect() {
    local err_file
    err_file=$(mktemp)
    mcp_autoconnect_enabled_servers >/dev/null 2>"$err_file"
    AC_RC=$?
    AC_ERR=$(cat "$err_file")
    rm -f "$err_file"
}

echo "=== T1: módulo wiring"
declare -f mcp_autoconnect_enabled_servers >/dev/null
assert_eq "mcp_autoconnect_enabled_servers definida" "$?" "0"

echo
echo "=== T2: config inexistente => no-op rc 0, sin conexiones"
_reset
run_autoconnect
assert_eq "rc 0 sin config" "$AC_RC" "0"
assert_eq "sin stderr cuando no hay config" "$AC_ERR" ""
assert_eq "0 conexiones" "$(connection_count)" "0"

echo
echo "=== T3: config malformada => rc 0, warn a stderr, sin conexiones"
_reset
printf 'not-json{' > "$CODER_MCP_CONFIG"
run_autoconnect
assert_eq "rc 0 (non-fatal)" "$AC_RC" "0"
assert_contains "warn menciona malformed" "malformed JSON" "$AC_ERR"
assert_eq "0 conexiones" "$(connection_count)" "0"

echo
echo "=== T4: schema vacío => rc 0, sin conexiones"
_reset
write_config '{"servers":{}}'
run_autoconnect
assert_eq "rc 0 con servers vacío" "$AC_RC" "0"
assert_eq "sin stderr" "$AC_ERR" ""
assert_eq "0 conexiones" "$(connection_count)" "0"

echo
echo "=== T5: único server enabled=true => conecta"
_reset
write_config "$(jq -nc --arg c "bash" --arg s "$STUB" '
    {servers: {alpha: {command: $c, args: [$s], enabled: true}}}
')"
run_autoconnect
assert_eq "rc 0" "$AC_RC" "0"
assert_eq "sin stderr" "$AC_ERR" ""
assert_eq "1 conexión" "$(connection_count)" "1"
mcp_is_connected "alpha"
assert_eq "alpha conectado" "$?" "0"
close_all_connections

echo
echo "=== T6: enabled=false => NO conecta"
_reset
write_config "$(jq -nc --arg c "bash" --arg s "$STUB" '
    {servers: {disabled_one: {command: $c, args: [$s], enabled: false}}}
')"
run_autoconnect
assert_eq "rc 0" "$AC_RC" "0"
assert_eq "sin stderr" "$AC_ERR" ""
assert_eq "0 conexiones" "$(connection_count)" "0"
mcp_is_connected "disabled_one"
assert_eq "disabled_one NO conectado" "$?" "1"

echo
echo "=== T7: enabled key omitida => default true => conecta"
_reset
write_config "$(jq -nc --arg c "bash" --arg s "$STUB" '
    {servers: {implicit: {command: $c, args: [$s]}}}
')"
run_autoconnect
assert_eq "rc 0" "$AC_RC" "0"
assert_eq "1 conexión" "$(connection_count)" "1"
mcp_is_connected "implicit"
assert_eq "implicit conectado por default" "$?" "0"
close_all_connections

echo
echo "=== T8: múltiples servers enabled => todos conectan"
_reset
write_config "$(jq -nc --arg c "bash" --arg s "$STUB" '
    {servers: {
        srv1: {command: $c, args: [$s], enabled: true},
        srv2: {command: $c, args: [$s], enabled: true},
        srv3: {command: $c, args: [$s]}
    }}
')"
run_autoconnect
assert_eq "rc 0" "$AC_RC" "0"
assert_eq "sin stderr" "$AC_ERR" ""
assert_eq "3 conexiones" "$(connection_count)" "3"
mcp_is_connected "srv1"
assert_eq "srv1 conectado" "$?" "0"
mcp_is_connected "srv2"
assert_eq "srv2 conectado" "$?" "0"
mcp_is_connected "srv3"
assert_eq "srv3 conectado por default" "$?" "0"
close_all_connections

echo
echo "=== T9: mix enabled + disabled => sólo conectan los enabled"
_reset
write_config "$(jq -nc --arg c "bash" --arg s "$STUB" '
    {servers: {
        on1: {command: $c, args: [$s], enabled: true},
        off:  {command: $c, args: [$s], enabled: false},
        on2:  {command: $c, args: [$s]}
    }}
')"
run_autoconnect
assert_eq "rc 0" "$AC_RC" "0"
assert_eq "2 conexiones (off no cuenta)" "$(connection_count)" "2"
mcp_is_connected "on1"; assert_eq "on1 conectado" "$?" "0"
mcp_is_connected "off"; assert_eq "off NO conectado" "$?" "1"
mcp_is_connected "on2"; assert_eq "on2 conectado" "$?" "0"
close_all_connections

echo
echo "=== T10: cmd inexistente => warn + continúa con los demás"
_reset
write_config "$(jq -nc --arg good "bash" --arg s "$STUB" '
    {servers: {
        bogus: {command: "/nonexistent/no-such-binary-xyz", args: [], enabled: true},
        good:  {command: $good, args: [$s], enabled: true}
    }}
')"
run_autoconnect
assert_eq "rc 0 (failure non-fatal)" "$AC_RC" "0"
assert_contains "warn menciona el server fallido" "bogus" "$AC_ERR"
assert_contains "warn menciona failed to connect" "failed to connect" "$AC_ERR"
mcp_is_connected "bogus"; assert_eq "bogus NO conectado" "$?" "1"
mcp_is_connected "good";  assert_eq "good conectado pese al fallo" "$?" "0"
close_all_connections

echo
echo "=== T11: server ya conectado => skip silencioso (idempotente)"
_reset
write_config "$(jq -nc --arg c "bash" --arg s "$STUB" '
    {servers: {dup: {command: $c, args: [$s], enabled: true}}}
')"
# Primera llamada conecta.
run_autoconnect
assert_eq "1 conexión post-llamada-1" "$(connection_count)" "1"
# Segunda llamada NO debe abrir una segunda conexión ni emitir warn.
run_autoconnect
assert_eq "rc 0 en llamada 2" "$AC_RC" "0"
assert_eq "sin stderr en llamada 2" "$AC_ERR" ""
assert_eq "sigue 1 conexión" "$(connection_count)" "1"
close_all_connections

echo
echo "=== T12: CODER_MCP_AUTOCONNECT=0 => no-op rc 0 incluso con enabled servers"
_reset
write_config "$(jq -nc --arg c "bash" --arg s "$STUB" '
    {servers: {alpha: {command: $c, args: [$s], enabled: true}}}
')"
CODER_MCP_AUTOCONNECT=0 run_autoconnect
assert_eq "rc 0 con opt-out" "$AC_RC" "0"
assert_eq "sin stderr con opt-out" "$AC_ERR" ""
assert_eq "0 conexiones con opt-out" "$(connection_count)" "0"
mcp_is_connected "alpha"; assert_eq "alpha NO conectado con opt-out" "$?" "1"

echo
echo "=== T13: command vacío => warn + skip"
_reset
write_config '{"servers": {"empty_cmd": {"command": "", "args": [], "enabled": true}, "good": {"command": "bash", "args": ["'"$STUB"'"], "enabled": true}}}'
run_autoconnect
assert_eq "rc 0 (skip non-fatal)" "$AC_RC" "0"
assert_contains "warn menciona el server con cmd vacío" "empty_cmd" "$AC_ERR"
assert_contains "warn menciona 'no command'" "no command" "$AC_ERR"
mcp_is_connected "empty_cmd"; assert_eq "empty_cmd NO conectado" "$?" "1"
mcp_is_connected "good";      assert_eq "good conectado" "$?" "0"
close_all_connections

echo
echo "=== T14: args vacíos => conecta sin args extra"
_reset
# Server que se auto-invoca sin args (el stub no necesita args).
write_config "$(jq -nc --arg s "$STUB" '
    {servers: {noarg: {command: $s, args: [], enabled: true}}}
')"
run_autoconnect
assert_eq "rc 0" "$AC_RC" "0"
mcp_is_connected "noarg"; assert_eq "noarg conectado sin args" "$?" "0"
close_all_connections

echo
echo "=== T15: args clave omitida => conecta sin args extra"
_reset
write_config "$(jq -nc --arg s "$STUB" '
    {servers: {no_args_key: {command: $s, enabled: true}}}
')"
run_autoconnect
assert_eq "rc 0" "$AC_RC" "0"
mcp_is_connected "no_args_key"; assert_eq "no_args_key conectado" "$?" "0"
close_all_connections

echo
echo "=== T16: integración con _register_agentic_tools"
_reset
write_config "$(jq -nc --arg c "bash" --arg s "$STUB" '
    {servers: {
        agconn: {command: $c, args: [$s], enabled: true}
    }}
')"
_register_agentic_tools "test_mcp_autoconnect" >/dev/null 2>&1
ec=$?
assert_eq "_register_agentic_tools rc 0" "$ec" "0"
mcp_is_connected "agconn"; assert_eq "agconn auto-conectado" "$?" "0"
# Tools nativas (8: read/write/edit/bash/web/grep/glob/subagent) + proxies del stub (2: tool_a, tool_b) = 10.
assert_eq "10 tools en REGISTERED_TOOLS (8 native + 2 MCP)" "${#REGISTERED_TOOLS[@]}" "10"
mcp_in_reg=0
if [ "${#REGISTERED_TOOLS[@]}" -gt 0 ]; then
    for t in "${REGISTERED_TOOLS[@]}"; do
        case "$t" in
            mcp__agconn__*) mcp_in_reg=$((mcp_in_reg + 1)) ;;
        esac
    done
fi
assert_eq "2 proxies mcp__agconn__* registrados" "$mcp_in_reg" "2"
close_all_connections

echo
echo "=== T17: integración con _register_agentic_tools + CODER_MCP_AUTOCONNECT=0"
_reset
write_config "$(jq -nc --arg c "bash" --arg s "$STUB" '
    {servers: {agconn2: {command: $c, args: [$s], enabled: true}}}
')"
CODER_MCP_AUTOCONNECT=0 _register_agentic_tools "test_mcp_autoconnect" >/dev/null 2>&1
ec=$?
assert_eq "_register_agentic_tools rc 0 con opt-out" "$ec" "0"
mcp_is_connected "agconn2"; assert_eq "agconn2 NO auto-conectado (opt-out)" "$?" "1"
# Sólo las 8 nativas — sin MCP proxies.
assert_eq "8 tools (sólo nativas)" "${#REGISTERED_TOOLS[@]}" "8"
close_all_connections

echo
echo
echo "=== summary ==="
echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
