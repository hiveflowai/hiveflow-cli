#!/bin/bash
#
# Smoke test standalone para lib/tools/grep_search.sh
# Sourcea lib/tool_calling.sh, registra la tool, ejerce el dispatcher contra
# archivos reales del repo (tests/fixtures/sample_config.sh) + un tmpdir aislado para casos de
# containment.
#
# Cubre ambos paths (rg + grep) vía CODER_GREP_FORCE_TOOL cuando rg está
# disponible. Cuando rg no existe, los tests "rg" se reportan SKIP.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT"

# shellcheck source=../lib/tool_calling.sh disable=SC1091
source "$REPO_ROOT/lib/agent/tool_calling.sh"

PASS=0
FAIL=0
SKIP=0
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

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

# =====================================================
# 1. Registro y definition
# =====================================================
note "=== Test: registración"
register_tool grep_search
if list_registered_tools | grep -q '^grep_search$'; then
    note "  PASS: grep_search en REGISTERED_TOOLS"
    PASS=$((PASS + 1))
else
    note "  FAIL: grep_search no aparece en REGISTERED_TOOLS"
    FAIL=$((FAIL + 1))
fi

note "=== Test: definition emite JSON válido"
def=$(get_tool_definition grep_search)
if echo "$def" | jq -e '.name == "grep_search"' >/dev/null; then
    note "  PASS: definition.name == grep_search"
    PASS=$((PASS + 1))
else
    note "  FAIL: definition no contiene name=grep_search"
    FAIL=$((FAIL + 1))
fi
if echo "$def" | jq -e '.input_schema.required | index("pattern")' >/dev/null; then
    note "  PASS: definition requiere pattern"
    PASS=$((PASS + 1))
else
    note "  FAIL: definition no marca pattern como required"
    FAIL=$((FAIL + 1))
fi
if echo "$def" | jq -e '.input_schema.properties.max_results.minimum == 1' >/dev/null; then
    note "  PASS: max_results.minimum == 1"
    PASS=$((PASS + 1))
else
    note "  FAIL: max_results.minimum no es 1"
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
err=$(dispatch_tool grep_search '' 2>&1 >/dev/null); rc=$?
set -e
# dispatch_tool con input vacío inyecta "{}" — luego el handler ve "pattern" missing.
assert_ok "exit 2 input vacío" "2" "$rc"

note "=== Test: pattern missing → exit 2"
set +e
err=$(dispatch_tool grep_search '{}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 pattern missing" "2" "$rc"
assert_contains "stderr menciona 'pattern'" "pattern" "$err"

note "=== Test: pattern vacío → exit 2"
set +e
err=$(dispatch_tool grep_search '{"pattern":""}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 pattern vacío" "2" "$rc"

note "=== Test: JSON inválido → exit 2"
set +e
err=$(dispatch_tool grep_search 'not json' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 JSON inválido" "2" "$rc"

note "=== Test: max_results=0 → exit 2"
set +e
err=$(dispatch_tool grep_search '{"pattern":"x","max_results":0}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 max_results=0" "2" "$rc"

note "=== Test: max_results=-1 → exit 2"
set +e
err=$(dispatch_tool grep_search '{"pattern":"x","max_results":-1}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 max_results=-1" "2" "$rc"

note "=== Test: max_results>1000 → exit 2"
set +e
err=$(dispatch_tool grep_search '{"pattern":"x","max_results":1001}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 max_results=1001" "2" "$rc"

note "=== Test: case_insensitive no-bool → exit 2"
set +e
err=$(dispatch_tool grep_search '{"pattern":"x","case_insensitive":"yes"}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 case_insensitive=string" "2" "$rc"

note "=== Test: fixed_strings no-bool → exit 2"
set +e
err=$(dispatch_tool grep_search '{"pattern":"x","fixed_strings":1}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 fixed_strings=1" "2" "$rc"

# =====================================================
# 3. Path containment
# =====================================================
note "=== Test: path no existe → exit 1"
set +e
err=$(dispatch_tool grep_search '{"pattern":"foo","path":"lib/does_not_exist__"}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 1 path no existe" "1" "$rc"
assert_contains "stderr menciona 'not found'" "not found" "$err"

note "=== Test: path fuera de cwd → exit 1"
external_dir="$TMPDIR_TEST/escape"
mkdir -p "$external_dir"
echo "secreto" > "$external_dir/leak.txt"
set +e
err=$(dispatch_tool grep_search "{\"pattern\":\"secreto\",\"path\":\"$external_dir\"}" 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 1 path fuera de cwd" "1" "$rc"
assert_contains "stderr menciona 'outside cwd'" "outside cwd" "$err"

note "=== Test: symlink rechazado"
ln -s "$external_dir" "$REPO_ROOT/.ralph_symlink_grep_test" 2>/dev/null || true
set +e
err=$(dispatch_tool grep_search '{"pattern":"secreto","path":".ralph_symlink_grep_test"}' 2>&1 >/dev/null); rc=$?
set -e
rm -f "$REPO_ROOT/.ralph_symlink_grep_test"
assert_ok "exit 1 symlink" "1" "$rc"
assert_contains "stderr menciona 'symlink'" "symlink" "$err"

# =====================================================
# 4. Happy path: grep (siempre disponible)
# =====================================================
note "=== Test: happy path (grep), pattern en tests/fixtures/sample_config.sh"
out=$(CODER_GREP_FORCE_TOOL="grep" dispatch_tool grep_search '{"pattern":"init_config_directories","path":"tests/fixtures/sample_config.sh"}' 2>&1)
rc=$?
assert_ok "exit 0 happy path grep" "0" "$rc"
assert_contains "header con tool=grep" "tool=grep" "$out"
assert_contains "header con matches=" "matches=" "$out"
assert_contains "section --- matches ---" "--- matches ---" "$out"
assert_contains "match menciona la función" "init_config_directories" "$out"
assert_contains "match incluye file:line:" "tests/fixtures/sample_config.sh:" "$out"

note "=== Test: cero matches → exit 0 con (no matches)"
out=$(CODER_GREP_FORCE_TOOL="grep" dispatch_tool grep_search '{"pattern":"zzzzzzNUNCAMATCHzzzzzz","path":"tests/fixtures/sample_config.sh"}' 2>&1)
rc=$?
assert_ok "exit 0 cero matches" "0" "$rc"
assert_contains "header dice matches=0" "matches=0" "$out"
assert_contains "body dice (no matches)" "(no matches)" "$out"
assert_contains "truncated=false" "truncated=false" "$out"

note "=== Test: case_insensitive"
# "FUNCTION" (mayúscula) NO debería matchear en config.sh con case sensitive,
# pero sí con case_insensitive.
out_sens=$(CODER_GREP_FORCE_TOOL="grep" dispatch_tool grep_search '{"pattern":"FUNCTION","path":"tests/fixtures/sample_config.sh"}' 2>&1)
out_insens=$(CODER_GREP_FORCE_TOOL="grep" dispatch_tool grep_search '{"pattern":"FUNCTION","path":"tests/fixtures/sample_config.sh","case_insensitive":true}' 2>&1)
# Si insensitive devuelve más matches que sensitive, el flag funciona.
n_sens=$(echo "$out_sens" | sed -n 's/.*matches=\([0-9]*\).*/\1/p')
n_insens=$(echo "$out_insens" | sed -n 's/.*matches=\([0-9]*\).*/\1/p')
if [ "${n_insens:-0}" -gt "${n_sens:-0}" ]; then
    note "  PASS: case_insensitive aumenta matches ($n_sens → $n_insens)"
    PASS=$((PASS + 1))
else
    note "  FAIL: case_insensitive no incrementó matches (sens=$n_sens, insens=$n_insens)"
    FAIL=$((FAIL + 1))
fi

note "=== Test: fixed_strings con regex meta-chars"
# Crear archivo en cwd con literal "foo.bar" y "fooXbar"
target_dir="$REPO_ROOT/.ralph_grep_fixtures"
mkdir -p "$target_dir"
echo "foo.bar literal" > "$target_dir/a.txt"
echo "fooXbar regex match" >> "$target_dir/a.txt"

# Sin fixed_strings (ERE): "foo.bar" matchea ambos.
out_regex=$(CODER_GREP_FORCE_TOOL="grep" dispatch_tool grep_search "{\"pattern\":\"foo.bar\",\"path\":\".ralph_grep_fixtures\"}" 2>&1)
n_regex=$(echo "$out_regex" | sed -n 's/.*matches=\([0-9]*\).*/\1/p')
# Con fixed_strings: "foo.bar" sólo matchea el literal.
out_fixed=$(CODER_GREP_FORCE_TOOL="grep" dispatch_tool grep_search "{\"pattern\":\"foo.bar\",\"path\":\".ralph_grep_fixtures\",\"fixed_strings\":true}" 2>&1)
n_fixed=$(echo "$out_fixed" | sed -n 's/.*matches=\([0-9]*\).*/\1/p')
if [ "${n_regex:-0}" -eq 2 ] && [ "${n_fixed:-0}" -eq 1 ]; then
    note "  PASS: fixed_strings=false matchea 2, =true matchea 1"
    PASS=$((PASS + 1))
else
    note "  FAIL: fixed_strings comportamiento inesperado (regex=$n_regex, fixed=$n_fixed)"
    FAIL=$((FAIL + 1))
fi
rm -rf "$target_dir"

note "=== Test: glob filter"
# Buscar 'function' sólo en *.md no debería encontrarlo en tests/fixtures/sample_config.sh (es .sh).
out_md=$(CODER_GREP_FORCE_TOOL="grep" dispatch_tool grep_search '{"pattern":"function","path":"lib","glob":"*.md"}' 2>&1)
n_md=$(echo "$out_md" | sed -n 's/.*matches=\([0-9]*\).*/\1/p')
out_sh=$(CODER_GREP_FORCE_TOOL="grep" dispatch_tool grep_search '{"pattern":"function","path":"lib","glob":"*.sh"}' 2>&1)
n_sh=$(echo "$out_sh" | sed -n 's/.*matches=\([0-9]*\).*/\1/p')
if [ "${n_md:-1}" -eq 0 ] && [ "${n_sh:-0}" -gt 0 ]; then
    note "  PASS: glob *.md filtra a 0, glob *.sh devuelve >0"
    PASS=$((PASS + 1))
else
    note "  FAIL: glob comportamiento inesperado (md=$n_md, sh=$n_sh)"
    FAIL=$((FAIL + 1))
fi

note "=== Test: max_results trunca"
# Buscar 'function' en lib/ (decenas de matches) con max_results=3.
out=$(CODER_GREP_FORCE_TOOL="grep" dispatch_tool grep_search '{"pattern":"function","path":"lib","max_results":3}' 2>&1)
assert_contains "truncated=true" "truncated=true" "$out"
# Contar líneas tras --- matches ---. Debe ser exactamente 3.
body_lines=$(echo "$out" | awk '/^--- matches ---$/{found=1; next} found' | wc -l | tr -d ' ')
if [ "$body_lines" = "3" ]; then
    note "  PASS: body tiene exactamente 3 líneas con max_results=3"
    PASS=$((PASS + 1))
else
    note "  FAIL: body tiene $body_lines líneas (esperaba 3)"
    FAIL=$((FAIL + 1))
fi

note "=== Test: default path = . y default max_results=100"
# Sin path → busca en "." (todo el repo). Asegurar que match aparece.
out=$(CODER_GREP_FORCE_TOOL="grep" dispatch_tool grep_search '{"pattern":"init_config_directories"}' 2>&1)
rc=$?
assert_ok "exit 0 default path" "0" "$rc"
assert_contains "match aparece sin path explícito" "init_config_directories" "$out"

note "=== Test: .git/ excluido por default"
# Construimos el patrón en runtime para evitar self-match (este archivo .sh
# contiene comentarios/json mencionando partes del pattern; concatenando piezas
# nos aseguramos que el literal completo NO existe en disco fuera de .git/HEAD).
pat_a='ref'
pat_b=': refs'
pat_c='/heads/'
pat_full="${pat_a}${pat_b}${pat_c}"
json_input=$(jq -nc --arg p "$pat_full" '{pattern: $p, path: "."}')
out=$(CODER_GREP_FORCE_TOOL="grep" dispatch_tool grep_search "$json_input" 2>&1)
assert_contains "header dice matches=0 (.git excluido)" "matches=0" "$out"
# Doble check: ninguna línea del cuerpo apunta al directorio git interno.
body=$(echo "$out" | awk '/^--- matches ---$/{found=1; next} found')
if printf '%s' "$body" | grep -q '\.git/'; then
    note "  FAIL: alguna línea apunta a .git/"
    note "       body was: $body"
    FAIL=$((FAIL + 1))
else
    note "  PASS: ninguna línea de matches apunta a .git/"
    PASS=$((PASS + 1))
fi
unset pat_a pat_b pat_c pat_full json_input body

note "=== Test: CODER_GREP_FORCE_TOOL inválido → exit 2"
set +e
err=$(CODER_GREP_FORCE_TOOL="bogus" dispatch_tool grep_search '{"pattern":"x","path":"tests/fixtures/sample_config.sh"}' 2>&1 >/dev/null); rc=$?
set -e
assert_ok "exit 2 force tool inválido" "2" "$rc"
assert_contains "stderr menciona 'CODER_GREP_FORCE_TOOL'" "CODER_GREP_FORCE_TOOL" "$err"

# =====================================================
# 5. Path ruta única (single file) funciona
# =====================================================
note "=== Test: search en single file"
out=$(CODER_GREP_FORCE_TOOL="grep" dispatch_tool grep_search '{"pattern":"#!/bin/bash","path":"tests/fixtures/sample_config.sh"}' 2>&1)
rc=$?
assert_ok "exit 0 single file" "0" "$rc"
assert_contains "header path=tests/fixtures/sample_config.sh" "path=tests/fixtures/sample_config.sh" "$out"

# =====================================================
# 6. Tool detection: auto path (rg si está, grep si no)
# =====================================================
note "=== Test: auto-detection (sin CODER_GREP_FORCE_TOOL)"
unset CODER_GREP_FORCE_TOOL
out=$(dispatch_tool grep_search '{"pattern":"init_config_directories","path":"tests/fixtures/sample_config.sh"}' 2>&1)
rc=$?
assert_ok "exit 0 auto-detect" "0" "$rc"
if command -v rg >/dev/null 2>&1; then
    assert_contains "auto-detect eligió rg" "tool=rg" "$out"
else
    assert_contains "auto-detect cayó a grep" "tool=grep" "$out"
fi

# =====================================================
# 7. Ruta rg (sólo si rg está instalado)
# =====================================================
if command -v rg >/dev/null 2>&1; then
    note "=== Test: happy path (rg)"
    out=$(CODER_GREP_FORCE_TOOL="rg" dispatch_tool grep_search '{"pattern":"init_config_directories","path":"tests/fixtures/sample_config.sh"}' 2>&1)
    rc=$?
    assert_ok "exit 0 rg happy" "0" "$rc"
    assert_contains "header con tool=rg" "tool=rg" "$out"
    assert_contains "match menciona la función (rg)" "init_config_directories" "$out"

    note "=== Test: rg cero matches"
    out=$(CODER_GREP_FORCE_TOOL="rg" dispatch_tool grep_search '{"pattern":"zzzzzzNUNCAMATCHzzzzzz","path":"tests/fixtures/sample_config.sh"}' 2>&1)
    rc=$?
    assert_ok "exit 0 rg cero matches" "0" "$rc"
    assert_contains "rg matches=0" "matches=0" "$out"
    assert_contains "rg (no matches)" "(no matches)" "$out"

    note "=== Test: rg max_results trunca"
    out=$(CODER_GREP_FORCE_TOOL="rg" dispatch_tool grep_search '{"pattern":"function","path":"lib","max_results":3}' 2>&1)
    assert_contains "rg truncated=true" "truncated=true" "$out"
else
    note "=== SKIP: rg no instalado, saltando 4 asserts de ruta rg"
    SKIP=$((SKIP + 4))
fi

note ""
note "==============================="
note "Resultado: $PASS pass, $FAIL fail, $SKIP skip"
note "==============================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
