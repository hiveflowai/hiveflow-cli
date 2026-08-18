#!/bin/bash
# tests/run_all.sh — runner for all bash suites under tests/.
# Exits non-zero if any suite fails. Designed for local dev and CI.
#
# Env:
#   CODER_TESTS_OFFLINE=1  — isolate HOME to a fresh tmpdir and unset provider
#                            API keys so Live E2E blocks skip deterministically.
#                            CI sets this by default (see .github/workflows/ci.yml).
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
tests_dir="$repo_root/tests"

if [ "${CODER_TESTS_OFFLINE:-0}" = "1" ]; then
    fake_home=$(mktemp -d 2>/dev/null || mktemp -d -t coder-run-home)
    export HOME="$fake_home"
    unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY chatgpt_api_key claude_api_key gemini_api_key
fi

shopt -s nullglob
files=("$tests_dir"/test_*.sh)
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
    echo "ERROR: no test files matched $tests_dir/test_*.sh" >&2
    exit 1
fi

log_dir=$(mktemp -d 2>/dev/null || mktemp -d -t coder-run-all)
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    rm -rf "$log_dir"
    [ -n "${fake_home:-}" ] && rm -rf "$fake_home"
}
trap cleanup EXIT

total=0
failed=()
start_ts=$(date +%s)

for f in "${files[@]}"; do
    total=$((total + 1))
    name=$(basename "$f")
    printf '  -> %-44s ' "$name"
    if bash "$f" >"$log_dir/$name.log" 2>&1; then
        last=$(grep -E '^Resultado:|^All [0-9]+ suites' "$log_dir/$name.log" | tail -1)
        if [ -n "$last" ]; then
            printf 'OK  (%s)\n' "$last"
        else
            printf 'OK\n'
        fi
    else
        rc=$?
        printf 'FAIL (rc=%d)\n' "$rc"
        failed+=("$name")
        echo "    --- last 40 lines of $name ---"
        tail -n 40 "$log_dir/$name.log" | sed 's/^/    /'
        echo "    --- end ---"
    fi
done

elapsed=$(($(date +%s) - start_ts))

echo ""
echo "==============================="
if [ "${#failed[@]}" -eq 0 ]; then
    echo "OK: $total suites passed in ${elapsed}s"
    exit 0
fi
echo "FAIL: ${#failed[@]} of $total suites failed in ${elapsed}s"
for s in "${failed[@]}"; do
    echo "  - $s"
done
exit 1
