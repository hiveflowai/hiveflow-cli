#!/bin/bash
#
# Smoke test standalone para lib/tools/edit_file.sh
# - Aisla PERMISSIONS_CONFIG / CODER_BACKUP_DIR / CONFIG_DIR en tmpdir.
# - cd al tmpdir para tests con cwd controlado (containment, etc).
# - Exit != 0 si algun assert falla.

set -uo pipefail

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

assert_file_bytes_eq() {
    # Compara bytes exactos (incluye trailing newlines).
    local desc="$1"
    local file="$2"
    local expected="$3"
    if [ ! -f "$file" ]; then
        echo "  FAIL: $desc (file not found: $file)"
        FAIL=$((FAIL + 1))
        return
    fi
    local got_hex want_hex
    got_hex=$(xxd -p "$file" | tr -d '\n')
    want_hex=$(printf '%s' "$expected" | xxd -p | tr -d '\n')
    if [ "$got_hex" = "$want_hex" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (byte mismatch)"
        echo "       expected hex: $want_hex"
        echo "       got hex:      $got_hex"
        FAIL=$((FAIL + 1))
    fi
}

# --- Registracion + definition ---
echo "=== Test: registracion"
register_tool edit_file
if list_registered_tools | grep -q '^edit_file$'; then
    echo "  PASS: edit_file en REGISTERED_TOOLS"
    PASS=$((PASS + 1))
else
    echo "  FAIL: edit_file no aparece en REGISTERED_TOOLS"
    FAIL=$((FAIL + 1))
fi

echo "=== Test: definition emite JSON valido"
def=$(get_tool_definition edit_file)
if echo "$def" | jq -e '.name == "edit_file"' >/dev/null; then
    echo "  PASS: definition.name == edit_file"
    PASS=$((PASS + 1))
else
    echo "  FAIL: definition.name != edit_file"
    FAIL=$((FAIL + 1))
fi
required=$(echo "$def" | jq -r '.input_schema.required | sort | join(",")')
assert_eq "definition requiere path,old_string,new_string" "new_string,old_string,path" "$required"

# --- Happy path: single unique replacement ---
echo "=== Test: reemplazo unico"
printf 'foo\nbar\nbaz\n' > "$TMPDIR_TEST/work/single.txt"
out=$(dispatch_tool edit_file '{"path":"single.txt","old_string":"bar","new_string":"BAR"}')
rc=$?
assert_eq "exit 0" "0" "$rc"
assert_contains "mensaje 'replaced 1 occurrence'" "replaced 1 occurrence" "$out"
assert_contains "mensaje incluye 'backup:'" "backup:" "$out"
assert_file_bytes_eq "contenido modificado (trailing newline preservado)" "$TMPDIR_TEST/work/single.txt" 'foo
BAR
baz
'

# --- Match no encontrado ---
echo "=== Test: old_string no encontrado"
set +e
err=$(dispatch_tool edit_file '{"path":"single.txt","old_string":"NOPE","new_string":"x"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1" "1" "$rc"
assert_contains "mensaje 'not found'" "not found" "$err"

# --- Match duplicado sin replace_all ---
echo "=== Test: old_string no unico sin replace_all"
printf 'aa\nbb\naa\n' > "$TMPDIR_TEST/work/dup.txt"
set +e
err=$(dispatch_tool edit_file '{"path":"dup.txt","old_string":"aa","new_string":"AA"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1 cuando no es unico" "1" "$rc"
assert_contains "mensaje 'not unique'" "not unique" "$err"
assert_contains "mensaje cuenta matches" "2 matches" "$err"
assert_file_bytes_eq "archivo intacto tras rechazo de no-unique" "$TMPDIR_TEST/work/dup.txt" 'aa
bb
aa
'

# --- replace_all=true ---
echo "=== Test: replace_all=true reemplaza todas las ocurrencias"
out=$(dispatch_tool edit_file '{"path":"dup.txt","old_string":"aa","new_string":"AA","replace_all":true}')
rc=$?
assert_eq "exit 0" "0" "$rc"
assert_contains "mensaje 'replaced 2 occurrence'" "replaced 2 occurrence" "$out"
assert_file_bytes_eq "ambas ocurrencias reemplazadas" "$TMPDIR_TEST/work/dup.txt" 'AA
bb
AA
'

# --- dry_run ---
echo "=== Test: dry_run muestra diff y NO modifica"
printf 'hello\nworld\n' > "$TMPDIR_TEST/work/dryrun.txt"
out=$(dispatch_tool edit_file '{"path":"dryrun.txt","old_string":"world","new_string":"WORLD","dry_run":true}')
rc=$?
assert_eq "exit 0 dry_run" "0" "$rc"
assert_contains "mensaje 'dry_run'" "dry_run" "$out"
assert_contains "diff con '-world'" "-world" "$out"
assert_contains "diff con '+WORLD'" "+WORLD" "$out"
assert_file_bytes_eq "archivo NO modificado tras dry_run" "$TMPDIR_TEST/work/dryrun.txt" 'hello
world
'

# --- new_string vacio (deletion) ---
echo "=== Test: new_string vacio elimina el old_string"
printf 'keep this delete this\n' > "$TMPDIR_TEST/work/del.txt"
out=$(dispatch_tool edit_file '{"path":"del.txt","old_string":" delete this","new_string":""}')
rc=$?
assert_eq "exit 0 deletion" "0" "$rc"
assert_file_bytes_eq "deletion aplicada" "$TMPDIR_TEST/work/del.txt" 'keep this
'

# --- Multiline old_string ---
echo "=== Test: old_string multilinea"
printf 'alpha\nbeta\ngamma\ndelta\n' > "$TMPDIR_TEST/work/multi.txt"
in=$(jq -nc --arg o 'beta
gamma' --arg n 'BETA
GAMMA' '{path:"multi.txt", old_string:$o, new_string:$n}')
out=$(dispatch_tool edit_file "$in")
rc=$?
assert_eq "exit 0 multilinea" "0" "$rc"
assert_file_bytes_eq "bloque multilinea reemplazado" "$TMPDIR_TEST/work/multi.txt" 'alpha
BETA
GAMMA
delta
'

# --- Bytes especiales (regex chars) ---
echo "=== Test: regex chars son literales (no metacharacter)"
printf 'a.b*c?d[e]f\n' > "$TMPDIR_TEST/work/regex.txt"
out=$(dispatch_tool edit_file '{"path":"regex.txt","old_string":".b*c?d[e]","new_string":"X"}')
rc=$?
assert_eq "exit 0 con regex chars" "0" "$rc"
assert_file_bytes_eq "regex chars tratados literalmente" "$TMPDIR_TEST/work/regex.txt" 'aXf
'

# --- Archivo SIN trailing newline ---
echo "=== Test: archivo sin trailing newline preserva no-newline final"
printf 'one\ntwo' > "$TMPDIR_TEST/work/notrail.txt"
out=$(dispatch_tool edit_file '{"path":"notrail.txt","old_string":"two","new_string":"TWO"}')
rc=$?
assert_eq "exit 0" "0" "$rc"
assert_file_bytes_eq "trailing-newlessness preservada" "$TMPDIR_TEST/work/notrail.txt" 'one
TWO'

# --- Input validation ---
echo "=== Test: input JSON invalido"
set +e
err=$(dispatch_tool edit_file 'not json' 2>&1)
rc=$?
set -e
assert_eq "exit 2 JSON invalido" "2" "$rc"

echo "=== Test: path missing"
set +e
err=$(dispatch_tool edit_file '{"old_string":"x","new_string":"y"}' 2>&1)
rc=$?
set -e
assert_eq "exit 2 path missing" "2" "$rc"
assert_contains "mensaje path missing" "missing required field 'path'" "$err"

echo "=== Test: old_string missing"
set +e
err=$(dispatch_tool edit_file '{"path":"single.txt","new_string":"y"}' 2>&1)
rc=$?
set -e
assert_eq "exit 2 old_string missing" "2" "$rc"
assert_contains "mensaje old_string missing" "missing required field 'old_string'" "$err"

echo "=== Test: new_string missing"
set +e
err=$(dispatch_tool edit_file '{"path":"single.txt","old_string":"x"}' 2>&1)
rc=$?
set -e
assert_eq "exit 2 new_string missing" "2" "$rc"
assert_contains "mensaje new_string missing" "missing required field 'new_string'" "$err"

echo "=== Test: old_string vacio rechazado"
set +e
err=$(dispatch_tool edit_file '{"path":"single.txt","old_string":"","new_string":"y"}' 2>&1)
rc=$?
set -e
assert_eq "exit 2 old_string vacio" "2" "$rc"
assert_contains "mensaje old_string non-empty" "must be a non-empty string" "$err"

# --- Containment ---
echo "=== Test: path fuera de cwd rechazado"
echo "external content with marker" > "$TMPDIR_TEST/outside.txt"
input=$(jq -nc --arg p "$TMPDIR_TEST/outside.txt" '{path:$p, old_string:"marker", new_string:"x"}')
set +e
err=$(dispatch_tool edit_file "$input" 2>&1)
rc=$?
set -e
assert_eq "exit 1 fuera de cwd" "1" "$rc"
assert_contains "mensaje 'outside cwd'" "outside cwd" "$err"
assert_contains "archivo externo intacto" "marker" "$(cat "$TMPDIR_TEST/outside.txt")"

echo "=== Test: symlink rechazado"
echo "target original" > "$TMPDIR_TEST/symtarget.txt"
ln -s "$TMPDIR_TEST/symtarget.txt" "$TMPDIR_TEST/work/sym.txt"
set +e
err=$(dispatch_tool edit_file '{"path":"sym.txt","old_string":"original","new_string":"clobber"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1 symlink" "1" "$rc"
assert_contains "mensaje 'symlink'" "symlink" "$err"
target_after=$(cat "$TMPDIR_TEST/symtarget.txt")
assert_contains "target sin tocar" "original" "$target_after"
rm -f "$TMPDIR_TEST/work/sym.txt"

echo "=== Test: archivo inexistente"
set +e
err=$(dispatch_tool edit_file '{"path":"ghost.txt","old_string":"x","new_string":"y"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1 inexistente" "1" "$rc"
assert_contains "mensaje 'file not found'" "file not found" "$err"

echo "=== Test: path apunta a directorio"
mkdir -p "$TMPDIR_TEST/work/somedir"
set +e
err=$(dispatch_tool edit_file '{"path":"somedir","old_string":"x","new_string":"y"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1 directorio" "1" "$rc"
assert_contains "mensaje not a regular file" "not a regular file" "$err"

# --- Permisos ---
echo "=== Test: needs-confirm + CODER_YES=0 + no-TTY => denied"
printf 'foo\n' > "$TMPDIR_TEST/work/perm.txt"
set +e
err=$(CODER_YES=0 dispatch_tool edit_file '{"path":"perm.txt","old_string":"foo","new_string":"FOO"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1 sin auto-yes en no-TTY" "1" "$rc"
assert_file_bytes_eq "archivo intacto tras denied" "$TMPDIR_TEST/work/perm.txt" 'foo
'

echo "=== Test: denylist gana sobre CODER_YES=1"
printf 'foo\n' > "$TMPDIR_TEST/work/blocked.txt"
permissions_deny edit_file "*/blocked.txt" >/dev/null
set +e
err=$(dispatch_tool edit_file '{"path":"blocked.txt","old_string":"foo","new_string":"FOO"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1 denylist match" "1" "$rc"
assert_file_bytes_eq "archivo intacto tras denylist" "$TMPDIR_TEST/work/blocked.txt" 'foo
'
permissions_remove deny edit_file "*/blocked.txt" >/dev/null

echo "=== Test: allowlist permite edit con CODER_YES=0"
printf 'foo\n' > "$TMPDIR_TEST/work/allowed.txt"
permissions_allow edit_file "*/allowed.txt" >/dev/null
out=$(CODER_YES=0 dispatch_tool edit_file '{"path":"allowed.txt","old_string":"foo","new_string":"FOO"}')
rc=$?
assert_eq "exit 0 allowlist match" "0" "$rc"
assert_file_bytes_eq "allowlist permite edit sin CODER_YES" "$TMPDIR_TEST/work/allowed.txt" 'FOO
'
permissions_remove allow edit_file "*/allowed.txt" >/dev/null

# --- Backup integrity ---
echo "=== Test: backup creado con contenido original"
printf 'before\n' > "$TMPDIR_TEST/work/backup.txt"
out=$(dispatch_tool edit_file '{"path":"backup.txt","old_string":"before","new_string":"after"}')
rc=$?
assert_eq "exit 0" "0" "$rc"
backup_msg_path=$(echo "$out" | sed -n 's/.*backup: \([^)]*\)).*/\1/p')
if [ -n "$backup_msg_path" ] && [ -f "$backup_msg_path" ]; then
    backup_content=$(cat "$backup_msg_path")
    assert_eq "backup contiene contenido original" "before" "$backup_content"
else
    echo "  FAIL: backup path no parseable de mensaje: '$out'"
    FAIL=$((FAIL + 1))
fi

# --- dry_run sin permission check ---
echo "=== Test: dry_run no requiere CODER_YES ni allowlist"
printf 'dry\n' > "$TMPDIR_TEST/work/dry_noperm.txt"
out=$(CODER_YES=0 dispatch_tool edit_file '{"path":"dry_noperm.txt","old_string":"dry","new_string":"WET","dry_run":true}')
rc=$?
assert_eq "exit 0 dry_run sin permiso" "0" "$rc"
assert_contains "mensaje dry_run" "dry_run" "$out"
assert_file_bytes_eq "archivo intacto tras dry_run sin permiso" "$TMPDIR_TEST/work/dry_noperm.txt" 'dry
'

# --- Failure mode: confirm_permission undefined ---
echo "=== Test: tool falla si confirm_permission no esta cargado"
printf 'orig\n' > "$TMPDIR_TEST/work/no_perm.txt"
if (
    unset -f confirm_permission check_permission
    set +e
    err=$(dispatch_tool edit_file '{"path":"no_perm.txt","old_string":"orig","new_string":"new"}' 2>&1)
    rc=$?
    set -e
    [ "$rc" = "1" ] || exit 1
    echo "$err" | grep -qF "permissions.sh not loaded" || exit 1
    [ "$(cat "$TMPDIR_TEST/work/no_perm.txt")" = "orig" ] || exit 1
); then
    echo "  PASS: edit rechazado sin permissions.sh"
    PASS=$((PASS + 1))
else
    echo "  FAIL: edit_file no detecto modulo faltante"
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
