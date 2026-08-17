#!/usr/bin/env bash
# Unit tests for lib/hooks.sh — pre/post hook registry + runner (P1.hooks-1).
#
# Run: bash tests/test_hooks.sh
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
export CODER_HOOKS_CONFIG="$TMPDIR_TEST/hooks.json"
# Ensure CONFIG_DIR fallback (used only if CODER_HOOKS_CONFIG were unset) does
# not leak into user dotfiles if the env override accidentally is unset.
export CONFIG_DIR="$TMPDIR_TEST/cfg"

# Source the module (idempotent under double-source).
# shellcheck disable=SC1091
source "$REPO_DIR/lib/agent/hooks.sh"
# shellcheck disable=SC1091
source "$REPO_DIR/lib/agent/hooks.sh"

echo "=== module wiring ==="
for fn in hooks_config_path hooks_init hooks_list_for hooks_run _hooks_valid_event _hooks_exec_one; do
    if declare -f "$fn" >/dev/null 2>&1; then
        _pass "$fn defined"
    else
        _fail "$fn defined"
    fi
done

echo
echo "=== hooks_config_path ==="
assert_eq "config_path honors env" "$CODER_HOOKS_CONFIG" "$(hooks_config_path)"

# Verify CONFIG_DIR fallback works (unset CODER_HOOKS_CONFIG in a subshell so
# the module's `:` default activates).
fallback_path=$(unset CODER_HOOKS_CONFIG; hooks_config_path)
assert_eq "config_path falls back to CONFIG_DIR" "$CONFIG_DIR/hooks.json" "$fallback_path"

echo
echo "=== hooks_init ==="
if [ -f "$CODER_HOOKS_CONFIG" ]; then _fail "config absent pre-init"; else _pass "config absent pre-init"; fi
hooks_init
assert_exit "init exit 0" "0" "$?"
if [ -f "$CODER_HOOKS_CONFIG" ]; then _pass "config exists post-init"; else _fail "config exists post-init"; fi

initial_content=$(cat "$CODER_HOOKS_CONFIG")
if echo "$initial_content" | jq -e '.tool_pre and .tool_post' >/dev/null 2>&1; then
    _pass "init writes valid schema"
else
    _fail "init writes valid schema (got: $initial_content)"
fi

# Idempotency: second init must not overwrite a hand-edited config.
echo '{"tool_pre":{"bash_exec":["custom"]},"tool_post":{}}' >"$CODER_HOOKS_CONFIG"
hooks_init
assert_exit "init idempotent exit 0" "0" "$?"
post_content=$(cat "$CODER_HOOKS_CONFIG")
assert_contains "init does not clobber existing config" "custom" "$post_content"

echo
echo "=== hooks_list_for input validation ==="
out=$(hooks_list_for foo 2>/dev/null); rc=$?
assert_exit "invalid event -> rc 2" "2" "$rc"
err=$(hooks_list_for foo 2>&1 >/dev/null)
assert_contains "invalid event stderr" "invalid event" "$err"

out=$(hooks_list_for "" 2>/dev/null); rc=$?
assert_exit "empty event -> rc 2" "2" "$rc"

echo
echo "=== hooks_list_for empty config ==="
# Remove the config to test missing-file path.
rm -f "$CODER_HOOKS_CONFIG"
out=$(hooks_list_for tool_pre bash_exec); rc=$?
assert_exit "missing file -> rc 0" "0" "$rc"
assert_eq "missing file -> empty output" "" "$out"

# Empty file path.
: >"$CODER_HOOKS_CONFIG"
out=$(hooks_list_for tool_pre bash_exec); rc=$?
assert_exit "empty file -> rc 0" "0" "$rc"
assert_eq "empty file -> empty output" "" "$out"

# Malformed JSON path.
echo 'not json {' >"$CODER_HOOKS_CONFIG"
out=$(hooks_list_for tool_pre bash_exec 2>/dev/null); rc=$?
assert_exit "malformed json -> rc 0" "0" "$rc"
assert_eq "malformed json -> empty output" "" "$out"

# Reset to canonical schema for the rest of the suite.
cat >"$CODER_HOOKS_CONFIG" <<'EOF'
{
  "tool_pre": {
    "bash_exec": ["echo PRE_BASH_SPECIFIC", "echo PRE_BASH_SECOND"],
    "*":          ["echo PRE_WILDCARD"]
  },
  "tool_post": {
    "write_file": ["echo POST_WRITE"],
    "*":           ["echo POST_WILDCARD"]
  }
}
EOF

echo
echo "=== hooks_list_for with hooks ==="
out=$(hooks_list_for tool_pre bash_exec)
# Tool-specific first (2 entries, order preserved), then wildcard.
expected_pre_bash=$'echo PRE_BASH_SPECIFIC\necho PRE_BASH_SECOND\necho PRE_WILDCARD'
assert_eq "tool-specific + wildcard, order preserved" "$expected_pre_bash" "$out"

out=$(hooks_list_for tool_pre other_tool)
assert_eq "non-matching tool falls back to wildcard only" "echo PRE_WILDCARD" "$out"

out=$(hooks_list_for tool_post write_file)
expected_post_write=$'echo POST_WRITE\necho POST_WILDCARD'
assert_eq "post: tool-specific + wildcard" "$expected_post_write" "$out"

out=$(hooks_list_for tool_post other_tool)
assert_eq "post: non-matching -> wildcard" "echo POST_WILDCARD" "$out"

# tool omitted: only wildcards for the event.
out=$(hooks_list_for tool_pre)
assert_eq "tool omitted -> wildcard only" "echo PRE_WILDCARD" "$out"

out=$(hooks_list_for tool_post)
assert_eq "tool omitted post -> wildcard only" "echo POST_WILDCARD" "$out"

# Event with no entries at all (config has tool_pre + tool_post; remove one).
cat >"$CODER_HOOKS_CONFIG" <<'EOF'
{"tool_pre":{},"tool_post":{}}
EOF
out=$(hooks_list_for tool_pre bash_exec)
assert_eq "empty event maps -> empty output" "" "$out"

# Special chars in command: pipes, quotes, $vars preserved verbatim.
cat >"$CODER_HOOKS_CONFIG" <<'EOF'
{
  "tool_pre": {
    "tricky": ["echo '\"hi\"' | tr 'a-z' 'A-Z' > /tmp/__hooks_test_special"]
  },
  "tool_post": {}
}
EOF
out=$(hooks_list_for tool_pre tricky)
assert_contains "preserves quotes/pipes verbatim" "tr 'a-z' 'A-Z'" "$out"
assert_contains "preserves redirect verbatim" "> /tmp/__hooks_test_special" "$out"

echo
echo "=== hooks_run input validation ==="
rc=0; hooks_run foo bar 2>/dev/null || rc=$?
assert_exit "invalid event -> rc 2" "2" "$rc"

rc=0; hooks_run tool_pre "" 2>/dev/null || rc=$?
assert_exit "empty tool name -> rc 2" "2" "$rc"

err=$(hooks_run "" bash_exec 2>&1 >/dev/null); rc=$?
assert_contains "stderr mentions invalid event" "invalid event" "$err"

# No hooks registered for event/tool: rc 0, silent.
cat >"$CODER_HOOKS_CONFIG" <<'EOF'
{"tool_pre":{},"tool_post":{}}
EOF
out=$(hooks_run tool_pre bash_exec '{}' 2>&1); rc=$?
assert_exit "no hooks registered -> rc 0" "0" "$rc"
assert_eq "no hooks registered -> silent" "" "$out"

echo
echo "=== hooks_run executes hooks (env vars) ==="
LOG="$TMPDIR_TEST/hookslog"
rm -f "$LOG"
# Hook records all env vars on one line (echo adds the trailing newline).
# Use `echo` not `printf '...\n'`: a literal `\n` inside the JSON string
# becomes a real newline after jq -r, splitting the cmd across two lines.
cat >"$CODER_HOOKS_CONFIG" <<EOF
{
  "tool_pre": {
    "read_file": ["echo \"pre|\$CODER_HOOK_EVENT|\$CODER_HOOK_TOOL|\$CODER_HOOK_INPUT|\$CODER_HOOK_EXIT|\$CODER_HOOK_OUTPUT\" >> $LOG"]
  },
  "tool_post": {
    "read_file": ["echo \"post|\$CODER_HOOK_EVENT|\$CODER_HOOK_TOOL|\$CODER_HOOK_INPUT|\$CODER_HOOK_EXIT|\$CODER_HOOK_OUTPUT\" >> $LOG"]
  }
}
EOF

hooks_run tool_pre read_file '{"path":"a.txt"}'; rc=$?
assert_exit "tool_pre run -> rc 0" "0" "$rc"
if [ -s "$LOG" ]; then _pass "tool_pre fired (log non-empty)"; else _fail "tool_pre fired (log non-empty)"; fi
pre_line=$(grep '^pre|' "$LOG" | head -1)
assert_contains "pre EVENT exported" "pre|tool_pre|" "$pre_line"
assert_contains "pre TOOL exported" "|read_file|" "$pre_line"
assert_contains "pre INPUT exported" '{"path":"a.txt"}' "$pre_line"
# Trailing | | means EXIT and OUTPUT are empty for pre.
assert_contains "pre EXIT empty for tool_pre" '|read_file|{"path":"a.txt"}||' "$pre_line"

rm -f "$LOG"
hooks_run tool_post read_file '{"path":"a.txt"}' 0 'file contents'; rc=$?
assert_exit "tool_post run -> rc 0" "0" "$rc"
post_line=$(grep '^post|' "$LOG" | head -1)
assert_contains "post EVENT exported" "post|tool_post|" "$post_line"
assert_contains "post TOOL exported" "|read_file|" "$post_line"
assert_contains "post INPUT exported" '{"path":"a.txt"}' "$post_line"
assert_contains "post EXIT exported" "|0|file contents" "$post_line"
assert_contains "post OUTPUT exported" "|file contents" "$post_line"

echo
echo "=== hooks_run: tool-specific + wildcard fire in order ==="
LOG="$TMPDIR_TEST/order"
rm -f "$LOG"
cat >"$CODER_HOOKS_CONFIG" <<EOF
{
  "tool_pre": {
    "bash_exec": ["echo SPECIFIC1 >> $LOG", "echo SPECIFIC2 >> $LOG"],
    "*":          ["echo WILDCARD >> $LOG"]
  },
  "tool_post": {}
}
EOF
hooks_run tool_pre bash_exec '{}'
order=$(tr '\n' ',' < "$LOG")
assert_eq "tool-specific 1, 2, then wildcard" "SPECIFIC1,SPECIFIC2,WILDCARD," "$order"

echo
echo "=== hooks_run: hook failure is non-fatal ==="
LOG="$TMPDIR_TEST/failures"
rm -f "$LOG"
cat >"$CODER_HOOKS_CONFIG" <<EOF
{
  "tool_pre": {
    "bash_exec": ["echo before-fail >> $LOG; exit 7"],
    "*":          ["echo wildcard-after-fail >> $LOG"]
  },
  "tool_post": {}
}
EOF
err=$(hooks_run tool_pre bash_exec '{}' 2>&1); rc=$?
assert_exit "failing hook -> caller rc 0" "0" "$rc"
assert_contains "stderr reports failure with rc" "rc=7" "$err"
assert_contains "stderr mentions event" "tool_pre" "$err"
assert_contains "stderr mentions tool" "bash_exec" "$err"
assert_contains "stderr embeds captured output" "before-fail" "$err"
# Wildcard must still fire after the prior hook failed.
if grep -q '^wildcard-after-fail$' "$LOG"; then
    _pass "subsequent hook still fires after failure"
else
    _fail "subsequent hook still fires after failure"
fi

echo
echo "=== hooks_run: successful hooks stay silent ==="
LOG="$TMPDIR_TEST/silent"
rm -f "$LOG"
cat >"$CODER_HOOKS_CONFIG" <<EOF
{
  "tool_pre": {
    "bash_exec": ["echo to-stdout-then-discard; echo to-stderr >&2; echo to-disk >> $LOG"]
  },
  "tool_post": {}
}
EOF
out=$(hooks_run tool_pre bash_exec '{}' 2>&1)
assert_eq "successful hook produces no stdout/stderr on caller" "" "$out"
if grep -q '^to-disk$' "$LOG"; then
    _pass "successful hook side-effect persisted"
else
    _fail "successful hook side-effect persisted"
fi

echo
echo "=== hooks_run: input/output truncation ==="
LOG="$TMPDIR_TEST/trunc"
rm -f "$LOG"
cat >"$CODER_HOOKS_CONFIG" <<EOF
{
  "tool_pre": {
    "x": ["printf '%s' \"\$CODER_HOOK_INPUT\" > $LOG.input"]
  },
  "tool_post": {
    "x": ["printf '%s' \"\$CODER_HOOK_OUTPUT\" > $LOG.output"]
  }
}
EOF

# Build a 100-byte payload.
big_input=$(printf 'A%.0s' $(seq 1 100))
big_output=$(printf 'B%.0s' $(seq 1 100))

# With limit 50, hook receives exactly 50 bytes.
CODER_HOOK_INPUT_MAX=50 hooks_run tool_pre x "$big_input"
got=$(wc -c < "$LOG.input" | tr -d ' ')
assert_eq "input truncated to CODER_HOOK_INPUT_MAX" "50" "$got"

CODER_HOOK_OUTPUT_MAX=50 hooks_run tool_post x '{}' 0 "$big_output"
got=$(wc -c < "$LOG.output" | tr -d ' ')
assert_eq "output truncated to CODER_HOOK_OUTPUT_MAX" "50" "$got"

# Under limit: byte-exact preservation.
small_input='hello'
hooks_run tool_pre x "$small_input"
got=$(cat "$LOG.input")
assert_eq "small input preserved verbatim" "$small_input" "$got"

echo
echo "=== hooks_run: multiple events isolated ==="
LOG="$TMPDIR_TEST/iso"
rm -f "$LOG"
cat >"$CODER_HOOKS_CONFIG" <<EOF
{
  "tool_pre": {
    "y": ["echo PRE_Y >> $LOG"]
  },
  "tool_post": {
    "y": ["echo POST_Y >> $LOG"]
  }
}
EOF
# tool_pre must not fire post hooks and vice versa.
hooks_run tool_pre y '{}'
sequence=$(cat "$LOG")
assert_eq "pre only fires pre" "PRE_Y" "$sequence"
hooks_run tool_post y '{}' 0 ''
sequence=$(tr '\n' ',' < "$LOG")
assert_eq "post run appends only POST_Y" "PRE_Y,POST_Y," "$sequence"

echo
echo "=== summary ==="
echo "  pass: $PASS"
echo "  fail: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
