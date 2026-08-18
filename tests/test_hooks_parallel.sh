#!/usr/bin/env bash
# tests/test_hooks_parallel.sh
#
# P2.parallel-5: verifica que tool_pre/tool_post hooks se invocan
# correctamente cuando `_dispatch_tools_parallel` corre en paralelo.
# Contrato:
#   - Sequential (max_workers <= 1): orden histórico de pre/post intercalados
#     por job. dispatch_tool fire los hooks inline (legacy path).
#   - Parallel (max_workers > 1): pre hooks corren serialmente ANTES del
#     spawn paralelo en orden de input; post hooks corren serialmente
#     DESPUÉS del wait en orden de input. Garantiza:
#       (a) sin concurrent appends al hooks log
#       (b) orden determinista de eventos para observadores
#       (c) handler rc/output exactos llegan al post hook de cada job
#       (d) skip flag interno no leak fuera del subshell
#
# Sin API keys. Sourcea tool_calling.sh + hooks.sh, registra un handler
# stub que dispara hooks contra un log temporal.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT" || exit 1

PASS=0
FAIL=0
note() { printf '%s\n' "$1"; }
_pass() { note "  PASS $1"; PASS=$((PASS + 1)); }
_fail() { note "  FAIL $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local label="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        _pass "$label"
    else
        _fail "$label (want='$want' got='$got')"
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

# Per-test isolation: dedicated tmpdir + hooks config.
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT INT TERM
export CONFIG_DIR="$TMPDIR_TEST/cfg"
mkdir -p "$CONFIG_DIR"

# shellcheck source=../lib/tool_calling.sh disable=SC1091
source "$REPO_ROOT/lib/agent/tool_calling.sh"
# shellcheck source=../lib/hooks.sh disable=SC1091
source "$REPO_ROOT/lib/agent/hooks.sh"

export CODER_HOOKS_CONFIG="$TMPDIR_TEST/hooks.json"

US=$'\x1f'

# Handler stub: emits a deterministic line; rc/output driven by input fields.
# shellcheck disable=SC2317
tool_demo_handler() {
    local input="$1"
    local val rc nap
    val=$(printf '%s' "$input" | jq -r '.val // "default"')
    rc=$(printf '%s' "$input" | jq -r '.rc // 0')
    # Small sleep to encourage parallel interleaving when run with N workers.
    nap=$(printf '%s' "$input" | jq -r '.sleep // "0"')
    if [ "$nap" != "0" ]; then
        sleep "$nap"
    fi
    printf 'out-%s' "$val"
    return "$rc"
}
register_tool demo 2>/dev/null || true

# Helper: write a hooks config with a pre cmd and a post cmd for tool "demo".
# Uses jq --arg so backslash escapes in the cmd string survive cleanly.
_write_hooks_config() {
    local pre_cmd="$1" post_cmd="$2"
    hooks_init >/dev/null 2>&1 || true
    jq -n \
        --arg pre  "$pre_cmd" \
        --arg post "$post_cmd" \
        '{tool_pre: {demo: [$pre]}, tool_post: {demo: [$post]}}' \
        > "$CODER_HOOKS_CONFIG"
}

# ---------------------------------------------------------------------------
note "## Phase A — Parallel path: pre/post fire once per job, in input order"
# ---------------------------------------------------------------------------
PRE_LOG="$TMPDIR_TEST/pre_A.log"
POST_LOG="$TMPDIR_TEST/post_A.log"
: > "$PRE_LOG"
: > "$POST_LOG"

_write_hooks_config \
    "printf '%s\\n' \"\$CODER_HOOK_INPUT\" >> '$PRE_LOG'" \
    "printf 'rc=%s out=%s\\n' \"\$CODER_HOOK_EXIT\" \"\$CODER_HOOK_OUTPUT\" >> '$POST_LOG'"

# 4 jobs with mixed sleep durations to force interleaved handler completion.
jobs=$(printf 'A%sdemo%s{"val":"a","sleep":"0.20"}\nB%sdemo%s{"val":"b","sleep":"0.05"}\nC%sdemo%s{"val":"c","sleep":"0.15"}\nD%sdemo%s{"val":"d","sleep":"0.01"}' \
    "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US")

out=$(printf '%s\n' "$jobs" | _dispatch_tools_parallel 4)
rc=$?
assert_eq "parallel rc=0" "0" "$rc"

# 4 result lines (one per job, in input order).
line_count=$(printf '%s' "$out" | grep -c .)
assert_eq "4 output lines emitted" "4" "$line_count"

# Pre log: 4 lines, in input order (jobs a,b,c,d by val).
pre_lines=$(grep -c . "$PRE_LOG" 2>/dev/null || echo 0)
assert_eq "pre log: 4 lines" "4" "$pre_lines"
pre_seq=$(sed -E 's/.*"val":"([a-z])".*/\1/' "$PRE_LOG" | tr -d '\n')
assert_eq "pre log: input order a,b,c,d" "abcd" "$pre_seq"

# Post log: 4 lines, in input order.
post_lines=$(grep -c . "$POST_LOG" 2>/dev/null || echo 0)
assert_eq "post log: 4 lines" "4" "$post_lines"
post_seq=$(sed -E 's/.*out=out-([a-z]).*/\1/' "$POST_LOG" | tr -d '\n')
assert_eq "post log: input order a,b,c,d" "abcd" "$post_seq"

# Post log: each line carries rc=0 (no failures).
zero_rc_count=$(grep -c '^rc=0 ' "$POST_LOG")
assert_eq "post log: all rc=0" "4" "$zero_rc_count"

# ---------------------------------------------------------------------------
note "## Phase B — Parallel path: all pre events precede all post events"
# ---------------------------------------------------------------------------
COMBINED_LOG="$TMPDIR_TEST/combined.log"
: > "$COMBINED_LOG"

_write_hooks_config \
    "printf 'PRE %s\\n' \"\$CODER_HOOK_INPUT\" >> '$COMBINED_LOG'" \
    "printf 'POST rc=%s\\n' \"\$CODER_HOOK_EXIT\" >> '$COMBINED_LOG'"

jobs=$(printf 'X1%sdemo%s{"val":"x1","sleep":"0.10"}\nX2%sdemo%s{"val":"x2","sleep":"0.05"}\nX3%sdemo%s{"val":"x3","sleep":"0.02"}' \
    "$US" "$US" "$US" "$US" "$US" "$US")
out=$(printf '%s\n' "$jobs" | _dispatch_tools_parallel 3)
rc=$?
assert_eq "phase B rc=0" "0" "$rc"

# Combined log: lines 1-3 must all be PRE, lines 4-6 must all be POST.
line1=$(sed -n '1p' "$COMBINED_LOG")
line2=$(sed -n '2p' "$COMBINED_LOG")
line3=$(sed -n '3p' "$COMBINED_LOG")
line4=$(sed -n '4p' "$COMBINED_LOG")
line5=$(sed -n '5p' "$COMBINED_LOG")
line6=$(sed -n '6p' "$COMBINED_LOG")
assert_contains "line1 is PRE" "PRE " "$line1"
assert_contains "line2 is PRE" "PRE " "$line2"
assert_contains "line3 is PRE" "PRE " "$line3"
assert_contains "line4 is POST" "POST " "$line4"
assert_contains "line5 is POST" "POST " "$line5"
assert_contains "line6 is POST" "POST " "$line6"

# Total line count exactly 6 — no concurrent appends produced extra/torn lines.
total_lines=$(grep -c . "$COMBINED_LOG")
assert_eq "combined log: 6 whole lines (no torn writes)" "6" "$total_lines"

# Pre input order: x1,x2,x3.
pre_only=$(grep '^PRE ' "$COMBINED_LOG" | sed -E 's/.*"val":"(x[0-9])".*/\1/' | tr '\n' ',')
assert_eq "pre order x1,x2,x3" "x1,x2,x3," "$pre_only"

# ---------------------------------------------------------------------------
note "## Phase C — Parallel path: post hook receives correct per-job rc"
# ---------------------------------------------------------------------------
POST_RC_LOG="$TMPDIR_TEST/post_rc.log"
: > "$POST_RC_LOG"

# Empty pre, only post.
hooks_init >/dev/null 2>&1 || true
jq -n \
    --arg post "printf 'rc=%s out=%s\\n' \"\$CODER_HOOK_EXIT\" \"\$CODER_HOOK_OUTPUT\" >> '$POST_RC_LOG'" \
    '{tool_pre: {}, tool_post: {demo: [$post]}}' \
    > "$CODER_HOOKS_CONFIG"

# Mix: ok, fail rc=7, ok, fail rc=3.
jobs=$(printf 'J1%sdemo%s{"val":"j1","rc":0}\nJ2%sdemo%s{"val":"j2","rc":7}\nJ3%sdemo%s{"val":"j3","rc":0}\nJ4%sdemo%s{"val":"j4","rc":3}' \
    "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US")
out=$(printf '%s\n' "$jobs" | _dispatch_tools_parallel 4)
rc=$?
assert_eq "phase C rc=0 (helper)" "0" "$rc"

# Post log: 4 lines in input order with correct rc.
post_rc_seq=$(awk '{print $1}' "$POST_RC_LOG" | tr '\n' '|')
assert_eq "post rc sequence rc=0|rc=7|rc=0|rc=3" "rc=0|rc=7|rc=0|rc=3|" "$post_rc_seq"

# Outputs in post log match val per job.
out_j1=$(sed -n '1p' "$POST_RC_LOG"); assert_contains "post J1 out=out-j1" "out=out-j1" "$out_j1"
out_j2=$(sed -n '2p' "$POST_RC_LOG"); assert_contains "post J2 out=out-j2" "out=out-j2" "$out_j2"
out_j3=$(sed -n '3p' "$POST_RC_LOG"); assert_contains "post J3 out=out-j3" "out=out-j3" "$out_j3"
out_j4=$(sed -n '4p' "$POST_RC_LOG"); assert_contains "post J4 out=out-j4" "out=out-j4" "$out_j4"

# ---------------------------------------------------------------------------
note "## Phase D — Sequential path: legacy interleaved order preserved"
# ---------------------------------------------------------------------------
SEQ_LOG="$TMPDIR_TEST/seq.log"
: > "$SEQ_LOG"

_write_hooks_config \
    "printf 'PRE %s\\n' \"\$CODER_HOOK_INPUT\" >> '$SEQ_LOG'" \
    "printf 'POST rc=%s\\n' \"\$CODER_HOOK_EXIT\" >> '$SEQ_LOG'"

jobs=$(printf 'S1%sdemo%s{"val":"s1"}\nS2%sdemo%s{"val":"s2"}\nS3%sdemo%s{"val":"s3"}' \
    "$US" "$US" "$US" "$US" "$US" "$US")
out=$(printf '%s\n' "$jobs" | _dispatch_tools_parallel 1)
rc=$?
assert_eq "phase D rc=0" "0" "$rc"

# Sequential path: dispatch_tool fires hooks inline per-job, so order is
# PRE/POST/PRE/POST/PRE/POST.
seq_lines=$(grep -c . "$SEQ_LOG")
assert_eq "seq log: 6 lines total" "6" "$seq_lines"
s1=$(sed -n '1p' "$SEQ_LOG"); assert_contains "seq L1 is PRE s1"  "PRE " "$s1"; assert_contains "seq L1 carries s1" "s1" "$s1"
s2=$(sed -n '2p' "$SEQ_LOG"); assert_contains "seq L2 is POST"    "POST " "$s2"
s3=$(sed -n '3p' "$SEQ_LOG"); assert_contains "seq L3 is PRE s2"  "PRE " "$s3"; assert_contains "seq L3 carries s2" "s2" "$s3"
s4=$(sed -n '4p' "$SEQ_LOG"); assert_contains "seq L4 is POST"    "POST " "$s4"
s5=$(sed -n '5p' "$SEQ_LOG"); assert_contains "seq L5 is PRE s3"  "PRE " "$s5"; assert_contains "seq L5 carries s3" "s3" "$s5"
s6=$(sed -n '6p' "$SEQ_LOG"); assert_contains "seq L6 is POST"    "POST " "$s6"

# ---------------------------------------------------------------------------
note "## Phase E — Skip-hooks env flag does not leak to parent shell"
# ---------------------------------------------------------------------------
# After parallel dispatch, `_CODER_DISPATCH_SKIP_HOOKS` must be unset/empty
# in the parent shell. We rely on the var being a function-scope (not exported)
# inside the `()` subshell.
PARENT_LOG="$TMPDIR_TEST/parent.log"
: > "$PARENT_LOG"

_write_hooks_config \
    "printf 'PRE\\n'  >> '$PARENT_LOG'" \
    "printf 'POST\\n' >> '$PARENT_LOG'"

# Run a parallel batch.
jobs=$(printf 'P1%sdemo%s{"val":"p1"}\nP2%sdemo%s{"val":"p2"}' "$US" "$US" "$US" "$US")
out=$(printf '%s\n' "$jobs" | _dispatch_tools_parallel 2)
phase_e_rc=$?
assert_eq "phase E rc=0" "0" "$phase_e_rc"

# Verify the skip flag is NOT set in the parent.
if [ -n "${_CODER_DISPATCH_SKIP_HOOKS:-}" ]; then
    _fail "skip flag leaked to parent shell (val='${_CODER_DISPATCH_SKIP_HOOKS}')"
else
    _pass "skip flag NOT leaked to parent shell"
fi

# Now invoke dispatch_tool directly — hooks MUST fire (skip flag was not leaked).
: > "$PARENT_LOG"
dispatch_tool demo '{"val":"direct"}' >/dev/null 2>&1
direct_rc=$?
assert_eq "direct dispatch rc=0" "0" "$direct_rc"
direct_lines=$(grep -c . "$PARENT_LOG")
assert_eq "direct dispatch fired pre+post (2 lines)" "2" "$direct_lines"

# ---------------------------------------------------------------------------
note "## Phase F — Pre-hook failure does not block dispatch (parallel)"
# ---------------------------------------------------------------------------
# Failing pre hook should NOT prevent the handler from running. This mirrors
# the v1 observe-only contract (lib/hooks.sh).
FAIL_LOG="$TMPDIR_TEST/fail.log"
: > "$FAIL_LOG"

hooks_init >/dev/null 2>&1 || true
jq -n \
    --arg post "printf 'POST rc=%s\\n' \"\$CODER_HOOK_EXIT\" >> '$FAIL_LOG'" \
    '{tool_pre: {demo: ["false"]}, tool_post: {demo: [$post]}}' \
    > "$CODER_HOOKS_CONFIG"

jobs=$(printf 'F1%sdemo%s{"val":"f1"}\nF2%sdemo%s{"val":"f2"}' "$US" "$US" "$US" "$US")
out=$(printf '%s\n' "$jobs" | _dispatch_tools_parallel 2 2>/dev/null)
rc=$?
assert_eq "phase F rc=0 (hook failure non-fatal)" "0" "$rc"

# Both handlers ran (post hook recorded each).
post_count=$(grep -c . "$FAIL_LOG")
assert_eq "phase F: post fired for both jobs" "2" "$post_count"

# Result lines contain the handler output ("out-f1" / "out-f2" base64-decoded).
b64_f1=$(printf '%s' "$out" | sed -n '1p' | awk -F"$US" '{print $3}')
b64_f2=$(printf '%s' "$out" | sed -n '2p' | awk -F"$US" '{print $3}')
dec_f1=$(printf '%s' "$b64_f1" | base64 -d 2>/dev/null)
dec_f2=$(printf '%s' "$b64_f2" | base64 -d 2>/dev/null)
assert_eq "phase F: F1 output preserved" "out-f1" "$dec_f1"
assert_eq "phase F: F2 output preserved" "out-f2" "$dec_f2"

# ---------------------------------------------------------------------------
note "## Phase G — Large N parallel: log integrity (no torn writes)"
# ---------------------------------------------------------------------------
# Stress test: 20 jobs at cap=4. Every pre+post must land as a whole line.
BIG_LOG="$TMPDIR_TEST/big.log"
: > "$BIG_LOG"

_write_hooks_config \
    "printf 'PRE %s\\n' \"\$CODER_HOOK_INPUT\" >> '$BIG_LOG'" \
    "printf 'POST %s rc=%s\\n' \"\$CODER_HOOK_INPUT\" \"\$CODER_HOOK_EXIT\" >> '$BIG_LOG'"

big_jobs=""
for k in $(seq 1 20); do
    if [ -n "$big_jobs" ]; then big_jobs+=$'\n'; fi
    big_jobs+="G${k}${US}demo${US}{\"val\":\"g${k}\"}"
done

out=$(printf '%s\n' "$big_jobs" | _dispatch_tools_parallel 4)
rc=$?
assert_eq "phase G rc=0" "0" "$rc"

# 20 PRE + 20 POST = 40 lines exactly.
big_lines=$(grep -c . "$BIG_LOG")
assert_eq "phase G: 40 log lines" "40" "$big_lines"

# First 20 are PRE, last 20 are POST.
pre_first_20=$(head -20 "$BIG_LOG" | grep -c '^PRE ')
post_last_20=$(tail -20 "$BIG_LOG" | grep -c '^POST ')
assert_eq "phase G: first 20 are PRE" "20" "$pre_first_20"
assert_eq "phase G: last 20 are POST" "20" "$post_last_20"

# PRE sequence: g1,g2,...,g20 (input order).
pre_seq=$(head -20 "$BIG_LOG" | sed -E 's/.*"val":"(g[0-9]+)".*/\1/' | tr '\n' ',')
expected_pre=""
for k in $(seq 1 20); do expected_pre+="g${k},"; done
assert_eq "phase G: PRE input order preserved" "$expected_pre" "$pre_seq"

# POST sequence: g1,g2,...,g20 (input order).
post_seq=$(tail -20 "$BIG_LOG" | sed -E 's/POST \{"val":"(g[0-9]+)"\} .*/\1/' | tr '\n' ',')
assert_eq "phase G: POST input order preserved" "$expected_pre" "$post_seq"

# ---------------------------------------------------------------------------
note ""
note "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 1
