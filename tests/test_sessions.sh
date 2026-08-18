#!/usr/bin/env bash
# Unit tests for lib/sessions.sh — persistent agentic sessions (P1.sessions-1).
#
# Run: bash tests/test_sessions.sh
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

assert_neq() {
    local label="$1" not_expected="$2" actual="$3"
    if [ "$not_expected" != "$actual" ]; then
        _pass "$label"
    else
        _fail "$label (got '$actual' but expected NOT to)"
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
        _fail "$label (needle='$needle' unexpectedly present in haystack='$haystack')"
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

# Isolation: dedicated tmpdir per run.
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT INT TERM
export CODER_SESSIONS_DIR="$TMPDIR_TEST/sessions"
export CONFIG_DIR="$TMPDIR_TEST/cfg"

# shellcheck disable=SC1091
source "$REPO_DIR/lib/agent/sessions.sh"
# Idempotent double-source.
# shellcheck disable=SC1091
source "$REPO_DIR/lib/agent/sessions.sh"

echo "=== module wiring ==="
for fn in sessions_dir sessions_init sessions_new sessions_exists sessions_save \
          sessions_load sessions_meta sessions_list sessions_remove \
          _sessions_valid_id _sessions_path _sessions_now_iso _sessions_gen_id \
          _sessions_atomic_write; do
    if declare -F "$fn" >/dev/null; then
        _pass "$fn defined"
    else
        _fail "$fn missing"
    fi
done

echo
echo "=== sessions_dir + sessions_init ==="
got=$(sessions_dir)
assert_eq "sessions_dir honors CODER_SESSIONS_DIR" "$TMPDIR_TEST/sessions" "$got"

sessions_init; rc=$?
assert_exit "sessions_init rc" 0 "$rc"
if [ -d "$TMPDIR_TEST/sessions" ]; then _pass "sessions_init created base dir"; else _fail "sessions_init did not create base dir"; fi

# Idempotent.
sessions_init; rc=$?
assert_exit "sessions_init idempotent rc" 0 "$rc"

echo
echo "=== _sessions_valid_id ==="
_sessions_valid_id "abc123"; assert_exit "valid: alnum" 0 "$?"
_sessions_valid_id "abc_123-xyz"; assert_exit "valid: with - and _" 0 "$?"
_sessions_valid_id ""; assert_exit "invalid: empty" 2 "$?"
_sessions_valid_id "a/b"; assert_exit "invalid: slash" 2 "$?"
_sessions_valid_id ".."; assert_exit "invalid: dot-dot" 2 "$?"
_sessions_valid_id ".hidden"; assert_exit "invalid: leading dot" 2 "$?"
_sessions_valid_id "abc def"; assert_exit "invalid: space" 2 "$?"
_sessions_valid_id "abc;rm"; assert_exit "invalid: special char" 2 "$?"
_sessions_valid_id "ñoño"; assert_exit "invalid: non-ascii" 2 "$?"

echo
echo "=== sessions_new ==="
id1=$(sessions_new "anthropic" "claude-sonnet-4-6" "first")
rc=$?
assert_exit "sessions_new rc" 0 "$rc"
assert_neq "sessions_new emits non-empty id" "" "$id1"
if [ -d "$TMPDIR_TEST/sessions/$id1" ]; then _pass "session dir created"; else _fail "session dir not created"; fi
if [ -f "$TMPDIR_TEST/sessions/$id1/meta.json" ]; then _pass "meta.json created"; else _fail "meta.json missing"; fi
if [ -f "$TMPDIR_TEST/sessions/$id1/messages.json" ]; then _pass "messages.json created"; else _fail "messages.json missing"; fi
msgs=$(cat "$TMPDIR_TEST/sessions/$id1/messages.json")
assert_eq "messages.json starts as empty array" "[]" "$msgs"
meta=$(cat "$TMPDIR_TEST/sessions/$id1/meta.json")
assert_eq "meta.id matches" "$id1" "$(printf '%s' "$meta" | jq -r '.id')"
assert_eq "meta.provider set" "anthropic" "$(printf '%s' "$meta" | jq -r '.provider')"
assert_eq "meta.model set" "claude-sonnet-4-6" "$(printf '%s' "$meta" | jq -r '.model')"
assert_eq "meta.label set" "first" "$(printf '%s' "$meta" | jq -r '.label')"
assert_eq "meta.turn_count starts at 0" "0" "$(printf '%s' "$meta" | jq -r '.turn_count')"
created=$(printf '%s' "$meta" | jq -r '.created_at')
updated=$(printf '%s' "$meta" | jq -r '.updated_at')
assert_eq "created_at == updated_at on new" "$created" "$updated"

# id format sanity: YYYYMMDDHHMMSS-<8hex>.
if [[ "$id1" =~ ^[0-9]{14}-[0-9a-f]{8}$ ]]; then
    _pass "id matches expected format"
else
    _fail "id format unexpected: $id1"
fi

# Empty-args new (anonymous).
id2=$(sessions_new)
assert_neq "anonymous new emits id" "" "$id2"
assert_neq "anonymous id != first id" "$id1" "$id2"
meta2=$(cat "$TMPDIR_TEST/sessions/$id2/meta.json")
assert_eq "anonymous meta.provider empty" "" "$(printf '%s' "$meta2" | jq -r '.provider')"
assert_eq "anonymous meta.label empty" "" "$(printf '%s' "$meta2" | jq -r '.label')"

echo
echo "=== sessions_exists ==="
sessions_exists "$id1"; assert_exit "existing id rc 0" 0 "$?"
sessions_exists "nonexistent-id"; assert_exit "missing id rc 1" 1 "$?"
sessions_exists ""; assert_exit "empty id rc 2" 2 "$?"
sessions_exists "../etc"; assert_exit "traversal rc 2" 2 "$?"

echo
echo "=== sessions_save ==="
msgs_v1='[{"role":"user","content":"hello"}]'
sessions_save "$id1" "$msgs_v1"; rc=$?
assert_exit "save rc" 0 "$rc"
got=$(cat "$TMPDIR_TEST/sessions/$id1/messages.json")
assert_eq "save: messages.json overwritten" "$msgs_v1" "$got"
meta_after=$(cat "$TMPDIR_TEST/sessions/$id1/meta.json")
assert_eq "save: turn_count incremented" "1" "$(printf '%s' "$meta_after" | jq -r '.turn_count')"
assert_eq "save: provider preserved" "anthropic" "$(printf '%s' "$meta_after" | jq -r '.provider')"
assert_eq "save: model preserved" "claude-sonnet-4-6" "$(printf '%s' "$meta_after" | jq -r '.model')"
# updated_at should be >= created_at (and may equal if same second).
updated_after=$(printf '%s' "$meta_after" | jq -r '.updated_at')
if [ -n "$updated_after" ]; then _pass "save: updated_at set"; else _fail "save: updated_at empty"; fi

# Override provider/model on save.
sleep 1  # ensure updated_at changes
sessions_save "$id1" "$msgs_v1" "openai" "gpt-5"
meta3=$(cat "$TMPDIR_TEST/sessions/$id1/meta.json")
assert_eq "save: provider overridden" "openai" "$(printf '%s' "$meta3" | jq -r '.provider')"
assert_eq "save: model overridden" "gpt-5" "$(printf '%s' "$meta3" | jq -r '.model')"
assert_eq "save: turn_count incremented again" "2" "$(printf '%s' "$meta3" | jq -r '.turn_count')"
updated3=$(printf '%s' "$meta3" | jq -r '.updated_at')
assert_neq "save: updated_at bumped after sleep" "$updated_after" "$updated3"

# Empty provider/model preserves (passing "" keeps existing).
sessions_save "$id1" "$msgs_v1" "" ""
meta4=$(cat "$TMPDIR_TEST/sessions/$id1/meta.json")
assert_eq "save with empty provider preserves prior" "openai" "$(printf '%s' "$meta4" | jq -r '.provider')"
assert_eq "save with empty model preserves prior" "gpt-5" "$(printf '%s' "$meta4" | jq -r '.model')"

# Invalid JSON rejected.
sessions_save "$id1" "not-json" 2>/dev/null; assert_exit "save rejects bad json" 2 "$?"
sessions_save "$id1" "" 2>/dev/null; assert_exit "save rejects empty msgs" 2 "$?"
sessions_save "" "[]" 2>/dev/null; assert_exit "save rejects empty id" 2 "$?"
sessions_save "../etc" "[]" 2>/dev/null; assert_exit "save rejects traversal id" 2 "$?"
sessions_save "nonexistent" "[]" 2>/dev/null; assert_exit "save rejects missing session" 1 "$?"

echo
echo "=== sessions_load ==="
loaded=$(sessions_load "$id1")
assert_exit "load rc" 0 "$?"
assert_eq "load returns last saved" "$msgs_v1" "$loaded"
sessions_load "nonexistent" 2>/dev/null; assert_exit "load missing rc 1" 1 "$?"
sessions_load "" 2>/dev/null; assert_exit "load empty id rc 2" 2 "$?"
sessions_load "../etc" 2>/dev/null; assert_exit "load traversal rc 2" 2 "$?"

echo
echo "=== sessions_meta ==="
meta_out=$(sessions_meta "$id1")
assert_exit "meta rc" 0 "$?"
assert_eq "meta returns id" "$id1" "$(printf '%s' "$meta_out" | jq -r '.id')"
sessions_meta "nonexistent" 2>/dev/null; assert_exit "meta missing rc 1" 1 "$?"
sessions_meta "" 2>/dev/null; assert_exit "meta empty id rc 2" 2 "$?"

echo
echo "=== sessions_list ==="
# Save id2 with a turn so updated_at differs deterministically.
sleep 1
sessions_save "$id2" '[{"role":"user","content":"x"}]' "gemini" "gemini-2.0"
listing=$(sessions_list)
assert_exit "list rc" 0 "$?"
assert_contains "list contains id1" "$id1" "$listing"
assert_contains "list contains id2" "$id2" "$listing"
# id2 was updated most recently (after the sleep), so it should appear first (sorted desc).
first_line=$(printf '%s\n' "$listing" | head -n1)
assert_contains "list sorted by updated_at desc (id2 first)" "$id2" "$first_line"
# TSV columns: id, turn_count, updated_at, provider, label.
# Parse the id1 row.
id1_row=$(printf '%s\n' "$listing" | grep "^$id1	")
if [ -n "$id1_row" ]; then _pass "list emits id1 row"; else _fail "list missing id1 row"; fi
tc_col=$(printf '%s' "$id1_row" | awk -F'\t' '{print $2}')
prov_col=$(printf '%s' "$id1_row" | awk -F'\t' '{print $4}')
assert_eq "list: id1 turn_count=3 (3 saves earlier)" "3" "$tc_col"
assert_eq "list: id1 provider=openai" "openai" "$prov_col"

# Garbage entry doesn't break list: drop a corrupt session dir.
mkdir -p "$TMPDIR_TEST/sessions/corrupt-x"
echo "not json" > "$TMPDIR_TEST/sessions/corrupt-x/meta.json"
listing2=$(sessions_list)
assert_not_contains "corrupt entry skipped" "corrupt-x" "$listing2"

# A stray non-conforming-id dir is also skipped.
mkdir -p "$TMPDIR_TEST/sessions/.hidden-junk"
listing3=$(sessions_list)
assert_not_contains ".hidden dir skipped" ".hidden-junk" "$listing3"

echo
echo "=== sessions_remove ==="
sessions_remove "$id2"; rc=$?
assert_exit "remove rc" 0 "$rc"
if [ -d "$TMPDIR_TEST/sessions/$id2" ]; then _fail "remove did not delete dir"; else _pass "remove deleted dir"; fi
sessions_remove "$id2" 2>/dev/null; assert_exit "remove missing rc 1" 1 "$?"
sessions_remove "" 2>/dev/null; assert_exit "remove empty rc 2" 2 "$?"
sessions_remove "../etc" 2>/dev/null; assert_exit "remove traversal rc 2" 2 "$?"
sessions_remove ".hidden" 2>/dev/null; assert_exit "remove leading dot rc 2" 2 "$?"

# Remove refuses if the dir doesn't look like a session.
mkdir -p "$TMPDIR_TEST/sessions/foo-empty"
sessions_remove "foo-empty" 2>/dev/null
assert_exit "remove refuses dir without meta/messages" 1 "$?"
if [ -d "$TMPDIR_TEST/sessions/foo-empty" ]; then _pass "non-session dir preserved"; else _fail "non-session dir deleted"; fi

# Replace with a symlink pointing outside (defense in depth: cd && pwd -P
# would resolve and refuse).
outside=$(mktemp -d)
ln -s "$outside" "$TMPDIR_TEST/sessions/escape"
sessions_remove "escape" 2>/dev/null; rc=$?
if [ -d "$outside" ]; then _pass "symlink target NOT deleted"; else _fail "symlink target was deleted"; fi
if [ "$rc" -ne 0 ]; then _pass "remove via symlink rejected"; else _fail "remove via symlink should have failed"; fi
rm -rf "$outside"
rm -f "$TMPDIR_TEST/sessions/escape"

echo
echo "=== _sessions_atomic_write ==="
target="$TMPDIR_TEST/sessions/atomic-test.txt"
mkdir -p "$(dirname "$target")"
_sessions_atomic_write "$target" "hello"; rc=$?
assert_exit "atomic_write rc" 0 "$rc"
assert_eq "atomic_write content" "hello" "$(cat "$target")"
_sessions_atomic_write "/nonexistent-dir-xyz/foo" "x" 2>/dev/null
assert_exit "atomic_write missing dir rc 1" 1 "$?"

echo
echo "=== summary ==="
echo "Pass: $PASS"
echo "Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
