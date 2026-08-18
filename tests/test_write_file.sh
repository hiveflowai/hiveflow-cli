#!/bin/bash
#
# Smoke test standalone para lib/tools/write_file.sh
# - Aisla PERMISSIONS_CONFIG / CODER_BACKUP_DIR / CONFIG_DIR en tmpdir.
# - cd al tmpdir para tests con cwd controlado (containment, etc).
# - Exit != 0 si algun assert falla.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# shellcheck source=../lib/tool_calling.sh disable=SC1091
source "$REPO_ROOT/lib/agent/tool_calling.sh"
# shellcheck source=../lib/permissions.sh disable=SC1091
source "$REPO_ROOT/lib/agent/permissions.sh"

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT INT TERM

export PERMISSIONS_CONFIG="$TMPDIR_TEST/permissions.json"
export CODER_BACKUP_DIR="$TMPDIR_TEST/backups"
export CONFIG_DIR="$TMPDIR_TEST/cfg"
export CODER_YES=1

mkdir -p "$TMPDIR_TEST/work"
cd "$TMPDIR_TEST/work"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (missing: '$needle')"
        echo "       output was: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_eq() {
    local desc="$1"
    local file="$2"
    local expected="$3"
    local actual
    if [ ! -f "$file" ]; then
        echo "  FAIL: $desc (file not found: $file)"
        FAIL=$((FAIL + 1))
        return
    fi
    actual=$(cat "$file")
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (file content mismatch)"
        echo "       expected: $expected"
        echo "       got:      $actual"
        FAIL=$((FAIL + 1))
    fi
}

# --- Registracion + definition ---
echo "=== Test: registracion"
register_tool write_file
if list_registered_tools | grep -q '^write_file$'; then
    echo "  PASS: write_file en REGISTERED_TOOLS"
    PASS=$((PASS + 1))
else
    echo "  FAIL: write_file no aparece en REGISTERED_TOOLS"
    FAIL=$((FAIL + 1))
fi

echo "=== Test: definition emite JSON valido"
def=$(get_tool_definition write_file)
if echo "$def" | jq -e '.name == "write_file"' >/dev/null; then
    echo "  PASS: definition.name == write_file"
    PASS=$((PASS + 1))
else
    echo "  FAIL: definition.name != write_file"
    FAIL=$((FAIL + 1))
fi
if echo "$def" | jq -e '.input_schema.required | index("path") and index("content")' >/dev/null; then
    echo "  PASS: definition requiere path + content"
    PASS=$((PASS + 1))
else
    echo "  FAIL: definition no marca path/content como required"
    FAIL=$((FAIL + 1))
fi

# --- Happy path: archivo nuevo ---
echo "=== Test: write file nuevo (sin backup)"
out=$(dispatch_tool write_file '{"path":"new.txt","content":"hello world"}')
rc=$?
assert_eq "exit 0" "0" "$rc"
assert_contains "mensaje 'wrote 11 bytes'" "wrote 11 bytes" "$out"
assert_contains "mensaje 'new file, no backup'" "new file, no backup" "$out"
assert_file_eq "contenido escrito" "$TMPDIR_TEST/work/new.txt" "hello world"

# --- Happy path: overwrite con backup ---
echo "=== Test: overwrite crea backup"
out=$(dispatch_tool write_file '{"path":"new.txt","content":"version 2"}')
rc=$?
assert_eq "exit 0" "0" "$rc"
assert_contains "mensaje incluye 'backup:'" "backup:" "$out"
assert_file_eq "archivo tiene nuevo contenido" "$TMPDIR_TEST/work/new.txt" "version 2"

# Extraer backup path del mensaje y verificar que tiene el contenido original.
backup_msg_path=$(echo "$out" | sed -n 's/.*backup: \([^)]*\)).*/\1/p')
if [ -n "$backup_msg_path" ] && [ -f "$backup_msg_path" ]; then
    backup_content=$(cat "$backup_msg_path")
    assert_eq "backup contiene contenido original" "hello world" "$backup_content"
else
    echo "  FAIL: backup file no parseable de mensaje: '$out'"
    FAIL=$((FAIL + 1))
fi

# --- Empty content permitido ---
echo "=== Test: contenido vacio produce archivo vacio"
out=$(dispatch_tool write_file '{"path":"empty.txt","content":""}')
rc=$?
assert_eq "exit 0" "0" "$rc"
assert_contains "mensaje 'wrote 0 bytes'" "wrote 0 bytes" "$out"
if [ -f "$TMPDIR_TEST/work/empty.txt" ] && [ ! -s "$TMPDIR_TEST/work/empty.txt" ]; then
    echo "  PASS: empty.txt creado y vacio"
    PASS=$((PASS + 1))
else
    echo "  FAIL: empty.txt no creado o no vacio"
    FAIL=$((FAIL + 1))
fi

# --- Contenido con saltos de linea ---
echo "=== Test: contenido multilinea"
multiline_input=$(jq -nc --arg c "line1
line2
line3" '{path:"multi.txt", content:$c}')
out=$(dispatch_tool write_file "$multiline_input")
rc=$?
assert_eq "exit 0" "0" "$rc"
line_count=$(wc -l < "$TMPDIR_TEST/work/multi.txt" | tr -d ' ')
# "line1\nline2\nline3" tiene 2 newlines, wc -l cuenta 2.
assert_eq "wc -l == 2" "2" "$line_count"

# --- Input validation ---
echo "=== Test: input JSON invalido"
set +e
err=$(dispatch_tool write_file 'not json' 2>&1)
rc=$?
set -e
assert_eq "exit 2 (dispatch_tool valida JSON)" "2" "$rc"

echo "=== Test: path missing"
set +e
err=$(dispatch_tool write_file '{"content":"x"}' 2>&1)
rc=$?
set -e
assert_eq "exit 2 cuando falta path" "2" "$rc"
assert_contains "mensaje path missing" "missing required field 'path'" "$err"

echo "=== Test: content missing"
set +e
err=$(dispatch_tool write_file '{"path":"x.txt"}' 2>&1)
rc=$?
set -e
assert_eq "exit 2 cuando falta content" "2" "$rc"
assert_contains "mensaje content missing" "missing required field 'content'" "$err"

echo "=== Test: path vacio"
set +e
err=$(dispatch_tool write_file '{"path":"","content":"x"}' 2>&1)
rc=$?
set -e
assert_eq "exit 2 path vacio" "2" "$rc"

# --- Containment ---
echo "=== Test: path fuera de cwd rechazado"
external_path="$TMPDIR_TEST/outside.txt"
input=$(jq -nc --arg p "$external_path" '{path:$p, content:"x"}')
set +e
err=$(dispatch_tool write_file "$input" 2>&1)
rc=$?
set -e
assert_eq "exit 1 path fuera de cwd" "1" "$rc"
assert_contains "mensaje 'outside cwd'" "outside cwd" "$err"
if [ -e "$external_path" ]; then
    echo "  FAIL: archivo se escribio fuera de cwd ($external_path)"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: nada escrito fuera de cwd"
    PASS=$((PASS + 1))
fi

echo "=== Test: symlink rechazado"
echo "target" > "$TMPDIR_TEST/target.txt"
ln -s "$TMPDIR_TEST/target.txt" "$TMPDIR_TEST/work/link.txt"
set +e
err=$(dispatch_tool write_file '{"path":"link.txt","content":"clobber"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1 symlink" "1" "$rc"
assert_contains "mensaje 'symlink'" "symlink" "$err"
target_after=$(cat "$TMPDIR_TEST/target.txt")
assert_eq "target sin tocar" "target" "$target_after"
rm -f "$TMPDIR_TEST/work/link.txt"

echo "=== Test: path apunta a directorio"
mkdir -p "$TMPDIR_TEST/work/subdir"
set +e
err=$(dispatch_tool write_file '{"path":"subdir","content":"x"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1 directorio" "1" "$rc"
assert_contains "mensaje not a regular file" "not a regular file" "$err"

echo "=== Test: parent inexistente"
set +e
err=$(dispatch_tool write_file '{"path":"nonexistent/foo.txt","content":"x"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1 parent inexistente" "1" "$rc"
assert_contains "mensaje parent" "parent directory" "$err"

# --- Permisos ---
echo "=== Test: needs-confirm + CODER_YES=0 + no-TTY => denied"
CODER_YES=0 set +e
err=$(CODER_YES=0 dispatch_tool write_file '{"path":"needs_confirm.txt","content":"x"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1 sin auto-yes en no-TTY" "1" "$rc"
if [ -e "$TMPDIR_TEST/work/needs_confirm.txt" ]; then
    echo "  FAIL: archivo se escribio aunque permission fue denied"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: nada escrito tras denied"
    PASS=$((PASS + 1))
fi

echo "=== Test: denylist gana sobre CODER_YES=1"
# Glob pattern para cubrir canonicalizacion de path (macOS /var/ -> /private/var/).
permissions_deny write_file "*/blocked.txt"
set +e
err=$(dispatch_tool write_file '{"path":"blocked.txt","content":"x"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1 denylist match" "1" "$rc"
if [ -e "$TMPDIR_TEST/work/blocked.txt" ]; then
    echo "  FAIL: archivo escrito aunque estaba en denylist"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: denylist bloqueo el write"
    PASS=$((PASS + 1))
fi
permissions_remove deny write_file "*/blocked.txt" >/dev/null

echo "=== Test: allowlist permite write con CODER_YES=0"
permissions_allow write_file "*/allowed.txt"
out=$(CODER_YES=0 dispatch_tool write_file '{"path":"allowed.txt","content":"ok"}')
rc=$?
assert_eq "exit 0 allowlist match" "0" "$rc"
assert_file_eq "archivo allowlist escrito" "$TMPDIR_TEST/work/allowed.txt" "ok"

# --- Backup integrity: timestamp + basename ---
echo "=== Test: backup dir creado bajo CODER_BACKUP_DIR"
ls "$CODER_BACKUP_DIR" >/dev/null 2>&1
backup_dirs=$(find "$CODER_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
if [ "$backup_dirs" -ge 1 ]; then
    echo "  PASS: al menos un backup subdir creado ($backup_dirs total)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: ningun backup subdir en $CODER_BACKUP_DIR"
    FAIL=$((FAIL + 1))
fi

# --- Failure mode: confirm_permission undefined ---
echo "=== Test: tool falla si confirm_permission no esta cargado"
if (
    unset -f confirm_permission check_permission
    set +e
    err=$(dispatch_tool write_file '{"path":"no_perm.txt","content":"x"}' 2>&1)
    rc=$?
    set -e
    [ "$rc" = "1" ] || exit 1
    echo "$err" | grep -qF "permissions.sh not loaded" || exit 1
    [ ! -e "$TMPDIR_TEST/work/no_perm.txt" ] || exit 1
); then
    echo "  PASS: write rechazado sin permissions.sh"
    PASS=$((PASS + 1))
else
    echo "  FAIL: write_file no detecto modulo faltante"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "==============================="
echo "Resultado: $PASS pass, $FAIL fail"
echo "==============================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
