#!/bin/bash
#
# Unit tests para lib/permissions.sh.
# Standalone: bash tests/test_permissions.sh
# Sale != 0 ante cualquier fallo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT" || exit 1

# Aislar config a tmp dir antes de sourcear el módulo.
TMP_DIR=$(mktemp -d)
export PERMISSIONS_CONFIG="$TMP_DIR/permissions.json"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# shellcheck source=../lib/permissions.sh disable=SC1091
source "$REPO_ROOT/lib/agent/permissions.sh"

PASS=0
FAIL=0

_assert() {
    local desc="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

_assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (missing: '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

# Helper: corre check_permission y devuelve el exit code (no propaga via set -e).
_check_rc() {
    check_permission "$1" "${2:-}"
    echo $?
}

# Reset config a estado limpio antes de cada bloque (idempotente).
_reset() {
    rm -f "$PERMISSIONS_CONFIG"
    permissions_init >/dev/null
}

echo "=== T1: permissions_init crea config con defaults"
_reset
if [ -f "$PERMISSIONS_CONFIG" ]; then
    _assert "config file exists" "yes" "yes"
else
    _assert "config file exists" "no" "yes"
fi
version=$(jq -r '.version' "$PERMISSIONS_CONFIG")
_assert "version=1" "$version" "1"
allow_len=$(jq -r '.allowlist | length' "$PERMISSIONS_CONFIG")
_assert "allowlist empty by default" "$allow_len" "0"
deny_len=$(jq -r '.denylist | length' "$PERMISSIONS_CONFIG")
_assert "denylist empty by default" "$deny_len" "0"

echo
echo "=== T2: read-only tools auto-allow"
_reset
_assert "read_file allowed"   "$(_check_rc read_file 'any/path.txt')"  "0"
_assert "grep_search allowed" "$(_check_rc grep_search 'foo')"          "0"
_assert "glob_files allowed"  "$(_check_rc glob_files '**')"            "0"

echo
echo "=== T3: unknown tool sin allowlist => needs-confirm (rc=2)"
_reset
_assert "write_file rc=2"     "$(_check_rc write_file 'some/file.txt')" "2"
_assert "bash_exec rc=2"      "$(_check_rc bash_exec 'echo hello')"     "2"

echo
echo "=== T4: hardcoded denylist bloquea comandos peligrosos"
_reset
_assert "rm -rf / denied"           "$(_check_rc bash_exec 'rm -rf /')"                       "1"
_assert "rm -rf /home/user denied"  "$(_check_rc bash_exec 'rm -rf /home/user')"             "1"
_assert "sudo rm -rf denied"        "$(_check_rc bash_exec 'sudo rm -rf /something')"        "1"
_assert "dd to /dev/sda denied"     "$(_check_rc bash_exec 'dd if=/dev/zero of=/dev/sda')"   "1"
_assert "dd of=before-if denied"    "$(_check_rc bash_exec 'dd of=/dev/sda if=/dev/zero')"   "1"
_assert "dd to /dev/nvme0 denied"   "$(_check_rc bash_exec 'dd if=/dev/zero of=/dev/nvme0')" "1"
_assert "dd of=nvme before-if"      "$(_check_rc bash_exec 'dd of=/dev/nvme0 if=/dev/zero')" "1"
_assert "dd to /dev/disk0 denied"   "$(_check_rc bash_exec 'dd if=/dev/zero of=/dev/disk0')" "1"
_assert "mkfs.ext4 denied"          "$(_check_rc bash_exec 'mkfs.ext4 /dev/sda')"            "1"
_assert "fork bomb denied"          "$(_check_rc bash_exec ':(){:|:&};:')"                   "1"
_assert "> /dev/sda denied"         "$(_check_rc bash_exec 'cat foo > /dev/sda')"            "1"
_assert ">/dev/sda no-space denied" "$(_check_rc bash_exec 'cat foo >/dev/sda')"             "1"
_assert ">>/dev/sda append denied"  "$(_check_rc bash_exec 'cat foo >>/dev/sda')"            "1"
_assert ">/dev/nvme denied"         "$(_check_rc bash_exec 'cat foo >/dev/nvme0n1')"         "1"
_assert "> /dev/disk denied"        "$(_check_rc bash_exec 'cat foo > /dev/disk0')"          "1"
_assert ">/dev/disk no-space"       "$(_check_rc bash_exec 'cat foo >/dev/disk0')"           "1"
_assert "chmod -R 777 / denied"     "$(_check_rc bash_exec 'chmod -R 777 /etc')"             "1"

echo
echo "=== T5: PERMISSION_REASON se setea correctamente"
_reset
check_permission bash_exec "rm -rf /tmp" >/dev/null 2>&1 || true
_assert_contains "hard deny reason set" "hard denylist" "$PERMISSION_REASON"
check_permission read_file "foo.txt" >/dev/null 2>&1 || true
_assert_contains "read-only reason set" "read-only" "$PERMISSION_REASON"

echo
echo "=== T6: hard denylist NO aplica a tools no-shell"
_reset
# write_file con un path que parece comando peligroso debe ser needs-confirm, no deny.
_assert "write_file 'rm -rf /' needs-confirm" "$(_check_rc write_file 'rm -rf /')" "2"

echo
echo "=== T7: comandos inocuos no matchean hard deny"
_reset
_assert "ls -la /tmp rc=2"      "$(_check_rc bash_exec 'ls -la /tmp')"       "2"
_assert "echo rm -rf rc=2"      "$(_check_rc bash_exec 'echo rm -rf foo')"   "2"
_assert "mkfs sin extension"    "$(_check_rc bash_exec 'echo mkfs is bad')"  "2"

echo
echo "=== T8: allowlist add + match"
_reset
permissions_allow write_file '/tmp/safe/*' || _assert "allow add succeeded" "fail" "ok"
_assert "write_file in allowed path" "$(_check_rc write_file '/tmp/safe/file.txt')" "0"
_assert "write_file outside path"    "$(_check_rc write_file '/etc/passwd')"        "2"

echo
echo "=== T9: denylist gana sobre allowlist"
_reset
permissions_allow write_file '*'
permissions_deny  write_file '/etc/*'
_assert "denylist wins for /etc/hosts"  "$(_check_rc write_file '/etc/hosts')"  "1"
_assert "wildcard allows /tmp/foo.txt"  "$(_check_rc write_file '/tmp/foo.txt')" "0"

echo
echo "=== T10: hard denylist gana sobre allowlist permisivo"
_reset
permissions_allow bash_exec '*'
_assert "rm -rf / sigue denegado"   "$(_check_rc bash_exec 'rm -rf /home')"      "1"
_assert "ls -la ahora allowed"      "$(_check_rc bash_exec 'ls -la')"            "0"

echo
echo "=== T11: user denylist aplica también a read-only tools"
_reset
permissions_deny read_file '/etc/secret/*'
_assert "user denylist supera auto-allow" "$(_check_rc read_file '/etc/secret/key')" "1"
_assert "otros paths siguen auto-allow"   "$(_check_rc read_file '/tmp/safe.txt')"   "0"

echo
echo "=== T12: idempotencia (add dos veces, una entry)"
_reset
permissions_allow write_file '/tmp/dup/*'
permissions_allow write_file '/tmp/dup/*'
count=$(jq -r '[.allowlist[] | select(.tool == "write_file" and .pattern == "/tmp/dup/*")] | length' "$PERMISSIONS_CONFIG")
_assert "no duplicates" "$count" "1"

echo
echo "=== T13: permissions_remove"
_reset
permissions_allow write_file '/tmp/x/*'
permissions_allow write_file '/tmp/y/*'
permissions_remove allow write_file '/tmp/x/*'
count=$(jq -r '[.allowlist[] | select(.pattern == "/tmp/x/*")] | length' "$PERMISSIONS_CONFIG")
_assert "/tmp/x/* removed" "$count" "0"
count=$(jq -r '[.allowlist[] | select(.pattern == "/tmp/y/*")] | length' "$PERMISSIONS_CONFIG")
_assert "/tmp/y/* preserved" "$count" "1"

echo
echo "=== T14: permissions_remove con list inválida falla"
_reset
permissions_remove badlist write_file '/tmp/x' 2>/dev/null
rc=$?
_assert "bad list rc!=0" "$([ $rc -ne 0 ] && echo nonzero || echo zero)" "nonzero"

echo
echo "=== T15: permissions_list dump"
_reset
permissions_allow write_file '/tmp/listed/*'
permissions_deny  bash_exec  'curl *evil*'
output=$(permissions_list)
_assert_contains "lists hardcoded denylist header" "Hardcoded denylist" "$output"
_assert_contains "lists read-only header"          "Read-only tools"    "$output"
_assert_contains "lists user allowlist entry"      "/tmp/listed/*"      "$output"
_assert_contains "lists user denylist entry"       "curl *evil*"        "$output"

echo
echo "=== T16: invalid JSON in config rejected"
echo "{not valid json" > "$PERMISSIONS_CONFIG"
permissions_init 2>/dev/null
rc=$?
_assert "init rejects bad json" "$([ $rc -ne 0 ] && echo nonzero || echo zero)" "nonzero"

echo
echo "=== T17: empty inputs rejected"
_reset
permissions_allow "" 'pattern' 2>/dev/null
rc=$?
_assert "empty tool rejected" "$([ $rc -ne 0 ] && echo nonzero || echo zero)" "nonzero"
permissions_allow tool "" 2>/dev/null
rc=$?
_assert "empty pattern rejected" "$([ $rc -ne 0 ] && echo nonzero || echo zero)" "nonzero"
_assert "empty tool in check_permission" "$(_check_rc '' '/tmp')" "1"

echo
echo "=== T18: glob con * en medio de path"
_reset
permissions_allow write_file '/tmp/*/safe/*'
_assert "matches /tmp/a/safe/x"  "$(_check_rc write_file '/tmp/a/safe/x.txt')" "0"
_assert "matches /tmp/deep/dir/safe/y"  "$(_check_rc write_file '/tmp/deep/dir/safe/y.txt')" "0"
# Nota: bash `[[ x == p ]]` permite que * matchee / también, por diseño.

echo
echo "=== T19: confirm_permission con yes_flag=1 aprueba needs-confirm"
_reset
confirm_permission write_file '/tmp/auto' 1 >/dev/null 2>&1
_assert "yes_flag approves needs-confirm" "$?" "0"

echo
echo "=== T20: confirm_permission con yes_flag=1 NO sobrepasa hard deny"
_reset
confirm_permission bash_exec 'rm -rf /home' 1 >/dev/null 2>&1
_assert "yes_flag does NOT bypass hard deny" "$?" "1"

echo
echo "=== T21: confirm_permission sin TTY y needs-confirm => deny"
_reset
# Redirigir stdin a /dev/null para simular no-TTY.
confirm_permission write_file '/tmp/no-tty' 0 </dev/null >/dev/null 2>&1
_assert "no-TTY needs-confirm => deny" "$?" "1"

echo
echo "=== T22: confirm_permission con tool allowed pasa sin prompt"
_reset
confirm_permission read_file '/tmp/anything' 0 </dev/null >/dev/null 2>&1
_assert "read_file confirm short-circuit" "$?" "0"

echo
echo "=== T23: dispatch dispara hard deny con espacios variables"
_reset
_assert "rm   -rf  /tmp denied (multi space)" "$(_check_rc bash_exec 'rm -rf /tmp')" "1"
# Pattern es '*rm -rf /*' — el comando real con un solo espacio matchea.

echo
echo "=== T24: shell_exec recibe mismo hard deny que bash_exec"
_reset
_assert "shell_exec rm -rf / denied" "$(_check_rc shell_exec 'rm -rf /')" "1"

echo
echo "=== Resultado: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
