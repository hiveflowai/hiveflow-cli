#!/bin/bash
#
# Smoke test standalone para lib/tools/subagent.sh
# - Aisla PERMISSIONS_CONFIG / CONFIG_DIR en tmpdir.
# - CODER_YES=1 por default; tests de "denied" lo overridean en la invocacion.
# - Usa un fake coder.sh (CODER_SUBAGENT_BIN) que registra ARGV, env y opcionalmente sleepea.
# - Exit != 0 si algun assert falla.

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

# --- Fake coder binary (stub) ---
# Comportamiento:
#   - Echo de un header con ARGV.
#   - Si la primera palabra del prompt es "SLEEP", duerme N (segunda palabra).
#   - Si la primera palabra del prompt es "BIG", emite N bytes 'A'.
#   - Si la primera palabra del prompt es "STDERR", emite el resto a stderr.
#   - Si la primera palabra del prompt es "EXIT", exit con N (segunda palabra).
#   - Si la primera palabra del prompt es "PWD", emite el cwd.
#   - Si la primera palabra del prompt es "DEPTH", emite $CODER_SUBAGENT_DEPTH.
#   - En cualquier otro caso, emite "fake: <prompt>" y exit 0.
FAKE_CODER="$TMPDIR_TEST/fake_coder.sh"
cat >"$FAKE_CODER" <<'SCRIPT'
#!/bin/bash
# Espera "-agent <prompt>" en ARGV.
if [ "${1:-}" != "-agent" ]; then
    echo "fake_coder: expected -agent as first arg, got: ${1:-}" >&2
    exit 99
fi
shift
prompt="$*"
read -r head rest <<<"$prompt"
case "$head" in
    SLEEP)
        sleep "${rest:-5}"
        ;;
    BIG)
        head -c "${rest:-1000}" /dev/zero | tr '\0' 'A'
        ;;
    STDERR)
        echo "fake-stderr: $rest" >&2
        ;;
    EXIT)
        exit "${rest:-0}"
        ;;
    PWD)
        pwd -P
        ;;
    DEPTH)
        echo "depth=${CODER_SUBAGENT_DEPTH:-unset}"
        ;;
    *)
        echo "fake: $prompt"
        ;;
esac
exit 0
SCRIPT
chmod +x "$FAKE_CODER"
export CODER_SUBAGENT_BIN="$FAKE_CODER"

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
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (missing: '$needle')"
        echo "       output was: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1"; local needle="$2"; local haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo "  FAIL: $desc (should NOT contain: '$needle')"
        echo "       output was: $haystack"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    fi
}

# --- Registracion + definition ---
echo "=== Test: registracion"
register_tool subagent
if list_registered_tools | grep -q '^subagent$'; then
    echo "  PASS: subagent en REGISTERED_TOOLS"; PASS=$((PASS + 1))
else
    echo "  FAIL: subagent no aparece en REGISTERED_TOOLS"; FAIL=$((FAIL + 1))
fi

echo "=== Test: definition emite JSON valido"
def=$(get_tool_definition subagent)
if echo "$def" | jq -e '.name == "subagent"' >/dev/null; then
    echo "  PASS: definition.name == subagent"; PASS=$((PASS + 1))
else
    echo "  FAIL: definition.name != subagent"; FAIL=$((FAIL + 1))
fi
if echo "$def" | jq -e '.input_schema.required | index("prompt")' >/dev/null; then
    echo "  PASS: definition requiere prompt"; PASS=$((PASS + 1))
else
    echo "  FAIL: definition no marca prompt como required"; FAIL=$((FAIL + 1))
fi
if echo "$def" | jq -e '.input_schema.properties.timeout_seconds.type == "integer"' >/dev/null; then
    echo "  PASS: timeout_seconds es integer"; PASS=$((PASS + 1))
else
    echo "  FAIL: timeout_seconds no es integer"; FAIL=$((FAIL + 1))
fi
if echo "$def" | jq -e '.input_schema.properties.working_directory.type == "string"' >/dev/null; then
    echo "  PASS: working_directory es string"; PASS=$((PASS + 1))
else
    echo "  FAIL: working_directory no es string"; FAIL=$((FAIL + 1))
fi

# --- Happy paths ---
echo "=== Test: prompt simple produce exit=0 + stdout"
out=$(dispatch_tool subagent '{"prompt":"hola mundo"}')
rc=$?
assert_eq "tool exit 0" "0" "$rc"
assert_contains "header exit=0" "exit=0" "$out"
assert_contains "header timed_out=false" "timed_out=false" "$out"
assert_contains "header depth=1 (child)" "depth=1" "$out"
assert_contains "stdout contiene 'fake: hola mundo'" "fake: hola mundo" "$out"
assert_contains "stderr seccion (empty)" "(empty)" "$out"

echo "=== Test: hijo con exit code != 0 propaga"
out=$(dispatch_tool subagent '{"prompt":"EXIT 7"}')
rc=$?
assert_eq "tool exit 0 (siempre, si ejecuto)" "0" "$rc"
assert_contains "header exit=7" "exit=7" "$out"

echo "=== Test: stderr separado de stdout"
out=$(dispatch_tool subagent '{"prompt":"STDERR este_va_a_stderr"}')
rc=$?
assert_eq "tool exit 0" "0" "$rc"
stdout_section=$(echo "$out" | awk '/^--- stdout ---$/{flag=1; next} /^--- stderr ---$/{flag=0} flag')
stderr_section=$(echo "$out" | awk '/^--- stderr ---$/{flag=1; next} flag')
assert_contains "stderr section tiene 'este_va_a_stderr'" "este_va_a_stderr" "$stderr_section"
assert_not_contains "stdout section NO tiene 'este_va_a_stderr'" "este_va_a_stderr" "$stdout_section"

echo "=== Test: working_directory override (PWD del hijo)"
input=$(jq -nc --arg wd "$TMPDIR_TEST/work" '{prompt: "PWD", working_directory: $wd}')
out=$(dispatch_tool subagent "$input")
rc=$?
assert_eq "tool exit 0" "0" "$rc"
# macOS canonicaliza /var/folders/... a /private/var/folders/... — comparar via basename.
assert_contains "pwd del hijo contiene 'work'" "work" "$out"

echo "=== Test: CODER_SUBAGENT_DEPTH se propaga al hijo (parent=0 => child=1)"
out=$(dispatch_tool subagent '{"prompt":"DEPTH"}')
rc=$?
assert_eq "tool exit 0" "0" "$rc"
assert_contains "child depth=1 en stdout" "depth=1" "$out"

echo "=== Test: CODER_SUBAGENT_DEPTH se propaga al hijo (parent=1 => child=2)"
out=$(CODER_SUBAGENT_DEPTH=1 dispatch_tool subagent '{"prompt":"DEPTH"}')
rc=$?
assert_eq "tool exit 0" "0" "$rc"
assert_contains "child depth=2 en stdout" "depth=2" "$out"
assert_contains "header reporta depth=2" "depth=2" "$out"

# --- Recursion guard ---
echo "=== Test: depth == max => hard-fail antes de spawn"
set +e
err=$(CODER_SUBAGENT_DEPTH=3 CODER_SUBAGENT_MAX_DEPTH=3 \
    dispatch_tool subagent '{"prompt":"deberia rechazarse"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1 depth excedido" "1" "$rc"
assert_contains "mensaje recursion depth" "recursion depth" "$err"

echo "=== Test: depth > max => hard-fail"
set +e
err=$(CODER_SUBAGENT_DEPTH=5 CODER_SUBAGENT_MAX_DEPTH=3 \
    dispatch_tool subagent '{"prompt":"deberia rechazarse"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1 depth muy alto" "1" "$rc"
assert_contains "mensaje recursion depth" "recursion depth" "$err"

echo "=== Test: depth = max - 1 funciona OK"
out=$(CODER_SUBAGENT_DEPTH=2 CODER_SUBAGENT_MAX_DEPTH=3 \
    dispatch_tool subagent '{"prompt":"ok"}')
rc=$?
assert_eq "tool exit 0" "0" "$rc"
assert_contains "child depth=3 (max alcanzado pero permitido)" "depth=3" "$out"

# --- Timeout ---
echo "=== Test: timeout enforcement (SLEEP 5 con timeout=10 => OK)"
out=$(dispatch_tool subagent '{"prompt":"SLEEP 1","timeout_seconds":10}')
rc=$?
assert_eq "tool exit 0" "0" "$rc"
assert_contains "timed_out=false" "timed_out=false" "$out"

echo "=== Test: timeout kill (SLEEP 30 con timeout=10 => SIGTERM/SIGKILL)"
# El fake duerme 30s pero el watchdog debe matarlo a los 10s + 1s grace ~= 11s.
# Como el timeout minimo del schema es 10, no podemos ir mas bajo; nos
# conformamos con un margen razonable.
start_ts=$(date +%s)
out=$(dispatch_tool subagent '{"prompt":"SLEEP 30","timeout_seconds":10}')
rc=$?
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
assert_eq "tool exit 0 aun con timeout" "0" "$rc"
assert_contains "header timed_out=true" "timed_out=true" "$out"
# Debe haber terminado en <=14s (10s timeout + 1s grace + ~3s margin).
if [ "$elapsed" -le 14 ]; then
    echo "  PASS: real elapsed <= 14s (got ${elapsed}s)"; PASS=$((PASS + 1))
else
    echo "  FAIL: real elapsed > 14s (got ${elapsed}s) — watchdog no killed"; FAIL=$((FAIL + 1))
fi

# --- Output truncation ---
echo "=== Test: stdout truncado a CODER_SUBAGENT_MAX_OUTPUT_BYTES"
out=$(CODER_SUBAGENT_MAX_OUTPUT_BYTES=128 \
    dispatch_tool subagent '{"prompt":"BIG 5000"}')
rc=$?
assert_eq "tool exit 0" "0" "$rc"
assert_contains "marker de truncado" "truncated" "$out"

# --- Input validation ---
echo "=== Test: input JSON invalido"
set +e
err=$(dispatch_tool subagent 'not json' 2>&1)
rc=$?
set -e
assert_eq "exit 2 (dispatch_tool valida JSON)" "2" "$rc"

echo "=== Test: prompt missing"
set +e
err=$(dispatch_tool subagent '{}' 2>&1)
rc=$?
set -e
assert_eq "exit 2 cuando falta prompt" "2" "$rc"
assert_contains "mensaje prompt missing" "missing required field 'prompt'" "$err"

echo "=== Test: prompt vacio"
set +e
err=$(dispatch_tool subagent '{"prompt":""}' 2>&1)
rc=$?
set -e
assert_eq "exit 2 prompt vacio" "2" "$rc"

echo "=== Test: prompt excede 32KB"
big=$(head -c 33000 /dev/zero | tr '\0' 'x')
input=$(jq -nc --arg p "$big" '{prompt: $p}')
set +e
err=$(dispatch_tool subagent "$input" 2>&1)
rc=$?
set -e
assert_eq "exit 2 prompt grande" "2" "$rc"
assert_contains "mensaje exceeds" "exceeds" "$err"

echo "=== Test: timeout_seconds invalido (string)"
set +e
err=$(dispatch_tool subagent '{"prompt":"x","timeout_seconds":"abc"}' 2>&1)
rc=$?
set -e
assert_eq "exit 2 timeout no numerico" "2" "$rc"
assert_contains "mensaje timeout integer" "positive integer" "$err"

echo "=== Test: timeout_seconds out of range (5, min=10)"
set +e
err=$(dispatch_tool subagent '{"prompt":"x","timeout_seconds":5}' 2>&1)
rc=$?
set -e
assert_eq "exit 2 timeout < 10" "2" "$rc"
assert_contains "mensaje out of range" "out of range" "$err"

echo "=== Test: timeout_seconds out of range (>3600)"
set +e
err=$(dispatch_tool subagent '{"prompt":"x","timeout_seconds":99999}' 2>&1)
rc=$?
set -e
assert_eq "exit 2 timeout >3600" "2" "$rc"
assert_contains "mensaje out of range" "out of range" "$err"

echo "=== Test: working_directory inexistente"
set +e
err=$(dispatch_tool subagent '{"prompt":"x","working_directory":"/no/such/dir"}' 2>&1)
rc=$?
set -e
assert_eq "exit 2 wd no existe" "2" "$rc"
assert_contains "mensaje no existing dir" "not an existing directory" "$err"

# --- Coder bin resolution ---
echo "=== Test: CODER_SUBAGENT_BIN apunta a archivo inexistente"
set +e
err=$(CODER_SUBAGENT_BIN="/no/such/coder.sh" \
    dispatch_tool subagent '{"prompt":"x"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1 bin no encontrado" "1" "$rc"
assert_contains "mensaje cannot resolve" "cannot resolve coder binary" "$err"

# --- Permission system ---
echo "=== Test: needs-confirm + CODER_YES=0 + no-TTY => denied"
set +e
err=$(CODER_YES=0 dispatch_tool subagent '{"prompt":"should_not_run"}' 2>&1)
rc=$?
set -e
assert_eq "exit 1 sin auto-yes en no-TTY" "1" "$rc"
assert_contains "mensaje permission denied" "permission denied" "$err"

echo ""
echo "==========================================="
echo "Resultado: $PASS pass, $FAIL fail"
echo "==========================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
