#!/usr/bin/env bash
# tests/test_skills_builtin.sh
# Cobertura de la resolucion built-in vs user en lib/skills.sh (P1.slash-3).
#
# Verifica:
#   - CODER_SKILLS_BUILTIN_DIR default apunta a <repo>/skills/builtin.
#   - Skills shipped (analyze, refactor, review, security, performance, test,
#     docs, think, files, focus, summary, fix) tienen frontmatter valido y
#     resuelven correctamente cuando solo built-in esta disponible.
#   - User dir gana sobre built-in cuando ambos definen el mismo nombre.
#   - skills_list dedupea por nombre, manteniendo la ruta del user dir.
#   - CODER_SKILLS_BUILTIN_DIR="" desactiva la fuente built-in.
#   - User dir vacio + built-in poblado funciona (registry solo built-in).
#   - User dir poblado + built-in apuntando a path inexistente funciona
#     (registry solo user, sin errores).

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

PASS=0
FAIL=0

_pass() { printf '  ok  %s\n' "$1"; PASS=$((PASS + 1)); }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        _pass "$label"
    else
        _fail "$label (expected='$expected' actual='$actual')"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        _pass "$label"
    else
        _fail "$label (needle='$needle' missing)"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        _pass "$label"
    else
        _fail "$label (unexpected needle='$needle' present)"
    fi
}

# Isolation: tmpdir for user dir; built-in points to repo's shipped dir.
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT INT TERM

# IMPORTANT: export BEFORE sourcing the module so the auto-detect can run and
# we observe its default. Then we override per-test as needed.
unset CODER_SKILLS_USER_DIR CODER_SKILLS_BUILTIN_DIR
export CODER_SKILLS_USER_DIR="$TMPDIR_TEST/user_skills"

# shellcheck disable=SC1091
source "$REPO_DIR/lib/agent/skills.sh"

echo "=== default built-in dir detection ==="
expected_builtin="$REPO_DIR/lib/skills/builtin"
assert_eq "default CODER_SKILLS_BUILTIN_DIR" "$expected_builtin" "$CODER_SKILLS_BUILTIN_DIR"
if [ -d "$CODER_SKILLS_BUILTIN_DIR" ]; then
    _pass "default built-in dir exists in repo"
else
    _fail "default built-in dir exists in repo (got $CODER_SKILLS_BUILTIN_DIR)"
fi

echo
echo "=== shipped built-in skills present + parseable ==="
expected_builtins=(analyze refactor review security performance test docs think files focus summary fix)
for skill in "${expected_builtins[@]}"; do
    if [ -f "$CODER_SKILLS_BUILTIN_DIR/$skill.md" ]; then
        _pass "$skill.md present"
    else
        _fail "$skill.md present"
        continue
    fi
    if skills_exists "$skill"; then
        _pass "$skill resolves via skills_exists"
    else
        _fail "$skill resolves via skills_exists"
    fi
    desc=$(skills_describe "$skill" 2>/dev/null)
    if [ -n "$desc" ]; then
        _pass "$skill has non-empty description"
    else
        _fail "$skill has non-empty description"
    fi
    body=$(skills_body "$skill" 2>/dev/null)
    if [ -n "$body" ]; then
        _pass "$skill has non-empty body"
    else
        _fail "$skill has non-empty body"
    fi
done

echo
echo "=== skills_list incluye los 12 built-ins (user dir vacio) ==="
mkdir -p "$CODER_SKILLS_USER_DIR"  # presente pero vacio
list_out=$(skills_list)
for skill in "${expected_builtins[@]}"; do
    assert_contains "skills_list contiene $skill" "$skill" "$list_out"
done
# `agent` legacy es slash reservado, NO debe estar shipped como skill.
assert_not_contains "skills/builtin no incluye agent.md" "$CODER_SKILLS_BUILTIN_DIR/agent.md" "$list_out"

echo
echo "=== user dir gana sobre built-in en colisiones ==="
cat > "$CODER_SKILLS_USER_DIR/analyze.md" <<'EOF'
---
name: analyze
description: User override de analyze
---
USER ANALYZE BODY {{args}}
EOF

# skills_path debe devolver el path del user dir.
got_path=$(skills_path analyze)
assert_eq "skills_path analyze devuelve user path" "$CODER_SKILLS_USER_DIR/analyze.md" "$got_path"

# skills_describe debe devolver la description del user dir.
got_desc=$(skills_describe analyze)
assert_eq "skills_describe analyze devuelve user description" "User override de analyze" "$got_desc"

# skills_body debe devolver el body del user dir.
got_body=$(skills_body analyze)
assert_contains "skills_body analyze devuelve USER body" "USER ANALYZE BODY" "$got_body"

# skills_render con args sustituye {{args}} literal.
got_render=$(skills_render analyze "X Y Z")
assert_contains "skills_render analyze interpola args del user body" "USER ANALYZE BODY X Y Z" "$got_render"

# skills_list dedupea: solo aparece UNA linea para `analyze`, y es la del user dir.
list_out=$(skills_list)
analyze_lines=$(printf '%s\n' "$list_out" | awk -F'\t' '$1 == "analyze"' | wc -l | tr -d ' ')
assert_eq "skills_list dedupea analyze (1 entrada)" "1" "$analyze_lines"
analyze_path=$(printf '%s\n' "$list_out" | awk -F'\t' '$1 == "analyze" {print $3}')
assert_eq "skills_list deja la entrada del user" "$CODER_SKILLS_USER_DIR/analyze.md" "$analyze_path"

# Los OTROS built-ins (no overridden) siguen apareciendo desde built-in dir.
review_path=$(printf '%s\n' "$list_out" | awk -F'\t' '$1 == "review" {print $3}')
assert_eq "review sigue resolviendo a built-in" "$CODER_SKILLS_BUILTIN_DIR/review.md" "$review_path"

echo
echo "=== user-only skill: cohabita con built-ins ==="
cat > "$CODER_SKILLS_USER_DIR/mycustom.md" <<'EOF'
---
name: mycustom
description: Skill solo del user
---
custom body
EOF

list_out=$(skills_list)
assert_contains "skills_list incluye mycustom" "mycustom" "$list_out"
mycustom_path=$(printf '%s\n' "$list_out" | awk -F'\t' '$1 == "mycustom" {print $3}')
assert_eq "mycustom path es user dir" "$CODER_SKILLS_USER_DIR/mycustom.md" "$mycustom_path"

# Total esperado: 12 built-ins (analyze overrideado pero aparece 1x via user) + mycustom.
total_lines=$(printf '%s\n' "$list_out" | grep -c .)
assert_eq "skills_list emite 13 entradas (12 builtins + 1 user custom)" "13" "$total_lines"

echo
echo "=== CODER_SKILLS_BUILTIN_DIR=\"\" desactiva built-in ==="
saved_builtin="$CODER_SKILLS_BUILTIN_DIR"
export CODER_SKILLS_BUILTIN_DIR=""

list_out=$(skills_list)
# user dir tiene analyze.md y mycustom.md, asi que esos dos deben aparecer y nada mas.
total_lines=$(printf '%s\n' "$list_out" | grep -c .)
assert_eq "con built-in vacio, skills_list emite solo user skills (2 entradas)" "2" "$total_lines"
assert_contains "user analyze sigue presente" "analyze" "$list_out"
assert_contains "user mycustom sigue presente" "mycustom" "$list_out"

if skills_exists review; then
    _fail "review NO debe resolver con built-in desactivado"
else
    _pass "review NO resuelve con built-in desactivado"
fi

# Restaurar para tests siguientes.
export CODER_SKILLS_BUILTIN_DIR="$saved_builtin"

echo
echo "=== built-in dir apuntando a path inexistente: no rompe ==="
export CODER_SKILLS_BUILTIN_DIR="$TMPDIR_TEST/does-not-exist"

list_out=$(skills_list 2>/dev/null)
ec=$?
assert_eq "skills_list exit 0 con built-in dir inexistente" "0" "$ec"
total_lines=$(printf '%s\n' "$list_out" | grep -c .)
assert_eq "solo user skills con built-in dir inexistente (2 entradas)" "2" "$total_lines"

if skills_exists analyze; then
    _pass "user analyze sigue resolviendo (built-in dir inexistente)"
else
    _fail "user analyze sigue resolviendo (built-in dir inexistente)"
fi

# Restaurar.
export CODER_SKILLS_BUILTIN_DIR="$saved_builtin"

echo
echo "=== user dir vacio + built-in poblado: registry solo built-in ==="
rm -rf "$CODER_SKILLS_USER_DIR"
mkdir -p "$CODER_SKILLS_USER_DIR"

list_out=$(skills_list)
total_lines=$(printf '%s\n' "$list_out" | grep -c .)
assert_eq "12 entradas con solo built-in disponible" "12" "$total_lines"

# analyze ahora resuelve a built-in (no hay user override).
got_path=$(skills_path analyze)
assert_eq "skills_path analyze (solo built-in) -> built-in path" "$CODER_SKILLS_BUILTIN_DIR/analyze.md" "$got_path"

echo
echo "=== render de skill built-in con {{args}} interpola correctamente ==="
got_render=$(skills_render fix "el bug X esta rompiendo Y")
assert_contains "skills_render fix interpola args" "el bug X esta rompiendo Y" "$got_render"
# El body de fix debe estar presente, no solo los args.
assert_contains "skills_render fix incluye body" "Workflow" "$got_render"

# Skills sin {{args}} obligatorio (analyze, review, etc.) aceptan args sin romper.
got_render=$(skills_render analyze "extra args")
assert_contains "skills_render analyze (sin placeholder) appendea args" "extra args" "$got_render"

echo
printf 'Resultado: %d pass, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
