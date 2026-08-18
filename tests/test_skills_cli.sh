#!/bin/bash
#
# P1.slash-4 CLI dispatcher (`skills_cli`) — unit tests.
# Aislamos $CODER_SKILLS_USER_DIR y $CODER_SKILLS_BUILTIN_DIR a tmp dirs.
# Las funciones internas (skills_list/skills_path/etc.) están cubiertas por
# tests/test_skills.sh y tests/test_skills_builtin.sh — aquí validamos el
# dispatcher: parsing de subcommand, validación de argc, exit codes,
# side-effects en el filesystem (install copia archivo, remove lo borra,
# remove de built-in falla, etc.).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT" || exit 1

TMP_DIR=$(mktemp -d)
export CODER_SKILLS_USER_DIR="$TMP_DIR/user"
export CODER_SKILLS_BUILTIN_DIR="$TMP_DIR/builtin"
export CONFIG_DIR="$TMP_DIR/cfg"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# shellcheck source=../lib/skills.sh disable=SC1091
source "$REPO_ROOT/lib/agent/skills.sh"

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
    rm -rf "$CODER_SKILLS_USER_DIR" "$CODER_SKILLS_BUILTIN_DIR"
    mkdir -p "$CODER_SKILLS_USER_DIR" "$CODER_SKILLS_BUILTIN_DIR"
}

_write_skill() {
    local dir="$1" name="$2" desc="$3" body="$4"
    cat >"$dir/$name.md" <<EOF
---
name: $name
description: $desc
---
$body
EOF
}

echo "=== T1: sin subcommand => usage en stderr + exit 2"
_reset
ec=0
out=$(skills_cli 2>&1 >/dev/null) || ec=$?
_assert "exit 2 sin subcommand" "$ec" "2"
_assert_contains "stderr menciona Uso" "Usage:" "$out"

echo
echo "=== T2: --help / -h / help imprimen usage en stdout + exit 0"
_reset
ec=0
out=$(skills_cli --help 2>/dev/null) || ec=$?
_assert "--help exit 0" "$ec" "0"
_assert_contains "--help muestra Subcommands" "Subcommands:" "$out"
ec=0
out=$(skills_cli -h 2>/dev/null) || ec=$?
_assert "-h exit 0" "$ec" "0"
ec=0
out=$(skills_cli help 2>/dev/null) || ec=$?
_assert "help (bareword) exit 0" "$ec" "0"
_assert_contains "help muestra Examples" "Examples:" "$out"

echo
echo "=== T3: subcommand desconocido => exit 2 + usage"
_reset
ec=0
err=$(skills_cli bogus 2>&1 >/dev/null) || ec=$?
_assert "bogus exit 2" "$ec" "2"
_assert_contains "stderr menciona unknown subcommand" "unknown subcommand" "$err"
_assert_contains "stderr incluye usage" "Subcommands:" "$err"

echo
echo "=== T4: list vacío imprime '(no skills installed)' + exit 0"
_reset
ec=0
out=$(skills_cli list 2>/dev/null) || ec=$?
_assert "list vacío exit 0" "$ec" "0"
_assert_contains "list vacío anuncia ausencia" "(no skills installed)" "$out"

echo
echo "=== T5: list con args extra => exit 2"
_reset
ec=0
skills_cli list extra >/dev/null 2>&1 || ec=$?
_assert "list extra → exit 2" "$ec" "2"

echo
echo "=== T6: list muestra columnas NAME/ORIGIN/DESCRIPTION + entries por dir"
_reset
_write_skill "$CODER_SKILLS_USER_DIR"    "mine"  "My skill"     "user body"
_write_skill "$CODER_SKILLS_BUILTIN_DIR" "built" "Builtin skill" "built body"
out=$(skills_cli list 2>/dev/null)
_assert_contains "list header NAME"        "NAME"        "$out"
_assert_contains "list header ORIGIN"      "ORIGIN"      "$out"
_assert_contains "list header DESCRIPTION" "DESCRIPTION" "$out"
_assert_contains "list muestra mine"       "mine"        "$out"
_assert_contains "list muestra user"       "user"        "$out"
_assert_contains "list muestra built"      "built"       "$out"
_assert_contains "list muestra builtin"    "builtin"     "$out"

echo
echo "=== T7: list dedupea collisions (user gana sobre builtin)"
_reset
_write_skill "$CODER_SKILLS_USER_DIR"    "collide" "User wins"  "u"
_write_skill "$CODER_SKILLS_BUILTIN_DIR" "collide" "Builtin desc" "b"
out=$(skills_cli list 2>/dev/null)
# exactly one row mentioning 'collide'
count=$(printf '%s\n' "$out" | grep -cE '^collide ')
_assert "dedup count == 1" "$count" "1"
_assert_contains "list muestra desc del user" "User wins" "$out"
_assert_not_contains "list NO muestra desc del builtin para collide" "Builtin desc" "$out"

echo
echo "=== T8: show <missing> => exit 1"
_reset
ec=0
err=$(skills_cli show nope 2>&1 >/dev/null) || ec=$?
_assert "show missing → exit 1" "$ec" "1"
_assert_contains "show missing menciona not found" "not found" "$err"

echo
echo "=== T9: show sin name => exit 2"
_reset
ec=0
skills_cli show >/dev/null 2>&1 || ec=$?
_assert "show sin name → exit 2" "$ec" "2"

echo
echo "=== T10: show con >1 name => exit 2"
_reset
ec=0
skills_cli show a b >/dev/null 2>&1 || ec=$?
_assert "show con 2 args → exit 2" "$ec" "2"

echo
echo "=== T11: show imprime metadata + cuerpo + origin correcto"
_reset
_write_skill "$CODER_SKILLS_USER_DIR"    "mine"  "My skill"      "body line one"
_write_skill "$CODER_SKILLS_BUILTIN_DIR" "built" "Builtin skill" "body of built"
out=$(skills_cli show mine 2>/dev/null)
_assert_contains "show muestra name"        "name: mine"          "$out"
_assert_contains "show muestra origin user" "origin: user"        "$out"
_assert_contains "show muestra description" "description: My skill" "$out"
_assert_contains "show muestra path"        "path: $CODER_SKILLS_USER_DIR/mine.md" "$out"
_assert_contains "show muestra cuerpo"      "body line one"       "$out"
_assert_contains "show muestra separator"   "---"                 "$out"
out=$(skills_cli show built 2>/dev/null)
_assert_contains "show builtin origin"      "origin: builtin"     "$out"

echo
echo "=== T12: install sin path => exit 2"
_reset
ec=0
skills_cli install >/dev/null 2>&1 || ec=$?
_assert "install sin path → exit 2" "$ec" "2"

echo
echo "=== T13: install path inexistente => exit 1"
_reset
ec=0
err=$(skills_cli install "$TMP_DIR/no-such-file.md" 2>&1 >/dev/null) || ec=$?
_assert "install inexistente → exit 1" "$ec" "1"
_assert_contains "install menciona file not found" "file not found" "$err"

echo
echo "=== T14: install file sin frontmatter => exit 1"
_reset
echo "no frontmatter here" >"$TMP_DIR/bad.md"
ec=0
err=$(skills_cli install "$TMP_DIR/bad.md" 2>&1 >/dev/null) || ec=$?
_assert "install sin FM → exit 1" "$ec" "1"
_assert_contains "install menciona frontmatter" "frontmatter" "$err"

echo
echo "=== T15: install file con FM sin cierre => exit 1"
_reset
cat >"$TMP_DIR/unclosed.md" <<'EOF'
---
name: unclosed
description: never closed
body without closing
EOF
ec=0
err=$(skills_cli install "$TMP_DIR/unclosed.md" 2>&1 >/dev/null) || ec=$?
_assert "install FM sin cierre → exit 1" "$ec" "1"
_assert_contains "install menciona frontmatter" "frontmatter" "$err"

echo
echo "=== T16: install ok copia al user dir + emite mensaje"
_reset
_write_skill "$TMP_DIR" "myskill" "A test skill" "the body"
ec=0
out=$(skills_cli install "$TMP_DIR/myskill.md" 2>/dev/null) || ec=$?
_assert "install exit 0" "$ec" "0"
_assert_contains "install reporta dest" "$CODER_SKILLS_USER_DIR/myskill.md" "$out"
_assert "archivo copiado al user dir" "$([ -f "$CODER_SKILLS_USER_DIR/myskill.md" ] && echo yes || echo no)" "yes"

echo
echo "=== T17: install dest existente sin --force => exit 1"
_reset
_write_skill "$TMP_DIR" "dup" "first" "v1"
skills_cli install "$TMP_DIR/dup.md" >/dev/null 2>&1
# rewrite source so we can detect overwrite
_write_skill "$TMP_DIR" "dup" "second" "v2"
ec=0
err=$(skills_cli install "$TMP_DIR/dup.md" 2>&1 >/dev/null) || ec=$?
_assert "install dup sin force → exit 1" "$ec" "1"
_assert_contains "menciona already exists" "already exists" "$err"
# Verify the original is untouched
body=$(skills_body dup 2>/dev/null)
_assert_contains "body original preservado" "v1" "$body"

echo
echo "=== T18: install --force sobreescribe"
_reset
_write_skill "$TMP_DIR" "dup" "first" "v1"
skills_cli install "$TMP_DIR/dup.md" >/dev/null 2>&1
_write_skill "$TMP_DIR" "dup" "second" "v2"
ec=0
skills_cli install "$TMP_DIR/dup.md" --force >/dev/null 2>&1 || ec=$?
_assert "install --force exit 0" "$ec" "0"
body=$(skills_body dup 2>/dev/null)
_assert_contains "body sobreescrito a v2" "v2" "$body"

echo
echo "=== T19: install -f también acepta short flag"
_reset
_write_skill "$TMP_DIR" "dup" "first" "v1"
skills_cli install "$TMP_DIR/dup.md" >/dev/null 2>&1
_write_skill "$TMP_DIR" "dup" "second" "v2"
ec=0
skills_cli install "$TMP_DIR/dup.md" -f >/dev/null 2>&1 || ec=$?
_assert "install -f exit 0" "$ec" "0"
body=$(skills_body dup 2>/dev/null)
_assert_contains "body sobreescrito con -f" "v2" "$body"

echo
echo "=== T20: install con flag desconocido => exit 2"
_reset
_write_skill "$TMP_DIR" "x" "y" "z"
ec=0
err=$(skills_cli install "$TMP_DIR/x.md" --bogus 2>&1 >/dev/null) || ec=$?
_assert "install --bogus → exit 2" "$ec" "2"
_assert_contains "menciona unknown flag" "unknown flag" "$err"

echo
echo "=== T21: install con 2 paths => exit 2"
_reset
_write_skill "$TMP_DIR" "a" "y" "z"
_write_skill "$TMP_DIR" "b" "y" "z"
ec=0
err=$(skills_cli install "$TMP_DIR/a.md" "$TMP_DIR/b.md" 2>&1 >/dev/null) || ec=$?
_assert "install 2 paths → exit 2" "$ec" "2"
_assert_contains "menciona only one source" "only one source" "$err"

echo
echo "=== T22: install resuelve name desde frontmatter, no basename"
_reset
# basename = filename.md, frontmatter name = renamed
cat >"$TMP_DIR/filename.md" <<'EOF'
---
name: renamed
description: name comes from FM
---
body
EOF
skills_cli install "$TMP_DIR/filename.md" >/dev/null 2>&1
_assert "dest usa name del FM" "$([ -f "$CODER_SKILLS_USER_DIR/renamed.md" ] && echo yes || echo no)" "yes"
_assert "dest NO usa basename" "$([ -f "$CODER_SKILLS_USER_DIR/filename.md" ] && echo yes || echo no)" "no"

echo
echo "=== T23: install rechaza nombres con whitespace o slash"
_reset
# Whitespace in name
cat >"$TMP_DIR/ws.md" <<'EOF'
---
name: bad name
description: x
---
body
EOF
ec=0
err=$(skills_cli install "$TMP_DIR/ws.md" 2>&1 >/dev/null) || ec=$?
_assert "name con espacio → exit 1" "$ec" "1"
_assert_contains "menciona invalid name" "invalid name" "$err"
# Slash in name
cat >"$TMP_DIR/sl.md" <<'EOF'
---
name: a/b
description: x
---
body
EOF
ec=0
err=$(skills_cli install "$TMP_DIR/sl.md" 2>&1 >/dev/null) || ec=$?
_assert "name con slash → exit 1" "$ec" "1"

echo
echo "=== T24: remove sin name => exit 2"
_reset
ec=0
skills_cli remove >/dev/null 2>&1 || ec=$?
_assert "remove sin name → exit 2" "$ec" "2"

echo
echo "=== T25: remove de skill inexistente => exit 1"
_reset
ec=0
err=$(skills_cli remove nope 2>&1 >/dev/null) || ec=$?
_assert "remove missing → exit 1" "$ec" "1"
_assert_contains "menciona not found" "not found" "$err"

echo
echo "=== T26: remove de built-in => exit 1 (protegido)"
_reset
_write_skill "$CODER_SKILLS_BUILTIN_DIR" "shipped" "Built-in" "body"
ec=0
err=$(skills_cli remove shipped 2>&1 >/dev/null) || ec=$?
_assert "remove builtin → exit 1" "$ec" "1"
_assert_contains "menciona built-in" "built-in" "$err"
_assert "archivo builtin NO borrado" "$([ -f "$CODER_SKILLS_BUILTIN_DIR/shipped.md" ] && echo yes || echo no)" "yes"

echo
echo "=== T27: remove de user skill ok + emite mensaje + archivo borrado"
_reset
_write_skill "$CODER_SKILLS_USER_DIR" "deleteme" "Will go" "bye"
ec=0
out=$(skills_cli remove deleteme 2>/dev/null) || ec=$?
_assert "remove user exit 0" "$ec" "0"
_assert_contains "reporta removed:" "removed: deleteme" "$out"
_assert "archivo user borrado" "$([ -f "$CODER_SKILLS_USER_DIR/deleteme.md" ] && echo yes || echo no)" "no"

echo
echo "=== T28: remove de user con override sobre builtin => sólo borra user, builtin queda"
_reset
_write_skill "$CODER_SKILLS_USER_DIR"    "shared" "User override" "u"
_write_skill "$CODER_SKILLS_BUILTIN_DIR" "shared" "Builtin"       "b"
ec=0
out=$(skills_cli remove shared 2>/dev/null) || ec=$?
_assert "remove override exit 0" "$ec" "0"
_assert "user override borrado"  "$([ -f "$CODER_SKILLS_USER_DIR/shared.md" ]    && echo yes || echo no)" "no"
_assert "builtin intacto"        "$([ -f "$CODER_SKILLS_BUILTIN_DIR/shared.md" ] && echo yes || echo no)" "yes"
# A second remove should now fail because the resolved entry is the builtin.
ec=0
err=$(skills_cli remove shared 2>&1 >/dev/null) || ec=$?
_assert "segundo remove de shared (ahora builtin) → exit 1" "$ec" "1"
_assert_contains "menciona built-in en segundo remove" "built-in" "$err"

echo
echo "=== T29: install crea el user dir si no existe"
_reset
rm -rf "$CODER_SKILLS_USER_DIR"
_write_skill "$TMP_DIR" "fresh" "first" "body"
ec=0
skills_cli install "$TMP_DIR/fresh.md" >/dev/null 2>&1 || ec=$?
_assert "install crea user dir" "$ec" "0"
_assert "dir creado" "$([ -d "$CODER_SKILLS_USER_DIR" ] && echo yes || echo no)" "yes"
_assert "file en user dir"  "$([ -f "$CODER_SKILLS_USER_DIR/fresh.md" ] && echo yes || echo no)" "yes"

echo
echo "=== Resultado: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
