#!/bin/bash
#
# P1.hooks-3 CLI dispatcher (`hooks_cli`) — unit tests.
# Aislamos $CODER_HOOKS_CONFIG a un tmp file. Las funciones internas
# (hooks_init/hooks_list_for/hooks_run) están cubiertas por tests/test_hooks.sh
# y tests/test_hooks_dispatch.sh — aquí validamos el dispatcher: parsing de
# subcommand, validación de argc, exit codes, side-effects en el JSON.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT" || exit 1

TMP_DIR=$(mktemp -d)
export CODER_HOOKS_CONFIG="$TMP_DIR/hooks.json"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# shellcheck source=../lib/hooks.sh disable=SC1091
source "$REPO_ROOT/lib/agent/hooks.sh"

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
        echo "  FAIL: $desc (unexpected presence of: '$needle')"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

_reset() {
    rm -f "$CODER_HOOKS_CONFIG"
}

echo "=== T1: sin subcommand => usage en stderr + exit 2"
_reset
ec=0
out=$(hooks_cli 2>&1 >/dev/null) || ec=$?
_assert "exit 2 sin subcommand" "$ec" "2"
_assert_contains "stderr menciona Uso" "Usage:" "$out"

echo
echo "=== T2: --help / -h / help => stdout + exit 0"
_reset
ec=0
out=$(hooks_cli --help 2>/dev/null) || ec=$?
_assert "--help exit 0" "$ec" "0"
_assert_contains "--help muestra Subcommands" "Subcommands:" "$out"
ec=0
out=$(hooks_cli -h 2>/dev/null) || ec=$?
_assert "-h exit 0" "$ec" "0"
ec=0
out=$(hooks_cli help 2>/dev/null) || ec=$?
_assert "help (bareword) exit 0" "$ec" "0"
_assert_contains "help muestra Examples" "Examples:" "$out"

echo
echo "=== T3: subcommand desconocido => exit 2 + usage"
_reset
ec=0
err=$(hooks_cli bogus 2>&1 >/dev/null) || ec=$?
_assert "bogus exit 2" "$ec" "2"
_assert_contains "stderr menciona unknown subcommand" "unknown subcommand" "$err"
_assert_contains "stderr incluye usage" "Subcommands:" "$err"

echo
echo "=== T4: list vacío => '(no hooks registered)' + exit 0"
_reset
ec=0
out=$(hooks_cli list 2>/dev/null) || ec=$?
_assert "list vacío exit 0" "$ec" "0"
_assert_contains "list vacío anuncia ausencia" "(no hooks registered)" "$out"

echo
echo "=== T5: list con args extra => exit 2"
_reset
ec=0
hooks_cli list extra >/dev/null 2>&1 || ec=$?
_assert "list extra → exit 2" "$ec" "2"

echo
echo "=== T6: add validaciones de argc"
_reset
ec=0
err=$(hooks_cli add 2>&1 >/dev/null) || ec=$?
_assert "add sin args → exit 2" "$ec" "2"
_assert_contains "menciona expected" "expected <event>" "$err"
ec=0
hooks_cli add tool_pre >/dev/null 2>&1 || ec=$?
_assert "add 1 arg → exit 2" "$ec" "2"
ec=0
hooks_cli add tool_pre read_file >/dev/null 2>&1 || ec=$?
_assert "add 2 args → exit 2" "$ec" "2"
ec=0
hooks_cli add tool_pre read_file 'echo' extra >/dev/null 2>&1 || ec=$?
_assert "add 4 args → exit 2" "$ec" "2"

echo
echo "=== T7: add con event inválido => exit 2"
_reset
ec=0
err=$(hooks_cli add bogus_event read_file 'echo hi' 2>&1 >/dev/null) || ec=$?
_assert "add event inválido → exit 2" "$ec" "2"
_assert_contains "menciona invalid event" "invalid event" "$err"

echo
echo "=== T8: add con tool/cmd vacíos => exit 2"
_reset
ec=0
err=$(hooks_cli add tool_pre "" 'echo' 2>&1 >/dev/null) || ec=$?
_assert "add tool vacío → exit 2" "$ec" "2"
_assert_contains "menciona tool name" "tool name" "$err"
ec=0
err=$(hooks_cli add tool_pre read_file "" 2>&1 >/dev/null) || ec=$?
_assert "add cmd vacío → exit 2" "$ec" "2"
_assert_contains "menciona command" "command" "$err"

echo
echo "=== T9: add happy path => crea archivo + emite mensaje"
_reset
ec=0
out=$(hooks_cli add tool_pre read_file 'echo "test"' 2>/dev/null) || ec=$?
_assert "add exit 0" "$ec" "0"
_assert_contains "reporta added" "added: tool_pre read_file" "$out"
_assert "archivo creado" "$([ -f "$CODER_HOOKS_CONFIG" ] && echo yes || echo no)" "yes"
content=$(cat "$CODER_HOOKS_CONFIG")
_assert_contains "JSON contiene tool_pre" "tool_pre" "$content"
_assert_contains "JSON contiene read_file" "read_file" "$content"
_assert_contains "JSON contiene cmd" 'echo \"test\"' "$content"

echo
echo "=== T10: add múltiples al mismo event/tool => array crece"
_reset
hooks_cli add tool_pre read_file 'cmd-a' >/dev/null
hooks_cli add tool_pre read_file 'cmd-b' >/dev/null
hooks_cli add tool_pre read_file 'cmd-c' >/dev/null
count=$(jq -r '.tool_pre.read_file | length' "$CODER_HOOKS_CONFIG")
_assert "3 entries en el array" "$count" "3"
# Orden preservado
order=$(jq -r '.tool_pre.read_file | join(",")' "$CODER_HOOKS_CONFIG")
_assert "orden preservado" "$order" "cmd-a,cmd-b,cmd-c"

echo
echo "=== T11: add wildcard '*' como tool"
_reset
hooks_cli add tool_post '*' 'logger -t coder' >/dev/null
content=$(jq -r '.tool_post["*"][0]' "$CODER_HOOKS_CONFIG")
_assert "wildcard guardado" "$content" "logger -t coder"

echo
echo "=== T12: add tool_post happy path"
_reset
ec=0
out=$(hooks_cli add tool_post bash_exec 'echo done' 2>/dev/null) || ec=$?
_assert "add tool_post exit 0" "$ec" "0"
content=$(jq -r '.tool_post.bash_exec[0]' "$CODER_HOOKS_CONFIG")
_assert "tool_post stored" "$content" "echo done"

echo
echo "=== T13: list muestra header + rows + index"
_reset
hooks_cli add tool_pre  read_file 'a' >/dev/null
hooks_cli add tool_pre  read_file 'b' >/dev/null
hooks_cli add tool_post '*'       'wildcard-cmd' >/dev/null
out=$(hooks_cli list 2>/dev/null)
_assert_contains "header EVENT"     "EVENT"     "$out"
_assert_contains "header TOOL"      "TOOL"      "$out"
_assert_contains "header COMMAND"   "COMMAND"   "$out"
_assert_contains "row tool_pre"     "tool_pre"  "$out"
_assert_contains "row read_file"    "read_file" "$out"
_assert_contains "row tool_post"    "tool_post" "$out"
_assert_contains "row wildcard"     "*"         "$out"
_assert_contains "muestra cmd a"    " a"        "$out"
_assert_contains "muestra cmd b"    " b"        "$out"
_assert_contains "muestra wildcard-cmd" "wildcard-cmd" "$out"
# index 1 y 2 presentes
count1=$(printf '%s\n' "$out" | grep -cE 'tool_pre +read_file +1 ')
count2=$(printf '%s\n' "$out" | grep -cE 'tool_pre +read_file +2 ')
_assert "row con index 1" "$count1" "1"
_assert "row con index 2" "$count2" "1"

echo
echo "=== T14: remove validaciones de argc"
_reset
ec=0
hooks_cli remove >/dev/null 2>&1 || ec=$?
_assert "remove sin args → exit 2" "$ec" "2"
ec=0
hooks_cli remove tool_pre >/dev/null 2>&1 || ec=$?
_assert "remove 1 arg → exit 2" "$ec" "2"
ec=0
hooks_cli remove tool_pre read_file >/dev/null 2>&1 || ec=$?
_assert "remove 2 args → exit 2" "$ec" "2"
ec=0
hooks_cli remove tool_pre read_file 1 extra >/dev/null 2>&1 || ec=$?
_assert "remove 4 args → exit 2" "$ec" "2"

echo
echo "=== T15: remove con event inválido => exit 2"
_reset
ec=0
err=$(hooks_cli remove bogus tool 1 2>&1 >/dev/null) || ec=$?
_assert "remove event inválido → exit 2" "$ec" "2"
_assert_contains "menciona invalid event" "invalid event" "$err"

echo
echo "=== T16: remove con index no numérico (que no es --all) => exit 2"
_reset
hooks_cli add tool_pre read_file 'a' >/dev/null
ec=0
err=$(hooks_cli remove tool_pre read_file abc 2>&1 >/dev/null) || ec=$?
_assert "index alfa → exit 2" "$ec" "2"
_assert_contains "menciona positive integer" "positive integer" "$err"
ec=0
err=$(hooks_cli remove tool_pre read_file -1 2>&1 >/dev/null) || ec=$?
_assert "index negativo → exit 2" "$ec" "2"

echo
echo "=== T17: remove de tool sin hooks => exit 1"
_reset
ec=0
err=$(hooks_cli remove tool_pre nonexistent 1 2>&1 >/dev/null) || ec=$?
_assert "remove sin hooks → exit 1" "$ec" "1"
_assert_contains "menciona no hooks" "no hooks registered" "$err"

echo
echo "=== T18: remove con index fuera de rango => exit 1"
_reset
hooks_cli add tool_pre read_file 'a' >/dev/null
hooks_cli add tool_pre read_file 'b' >/dev/null
ec=0
err=$(hooks_cli remove tool_pre read_file 5 2>&1 >/dev/null) || ec=$?
_assert "index >count → exit 1" "$ec" "1"
_assert_contains "menciona out of range" "out of range" "$err"
ec=0
err=$(hooks_cli remove tool_pre read_file 0 2>&1 >/dev/null) || ec=$?
_assert "index 0 → exit 1" "$ec" "1"

echo
echo "=== T19: remove índice happy path => quita uno + reorder"
_reset
hooks_cli add tool_pre read_file 'a' >/dev/null
hooks_cli add tool_pre read_file 'b' >/dev/null
hooks_cli add tool_pre read_file 'c' >/dev/null
ec=0
out=$(hooks_cli remove tool_pre read_file 2 2>/dev/null) || ec=$?
_assert "remove idx 2 exit 0" "$ec" "0"
_assert_contains "reporta removed" "removed: tool_pre read_file #2" "$out"
remaining=$(jq -r '.tool_pre.read_file | join(",")' "$CODER_HOOKS_CONFIG")
_assert "queda 'a,c'" "$remaining" "a,c"

echo
echo "=== T20: remove --all => elimina la key entera"
_reset
hooks_cli add tool_pre read_file 'a' >/dev/null
hooks_cli add tool_pre read_file 'b' >/dev/null
ec=0
out=$(hooks_cli remove tool_pre read_file --all 2>/dev/null) || ec=$?
_assert "remove --all exit 0" "$ec" "0"
_assert_contains "menciona removed all count" "(2 hook(s))" "$out"
key_exists=$(jq -r '.tool_pre | has("read_file")' "$CODER_HOOKS_CONFIG")
_assert "key removida" "$key_exists" "false"

echo
echo "=== T21: remove del último hook deja la tool key sin entry"
_reset
hooks_cli add tool_pre read_file 'only' >/dev/null
hooks_cli remove tool_pre read_file 1 >/dev/null
key_exists=$(jq -r '.tool_pre | has("read_file")' "$CODER_HOOKS_CONFIG")
_assert "key auto-cleanup tras último remove" "$key_exists" "false"

echo
echo "=== T22: remove no toca otros events/tools"
_reset
hooks_cli add tool_pre  read_file  'pre-r' >/dev/null
hooks_cli add tool_pre  bash_exec  'pre-b' >/dev/null
hooks_cli add tool_post read_file  'post-r' >/dev/null
hooks_cli remove tool_pre read_file --all >/dev/null
# read_file pre debe estar muerto, bash_exec pre vivo, read_file post vivo
pre_r=$(jq -r '.tool_pre | has("read_file")' "$CODER_HOOKS_CONFIG")
pre_b=$(jq -r '.tool_pre.bash_exec[0]'       "$CODER_HOOKS_CONFIG")
post_r=$(jq -r '.tool_post.read_file[0]'     "$CODER_HOOKS_CONFIG")
_assert "tool_pre.read_file gone"  "$pre_r"  "false"
_assert "tool_pre.bash_exec intact" "$pre_b" "pre-b"
_assert "tool_post.read_file intact" "$post_r" "post-r"

echo
echo "=== T23: list tras config malformado => exit 1"
_reset
echo "not-json" > "$CODER_HOOKS_CONFIG"
ec=0
err=$(hooks_cli list 2>&1 >/dev/null) || ec=$?
_assert "malformed list → exit 1" "$ec" "1"
_assert_contains "menciona malformed" "malformed" "$err"

echo
echo "=== T24: add tras config malformado => exit 1 (no clobbers)"
_reset
echo "not-json" > "$CODER_HOOKS_CONFIG"
ec=0
err=$(hooks_cli add tool_pre read_file 'x' 2>&1 >/dev/null) || ec=$?
_assert "malformed add → exit 1" "$ec" "1"
content=$(cat "$CODER_HOOKS_CONFIG")
_assert "config no se sobrescribió" "$content" "not-json"

echo
echo "=== T25: add round-trip por hooks_list_for visible"
_reset
hooks_cli add tool_pre read_file 'echo via-cli-1' >/dev/null
hooks_cli add tool_pre read_file 'echo via-cli-2' >/dev/null
hooks_cli add tool_pre '*'       'echo wildcard' >/dev/null
listed=$(hooks_list_for tool_pre read_file)
_assert_contains "list_for ve cmd-1" "echo via-cli-1" "$listed"
_assert_contains "list_for ve cmd-2" "echo via-cli-2" "$listed"
_assert_contains "list_for ve wildcard tras tool-specific" "echo wildcard" "$listed"
# tool-specific debe aparecer antes que wildcard
first=$(printf '%s\n' "$listed" | head -1)
_assert "tool-specific primero" "$first" "echo via-cli-1"

echo
echo "=== T26: list con cmd que contiene comillas/escapes => muestra verbatim"
_reset
# shellcheck disable=SC2016
hooks_cli add tool_pre read_file 'echo "$VAR" | tee /tmp/x' >/dev/null
out=$(hooks_cli list 2>/dev/null)
# shellcheck disable=SC2016
_assert_contains "list preserva quotes" '"$VAR"' "$out"
_assert_contains "list preserva pipe"   '| tee'  "$out"

echo
echo "=== T27: removed mensaje cuenta plural correcto"
_reset
hooks_cli add tool_pre read_file 'a' >/dev/null
ec=0
out=$(hooks_cli remove tool_pre read_file --all 2>/dev/null) || ec=$?
_assert "remove --all single exit 0" "$ec" "0"
_assert_contains "muestra count=1" "(1 hook(s))" "$out"

echo
echo "=== Resultado: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
