#!/bin/bash
#
# M2.1b CLI dispatcher (`permissions_cli`) — unit tests.
# Aislamos `PERMISSIONS_CONFIG` a un tmp dir; las funciones subyacentes
# (`permissions_allow/deny/list/remove`) están cubiertas por
# tests/test_permissions.sh — aquí validamos el dispatcher: parsing de
# subcommand, validación de argc, exit codes (0 ok / 2 usage), y que
# las side-effects lleguen al config.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT" || exit 1

TMP_DIR=$(mktemp -d)
export PERMISSIONS_CONFIG="$TMP_DIR/permissions.json"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# shellcheck source=../lib/permissions.sh disable=SC1091
source "$REPO_ROOT/lib/agent/permissions.sh"

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
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (missing: '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

_reset() {
    rm -f "$PERMISSIONS_CONFIG"
    permissions_init >/dev/null
}

echo "=== T1: sin subcommand => usage en stderr + exit 2"
_reset
ec=0
out=$(permissions_cli 2>&1 >/dev/null) || ec=$?
_assert "exit 2 sin subcommand" "$ec" "2"
_assert_contains "stderr menciona Uso" "Usage:" "$out"

echo
echo "=== T2: subcommand list (vacío) imprime headers y allow/deny vacíos"
_reset
ec=0
out=$(permissions_cli list 2>/dev/null) || ec=$?
_assert "list exit 0" "$ec" "0"
_assert_contains "list hardcoded denylist header" "Hardcoded denylist" "$out"
_assert_contains "list read-only header"          "Read-only tools"    "$out"
_assert_contains "list muestra (empty)"           "(empty)"            "$out"

echo
echo "=== T3: allow ok persiste entry"
_reset
ec=0
permissions_cli allow write_file '/tmp/a/*' >/dev/null 2>&1 || ec=$?
_assert "allow exit 0" "$ec" "0"
count=$(jq -r '[.allowlist[] | select(.tool=="write_file" and .pattern=="/tmp/a/*")] | length' "$PERMISSIONS_CONFIG")
_assert "entry persistida en allowlist" "$count" "1"

echo
echo "=== T4: allow con args insuficientes => exit 2 + usage"
_reset
ec=0
err=$(permissions_cli allow write_file 2>&1 >/dev/null) || ec=$?
_assert "allow sin pattern → exit 2" "$ec" "2"
_assert_contains "stderr menciona expected" "expected" "$err"
ec=0
permissions_cli allow >/dev/null 2>&1 || ec=$?
_assert "allow sin tool ni pattern → exit 2" "$ec" "2"
ec=0
permissions_cli allow a b c >/dev/null 2>&1 || ec=$?
_assert "allow con 3 args → exit 2" "$ec" "2"

echo
echo "=== T5: deny ok persiste entry"
_reset
ec=0
permissions_cli deny bash_exec '*curl evil*' >/dev/null 2>&1 || ec=$?
_assert "deny exit 0" "$ec" "0"
count=$(jq -r '[.denylist[] | select(.tool=="bash_exec" and .pattern=="*curl evil*")] | length' "$PERMISSIONS_CONFIG")
_assert "entry persistida en denylist" "$count" "1"

echo
echo "=== T6: deny con args insuficientes => exit 2"
_reset
ec=0
permissions_cli deny bash_exec >/dev/null 2>&1 || ec=$?
_assert "deny sin pattern → exit 2" "$ec" "2"

echo
echo "=== T7: remove ok elimina entry"
_reset
permissions_cli allow write_file '/tmp/x/*' >/dev/null 2>&1
permissions_cli allow write_file '/tmp/y/*' >/dev/null 2>&1
ec=0
permissions_cli remove allow write_file '/tmp/x/*' >/dev/null 2>&1 || ec=$?
_assert "remove exit 0" "$ec" "0"
count=$(jq -r '[.allowlist[] | select(.pattern=="/tmp/x/*")] | length' "$PERMISSIONS_CONFIG")
_assert "/tmp/x/* removed" "$count" "0"
count=$(jq -r '[.allowlist[] | select(.pattern=="/tmp/y/*")] | length' "$PERMISSIONS_CONFIG")
_assert "/tmp/y/* preserved" "$count" "1"

echo
echo "=== T8: remove con args insuficientes => exit 2"
_reset
ec=0
permissions_cli remove allow write_file >/dev/null 2>&1 || ec=$?
_assert "remove sin pattern → exit 2" "$ec" "2"
ec=0
permissions_cli remove allow >/dev/null 2>&1 || ec=$?
_assert "remove sin tool ni pattern → exit 2" "$ec" "2"

echo
echo "=== T9: remove con list inválida => exit != 0 (propagado del módulo)"
_reset
ec=0
permissions_cli remove bogus write_file '/tmp/x' >/dev/null 2>&1 || ec=$?
_assert "remove con list inválida → exit != 0" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"

echo
echo "=== T10: subcommand desconocido => exit 2 + usage"
_reset
ec=0
err=$(permissions_cli bogus 2>&1 >/dev/null) || ec=$?
_assert "bogus exit 2" "$ec" "2"
_assert_contains "stderr menciona unknown subcommand" "unknown subcommand" "$err"
_assert_contains "stderr incluye usage" "Subcommands:" "$err"

echo
echo "=== T11: --help / -h / help imprimen usage en stdout y exit 0"
_reset
ec=0
out=$(permissions_cli --help 2>/dev/null) || ec=$?
_assert "--help exit 0" "$ec" "0"
_assert_contains "--help muestra Subcommands" "Subcommands:" "$out"
ec=0
out=$(permissions_cli -h 2>/dev/null) || ec=$?
_assert "-h exit 0" "$ec" "0"
ec=0
out=$(permissions_cli help 2>/dev/null) || ec=$?
_assert "help (bareword) exit 0" "$ec" "0"
_assert_contains "help muestra Examples" "Examples:" "$out"

echo
echo "=== T12: list refleja modificaciones hechas via cli"
_reset
permissions_cli allow write_file '/tmp/listed/*' >/dev/null 2>&1
permissions_cli deny  bash_exec  'curl *evil*'   >/dev/null 2>&1
out=$(permissions_cli list 2>/dev/null)
_assert_contains "list muestra allow entry" "/tmp/listed/*" "$out"
_assert_contains "list muestra deny entry"  "curl *evil*"   "$out"

echo
echo "=== T13: shift de subcommand no contamina argv (espacios y globs)"
_reset
permissions_cli allow write_file '/tmp/with spaces/*.txt' >/dev/null 2>&1
count=$(jq -r '[.allowlist[] | select(.pattern=="/tmp/with spaces/*.txt")] | length' "$PERMISSIONS_CONFIG")
_assert "pattern con espacios preservado" "$count" "1"

echo
echo "=== Resultado: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
