#!/bin/bash
# tests/test_parallel_dispatch.sh
# P2.parallel-1: `_dispatch_tools_parallel` helper bash-nativo.
#
# Sin API keys. Sourcea lib/tool_calling.sh, define handlers stub locales para
# ejercitar el dispatcher en isolation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT" || exit 1

# shellcheck source=../lib/tool_calling.sh disable=SC1091
source "$REPO_ROOT/lib/agent/tool_calling.sh"

pass=0
fail=0
note() { printf '%s\n' "$1"; }
assert_eq() {
    local got="$1" want="$2" label="$3"
    if [ "$got" = "$want" ]; then
        note "  PASS $label"
        pass=$((pass + 1))
    else
        note "  FAIL $label"
        note "    got:  '$got'"
        note "    want: '$want'"
        fail=$((fail + 1))
    fi
}
assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        note "  PASS $label"
        pass=$((pass + 1))
    else
        note "  FAIL $label"
        note "    haystack: '$haystack'"
        note "    needle:   '$needle'"
        fail=$((fail + 1))
    fi
}
assert_le() {
    local got="$1" upper="$2" label="$3"
    if [ "$got" -le "$upper" ]; then
        note "  PASS $label (got=$got <= $upper)"
        pass=$((pass + 1))
    else
        note "  FAIL $label (got=$got > $upper)"
        fail=$((fail + 1))
    fi
}

US=$'\x1f'

# ---------------------------------------------------------------------------
# Handlers stub
# ---------------------------------------------------------------------------

# shellcheck disable=SC2317
tool_echo_handler() {
    local input="$1"
    local text
    text=$(printf '%s' "$input" | jq -r '.text // ""')
    printf '%s' "$text"
    return 0
}

# shellcheck disable=SC2317
tool_fail_handler() {
    local input="$1"
    local rc msg
    rc=$(printf '%s' "$input" | jq -r '.rc // 7')
    msg=$(printf '%s' "$input" | jq -r '.msg // "boom"')
    echo "$msg" >&2
    return "$rc"
}

# shellcheck disable=SC2317
tool_multiline_handler() {
    local input="$1"
    local n pre i
    n=$(printf '%s' "$input" | jq -r '.n // 3')
    pre=$(printf '%s' "$input" | jq -r '.pre // "L"')
    i=0
    while [ "$i" -lt "$n" ]; do
        echo "${pre}${i}"
        i=$((i + 1))
    done
    return 0
}

# shellcheck disable=SC2317
tool_sleep_handler() {
    local input="$1"
    local secs tag
    secs=$(printf '%s' "$input" | jq -r '.secs // 0.1')
    tag=$(printf '%s' "$input" | jq -r '.tag // "T"')
    sleep "$secs" 2>/dev/null || true
    printf '%s' "$tag"
    return 0
}

# shellcheck disable=SC2317
tool_special_handler() {
    local input="$1"
    local mode
    mode=$(printf '%s' "$input" | jq -r '.mode // "default"')
    case "$mode" in
        empty) ;;
        quotes) printf 'has "double" and '\''single'\'' quotes' ;;
        backslash) printf 'line1\\line2' ;;
        utf8) printf 'ñoño 漢字 emoji 🚀' ;;
        *) printf 'default' ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Parsers for output stream.
# Each line: <id><US><rc><US><output_b64>
# ---------------------------------------------------------------------------
line_id()   { local l="$1"; printf '%s' "$l" | awk -F$'\x1f' '{print $1}'; }
line_rc()   { local l="$1"; printf '%s' "$l" | awk -F$'\x1f' '{print $2}'; }
line_text() {
    local l="$1"
    local b64
    b64=$(printf '%s' "$l" | awk -F$'\x1f' '{print $3}')
    printf '%s' "$b64" | base64 -d 2>/dev/null || true
}

# make_jobs id1 name1 input1 id2 name2 input2 ...
# Emite las 3-tuplas como líneas con US separator y trailing \n. Cada job toma
# 3 args posicionales — la función agrupa de 3 en 3.
make_jobs() {
    local out=""
    while [ "$#" -gt 0 ]; do
        if [ "$#" -lt 3 ]; then
            echo "make_jobs: argc must be multiple of 3 (got remainder $#)" >&2
            return 1
        fi
        out+="$1${US}$2${US}$3"$'\n'
        shift 3
    done
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
note "## Module wiring"
# ---------------------------------------------------------------------------

if declare -f _dispatch_tools_parallel >/dev/null; then
    assert_eq "yes" "yes" "_dispatch_tools_parallel defined"
else
    assert_eq "no" "yes" "_dispatch_tools_parallel defined"
fi

# ---------------------------------------------------------------------------
note "## max_workers validation"
# ---------------------------------------------------------------------------

ec=0
echo "" | _dispatch_tools_parallel "abc" >/dev/null 2>&1 || ec=$?
assert_eq "$ec" "2" "non-numeric max_workers → rc 2"

ec=0
make_jobs "a" "echo" '{"text":"x"}' | _dispatch_tools_parallel "-1" >/dev/null 2>&1 || ec=$?
assert_eq "$ec" "2" "negative max_workers → rc 2"

# Empty string max_workers → ${1:-1} substitutes "1" → valid sequential path.
ec=0
make_jobs "a" "echo" '{"text":"hi"}' | _dispatch_tools_parallel "" >/dev/null 2>&1 || ec=$?
assert_eq "$ec" "0" "empty max_workers normalized to 1 → rc 0"

# ---------------------------------------------------------------------------
note "## Empty stdin → rc 2"
# ---------------------------------------------------------------------------

ec=0
err=$(printf '' | _dispatch_tools_parallel 1 2>&1 1>/dev/null) || ec=$?
assert_eq "$ec" "2" "empty stdin sequential → rc 2"
assert_contains "$err" "no jobs received" "empty stdin sequential → stderr message"

ec=0
printf '' | _dispatch_tools_parallel 4 >/dev/null 2>&1 || ec=$?
assert_eq "$ec" "2" "empty stdin parallel → rc 2"

# ---------------------------------------------------------------------------
note "## Sequential path (max_workers=1)"
# ---------------------------------------------------------------------------

jobs=$(make_jobs "id_a" "echo" '{"text":"hello"}')
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 1)
rc=$?
assert_eq "$rc" "0" "sequential 1 job → rc 0"

lines=$(printf '%s\n' "$out" | grep -c .)
assert_eq "$lines" "1" "sequential 1 job → 1 output line"

assert_eq "$(line_id "$out")"   "id_a"  "sequential id preserved"
assert_eq "$(line_rc "$out")"   "0"     "sequential rc preserved"
assert_eq "$(line_text "$out")" "hello" "sequential output preserved"

# Multi-job sequential preserves order.
jobs=$(make_jobs \
    "id_1" "echo" '{"text":"alpha"}' \
    "id_2" "echo" '{"text":"beta"}' \
    "id_3" "echo" '{"text":"gamma"}')
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 1)
rc=$?
assert_eq "$rc" "0" "sequential 3 jobs → rc 0"

expected_ids=("id_1" "id_2" "id_3")
expected_texts=("alpha" "beta" "gamma")
i=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    assert_eq "$(line_id   "$line")" "${expected_ids[$i]}"   "sequential order id[$i]"
    assert_eq "$(line_text "$line")" "${expected_texts[$i]}" "sequential order text[$i]"
    assert_eq "$(line_rc   "$line")" "0"                      "sequential order rc[$i]"
    i=$((i + 1))
done <<<"$out"
assert_eq "$i" "3" "sequential 3 jobs produced 3 output lines"

# ---------------------------------------------------------------------------
note "## rc propagation"
# ---------------------------------------------------------------------------

jobs=$(make_jobs \
    "ok_id"  "echo" '{"text":"good"}' \
    "bad_id" "fail" '{"rc":42,"msg":"deliberate"}')
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 1)
rc=$?
assert_eq "$rc" "0" "mixed rc → helper itself returns 0"

l1=$(printf '%s\n' "$out" | sed -n '1p')
l2=$(printf '%s\n' "$out" | sed -n '2p')
assert_eq "$(line_id "$l1")" "ok_id"  "rc propagation: id[0]"
assert_eq "$(line_rc "$l1")" "0"      "rc propagation: rc[0]=0"
assert_eq "$(line_text "$l1")" "good" "rc propagation: text[0]"
assert_eq "$(line_id "$l2")" "bad_id" "rc propagation: id[1]"
assert_eq "$(line_rc "$l2")" "42"     "rc propagation: rc[1]=42"
assert_contains "$(line_text "$l2")" "deliberate" "rc propagation: stderr captured (2>&1)"

# ---------------------------------------------------------------------------
note "## Output content preservation"
# ---------------------------------------------------------------------------

# Multiline content survives base64 roundtrip.
jobs=$(make_jobs "ml" "multiline" '{"n":5,"pre":"row"}')
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 1)
text=$(line_text "$out")
# multiline emits "row0\nrow1\n...\nrow4\n"; $() captures + strips trailing \n.
# Result: row0\nrow1\n...\nrow4 (4 inner \n + 5 lines).
assert_contains "$text" "row0" "multiline output: row0 present"
assert_contains "$text" "row4" "multiline output: row4 present"
nl_count=$(printf '%s' "$text" | awk 'END { print NR }')
# awk counts records by separator; without trailing \n, BSD awk counts the
# last partial line too.
assert_eq "$nl_count" "5" "multiline output: 5 lines decoded"

# UTF-8 content roundtrips byte-exact.
jobs=$(make_jobs "u" "special" '{"mode":"utf8"}')
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 1)
assert_eq "$(line_text "$out")" "ñoño 漢字 emoji 🚀" "utf8 content roundtrip"

# Quotes roundtrip.
jobs=$(make_jobs "q" "special" '{"mode":"quotes"}')
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 1)
assert_eq "$(line_text "$out")" 'has "double" and '\''single'\'' quotes' "quote content roundtrip"

# Backslash roundtrip.
jobs=$(make_jobs "b" "special" '{"mode":"backslash"}')
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 1)
assert_eq "$(line_text "$out")" 'line1\line2' "backslash content roundtrip"

# Empty output roundtrip.
jobs=$(make_jobs "e" "special" '{"mode":"empty"}')
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 1)
assert_eq "$(line_text "$out")" "" "empty content roundtrip"

# ---------------------------------------------------------------------------
note "## Parallel path (max_workers > 1)"
# ---------------------------------------------------------------------------

jobs=$(make_jobs \
    "p1" "echo" '{"text":"first"}' \
    "p2" "echo" '{"text":"second"}' \
    "p3" "echo" '{"text":"third"}')
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 3)
rc=$?
assert_eq "$rc" "0" "parallel 3 jobs → rc 0"

expected_ids=("p1" "p2" "p3")
expected_texts=("first" "second" "third")
i=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    assert_eq "$(line_id   "$line")" "${expected_ids[$i]}"   "parallel stable order id[$i]"
    assert_eq "$(line_text "$line")" "${expected_texts[$i]}" "parallel stable order text[$i]"
    i=$((i + 1))
done <<<"$out"
assert_eq "$i" "3" "parallel 3 jobs produced 3 output lines"

# Order preserved when jobs finish out-of-order.
jobs=$(make_jobs \
    "s1" "sleep" '{"secs":0.3,"tag":"slow"}' \
    "s2" "sleep" '{"secs":0.1,"tag":"fast"}' \
    "s3" "sleep" '{"secs":0.2,"tag":"medium"}')
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 4)
expected_tags=("slow" "fast" "medium")
expected_ids=("s1" "s2" "s3")
i=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    assert_eq "$(line_id   "$line")" "${expected_ids[$i]}"  "out-of-order id[$i] stable"
    assert_eq "$(line_text "$line")" "${expected_tags[$i]}" "out-of-order text[$i] stable"
    i=$((i + 1))
done <<<"$out"

# Concurrency: 4 jobs of sleep 0.5s with max_workers=4 should finish in ~0.5s.
# Serial would be ~2.0s. We allow 2s ceiling (still under serial).
jobs_args=()
for k in 1 2 3 4; do
    jobs_args+=("c$k" "sleep" "{\"secs\":0.5,\"tag\":\"c$k\"}")
done
jobs=$(make_jobs "${jobs_args[@]}")
t0=$(date +%s)
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 4)
t1=$(date +%s)
elapsed=$((t1 - t0))
assert_le "$elapsed" "2" "parallel concurrency (4x sleep 0.5s, cap=4)"

lines=$(printf '%s\n' "$out" | grep -c .)
assert_eq "$lines" "4" "parallel concurrency: 4 output lines"

# ---------------------------------------------------------------------------
note "## Parallel batching (N > max_workers)"
# ---------------------------------------------------------------------------

jobs_args=()
for k in 1 2 3 4 5 6; do
    jobs_args+=("B$k" "sleep" "{\"secs\":0.3,\"tag\":\"B$k\"}")
done
jobs=$(make_jobs "${jobs_args[@]}")
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 2)
rc=$?
assert_eq "$rc" "0" "batched 6 jobs cap=2 → rc 0"

i=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    assert_eq "$(line_id   "$line")" "B$((i + 1))" "batched id order[$i]"
    assert_eq "$(line_text "$line")" "B$((i + 1))" "batched tag order[$i]"
    i=$((i + 1))
done <<<"$out"
assert_eq "$i" "6" "batched 6 jobs produced 6 output lines"

# ---------------------------------------------------------------------------
note "## Handler not registered"
# ---------------------------------------------------------------------------

jobs=$(make_jobs "nx" "nonexistent_tool" '{}')
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 1)
rc=$?
assert_eq "$rc" "0" "unregistered tool sequential → helper rc 0"
assert_eq "$(line_id "$out")"   "nx" "unregistered tool: id preserved"
assert_eq "$(line_rc "$out")"   "1"  "unregistered tool: rc=1 from dispatch_tool"
assert_contains "$(line_text "$out")" "not registered" "unregistered tool: stderr captured"

jobs=$(make_jobs "nx" "nonexistent_tool" '{}')
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 4)
assert_eq "$(line_rc "$out")" "1" "unregistered tool (parallel): rc=1"
assert_contains "$(line_text "$out")" "not registered" "unregistered tool (parallel): stderr captured"

# ---------------------------------------------------------------------------
note "## Mixed success/failure in parallel"
# ---------------------------------------------------------------------------

jobs=$(make_jobs \
    "m1" "echo" '{"text":"good"}' \
    "m2" "fail" '{"rc":3,"msg":"x"}' \
    "m3" "echo" '{"text":"also good"}' \
    "m4" "fail" '{"rc":9,"msg":"y"}')
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 4)
rc=$?
assert_eq "$rc" "0" "mixed parallel → helper rc 0"

expected_ids=("m1" "m2" "m3" "m4")
expected_rcs=("0" "3" "0" "9")
i=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    assert_eq "$(line_id "$line")" "${expected_ids[$i]}" "mixed order id[$i]"
    assert_eq "$(line_rc "$line")" "${expected_rcs[$i]}" "mixed rc[$i]"
    i=$((i + 1))
done <<<"$out"
assert_eq "$i" "4" "mixed parallel: 4 output lines"

# ---------------------------------------------------------------------------
note "## Hooks integration (off-path: hooks.sh sourced)"
# ---------------------------------------------------------------------------

# shellcheck source=../lib/hooks.sh disable=SC1091
source "$REPO_ROOT/lib/agent/hooks.sh"

HOOKS_TMP=$(mktemp -d)
export CODER_HOOKS_CONFIG="$HOOKS_TMP/hooks.json"
hooks_init

LOG_FILE="$HOOKS_TMP/pre.log"
# Note: cmd uses `printf` with escaped \\n so jq stores LITERAL backslash-n in
# JSON value. When hooks_list_for reads with `read -r`, the cmd is one line.
jq --arg cmd "echo via-pre >> '$LOG_FILE'" \
    '.tool_pre.echo = [$cmd]' "$CODER_HOOKS_CONFIG" \
    > "$CODER_HOOKS_CONFIG.tmp" && mv "$CODER_HOOKS_CONFIG.tmp" "$CODER_HOOKS_CONFIG"

jobs=$(make_jobs "h1" "echo" '{"text":"hooked"}')
out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 1)
rc=$?
assert_eq "$rc" "0" "hooks-loaded sequential → rc 0"
assert_eq "$(line_rc "$out")"   "0"      "hooks-loaded sequential: handler rc preserved"
assert_eq "$(line_text "$out")" "hooked" "hooks-loaded sequential: output preserved"

rm -rf "$HOOKS_TMP"
unset CODER_HOOKS_CONFIG

# ---------------------------------------------------------------------------
note "## Large N (20 jobs, cap=4)"
# ---------------------------------------------------------------------------

jobs_args=()
expected_ids=()
expected_texts=()
for k in $(seq 1 20); do
    jobs_args+=("L$k" "echo" "{\"text\":\"v$k\"}")
    expected_ids+=("L$k")
    expected_texts+=("v$k")
done
jobs=$(make_jobs "${jobs_args[@]}")

out=$(printf '%s' "$jobs" | _dispatch_tools_parallel 4)
rc=$?
assert_eq "$rc" "0" "N=20 cap=4 → rc 0"

i=0
mismatch=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [ "$(line_id "$line")" != "${expected_ids[$i]}" ] \
        || [ "$(line_text "$line")" != "${expected_texts[$i]}" ]; then
        mismatch=$((mismatch + 1))
    fi
    i=$((i + 1))
done <<<"$out"
assert_eq "$i" "20" "N=20 cap=4 produced 20 output lines"
assert_eq "$mismatch" "0" "N=20 cap=4: all 20 entries in stable order"

# ---------------------------------------------------------------------------
note "## Meta: shellcheck + bash -n"
# ---------------------------------------------------------------------------

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -e SC1091 "$REPO_ROOT/lib/agent/tool_calling.sh" 2>/dev/null; then
        assert_eq "yes" "yes" "shellcheck lib/tool_calling.sh clean"
    else
        assert_eq "no" "yes" "shellcheck lib/tool_calling.sh clean"
    fi
else
    note "  SKIP shellcheck not installed"
fi

if bash -n "$REPO_ROOT/lib/agent/tool_calling.sh" 2>/dev/null; then
    assert_eq "yes" "yes" "bash -n lib/tool_calling.sh"
else
    assert_eq "no" "yes" "bash -n lib/tool_calling.sh"
fi

# ---------------------------------------------------------------------------
note ""
note "Resultado: $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
