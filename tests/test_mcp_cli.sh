#!/usr/bin/env bash
#
# P1.mcp-4a CLI dispatcher (`mcp_cli`) — unit tests.
# Aislamos $CODER_MCP_CONFIG a un tmp file. La transport layer
# (mcp_connect/mcp_list_tools/mcp_close) está cubierta por test_mcp_client.sh
# y test_mcp_tools.sh — aquí validamos el dispatcher: parsing de subcommands,
# validación de argc, exit codes, side-effects en el JSON, end-to-end de
# `test` contra el stub fixture.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
STUB="$SCRIPT_DIR/fixtures/mcp_stub_server.sh"
chmod +x "$STUB"

TMP_DIR=$(mktemp -d)
export CODER_MCP_CONFIG="$TMP_DIR/mcp.json"
export CODER_MCP_TIMEOUT=5
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# shellcheck source=../lib/mcp_client.sh disable=SC1091
source "$REPO_DIR/lib/agent/mcp_client.sh"

PASS=0
FAIL=0

_assert() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

_assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (missing: '$needle' in: $(printf '%s' "$haystack" | head -c 200))"
        FAIL=$((FAIL + 1))
    fi
}

_assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  FAIL: $desc (unexpected presence of '$needle')"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

_reset() {
    rm -f "$CODER_MCP_CONFIG"
}

echo "=== T1: sin subcommand => usage en stderr + exit 2"
_reset
ec=0
out=$(mcp_cli 2>&1 >/dev/null) || ec=$?
_assert "exit 2 sin subcommand" "$ec" "2"
_assert_contains "stderr menciona Uso" "Usage:" "$out"

echo
echo "=== T2: --help / -h / help => stdout + exit 0"
_reset
ec=0
out=$(mcp_cli --help 2>/dev/null) || ec=$?
_assert "--help exit 0" "$ec" "0"
_assert_contains "--help muestra Subcommands" "Subcommands:" "$out"
ec=0
out=$(mcp_cli -h 2>/dev/null) || ec=$?
_assert "-h exit 0" "$ec" "0"
ec=0
out=$(mcp_cli help 2>/dev/null) || ec=$?
_assert "help (bareword) exit 0" "$ec" "0"
_assert_contains "help muestra Examples" "Examples:" "$out"

echo
echo "=== T3: subcommand desconocido => exit 2 + usage en stderr"
_reset
ec=0
err=$(mcp_cli bogus 2>&1 >/dev/null) || ec=$?
_assert "bogus exit 2" "$ec" "2"
_assert_contains "stderr menciona unknown" "unknown subcommand" "$err"
_assert_contains "stderr incluye usage" "Subcommands:" "$err"

echo
echo "=== T4: list vacío => '(no MCP servers configured)' + exit 0"
_reset
ec=0
out=$(mcp_cli list 2>/dev/null) || ec=$?
_assert "list vacío exit 0" "$ec" "0"
_assert_contains "list vacío anuncia ausencia" "(no MCP servers configured)" "$out"

echo
echo "=== T5: list con args inesperados => exit 2"
_reset
ec=0
err=$(mcp_cli list extra 2>&1 >/dev/null) || ec=$?
_assert "list extra args exit 2" "$ec" "2"
_assert_contains "stderr menciona unexpected" "unexpected arguments" "$err"

echo
echo "=== T6: add sin args / con un solo arg => exit 2"
_reset
ec=0
err=$(mcp_cli add 2>&1 >/dev/null) || ec=$?
_assert "add sin args exit 2" "$ec" "2"
_assert_contains "add stderr menciona <name> <cmd>" "<name> <cmd>" "$err"
ec=0
err=$(mcp_cli add solo 2>&1 >/dev/null) || ec=$?
_assert "add con un solo arg exit 2" "$ec" "2"

echo
echo "=== T7: add con name inválido (espacio/slash) => exit 2"
_reset
ec=0
err=$(mcp_cli add "bad name" cmd 2>&1 >/dev/null) || ec=$?
_assert "add name con espacio exit 2" "$ec" "2"
_assert_contains "stderr menciona invalid server name" "invalid server name" "$err"
ec=0
err=$(mcp_cli add "bad/name" cmd 2>&1 >/dev/null) || ec=$?
_assert "add name con slash exit 2" "$ec" "2"

echo
echo "=== T8: add happy path con args"
_reset
ec=0
out=$(mcp_cli add fs npx -y "@x/y" /tmp 2>&1) || ec=$?
_assert "add happy exit 0" "$ec" "0"
_assert_contains "stdout 'added: fs'" "added: fs" "$out"
_assert "config file existe" "$([ -f "$CODER_MCP_CONFIG" ] && echo y)" "y"
json=$(cat "$CODER_MCP_CONFIG")
_assert_contains "command persisted" '"npx"' "$json"
_assert_contains "first arg persisted" '"-y"' "$json"
_assert_contains "second arg persisted" '"@x/y"' "$json"
enabled_v=$(printf '%s' "$json" | jq -r '.servers.fs.enabled')
_assert "enabled=true persisted" "$enabled_v" "true"

echo
echo "=== T9: add duplicado sin --force => exit 1, archivo intacto"
ec=0
err=$(mcp_cli add fs npx other 2>&1 >/dev/null) || ec=$?
_assert "add dup exit 1" "$ec" "1"
_assert_contains "stderr menciona already exists" "already exists" "$err"
json=$(cat "$CODER_MCP_CONFIG")
_assert_contains "config aún tiene los args originales" '"@x/y"' "$json"

echo
echo "=== T10: add duplicado con --force => exit 0, overwrite"
ec=0
out=$(mcp_cli add fs node /new/path --force 2>&1) || ec=$?
_assert "add --force exit 0" "$ec" "0"
_assert_contains "stdout 'updated: fs'" "updated: fs" "$out"
json=$(cat "$CODER_MCP_CONFIG")
_assert_contains "command overwritten" '"node"' "$json"
_assert_not_contains "old args removed" '"@x/y"' "$json"

# Misma cosa con -f corto.
ec=0
out=$(mcp_cli add fs cat -f 2>&1) || ec=$?
_assert "add -f exit 0" "$ec" "0"
_assert_contains "stdout 'updated: fs' (-f)" "updated: fs" "$out"
json=$(cat "$CODER_MCP_CONFIG")
_assert_contains "command overwritten (-f)" '"cat"' "$json"

echo
echo "=== T11: add con cero args extra (sólo cmd)"
_reset
ec=0
out=$(mcp_cli add solo cmd 2>&1) || ec=$?
_assert "add solo cmd exit 0" "$ec" "0"
json=$(cat "$CODER_MCP_CONFIG")
args_len=$(printf '%s' "$json" | jq -r '.servers.solo.args | length')
_assert "args array vacío" "$args_len" "0"
cmd_v=$(printf '%s' "$json" | jq -r '.servers.solo.command')
_assert "command persisted" "$cmd_v" "cmd"

echo
echo "=== T12: list con server => header + row"
ec=0
out=$(mcp_cli list 2>/dev/null) || ec=$?
_assert "list exit 0" "$ec" "0"
_assert_contains "header NAME" "NAME" "$out"
_assert_contains "header ENABLED" "ENABLED" "$out"
_assert_contains "row con solo" "solo" "$out"
_assert_contains "row con cmd" "cmd" "$out"

echo
echo "=== T13: list multi-server"
_reset
mcp_cli add a cmd_a >/dev/null
mcp_cli add b cmd_b arg1 arg2 >/dev/null
ec=0
out=$(mcp_cli list 2>/dev/null) || ec=$?
_assert "list multi exit 0" "$ec" "0"
_assert_contains "row a" "cmd_a" "$out"
_assert_contains "row b" "cmd_b" "$out"
_assert_contains "row b args" "arg1 arg2" "$out"

echo
echo "=== T14: remove argc validation"
ec=0
err=$(mcp_cli remove 2>&1 >/dev/null) || ec=$?
_assert "remove sin args exit 2" "$ec" "2"
ec=0
err=$(mcp_cli remove a b 2>&1 >/dev/null) || ec=$?
_assert "remove con 2 args exit 2" "$ec" "2"

echo
echo "=== T15: remove name inválido"
ec=0
err=$(mcp_cli remove "bad name" 2>&1 >/dev/null) || ec=$?
_assert "remove name con espacio exit 2" "$ec" "2"

echo
echo "=== T16: remove server inexistente => exit 1"
ec=0
err=$(mcp_cli remove nope 2>&1 >/dev/null) || ec=$?
_assert "remove inexistente exit 1" "$ec" "1"
_assert_contains "stderr menciona no such server" "no such server" "$err"

echo
echo "=== T17: remove happy path"
ec=0
out=$(mcp_cli remove a 2>/dev/null) || ec=$?
_assert "remove a exit 0" "$ec" "0"
_assert_contains "stdout 'removed: a'" "removed: a" "$out"
# 'a' debe haber desaparecido, 'b' persiste.
json=$(cat "$CODER_MCP_CONFIG")
has_a=$(printf '%s' "$json" | jq -r '.servers | has("a")')
has_b=$(printf '%s' "$json" | jq -r '.servers | has("b")')
_assert "a removed" "$has_a" "false"
_assert "b preserved" "$has_b" "true"

echo
echo "=== T18: test argc validation"
ec=0
err=$(mcp_cli test 2>&1 >/dev/null) || ec=$?
_assert "test sin args exit 2" "$ec" "2"
ec=0
err=$(mcp_cli test a b 2>&1 >/dev/null) || ec=$?
_assert "test con 2 args exit 2" "$ec" "2"

echo
echo "=== T19: test server inexistente => exit 1"
_reset
ec=0
err=$(mcp_cli test nope 2>&1 >/dev/null) || ec=$?
_assert "test inexistente exit 1" "$ec" "1"
_assert_contains "stderr menciona no such server" "no such server" "$err"

echo
echo "=== T20: test happy path contra stub (tools/list)"
_reset
mcp_cli add demo "$STUB" >/dev/null
ec=0
out=$(mcp_cli test demo 2>&1) || ec=$?
_assert "test demo exit 0" "$ec" "0"
_assert_contains "stdout menciona Connecting" "Connecting to 'demo'" "$out"
_assert_contains "stdout menciona OK" "OK:" "$out"
_assert_contains "stdout lista tool_a" "tool_a" "$out"
_assert_contains "stdout lista tool_b" "tool_b" "$out"
# La conexión debe haber sido cerrada (test cierra explícitamente).
mcp_is_connected demo
rc_conn=$?
_assert "conexión cerrada post-test" "$rc_conn" "1"

echo
echo "=== T21: test con server.enabled=false => warn pero corre"
# Edit JSON directly to flip enabled.
json=$(cat "$CODER_MCP_CONFIG")
new_json=$(printf '%s' "$json" | jq -c '.servers.demo.enabled = false')
printf '%s\n' "$new_json" > "$CODER_MCP_CONFIG"
ec=0
out=$(mcp_cli test demo 2>&1) || ec=$?
_assert "test disabled exit 0" "$ec" "0"
_assert_contains "warn disabled" "is disabled" "$out"
_assert_contains "still OK" "OK:" "$out"
# list debe mostrar enabled=false (no clobbereado por // true).
out=$(mcp_cli list 2>/dev/null)
_assert_contains "list muestra ENABLED=false" "false" "$out"

echo
echo "=== T22: test con cmd que no existe => exit 1"
_reset
mcp_cli add ghost /nonexistent/path/to/server >/dev/null
ec=0
err=$(mcp_cli test ghost 2>&1) || ec=$?
_assert "test cmd inexistente exit 1" "$ec" "1"
_assert_contains "stderr menciona connection failed" "connection failed" "$err"

echo
echo "=== T23: malformed config en list => exit 1"
printf '{not json' > "$CODER_MCP_CONFIG"
ec=0
err=$(mcp_cli list 2>&1 >/dev/null) || ec=$?
_assert "list malformed exit 1" "$ec" "1"
_assert_contains "stderr menciona malformed" "malformed JSON" "$err"

echo
echo "=== T24: malformed config en add => exit 1 (no clobber)"
ec=0
err=$(mcp_cli add x y 2>&1 >/dev/null) || ec=$?
_assert "add malformed exit 1" "$ec" "1"
# El archivo no fue sobrescrito.
content=$(cat "$CODER_MCP_CONFIG")
_assert_contains "config no fue clobbereado" "not json" "$content"

echo
echo "=== T25: mcp_config_path emite path"
_reset
out=$(mcp_config_path)
_assert "mcp_config_path equals CODER_MCP_CONFIG" "$out" "$CODER_MCP_CONFIG"

echo
echo "=== T26: mcp_config_init crea archivo si falta"
_reset
ec=0
mcp_config_init >/dev/null || ec=$?
_assert "init exit 0" "$ec" "0"
_assert "archivo existe post-init" "$([ -f "$CODER_MCP_CONFIG" ] && echo y)" "y"
content=$(cat "$CODER_MCP_CONFIG")
servers_keys=$(printf '%s' "$content" | jq -r '.servers | keys | length')
_assert "schema con servers vacío" "$servers_keys" "0"
# Idempotente: segunda llamada no clobberea.
mcp_cli add keep cmd >/dev/null
mcp_config_init >/dev/null
has=$(jq -r '.servers | has("keep")' "$CODER_MCP_CONFIG")
_assert "init idempotente preserva contenido" "$has" "true"

echo
echo "=== T27: mcp_config_get_server"
ec=0
out=$(mcp_config_get_server keep) || ec=$?
_assert "get_server exit 0" "$ec" "0"
cmd_v=$(printf '%s' "$out" | jq -r '.command')
_assert "get_server emite command" "$cmd_v" "cmd"
ec=0
out=$(mcp_config_get_server missing 2>/dev/null) || ec=$?
_assert "get_server missing exit 1" "$ec" "1"
ec=0
out=$(mcp_config_get_server "" 2>/dev/null) || ec=$?
_assert "get_server empty name exit 2" "$ec" "2"

echo
echo "=== T28: mcp_config_list_servers"
_reset
mcp_config_init >/dev/null
mcp_cli add a cmd_a >/dev/null
mcp_cli add b cmd_b >/dev/null
out=$(mcp_config_list_servers)
_assert_contains "list_servers incluye a" "a" "$out"
_assert_contains "list_servers incluye b" "b" "$out"
line_count=$(printf '%s\n' "$out" | wc -l | awk '{print $1}')
_assert "list_servers emite 2 lineas" "$line_count" "2"

echo
echo "=== T29: add con --force como flag intermedio (no al final)"
_reset
ec=0
out=$(mcp_cli add fs --force cmd 2>&1) || ec=$?
# `add` parsea flags en cualquier posición; este caso: name=fs, cmd=cmd, --force ignorado por falta de previo. Server no existe → succeed.
_assert "add --force intermedio exit 0" "$ec" "0"
json=$(cat "$CODER_MCP_CONFIG")
cmd_v=$(printf '%s' "$json" | jq -r '.servers.fs.command')
_assert "command parseado correctamente" "$cmd_v" "cmd"

echo
echo "=== Resumen ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && echo "OK" || echo "FAIL"
exit $((FAIL > 0 ? 1 : 0))
