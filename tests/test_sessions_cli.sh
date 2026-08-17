#!/bin/bash
#
# P1.sessions-3 CLI dispatcher (`sessions_cli`) — unit tests.
# Isolates $CODER_SESSIONS_DIR to a tmp dir. The core API
# (sessions_new/save/load/remove/list) is covered by tests/test_sessions.sh —
# here we validate the dispatcher: subcommand parsing, argc validation, exit
# codes, table formatting, resume guards.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT" || exit 1

TMP_DIR=$(mktemp -d)
export CODER_SESSIONS_DIR="$TMP_DIR/sessions"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# shellcheck source=../lib/sessions.sh disable=SC1091
source "$REPO_ROOT/lib/agent/sessions.sh"

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
    # Bash native pattern match: avoids the `printf | grep -q` SIGPIPE flake
    # under `set -o pipefail` when grep short-circuits on a multi-line haystack.
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (missing: '$needle' in: ${haystack:0:200})"
        FAIL=$((FAIL + 1))
    fi
}

_assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  FAIL: $desc (unexpected presence of: '$needle')"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

_reset() {
    rm -rf "$CODER_SESSIONS_DIR"
}

echo "=== T1: no subcommand => usage on stderr + exit 2"
_reset
ec=0
out=$(sessions_cli 2>&1 >/dev/null) || ec=$?
_assert "exit 2 without subcommand" "$ec" "2"
_assert_contains "stderr mentions Uso" "Usage:" "$out"

echo
echo "=== T2: --help / -h / help => stdout + exit 0"
_reset
ec=0
out=$(sessions_cli --help 2>/dev/null) || ec=$?
_assert "--help exit 0" "$ec" "0"
_assert_contains "--help shows Subcommands" "Subcommands:" "$out"
ec=0
out=$(sessions_cli -h 2>/dev/null) || ec=$?
_assert "-h exit 0" "$ec" "0"
ec=0
out=$(sessions_cli help 2>/dev/null) || ec=$?
_assert "help (bareword) exit 0" "$ec" "0"
_assert_contains "help shows Examples" "Examples:" "$out"

echo
echo "=== T3: unknown subcommand => exit 2 + usage"
_reset
ec=0
err=$(sessions_cli bogus 2>&1 >/dev/null) || ec=$?
_assert "bogus exit 2" "$ec" "2"
_assert_contains "stderr mentions unknown subcommand" "unknown subcommand" "$err"
_assert_contains "stderr includes usage" "Subcommands:" "$err"

echo
echo "=== T4: list empty => '(no sessions)' + exit 0"
_reset
ec=0
out=$(sessions_cli list 2>/dev/null) || ec=$?
_assert "empty list exit 0" "$ec" "0"
_assert_contains "empty list shows '(no sessions)'" "(no sessions)" "$out"

echo
echo "=== T5: list with extra args => exit 2"
_reset
ec=0
err=$(sessions_cli list extra 2>&1 >/dev/null) || ec=$?
_assert "list extra exit 2" "$ec" "2"
_assert_contains "stderr mentions unexpected" "unexpected arguments" "$err"

echo
echo "=== T6: list with rows => header + entries"
_reset
id1=$(sessions_new "anthropic" "claude-sonnet-4-6" "demo")
sleep 1   # ensure updated_at differs lexicographically
id2=$(sessions_new "openai" "gpt-4o" "alt")
# Save once so turn_count=1 on id2 (proves the column wiring).
sessions_save "$id2" '[{"role":"user","content":"hi"}]' >/dev/null
ec=0
out=$(sessions_cli list 2>/dev/null) || ec=$?
_assert "list exit 0" "$ec" "0"
_assert_contains "list header has ID column" "ID" "$out"
_assert_contains "list header has TURNS column" "TURNS" "$out"
_assert_contains "list header has UPDATED column" "UPDATED" "$out"
_assert_contains "list header has PROVIDER column" "PROVIDER" "$out"
_assert_contains "list header has LABEL column" "LABEL" "$out"
_assert_contains "list shows id1" "$id1" "$out"
_assert_contains "list shows id2" "$id2" "$out"
_assert_contains "list shows provider anthropic" "anthropic" "$out"
_assert_contains "list shows provider openai" "openai" "$out"
_assert_contains "list shows label demo" "demo" "$out"

echo
echo "=== T7: show without arg => exit 2"
_reset
ec=0
err=$(sessions_cli show 2>&1 >/dev/null) || ec=$?
_assert "show no arg exit 2" "$ec" "2"
_assert_contains "stderr mentions expected <id>" "expected <id>" "$err"

echo
echo "=== T8: show with extra args => exit 2"
_reset
ec=0
err=$(sessions_cli show a b 2>&1 >/dev/null) || ec=$?
_assert "show extra exit 2" "$ec" "2"

echo
echo "=== T9: show invalid id => exit 2"
_reset
ec=0
err=$(sessions_cli show "../escape" 2>&1 >/dev/null) || ec=$?
_assert "show invalid id exit 2" "$ec" "2"
_assert_contains "stderr mentions invalid id" "invalid id" "$err"

echo
echo "=== T10: show non-existent id => exit 1"
_reset
ec=0
err=$(sessions_cli show "nonexistent-1234" 2>&1 >/dev/null) || ec=$?
_assert "show missing exit 1" "$ec" "1"
_assert_contains "stderr mentions not found" "not found" "$err"

echo
echo "=== T11: show existing session => metadata fields + path"
_reset
id=$(sessions_new "anthropic" "claude-sonnet-4-6" "")
sessions_save "$id" '[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"}]' >/dev/null
ec=0
out=$(sessions_cli show "$id" 2>/dev/null) || ec=$?
_assert "show existing exit 0" "$ec" "0"
_assert_contains "show emits id:" "id: $id" "$out"
_assert_contains "show emits created_at:" "created_at: " "$out"
_assert_contains "show emits updated_at:" "updated_at: " "$out"
_assert_contains "show emits provider: anthropic" "provider: anthropic" "$out"
_assert_contains "show emits model:" "model: claude-sonnet-4-6" "$out"
_assert_contains "show emits turn_count: 1" "turn_count: 1" "$out"
_assert_contains "show emits message_count: 2" "message_count: 2" "$out"
_assert_contains "show emits path" "path: $CODER_SESSIONS_DIR/$id" "$out"

echo
echo "=== T12: remove without arg => exit 2"
_reset
ec=0
err=$(sessions_cli remove 2>&1 >/dev/null) || ec=$?
_assert "remove no arg exit 2" "$ec" "2"

echo
echo "=== T13: remove invalid id => exit 2"
_reset
ec=0
err=$(sessions_cli remove "../escape" 2>&1 >/dev/null) || ec=$?
_assert "remove invalid id exit 2" "$ec" "2"
_assert_contains "stderr mentions invalid id" "invalid id" "$err"

echo
echo "=== T14: remove non-existent id => exit 1"
_reset
ec=0
err=$(sessions_cli remove "nonexistent-1234" 2>&1 >/dev/null) || ec=$?
_assert "remove missing exit 1" "$ec" "1"
_assert_contains "stderr mentions not found" "not found" "$err"

echo
echo "=== T15: remove existing session => exit 0 + directory gone"
_reset
id=$(sessions_new "anthropic" "claude-sonnet-4-6" "")
[ -d "$CODER_SESSIONS_DIR/$id" ] && _pass_pre=ok || _pass_pre=missing
_assert "pre: session dir exists" "$_pass_pre" "ok"
ec=0
out=$(sessions_cli remove "$id" 2>/dev/null) || ec=$?
_assert "remove exit 0" "$ec" "0"
_assert_contains "stdout confirms removal" "removed: $id" "$out"
[ -d "$CODER_SESSIONS_DIR/$id" ] && _post=present || _post=gone
_assert "post: session dir removed" "$_post" "gone"

echo
echo "=== T16: resume without arg => exit 2"
_reset
ec=0
err=$(sessions_cli resume 2>&1 >/dev/null) || ec=$?
_assert "resume no arg exit 2" "$ec" "2"

echo
echo "=== T17: resume invalid id => exit 2"
_reset
ec=0
err=$(sessions_cli resume "../escape" 2>&1 >/dev/null) || ec=$?
_assert "resume invalid id exit 2" "$ec" "2"
_assert_contains "stderr mentions invalid id" "invalid id" "$err"

echo
echo "=== T18: resume non-existent id => exit 1"
_reset
ec=0
err=$(sessions_cli resume "nonexistent-1234" 2>&1 >/dev/null) || ec=$?
_assert "resume missing exit 1" "$ec" "1"
_assert_contains "stderr mentions not found" "not found" "$err"

echo
echo "=== T19: resume existing session w/o modo_agentico_interactivo => exit 1 + hint"
_reset
id=$(sessions_new "anthropic" "claude-sonnet-4-6" "")
# In this test process, modo_agentico_interactivo is NOT defined (we only
# sourced lib/sessions.sh). The guard must trigger.
ec=0
err=$(sessions_cli resume "$id" 2>&1 >/dev/null) || ec=$?
_assert "resume w/o agentic exit 1" "$ec" "1"
_assert_contains "stderr mentions agentic missing" "agentic mode not available" "$err"

echo
echo "=== T20: resume existing session WITH stubbed agentic => exit 0 + env set"
_reset
id=$(sessions_new "anthropic" "claude-sonnet-4-6" "")
# Stub modo_agentico_interactivo + get_api_config to verify wire-up.
# shellcheck disable=SC2317
modo_agentico_interactivo() {
    echo "STUB: modo_agentico_interactivo called with CODER_RESUME_SESSION_ID=${CODER_RESUME_SESSION_ID:-}"
    return 0
}
# shellcheck disable=SC2317
get_api_config() {
    echo "STUB: get_api_config called" >&2
    return 0
}
ec=0
out=$(sessions_cli resume "$id" 2>/dev/null) || ec=$?
_assert "resume w/ stub exit 0" "$ec" "0"
_assert_contains "stub saw CODER_RESUME_SESSION_ID set to id" "CODER_RESUME_SESSION_ID=$id" "$out"
unset -f modo_agentico_interactivo get_api_config
unset CODER_RESUME_SESSION_ID

echo
echo "=== T21: list survives a malformed session dir (skipped silently)"
_reset
id=$(sessions_new "anthropic" "claude-sonnet-4-6" "good")
# Plant a corrupted dir alongside.
mkdir -p "$CODER_SESSIONS_DIR/bad-id"
printf 'not-json' >"$CODER_SESSIONS_DIR/bad-id/meta.json"
ec=0
out=$(sessions_cli list 2>/dev/null) || ec=$?
_assert "list w/ corrupt sibling exit 0" "$ec" "0"
_assert_contains "list still shows good id" "$id" "$out"
_assert_not_contains "list skips bad-id" "bad-id" "$out"

echo
echo "=== Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
