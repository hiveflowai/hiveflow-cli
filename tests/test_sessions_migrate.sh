#!/bin/bash
#
# P1.sessions-4 — unit tests for `sessions_migrate_legacy` + `sessions_cli migrate`.
# Migration converts $CONFIG_DIR/historial_*.txt files into sessions/ entries.
# All asserts isolated to a tmp dir; user config untouched.
#
# Run: bash tests/test_sessions_migrate.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT" || exit 1

TMP_DIR=$(mktemp -d)
export CONFIG_DIR="$TMP_DIR/config"
export CODER_SESSIONS_DIR="$TMP_DIR/sessions"
mkdir -p "$CONFIG_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# shellcheck source=../lib/sessions.sh disable=SC1091
source "$REPO_ROOT/lib/agent/sessions.sh"

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
        _fail "$label (missing: '$needle' in: ${haystack:0:300})"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        _fail "$label (unexpected presence of: '$needle')"
    else
        _pass "$label"
    fi
}

_reset() {
    rm -rf "$CONFIG_DIR" "$CODER_SESSIONS_DIR"
    mkdir -p "$CONFIG_DIR"
}

# ---------------------------------------------------------------------------

echo "=== T1: empty CONFIG_DIR (no historial files) => 0/0/0 summary + exit 0"
_reset
ec=0
out=$(sessions_migrate_legacy 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
assert_contains "reports no files found" "no historial files found" "$out"
assert_contains "summary line present" "summary: 0 migrated, 0 skipped, 0 total" "$out"

echo
echo "=== T2: one historial file => migrated, session created"
_reset
echo "Hola, ¿cómo estás?" >"$CONFIG_DIR/historial_20250809_143012.txt"
ec=0
out=$(sessions_migrate_legacy 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
assert_contains "MIGRATE line present" "MIGRATE historial_20250809_143012.txt -> " "$out"
assert_contains "summary 1/0/1" "summary: 1 migrated, 0 skipped, 1 total" "$out"
# Extract the new id from MIGRATE line and verify the session.
new_id=$(printf '%s\n' "$out" | sed -n 's/^MIGRATE historial_20250809_143012.txt -> //p')
if [ -n "$new_id" ]; then _pass "id non-empty"; else _fail "id non-empty (out=$out)"; fi
sessions_exists "$new_id"
rc=$?
assert_eq "session exists" "0" "$rc"
meta=$(sessions_meta "$new_id")
assert_contains "meta has origin=legacy_historial" '"origin": "legacy_historial"' "$meta"
assert_contains "meta has legacy_basename" '"legacy_basename": "historial_20250809_143012.txt"' "$meta"
assert_contains "meta legacy_path is absolute" "\"legacy_path\": \"$CONFIG_DIR/historial_20250809_143012.txt\"" "$meta"
assert_contains "meta created_at parsed from filename" '"created_at": "2025-08-09T14:30:12Z"' "$meta"
assert_contains "meta updated_at == created_at" '"updated_at": "2025-08-09T14:30:12Z"' "$meta"
assert_contains "meta turn_count is 0" '"turn_count": 0' "$meta"
assert_contains "meta label uses parsed date" '"label": "Legacy 2025-08-09"' "$meta"
msgs=$(sessions_load "$new_id")
# Validate single user message with verbatim content.
msg_len=$(printf '%s' "$msgs" | jq 'length')
assert_eq "messages.json length 1" "1" "$msg_len"
role=$(printf '%s' "$msgs" | jq -r '.[0].role')
assert_eq "first message role=user" "user" "$role"
content=$(printf '%s' "$msgs" | jq -r '.[0].content')
assert_eq "first message content preserves text" "Hola, ¿cómo estás?" "$content"

echo
echo "=== T3: re-running on same dir => idempotent (skip already-migrated)"
ec=0
out=$(sessions_migrate_legacy 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
assert_contains "SKIP already-migrated line" "SKIP historial_20250809_143012.txt (already migrated as $new_id)" "$out"
assert_contains "summary 0/1/1" "summary: 0 migrated, 1 skipped, 1 total" "$out"
# Confirm no second session was created (still just the one).
session_count=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
assert_eq "still 1 session dir" "1" "$session_count"

echo
echo "=== T4: empty historial file => skipped with (empty)"
_reset
: >"$CONFIG_DIR/historial_20250809_143012.txt"  # zero-byte
ec=0
out=$(sessions_migrate_legacy 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
assert_contains "SKIP empty" "SKIP historial_20250809_143012.txt (empty)" "$out"
assert_contains "summary 0/1/1" "summary: 0 migrated, 1 skipped, 1 total" "$out"
session_count=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no session created for empty" "0" "$session_count"

echo
echo "=== T5: badly-named historial file (no timestamp) => migrated with fallback label"
_reset
echo "garbage filename content" >"$CONFIG_DIR/historial_garbage.txt"
ec=0
out=$(sessions_migrate_legacy 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
assert_contains "MIGRATE garbage line" "MIGRATE historial_garbage.txt -> " "$out"
new_id=$(printf '%s\n' "$out" | sed -n 's/^MIGRATE historial_garbage.txt -> //p')
meta=$(sessions_meta "$new_id")
assert_contains "fallback label uses basename" '"label": "Legacy historial_garbage.txt"' "$meta"
# created_at falls back to "now" — just assert it parses as ISO8601 Z.
created_at=$(printf '%s' "$meta" | jq -r '.created_at')
if [[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    _pass "fallback created_at is ISO-8601"
else
    _fail "fallback created_at not ISO-8601 (got '$created_at')"
fi

echo
echo "=== T6: --dry-run => emits DRY-RUN line, no sessions written, legacy preserved"
_reset
echo "preview me" >"$CONFIG_DIR/historial_20250809_143012.txt"
ec=0
out=$(sessions_migrate_legacy --dry-run 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
assert_contains "DRY-RUN line" "DRY-RUN historial_20250809_143012.txt -> " "$out"
assert_contains "DRY-RUN includes label" "label='Legacy 2025-08-09'" "$out"
assert_contains "summary 1/0/1 even in dry-run" "summary: 1 migrated, 0 skipped, 1 total" "$out"
session_count=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no session created in dry-run" "0" "$session_count"
if [ -f "$CONFIG_DIR/historial_20250809_143012.txt" ]; then
    _pass "legacy file preserved in dry-run"
else
    _fail "legacy file removed in dry-run"
fi

echo
echo "=== T7: --remove-legacy => migrates and deletes the .txt file"
_reset
echo "remove me" >"$CONFIG_DIR/historial_20250809_143012.txt"
ec=0
out=$(sessions_migrate_legacy --remove-legacy 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
assert_contains "MIGRATE line" "MIGRATE historial_20250809_143012.txt -> " "$out"
if [ ! -e "$CONFIG_DIR/historial_20250809_143012.txt" ]; then
    _pass "legacy .txt removed"
else
    _fail "legacy .txt still present after --remove-legacy"
fi
session_count=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
assert_eq "1 session created" "1" "$session_count"

echo
echo "=== T8: --from <alt-dir> => migrates from alternate dir"
_reset
ALT_DIR="$TMP_DIR/alt"
mkdir -p "$ALT_DIR"
echo "alternate" >"$ALT_DIR/historial_20250809_143012.txt"
# Also place a file in CONFIG_DIR that must NOT be migrated.
echo "should-not-be-migrated" >"$CONFIG_DIR/historial_20240101_000000.txt"
ec=0
out=$(sessions_migrate_legacy --from "$ALT_DIR" 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
assert_contains "MIGRATE for alt-dir file" "MIGRATE historial_20250809_143012.txt -> " "$out"
assert_not_contains "config-dir file not touched" "historial_20240101_000000.txt" "$out"
assert_contains "summary 1/0/1" "summary: 1 migrated, 0 skipped, 1 total" "$out"
# Verify legacy_path is from alt-dir.
new_id=$(printf '%s\n' "$out" | sed -n 's/^MIGRATE historial_20250809_143012.txt -> //p')
meta=$(sessions_meta "$new_id")
assert_contains "legacy_path points to alt-dir" "\"legacy_path\": \"$ALT_DIR/historial_20250809_143012.txt\"" "$meta"

echo
echo "=== T9: --from=<dir> equals form => same behavior"
_reset
ALT_DIR="$TMP_DIR/alt2"
mkdir -p "$ALT_DIR"
echo "equals form" >"$ALT_DIR/historial_20250809_143012.txt"
ec=0
out=$(sessions_migrate_legacy --from="$ALT_DIR" 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
assert_contains "MIGRATE line" "MIGRATE historial_20250809_143012.txt -> " "$out"

echo
echo "=== T10: --from <nonexistent-dir> => exit 1, error on stderr"
_reset
ec=0
err=$(sessions_migrate_legacy --from "$TMP_DIR/does-not-exist" 2>&1 >/dev/null) || ec=$?
assert_eq "exit 1 on missing dir" "1" "$ec"
assert_contains "stderr mentions not found" "directory not found" "$err"

echo
echo "=== T11: --from without arg => exit 2 usage error"
_reset
ec=0
err=$(sessions_migrate_legacy --from 2>&1 >/dev/null) || ec=$?
assert_eq "exit 2 on missing arg" "2" "$ec"
assert_contains "stderr mentions --from needs" "--from needs" "$err"

echo
echo "=== T12: unknown flag => exit 2"
_reset
ec=0
err=$(sessions_migrate_legacy --bogus 2>&1 >/dev/null) || ec=$?
assert_eq "exit 2 on unknown flag" "2" "$ec"
assert_contains "stderr mentions unknown flag" "unknown flag" "$err"

echo
echo "=== T13: multiple files in one pass => all migrated, summary reflects N"
_reset
echo "one" >"$CONFIG_DIR/historial_20250101_010101.txt"
echo "two" >"$CONFIG_DIR/historial_20250202_020202.txt"
echo "three" >"$CONFIG_DIR/historial_20250303_030303.txt"
ec=0
out=$(sessions_migrate_legacy 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
migrate_count=$(printf '%s\n' "$out" | grep -c '^MIGRATE ' || true)
assert_eq "3 MIGRATE lines" "3" "$migrate_count"
assert_contains "summary 3/0/3" "summary: 3 migrated, 0 skipped, 3 total" "$out"
session_count=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
assert_eq "3 session dirs" "3" "$session_count"

echo
echo "=== T14: content with newlines + special chars round-trips through JSON"
_reset
printf 'line one\nline two with "quotes" and \\backslash\n' >"$CONFIG_DIR/historial_20250809_143012.txt"
ec=0
out=$(sessions_migrate_legacy 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
new_id=$(printf '%s\n' "$out" | sed -n 's/^MIGRATE historial_20250809_143012.txt -> //p')
msgs=$(sessions_load "$new_id")
# `jq -j` emits the raw value without jq's auto-trailing newline; sentinel
# `.` then guards against `$(...)` stripping any trailing newlines that are
# legitimately part of the file's bytes.
content=$(printf '%s' "$msgs" | jq -j '.[0].content'; printf .)
content="${content%.}"
expected=$'line one\nline two with "quotes" and \\backslash\n'
assert_eq "content round-trips verbatim" "$expected" "$content"

echo
echo "=== T15: messages.json is valid JSON"
# Reuse session from T14.
msgs=$(sessions_load "$new_id")
if printf '%s' "$msgs" | jq empty >/dev/null 2>&1; then
    _pass "messages.json is valid JSON"
else
    _fail "messages.json is invalid JSON"
fi

# ---------- CLI surface (sessions_cli migrate ...) -------------------------

echo
echo "=== T16: sessions_cli migrate (no flags) on empty dir => exit 0 + summary"
_reset
ec=0
out=$(sessions_cli migrate 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
assert_contains "summary 0/0/0" "summary: 0 migrated, 0 skipped, 0 total" "$out"

echo
echo "=== T17: sessions_cli migrate --dry-run forwards to core"
_reset
echo "cli dry" >"$CONFIG_DIR/historial_20250809_143012.txt"
ec=0
out=$(sessions_cli migrate --dry-run 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
assert_contains "DRY-RUN line" "DRY-RUN historial_20250809_143012.txt -> " "$out"
session_count=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no session created via CLI dry-run" "0" "$session_count"

echo
echo "=== T18: sessions_cli migrate --remove-legacy forwards properly"
_reset
echo "cli remove" >"$CONFIG_DIR/historial_20250809_143012.txt"
ec=0
out=$(sessions_cli migrate --remove-legacy 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
if [ ! -e "$CONFIG_DIR/historial_20250809_143012.txt" ]; then
    _pass "legacy removed via CLI"
else
    _fail "legacy not removed via CLI"
fi

echo
echo "=== T19: sessions_cli migrate --from <dir> forwards properly"
_reset
ALT_DIR="$TMP_DIR/cli-alt"
mkdir -p "$ALT_DIR"
echo "cli-alt" >"$ALT_DIR/historial_20250809_143012.txt"
ec=0
out=$(sessions_cli migrate --from "$ALT_DIR" 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
assert_contains "MIGRATE from alt dir" "MIGRATE historial_20250809_143012.txt -> " "$out"

echo
echo "=== T20: sessions_cli migrate --from without arg => exit 2 + usage on stderr"
_reset
ec=0
err=$(sessions_cli migrate --from 2>&1 >/dev/null) || ec=$?
assert_eq "exit 2" "2" "$ec"
assert_contains "stderr mentions needs <dir>" "--from needs <dir>" "$err"
assert_contains "stderr includes usage Subcommands" "Subcommands:" "$err"

echo
echo "=== T21: sessions_cli migrate --bogus => exit 2 + usage on stderr"
_reset
ec=0
err=$(sessions_cli migrate --bogus 2>&1 >/dev/null) || ec=$?
assert_eq "exit 2" "2" "$ec"
assert_contains "stderr mentions unknown argument" "unknown argument" "$err"
assert_contains "stderr includes usage" "Subcommands:" "$err"

echo
echo "=== T22: sessions_cli migrate --help => exit 0 + usage on stdout"
_reset
ec=0
out=$(sessions_cli migrate --help 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
assert_contains "help shows migrate entry" "migrate" "$out"
assert_contains "help mentions --dry-run" "--dry-run" "$out"
assert_contains "help mentions --remove-legacy" "--remove-legacy" "$out"

echo
echo "=== T23: sessions_cli help/usage globally lists migrate"
_reset
ec=0
out=$(sessions_cli --help 2>/dev/null) || ec=$?
assert_eq "exit 0" "0" "$ec"
assert_contains "global help lists migrate" "migrate " "$out"

# ---------------------------------------------------------------------------

echo
echo "==============================="
echo "Resultado: $PASS pass, $FAIL fail"
echo "==============================="
[ "$FAIL" -eq 0 ]
