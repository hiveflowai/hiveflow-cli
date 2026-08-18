#!/usr/bin/env bash
# Unit tests for the P1.hooks-2 wire-up: dispatch_tool invokes
# `hooks_run tool_pre/tool_post` around each handler when lib/hooks.sh is
# loaded, and behaves like pre-P1.hooks-2 when it isn't.
#
# Run: bash tests/test_hooks_dispatch.sh

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
        _fail "$label (needle='$needle' unexpectedly present)"
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [ -f "$path" ]; then
        _pass "$label"
    else
        _fail "$label (missing: $path)"
    fi
}

# Per-test isolation: dedicated tmpdir; CODER_HOOKS_CONFIG points inside it.
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT INT TERM
export CONFIG_DIR="$TMPDIR_TEST/cfg"
mkdir -p "$CONFIG_DIR"

# Source dispatcher first (without hooks loaded) to test the no-hooks path.
# shellcheck disable=SC1091
source "$REPO_DIR/lib/agent/tool_calling.sh"

# Provide a minimal handler that emits a deterministic payload AND a stderr line,
# so we can assert stream semantics independently.
tool_demo_handler() {
    local input="$1"
    local val
    val=$(echo "$input" | jq -r '.val // "default"')
    if [ "$val" = "boom" ]; then
        echo "demo_err: $val" >&2
        return 7
    fi
    echo "stderr_line" >&2
    echo "demo_out: $val"
    return 0
}
register_tool demo 2>/dev/null || true

echo "=== no-hooks path (lib/hooks.sh not sourced yet) ==="
# Ensure hooks_run is genuinely undefined at this point.
if declare -f hooks_run >/dev/null 2>&1; then
    _fail "pre-source: hooks_run unexpectedly defined"
else
    _pass "pre-source: hooks_run undefined"
fi

# Happy path passes through stdout verbatim, preserves exit code.
out=$(dispatch_tool demo '{"val":"hello"}' 2>/dev/null)
rc=$?
assert_eq "no-hooks rc=0" "0" "$rc"
assert_eq "no-hooks stdout verbatim" "demo_out: hello" "$out"

# Stderr passthrough: caller can 2>&1 to merge.
combined=$(dispatch_tool demo '{"val":"hello"}' 2>&1)
assert_contains "no-hooks stderr passthrough" "stderr_line" "$combined"
assert_contains "no-hooks stderr passthrough keeps stdout" "demo_out: hello" "$combined"

# Failure path: handler rc propagates; stderr surfaced via 2>&1.
combined=$(dispatch_tool demo '{"val":"boom"}' 2>&1)
rc=$?
assert_eq "no-hooks rc=7 propagates" "7" "$rc"
assert_contains "no-hooks failure stderr" "demo_err: boom" "$combined"

# Invalid JSON still returns 2 with the canonical error.
combined=$(dispatch_tool demo 'not json' 2>&1)
rc=$?
assert_eq "no-hooks invalid JSON rc=2" "2" "$rc"
assert_contains "no-hooks invalid JSON err msg" "invalid JSON input" "$combined"

# Unregistered tool returns 1.
combined=$(dispatch_tool nonexistent_tool '{}' 2>&1)
rc=$?
assert_eq "no-hooks not-registered rc=1" "1" "$rc"
assert_contains "no-hooks not-registered err msg" "not registered" "$combined"

echo
echo "=== source lib/hooks.sh and configure pre/post hooks ==="
export CODER_HOOKS_CONFIG="$TMPDIR_TEST/hooks.json"
# shellcheck disable=SC1091
source "$REPO_DIR/lib/agent/hooks.sh"
if declare -f hooks_run >/dev/null 2>&1; then
    _pass "post-source: hooks_run defined"
else
    _fail "post-source: hooks_run defined"
fi

# Write a config with both tool-specific and wildcard hooks. Use a quoted
# heredoc so $CODER_HOOK_* stays literal (must be expanded by the hook, not
# by this test's shell), then sed-substitute the log paths.
PRE_LOG="$TMPDIR_TEST/pre.log"
POST_LOG="$TMPDIR_TEST/post.log"
WILDCARD_LOG="$TMPDIR_TEST/wild.log"
cat >"$CODER_HOOKS_CONFIG" <<'EOF'
{
  "tool_pre": {
    "demo": ["printf '%s|%s|%s\\n' \"$CODER_HOOK_EVENT\" \"$CODER_HOOK_TOOL\" \"$CODER_HOOK_INPUT\" >> '__PRE_LOG__'"],
    "*":    ["printf '%s|%s\\n' \"$CODER_HOOK_EVENT\" \"$CODER_HOOK_TOOL\" >> '__WILD_LOG__'"]
  },
  "tool_post": {
    "demo": ["printf '%s|%s|%s|%s|%s\\n' \"$CODER_HOOK_EVENT\" \"$CODER_HOOK_TOOL\" \"$CODER_HOOK_INPUT\" \"$CODER_HOOK_EXIT\" \"$CODER_HOOK_OUTPUT\" >> '__POST_LOG__'"]
  }
}
EOF
sed -i.bak \
    -e "s|__PRE_LOG__|$PRE_LOG|g" \
    -e "s|__WILD_LOG__|$WILDCARD_LOG|g" \
    -e "s|__POST_LOG__|$POST_LOG|g" \
    "$CODER_HOOKS_CONFIG"
rm -f "$CODER_HOOKS_CONFIG.bak"

echo
echo "=== hooks-active happy path ==="
out=$(dispatch_tool demo '{"val":"hooked"}' 2>/dev/null)
rc=$?
assert_eq "hooks rc=0 preserved" "0" "$rc"
assert_eq "hooks stdout verbatim" "demo_out: hooked" "$out"

# Pre-hook fired exactly once with the right env.
assert_file_exists "pre log created" "$PRE_LOG"
pre_content=$(cat "$PRE_LOG" 2>/dev/null || true)
assert_contains "pre log carries tool_pre event" "tool_pre|demo|" "$pre_content"
assert_contains "pre log carries input json" '"val":"hooked"' "$pre_content"
pre_lines=$(wc -l <"$PRE_LOG" | tr -d ' ')
assert_eq "pre log line count = 1" "1" "$pre_lines"

# Wildcard pre-hook also fired (tool-specific + wildcard order).
assert_file_exists "wildcard log created" "$WILDCARD_LOG"
wild_content=$(cat "$WILDCARD_LOG" 2>/dev/null || true)
assert_contains "wildcard log fired for demo" "tool_pre|demo" "$wild_content"

# Post-hook captured rc + output.
assert_file_exists "post log created" "$POST_LOG"
post_content=$(cat "$POST_LOG" 2>/dev/null || true)
assert_contains "post log event/tool" "tool_post|demo|" "$post_content"
assert_contains "post log carries rc=0" "|0|demo_out: hooked" "$post_content"

# Stderr still passes through to the caller (not swallowed by the buffer).
combined=$(dispatch_tool demo '{"val":"again"}' 2>&1)
assert_contains "stderr passthrough survives buffering" "stderr_line" "$combined"
assert_contains "stdout still re-emitted verbatim" "demo_out: again" "$combined"

echo
echo "=== hooks-active failure path (rc + stderr propagate, post hook still fires) ==="
: >"$POST_LOG"
combined=$(dispatch_tool demo '{"val":"boom"}' 2>&1)
rc=$?
assert_eq "hooks failure rc=7 preserved" "7" "$rc"
assert_contains "hooks failure stderr passthrough" "demo_err: boom" "$combined"
post_content=$(cat "$POST_LOG" 2>/dev/null || true)
assert_contains "post log captures rc=7" "|7|" "$post_content"
assert_contains "post log records boom input" '"val":"boom"' "$post_content"

echo
echo "=== hook failure is non-fatal (handler rc preserved) ==="
# Replace config with a guaranteed-failing post hook for 'demo'.
cat >"$CODER_HOOKS_CONFIG" <<'EOF'
{
  "tool_pre":  {},
  "tool_post": { "demo": ["false"] }
}
EOF
out=$(dispatch_tool demo '{"val":"survives"}' 2>/dev/null)
rc=$?
assert_eq "failing post-hook does not change rc" "0" "$rc"
assert_eq "failing post-hook does not eat stdout" "demo_out: survives" "$out"

# A failing pre-hook is also non-fatal.
cat >"$CODER_HOOKS_CONFIG" <<'EOF'
{
  "tool_pre":  { "demo": ["false"] },
  "tool_post": {}
}
EOF
out=$(dispatch_tool demo '{"val":"survives2"}' 2>/dev/null)
rc=$?
assert_eq "failing pre-hook does not change rc" "0" "$rc"
assert_eq "failing pre-hook does not eat stdout" "demo_out: survives2" "$out"

echo
echo "=== hooks-active: validation errors short-circuit before hooks fire ==="
# A clean log: writing this hook would create the file; if no hooks ran, file is absent.
SENTINEL="$TMPDIR_TEST/sentinel.log"
cat >"$CODER_HOOKS_CONFIG" <<EOF
{
  "tool_pre":  { "*": ["touch '$SENTINEL'"] },
  "tool_post": { "*": ["touch '$SENTINEL'"] }
}
EOF
rm -f "$SENTINEL"
combined=$(dispatch_tool demo 'not json' 2>&1)
rc=$?
assert_eq "invalid JSON still rc=2 with hooks loaded" "2" "$rc"
assert_contains "invalid JSON err preserved" "invalid JSON input" "$combined"
if [ -f "$SENTINEL" ]; then
    _fail "validation error must not fire pre/post hook (sentinel exists)"
else
    _pass "validation error short-circuits hooks"
fi

rm -f "$SENTINEL"
combined=$(dispatch_tool nonexistent_tool '{}' 2>&1)
rc=$?
assert_eq "not-registered still rc=1 with hooks loaded" "1" "$rc"
if [ -f "$SENTINEL" ]; then
    _fail "not-registered must not fire pre/post hook (sentinel exists)"
else
    _pass "not-registered short-circuits hooks"
fi

echo
echo "=== summary ==="
echo "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
