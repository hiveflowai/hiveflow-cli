#!/bin/bash
#
# Smoke test standalone para lib/tools/glob_files.sh
# Sourcea lib/tool_calling.sh, registra la tool, ejerce el dispatcher contra
# archivos reales del repo (lib/, tests/) + un tmpdir aislado para casos de
# containment.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT"

# shellcheck source=../lib/tool_calling.sh disable=SC1091
source "$REPO_ROOT/lib/agent/tool_calling.sh"

PASS=0
FAIL=0
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST" "$REPO_ROOT/.ralph_glob_fixtures" "$REPO_ROOT/.ralph_symlink_glob_test"' EXIT

note() { printf '%s\n' "$1"; }

assert_ok() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        note "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        note "  FAIL: $desc (expected exit $expected, got $actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        note "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        note "  FAIL: $desc (missing: '$needle')"
        note "       output was: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        note "  FAIL: $desc (unexpectedly contains: '$needle')"
        note "       output was: $haystack"
        FAIL=$((FAIL + 1))
    else
        note "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

# =====================================================
# 1. Registro y definition
# =====================================================
note "=== Test: registración"
register_tool glob_files
if list_registered_tools | grep -q '^glob_files$'; then
    note "  PASS: glob_files en REGISTERED_TOOLS"
    PASS=$((PASS + 1))
else
    note "  FAIL: glob_files no aparece en REGISTERED_TOOLS"
    FAIL=$((FAIL + 1))
fi

note "=== Test: definition emite JSON válido"
def=$(get_tool_definition glob_files)
if echo "$def" | jq -e '.name == "glob_files"' >/dev/null; then
    note "  PASS: definition.name == glob_files"
    PASS=$((PASS + 1))
else
    note "  FAIL: definition no contiene name=glob_files"
    FAIL=$((FAIL + 1))
fi
if echo "$def" | jq -e '.input_schema.required | index("pattern")' >/dev/null; then
    note "  PASS: definition requiere pattern"
    PASS=$((PASS + 1))
else
    note "  FAIL: definition no marca pattern como required"
    FAIL=$((FAIL + 1))
fi
if echo "$def" | jq -e '.input_schema.properties.type.enum == ["file","dir","any"]' >/dev/null; then
    note "  PASS: type tiene enum file|dir|any"
    PASS=$((PASS + 1))
else
    note "  FAIL: enum de type incorrecto"
    FAIL=$((FAIL + 1))
fi
if echo "$def" | jq -e '.input_schema.properties.max_results.maximum == 1000' >/dev/null; then
    note "  PASS: max_results.maximum == 1000"
    PASS=$((PASS + 1))
else
    note "  FAIL: max_results.maximum no es 1000"
    FAIL=$((FAIL + 1))
fi

# =====================================================
# 2. Input validation (exit 2)
# =====================================================
note "=== Test: input vacío → exit 2"
set +e
err=$(dispatch_tool glob_files '' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 input vacío" "2" "$rc"

note "=== Test: pattern missing → exit 2"
set +e
err=$(dispatch_tool glob_files '{}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 pattern missing" "2" "$rc"
assert_contains "stderr menciona 'pattern'" "pattern" "$err"

note "=== Test: pattern vacío → exit 2"
set +e
err=$(dispatch_tool glob_files '{"pattern":""}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 pattern vacío" "2" "$rc"

note "=== Test: JSON inválido → exit 2"
set +e
err=$(dispatch_tool glob_files 'not json' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 JSON inválido" "2" "$rc"

note "=== Test: max_results=0 → exit 2"
set +e
err=$(dispatch_tool glob_files '{"pattern":"*.sh","max_results":0}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 max_results=0" "2" "$rc"

note "=== Test: max_results=-1 → exit 2"
set +e
err=$(dispatch_tool glob_files '{"pattern":"*.sh","max_results":-1}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 max_results=-1" "2" "$rc"

note "=== Test: max_results>1000 → exit 2"
set +e
err=$(dispatch_tool glob_files '{"pattern":"*.sh","max_results":1001}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 max_results=1001" "2" "$rc"

note "=== Test: case_insensitive no-bool → exit 2"
set +e
err=$(dispatch_tool glob_files '{"pattern":"*.sh","case_insensitive":"yes"}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 case_insensitive=string" "2" "$rc"

note "=== Test: type inválido → exit 2"
set +e
err=$(dispatch_tool glob_files '{"pattern":"*.sh","type":"symlink"}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 type=symlink" "2" "$rc"
assert_contains "stderr menciona 'type'" "'type'" "$err"

# =====================================================
# 3. Path containment / validation
# =====================================================
note "=== Test: path no existe → exit 1"
set +e
err=$(dispatch_tool glob_files '{"pattern":"*","path":"lib/does_not_exist__"}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 1 path no existe" "1" "$rc"
assert_contains "stderr menciona 'not found'" "not found" "$err"

note "=== Test: path es archivo (no dir) → exit 1"
set +e
err=$(dispatch_tool glob_files '{"pattern":"*","path":"tests/fixtures/sample_config.sh"}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 1 path es archivo" "1" "$rc"
assert_contains "stderr menciona 'not a directory'" "not a directory" "$err"

note "=== Test: path fuera de cwd → exit 1"
external_dir="$TMPDIR_TEST/escape"
mkdir -p "$external_dir"
echo "secreto" > "$external_dir/leak.txt"
set +e
err=$(dispatch_tool glob_files "{\"pattern\":\"*.txt\",\"path\":\"$external_dir\"}" 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 1 path fuera de cwd" "1" "$rc"
assert_contains "stderr menciona 'outside cwd'" "outside cwd" "$err"

note "=== Test: symlink rechazado"
ln -s "$external_dir" "$REPO_ROOT/.ralph_symlink_glob_test" 2>/dev/null || true
set +e
err=$(dispatch_tool glob_files '{"pattern":"*","path":".ralph_symlink_glob_test"}' 2>&1 >/dev/null); rc=$?
set -e
rm -f "$REPO_ROOT/.ralph_symlink_glob_test"
assert_ok "exit 1 symlink" "1" "$rc"
assert_contains "stderr menciona 'symlink'" "symlink" "$err"

# =====================================================
# 4. Happy paths: basename glob
# =====================================================
note "=== Test: happy path *.sh en lib/"
out=$(dispatch_tool glob_files '{"pattern":"*.sh","path":"lib"}' 2>&1)
rc=$?
assert_ok "exit 0 happy *.sh" "0" "$rc"
assert_contains "header con pattern=*.sh" "pattern=*.sh" "$out"
assert_contains "header con path=lib" "path=lib" "$out"
assert_contains "header con type=file" "type=file" "$out"
assert_contains "header con matches=" "matches=" "$out"
assert_contains "section --- files ---" "--- files ---" "$out"
assert_contains "lista lib/core/config.sh" "lib/core/config.sh" "$out"
assert_contains "lista lib/agent/tool_calling.sh" "lib/agent/tool_calling.sh" "$out"

# Verificar que NO incluye contenido de subdirs si pattern es basename `*.sh`
# (find -name '*.sh' recursivo SÍ incluye subdirs — debería ver lib/tools/*.sh).
out=$(dispatch_tool glob_files '{"pattern":"*.sh","path":"lib"}' 2>&1)
assert_contains "incluye lib/tools/read_file.sh (recursivo)" "lib/agent/tools/read_file.sh" "$out"

note "=== Test: pattern muy específico, single match"
out=$(dispatch_tool glob_files '{"pattern":"config.sh","path":"lib"}' 2>&1)
rc=$?
assert_ok "exit 0 single match" "0" "$rc"
assert_contains "header matches=1" "matches=1" "$out"
assert_contains "body lista lib/core/config.sh" "lib/core/config.sh" "$out"

note "=== Test: cero matches → exit 0 con (no matches)"
out=$(dispatch_tool glob_files '{"pattern":"zzzzz_no_match__.bla","path":"lib"}' 2>&1)
rc=$?
assert_ok "exit 0 cero matches" "0" "$rc"
assert_contains "header matches=0" "matches=0" "$out"
assert_contains "body dice (no matches)" "(no matches)" "$out"
assert_contains "truncated=false" "truncated=false" "$out"

# =====================================================
# 5. Path-mode glob (pattern con '/')
# =====================================================
note "=== Test: pattern con '/' usa -path"
out=$(dispatch_tool glob_files '{"pattern":"tests/test_grep_search.sh"}' 2>&1)
rc=$?
assert_ok "exit 0 path-mode" "0" "$rc"
assert_contains "matches=1" "matches=1" "$out"
assert_contains "body lista tests/test_grep_search.sh" "tests/test_grep_search.sh" "$out"

note "=== Test: globstar '**' aplanado a '*'"
out=$(dispatch_tool glob_files '{"pattern":"**/test_grep_search.sh"}' 2>&1)
rc=$?
assert_ok "exit 0 globstar" "0" "$rc"
assert_contains "matches=1 con globstar" "matches=1" "$out"
assert_contains "body lista tests/test_grep_search.sh (globstar)" "tests/test_grep_search.sh" "$out"

# =====================================================
# 6. case_insensitive
# =====================================================
note "=== Test: case_insensitive"
# CONFIG.SH (mayúscula) no matchea sin ci, sí con ci.
out_sens=$(dispatch_tool glob_files '{"pattern":"CONFIG.SH","path":"lib"}' 2>&1)
n_sens=$(echo "$out_sens" | sed -n 's/.*matches=\([0-9]*\).*/\1/p')
out_insens=$(dispatch_tool glob_files '{"pattern":"CONFIG.SH","path":"lib","case_insensitive":true}' 2>&1)
n_insens=$(echo "$out_insens" | sed -n 's/.*matches=\([0-9]*\).*/\1/p')
if [ "${n_sens:-99}" -eq 0 ] && [ "${n_insens:-0}" -ge 1 ]; then
    note "  PASS: case_insensitive: sens=$n_sens, insens=$n_insens"
    PASS=$((PASS + 1))
else
    note "  FAIL: case_insensitive (sens=$n_sens, insens=$n_insens; esperaba sens=0, insens>=1)"
    FAIL=$((FAIL + 1))
fi

# =====================================================
# 7. type filter
# =====================================================
note "=== Test: type=dir matchea directorios"
out=$(dispatch_tool glob_files '{"pattern":"tools","path":"lib","type":"dir"}' 2>&1)
rc=$?
assert_ok "exit 0 type=dir" "0" "$rc"
assert_contains "header type=dir" "type=dir" "$out"
assert_contains "matches=1 (lib/tools dir)" "matches=1" "$out"
assert_contains "body lista lib/agent/tools" "lib/agent/tools" "$out"

note "=== Test: type=file NO matchea dirs"
# pattern "tools" sin type=dir → debería ser cero (default type=file).
out=$(dispatch_tool glob_files '{"pattern":"tools","path":"lib"}' 2>&1)
rc=$?
assert_ok "exit 0 type=file no dirs" "0" "$rc"
assert_contains "matches=0 (default type=file vs dir 'tools')" "matches=0" "$out"

note "=== Test: type=any matchea ambos"
# pattern 'config*' en lib/: config.sh (file) + (no dir 'config*' aquí, así
# verificamos en un tmpdir controlado).
fixture_dir="$REPO_ROOT/.ralph_glob_fixtures"
mkdir -p "$fixture_dir/sub"
touch "$fixture_dir/sub/leaf.txt"
touch "$fixture_dir/file_one.txt"
out_any=$(dispatch_tool glob_files "{\"pattern\":\"*\",\"path\":\".ralph_glob_fixtures\",\"type\":\"any\"}" 2>&1)
n_any=$(echo "$out_any" | sed -n 's/.*matches=\([0-9]*\).*/\1/p')
# any debe ver: file_one.txt, sub, sub/leaf.txt → 3
if [ "${n_any:-0}" -ge 3 ]; then
    note "  PASS: type=any incluye archivos + dirs (n=$n_any)"
    PASS=$((PASS + 1))
else
    note "  FAIL: type=any matches=$n_any (esperaba >=3)"
    note "       output: $out_any"
    FAIL=$((FAIL + 1))
fi

# =====================================================
# 8. max_results trunca
# =====================================================
note "=== Test: max_results trunca"
out=$(dispatch_tool glob_files '{"pattern":"*.sh","path":"lib","max_results":3}' 2>&1)
assert_contains "truncated=true" "truncated=true" "$out"
body_lines=$(echo "$out" | awk '/^--- files ---$/{found=1; next} found' | wc -l | tr -d ' ')
if [ "$body_lines" = "3" ]; then
    note "  PASS: body tiene exactamente 3 líneas con max_results=3"
    PASS=$((PASS + 1))
else
    note "  FAIL: body tiene $body_lines líneas (esperaba 3)"
    FAIL=$((FAIL + 1))
fi
# Verificar orden lexical determinístico (LC_ALL=C sort).
expected_first="lib/agent/hooks.sh"
first_line=$(echo "$out" | awk '/^--- files ---$/{found=1; next} found' | head -n1)
if [ "$first_line" = "$expected_first" ]; then
    note "  PASS: orden lexical determinístico (primero=$first_line)"
    PASS=$((PASS + 1))
else
    note "  FAIL: orden inesperado (primero=$first_line, esperaba=$expected_first)"
    FAIL=$((FAIL + 1))
fi

# =====================================================
# 9. Default path = .
# =====================================================
note "=== Test: default path = ."
out=$(dispatch_tool glob_files '{"pattern":"BACKLOG.md"}' 2>&1)
rc=$?
assert_ok "exit 0 default path" "0" "$rc"
assert_contains "header path=." "path=." "$out"
assert_contains "match aparece sin path explícito" "BACKLOG.md" "$out"
# Y NO debe tener prefijo "./" (strip cuando path=".").
assert_not_contains "no prefijo ./BACKLOG.md" "./BACKLOG.md" "$out"

# =====================================================
# 10. .git/ excluido por default
# =====================================================
note "=== Test: .git/ excluido del recorrido"
# Crear .git/ fake dentro del tmpdir + un archivo .sh adentro.
git_test_dir="$REPO_ROOT/.ralph_glob_fixtures"
mkdir -p "$git_test_dir/.git"
touch "$git_test_dir/.git/inside_git.sh"
touch "$git_test_dir/outside_git.sh"
out=$(dispatch_tool glob_files "{\"pattern\":\"*.sh\",\"path\":\".ralph_glob_fixtures\"}" 2>&1)
assert_contains "incluye outside_git.sh" "outside_git.sh" "$out"
assert_not_contains "NO incluye inside_git.sh (.git/ pruneado)" "inside_git.sh" "$out"

# =====================================================
# Cleanup + resumen
# =====================================================
rm -rf "$git_test_dir"

note ""
note "==============================="
note "Resultado: $PASS pass, $FAIL fail"
note "==============================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
