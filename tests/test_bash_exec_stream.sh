#!/bin/bash
#
# Smoke test para CODER_TOOL_LIVE_STREAM=1 en lib/tools/bash_exec.sh (P2.streaming-1).
# Verifica que el opt-in flag (a) emite stdout/stderr del cmd hijo a la stderr
# del handler EN VIVO, (b) mantiene intacta la salida canonica estructurada
# (header + secciones --- stdout --- / --- stderr ---), (c) preserva todos los
# contratos previos (timeout, exit code propagation, default OFF).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# shellcheck source=../lib/tool_calling.sh disable=SC1091
source "$REPO_ROOT/lib/agent/tool_calling.sh"
# shellcheck source=../lib/permissions.sh disable=SC1091
source "$REPO_ROOT/lib/agent/permissions.sh"

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT INT TERM

export PERMISSIONS_CONFIG="$TMPDIR_TEST/permissions.json"
export CONFIG_DIR="$TMPDIR_TEST/cfg"
export CODER_YES=1

mkdir -p "$TMPDIR_TEST/work"
cd "$TMPDIR_TEST/work"

register_tool bash_exec

PASS=0
FAIL=0

assert_eq() {
    local desc="$1"; local expected="$2"; local actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1"; local needle="$2"; local haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (missing: '$needle')"
        echo "       haystack was: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1"; local needle="$2"; local haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  FAIL: $desc (should NOT contain: '$needle')"
        echo "       haystack was: $haystack"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    fi
}

# ---------------------------------------------------------------------------
# Test 1: default mode (env unset) NO emite stream live a la stderr del handler.
# ---------------------------------------------------------------------------
echo "=== Test: default (CODER_TOOL_LIVE_STREAM unset) no emite stream live"
unset CODER_TOOL_LIVE_STREAM || true
out=$(tool_bash_exec_handler '{"command":"echo TICK_DEFAULT"}' 2>"$TMPDIR_TEST/stderr.1")
stderr_content=$(cat "$TMPDIR_TEST/stderr.1")
assert_contains "default: canonical stdout tiene TICK_DEFAULT" "TICK_DEFAULT" "$out"
assert_contains "default: header con exit=0" "exit=0" "$out"
assert_eq      "default: stderr handler vacio (sin stream)" "" "$stderr_content"

# ---------------------------------------------------------------------------
# Test 2: CODER_TOOL_LIVE_STREAM=1 emite stdout del cmd a la stderr del handler
# Y mantiene el canonical structured output intacto.
# ---------------------------------------------------------------------------
echo "=== Test: CODER_TOOL_LIVE_STREAM=1 emite stream a stderr"
out=$(CODER_TOOL_LIVE_STREAM=1 tool_bash_exec_handler '{"command":"echo TICK_STREAM"}' 2>"$TMPDIR_TEST/stderr.2")
stderr_content=$(cat "$TMPDIR_TEST/stderr.2")
assert_contains "stream=1: canonical stdout tiene TICK_STREAM" "TICK_STREAM" "$out"
assert_contains "stream=1: header con exit=0" "exit=0" "$out"
assert_contains "stream=1: stderr live captura TICK_STREAM" "TICK_STREAM" "$stderr_content"

# ---------------------------------------------------------------------------
# Test 3: stream-on + stderr-only cmd → live stderr captura, canonical section
# pone el contenido en --- stderr ---, stdout section queda vacia.
# ---------------------------------------------------------------------------
echo "=== Test: CODER_TOOL_LIVE_STREAM=1 con stderr-only cmd"
out=$(CODER_TOOL_LIVE_STREAM=1 tool_bash_exec_handler '{"command":"echo ONLY_ERR >&2"}' 2>"$TMPDIR_TEST/stderr.3")
stderr_content=$(cat "$TMPDIR_TEST/stderr.3")
stdout_section=$(echo "$out" | awk '/^--- stdout ---$/{flag=1; next} /^--- stderr ---$/{flag=0} flag')
stderr_section=$(echo "$out" | awk '/^--- stderr ---$/{flag=1; next} flag')
assert_contains "stream stderr-only: --- stderr --- section tiene ONLY_ERR" "ONLY_ERR" "$stderr_section"
assert_contains "stream stderr-only: --- stdout --- section vacia (empty)" "(empty)" "$stdout_section"
assert_contains "stream stderr-only: live captura ONLY_ERR" "ONLY_ERR" "$stderr_content"

# ---------------------------------------------------------------------------
# Test 4: stream-on + timeout → comando se mata, header marca timed_out=true,
# duracion acotada (timeout + grace + drain overhead).
# ---------------------------------------------------------------------------
echo "=== Test: CODER_TOOL_LIVE_STREAM=1 con timeout"
start_ts=$(date +%s)
out=$(CODER_TOOL_LIVE_STREAM=1 tool_bash_exec_handler '{"command":"sleep 5","timeout_seconds":1}' 2>"$TMPDIR_TEST/stderr.4")
end_ts=$(date +%s)
duration_sec=$((end_ts - start_ts))
assert_contains "stream + timeout: marca timed_out=true" "timed_out=true" "$out"
if [ "$duration_sec" -le 5 ]; then
    echo "  PASS: stream + timeout termina rapido (${duration_sec}s <= 5s)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: stream + timeout tomo demasiado: ${duration_sec}s"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Test 5: stream-on + exit code != 0 propaga al header canonico.
# ---------------------------------------------------------------------------
echo "=== Test: CODER_TOOL_LIVE_STREAM=1 propaga exit code != 0"
out=$(CODER_TOOL_LIVE_STREAM=1 tool_bash_exec_handler '{"command":"exit 7"}' 2>"$TMPDIR_TEST/stderr.5")
assert_contains "stream + exit 7: header marca exit=7" "exit=7" "$out"
assert_contains "stream + exit 7: timed_out=false" "timed_out=false" "$out"

# ---------------------------------------------------------------------------
# Test 6: stream-on + cmd que emite tanto stdout como stderr → secciones
# canonical separadas correctamente Y ambos chunks visibles en stderr live.
# ---------------------------------------------------------------------------
echo "=== Test: CODER_TOOL_LIVE_STREAM=1 separa stdout/stderr en sections"
out=$(CODER_TOOL_LIVE_STREAM=1 tool_bash_exec_handler '{"command":"echo OUT_TOKEN; echo ERR_TOKEN >&2"}' 2>"$TMPDIR_TEST/stderr.6")
stderr_content=$(cat "$TMPDIR_TEST/stderr.6")
stdout_section=$(echo "$out" | awk '/^--- stdout ---$/{flag=1; next} /^--- stderr ---$/{flag=0} flag')
stderr_section=$(echo "$out" | awk '/^--- stderr ---$/{flag=1; next} flag')
assert_contains "stream mixed: --- stdout --- contiene OUT_TOKEN" "OUT_TOKEN" "$stdout_section"
assert_contains "stream mixed: --- stderr --- contiene ERR_TOKEN" "ERR_TOKEN" "$stderr_section"
assert_not_contains "stream mixed: --- stdout --- NO contamina con ERR_TOKEN" "ERR_TOKEN" "$stdout_section"
assert_not_contains "stream mixed: --- stderr --- NO contamina con OUT_TOKEN" "OUT_TOKEN" "$stderr_section"
assert_contains "stream mixed: stderr live contiene OUT_TOKEN" "OUT_TOKEN" "$stderr_content"
assert_contains "stream mixed: stderr live contiene ERR_TOKEN" "ERR_TOKEN" "$stderr_content"

# ---------------------------------------------------------------------------
# Test 7: CODER_TOOL_LIVE_STREAM=0 explicito → comportamiento igual a unset.
# ---------------------------------------------------------------------------
echo "=== Test: CODER_TOOL_LIVE_STREAM=0 explicito (off)"
out=$(CODER_TOOL_LIVE_STREAM=0 tool_bash_exec_handler '{"command":"echo OFF_TOKEN"}' 2>"$TMPDIR_TEST/stderr.7")
stderr_content=$(cat "$TMPDIR_TEST/stderr.7")
assert_contains "off explicit: canonical tiene OFF_TOKEN" "OFF_TOKEN" "$out"
assert_eq      "off explicit: stderr handler vacio" "" "$stderr_content"

# ---------------------------------------------------------------------------
# Test 8: stream-on + comando multilinea con tee preservando orden por stream.
# (Cada stream procesa lineas en orden FIFO; lo verificamos por separado.)
# ---------------------------------------------------------------------------
echo "=== Test: CODER_TOOL_LIVE_STREAM=1 preserva orden de lineas por stream"
out=$(CODER_TOOL_LIVE_STREAM=1 tool_bash_exec_handler '{"command":"printf 'A\\nB\\nC\\n'"}' 2>"$TMPDIR_TEST/stderr.8")
stdout_section=$(echo "$out" | awk '/^--- stdout ---$/{flag=1; next} /^--- stderr ---$/{flag=0} flag')
# Comprobamos que A aparece antes que B y B antes que C en la canonical section.
order_check=$(echo "$stdout_section" | tr -d '[:space:]')
if [[ "$order_check" == *A*B*C* ]]; then
    echo "  PASS: stream multiline: orden A,B,C preservado en canonical section"
    PASS=$((PASS + 1))
else
    echo "  FAIL: stream multiline: orden roto en canonical section"
    echo "       section was: $stdout_section"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Test 9: stream-on no rompe truncation cap.
# ---------------------------------------------------------------------------
echo "=== Test: CODER_TOOL_LIVE_STREAM=1 respeta CODER_BASH_EXEC_MAX_OUTPUT_BYTES"
out=$(CODER_TOOL_LIVE_STREAM=1 CODER_BASH_EXEC_MAX_OUTPUT_BYTES=64 \
    tool_bash_exec_handler '{"command":"printf %s $(printf x%.0s {1..200})"}' \
    2>"$TMPDIR_TEST/stderr.9")
assert_contains "stream + max_bytes: marker truncated presente" "truncated" "$out"

echo "==============================="
echo "Resultado: $PASS pass, $FAIL fail"
echo "==============================="
[ "$FAIL" -eq 0 ]
