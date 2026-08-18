#!/bin/bash
#
# Smoke test standalone para lib/tools/read_file.sh
# Sourcea lib/tool_calling.sh, registra la tool, ejerce el dispatcher.
# Sale != 0 ante cualquier fallo. Pensado para CI futuro (M1 / bats opcional).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT"

# shellcheck source=../lib/tool_calling.sh disable=SC1091
source "$REPO_ROOT/lib/agent/tool_calling.sh"

PASS=0
FAIL=0
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

assert_ok() {
    local desc="$1"
    local expected_exit="$2"
    local actual_exit="$3"
    if [ "$actual_exit" = "$expected_exit" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected exit $expected_exit, got $actual_exit)"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (missing: '$needle')"
        echo "       output was: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Test: registración"
register_tool read_file
if list_registered_tools | grep -q '^read_file$'; then
    echo "  PASS: read_file en REGISTERED_TOOLS"
    PASS=$((PASS + 1))
else
    echo "  FAIL: read_file no aparece en REGISTERED_TOOLS"
    FAIL=$((FAIL + 1))
fi

echo "=== Test: definition emite JSON válido"
def=$(get_tool_definition read_file)
if echo "$def" | jq -e '.name == "read_file"' >/dev/null; then
    echo "  PASS: definition.name == read_file"
    PASS=$((PASS + 1))
else
    echo "  FAIL: definition no contiene name=read_file"
    FAIL=$((FAIL + 1))
fi
if echo "$def" | jq -e '.input_schema.required | index("path")' >/dev/null; then
    echo "  PASS: definition requiere path"
    PASS=$((PASS + 1))
else
    echo "  FAIL: definition no marca path como required"
    FAIL=$((FAIL + 1))
fi

echo "=== Test: dispatch happy path (tests/fixtures/sample_config.sh)"
out=$(dispatch_tool read_file '{"path":"tests/fixtures/sample_config.sh","limit":3}')
rc=$?
assert_ok "exit code 0" "0" "$rc"
assert_contains "line 1 con prefijo numérico" "     1" "$out"
line_count=$(echo "$out" | wc -l | tr -d ' ')
if [ "$line_count" = "3" ]; then
    echo "  PASS: limit=3 emitió 3 líneas (got $line_count)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: limit=3 esperaba 3 líneas, obtuvo $line_count"
    FAIL=$((FAIL + 1))
fi

echo "=== Test: offset funciona"
out=$(dispatch_tool read_file '{"path":"tests/fixtures/sample_config.sh","offset":10,"limit":2}')
first_line_nr=$(echo "$out" | head -1 | awk '{print $1}')
if [ "$first_line_nr" = "10" ]; then
    echo "  PASS: offset=10 emitió línea 10 primero"
    PASS=$((PASS + 1))
else
    echo "  FAIL: offset=10 esperaba primera línea 10, obtuvo '$first_line_nr'"
    FAIL=$((FAIL + 1))
fi

echo "=== Test: archivo inexistente"
set +e
err=$(dispatch_tool read_file '{"path":"lib/does_not_exist.sh"}' 2>&1)
rc=$?
set -e
assert_ok "exit code 1 para archivo inexistente" "1" "$rc"
assert_contains "mensaje 'file not found'" "file not found" "$err"

echo "=== Test: directorio rechazado"
set +e
err=$(dispatch_tool read_file '{"path":"lib"}' 2>&1)
rc=$?
set -e
assert_ok "exit code 1 para directorio" "1" "$rc"
assert_contains "mensaje sobre directorio" "directory" "$err"

echo "=== Test: path fuera de cwd rechazado"
external="$TMPDIR_TEST/escape.txt"
echo "secret" > "$external"
set +e
err=$(dispatch_tool read_file "{\"path\":\"$external\"}" 2>&1)
rc=$?
set -e
assert_ok "exit code 1 para path fuera de cwd" "1" "$rc"
assert_contains "mensaje 'outside cwd'" "outside cwd" "$err"

echo "=== Test: symlink rechazado"
ln -s "$external" "$REPO_ROOT/.ralph_symlink_test" 2>/dev/null || true
set +e
err=$(dispatch_tool read_file '{"path":".ralph_symlink_test"}' 2>&1)
rc=$?
set -e
rm -f "$REPO_ROOT/.ralph_symlink_test"
assert_ok "exit code 1 para symlink" "1" "$rc"
assert_contains "mensaje 'symlink'" "symlink" "$err"

echo "=== Test: JSON inválido"
set +e
err=$(dispatch_tool read_file 'not json' 2>&1)
rc=$?
set -e
assert_ok "exit code 2 para JSON inválido" "2" "$rc"

echo "=== Test: path missing"
set +e
err=$(dispatch_tool read_file '{}' 2>&1)
rc=$?
set -e
assert_ok "exit code 2 cuando falta path" "2" "$rc"

echo "=== Test: offset inválido"
set +e
err=$(dispatch_tool read_file '{"path":"tests/fixtures/sample_config.sh","offset":-1}' 2>&1)
rc=$?
set -e
assert_ok "exit code 2 para offset negativo" "2" "$rc"

echo ""
echo "==============================="
echo "Resultado: $PASS pass, $FAIL fail"
echo "==============================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
