#!/usr/bin/env bash
# Unit tests for lib/skills.sh — skill registry / parser.
#
# Run: bash tests/test_skills.sh
# All asserts isolated in tmpdir; user config untouched.

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
        _fail "$label (needle='$needle' missing from haystack='$haystack')"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        _pass "$label"
    else
        _fail "$label (unexpected needle='$needle' in haystack='$haystack')"
    fi
}

assert_exit() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        _pass "$label"
    else
        _fail "$label (expected exit=$expected actual=$actual)"
    fi
}

# Isolation: dedicated tmpdir per run, exported to override the module's default.
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT INT TERM
export CODER_SKILLS_USER_DIR="$TMPDIR_TEST/skills"
# Aislar de los skills built-in shipped en el repo (P1.slash-3): esta suite
# verifica el comportamiento del registry de user-dir solamente.
export CODER_SKILLS_BUILTIN_DIR=""

# Source the module. Should be idempotent under double-source.
# shellcheck disable=SC1091
source "$REPO_DIR/lib/agent/skills.sh"
# shellcheck disable=SC1091
source "$REPO_DIR/lib/agent/skills.sh"

echo "=== module wiring ==="
for fn in skills_init skills_list skills_path skills_exists skills_describe skills_body skills_render; do
    if declare -f "$fn" >/dev/null 2>&1; then
        _pass "$fn defined"
    else
        _fail "$fn defined"
    fi
done

echo
echo "=== skills_init ==="
if [ ! -d "$CODER_SKILLS_USER_DIR" ]; then _pass "user dir absent pre-init"; else _fail "user dir absent pre-init"; fi
skills_init
ec=$?
assert_exit "skills_init exit 0" "0" "$ec"
if [ -d "$CODER_SKILLS_USER_DIR" ]; then _pass "user dir created"; else _fail "user dir created"; fi

echo
echo "=== empty registry ==="
out=$(skills_list)
assert_eq "skills_list empty registry" "" "$out"
skills_exists anything
assert_exit "skills_exists empty -> 1" "1" "$?"

echo
echo "=== single skill, full frontmatter ==="
cat >"$CODER_SKILLS_USER_DIR/analyze.md" <<'EOF'
---
name: analyze
description: Full project analysis
---
Run a full project analysis.
Use read_file on key files.
{{args}}
EOF

out=$(skills_list)
assert_contains "list includes name" $'analyze\t' "$out"
assert_contains "list includes description" "Full project analysis" "$out"
assert_contains "list includes path" "$CODER_SKILLS_USER_DIR/analyze.md" "$out"

skills_exists analyze
assert_exit "exists analyze -> 0" "0" "$?"

path=$(skills_path analyze)
assert_eq "path analyze" "$CODER_SKILLS_USER_DIR/analyze.md" "$path"

desc=$(skills_describe analyze)
assert_eq "describe analyze" "Full project analysis" "$desc"

body=$(skills_body analyze)
assert_contains "body first line" "Run a full project analysis." "$body"
assert_contains "body second line" "Use read_file on key files." "$body"
assert_contains "body has placeholder" "{{args}}" "$body"
assert_not_contains "body excludes frontmatter delimiter" "---" "$body"
assert_not_contains "body excludes name field" "name: analyze" "$body"

echo
echo "=== skills_render with placeholder ==="
rendered=$(skills_render analyze fix the login bug)
assert_contains "render replaces {{args}}" "fix the login bug" "$rendered"
assert_not_contains "render strips placeholder" "{{args}}" "$rendered"
assert_contains "render preserves body line 1" "Run a full project analysis." "$rendered"

rendered_empty=$(skills_render analyze)
# Empty args means placeholder becomes empty string but line containing it survives.
assert_not_contains "render with no args strips placeholder" "{{args}}" "$rendered_empty"
assert_contains "render with no args preserves body" "Run a full project analysis." "$rendered_empty"

echo
echo "=== second skill without placeholder ==="
cat >"$CODER_SKILLS_USER_DIR/think.md" <<'EOF'
---
description: Deep thinking
---
Think deeply about the topic. Consider trade-offs.
EOF

# Name should fall back to basename.
path_think=$(skills_path think)
assert_eq "think path resolves via basename" "$CODER_SKILLS_USER_DIR/think.md" "$path_think"

desc_think=$(skills_describe think)
assert_eq "think description" "Deep thinking" "$desc_think"

rendered=$(skills_render think)
assert_eq "think render no args = body verbatim" "Think deeply about the topic. Consider trade-offs." "$rendered"

rendered_append=$(skills_render think login flow)
assert_contains "think render appends args after blank line" "login flow" "$rendered_append"
assert_contains "think render preserves body" "Think deeply about the topic." "$rendered_append"
# Args separated by blank line per contract.
case "$rendered_append" in
    *$'\n\nlogin flow'*) _pass "args separator: blank line before args" ;;
    *) _fail "args separator: blank line before args (got: $(printf '%q' "$rendered_append"))" ;;
esac

echo
echo "=== broken frontmatter is skipped ==="
cat >"$CODER_SKILLS_USER_DIR/broken.md" <<'EOF'
no frontmatter at all
just plain text body
EOF

out=$(skills_list)
assert_not_contains "list excludes broken skill" "broken" "$out"
skills_exists broken
assert_exit "exists broken -> 1" "1" "$?"

# Frontmatter open but never closed = also skipped.
cat >"$CODER_SKILLS_USER_DIR/unclosed.md" <<'EOF'
---
name: unclosed
description: missing closing dashes
body without separator
EOF

out=$(skills_list)
assert_not_contains "list excludes unclosed frontmatter skill" "unclosed" "$out"

echo
echo "=== quoted values are unquoted ==="
cat >"$CODER_SKILLS_USER_DIR/quoted.md" <<'EOF'
---
name: "quoted-name"
description: 'Single quoted desc'
---
Body.
EOF

desc=$(skills_describe quoted-name)
assert_eq "single-quoted description unwrapped" "Single quoted desc" "$desc"
path=$(skills_path quoted-name)
assert_eq "double-quoted name resolves" "$CODER_SKILLS_USER_DIR/quoted.md" "$path"

echo
echo "=== sort order is lexical ==="
cat >"$CODER_SKILLS_USER_DIR/aaa.md" <<'EOF'
---
name: aaa
description: alpha
---
A
EOF
cat >"$CODER_SKILLS_USER_DIR/zzz.md" <<'EOF'
---
name: zzz
description: omega
---
Z
EOF

out=$(skills_list | awk -F'\t' '{print $1}')
first=$(echo "$out" | head -1)
last=$(echo "$out" | tail -1)
assert_eq "first listed = aaa" "aaa" "$first"
assert_eq "last listed = zzz" "zzz" "$last"

echo
echo "=== missing skill exit codes ==="
skills_path nope >/dev/null 2>&1
assert_exit "path missing -> 1" "1" "$?"
skills_describe nope >/dev/null 2>&1
assert_exit "describe missing -> 1" "1" "$?"
skills_body nope >/dev/null 2>&1
assert_exit "body missing -> 1" "1" "$?"
skills_render nope >/dev/null 2>&1
assert_exit "render missing -> 1" "1" "$?"
skills_render "" >/dev/null 2>&1
assert_exit "render empty-name -> 2" "2" "$?"

echo
echo "=== body preserves verbatim content ==="
# Use printf to embed exact bytes; quotes, backslash, blank lines preserved.
cat >"$CODER_SKILLS_USER_DIR/verbatim.md" <<'EOF'
---
name: verbatim
description: tricky body
---
Line with "quotes" and 'apostrophes'.

Backslash: \n is literal here.
End.
EOF

body=$(skills_body verbatim)
assert_contains "body keeps double quotes" 'Line with "quotes"' "$body"
assert_contains "body keeps apostrophes" "'apostrophes'" "$body"
assert_contains "body keeps literal backslash-n" '\n is literal here' "$body"
assert_contains "body keeps end marker" "End." "$body"

echo
echo "=== skills_init is idempotent ==="
skills_init
assert_exit "skills_init re-run -> 0" "0" "$?"

echo
echo "=== empty CODER_SKILLS_USER_DIR is harmless ==="
ALT_TMP=$(mktemp -d)
CODER_SKILLS_USER_DIR="$ALT_TMP/never-created" skills_list >/dev/null 2>&1
assert_exit "list on missing dir -> 0" "0" "$?"
out=$(CODER_SKILLS_USER_DIR="$ALT_TMP/never-created" skills_list)
assert_eq "list on missing dir is empty" "" "$out"
rm -rf "$ALT_TMP"

echo
echo "=================="
echo "Resultado: $PASS pass, $FAIL fail"
echo "=================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
