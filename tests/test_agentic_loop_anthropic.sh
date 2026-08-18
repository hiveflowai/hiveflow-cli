#!/bin/bash
#
# Tests para lib/tool_calling.sh :: agentic_loop_anthropic (M1.3)
#
# Dos capas:
#   1) Unit tests sobre helpers `_anthropic_*` con fixtures JSON (offline, sin API).
#   2) Smoke test end-to-end contra /v1/messages — sólo si ANTHROPIC_API_KEY está
#      en env. Si no, lo skipea con mensaje claro.
#
# Exit != 0 si cualquier check falla.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT"

# shellcheck source=../lib/tool_calling.sh disable=SC1091
source "$REPO_ROOT/lib/agent/tool_calling.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        pass "$desc"
    else
        fail "$desc (missing: '$needle')"
        echo "       haystack was: $haystack"
    fi
}

# =====================================================================
# Setup: registrar read_file (necesario para fixture parsing + smoke)
# =====================================================================
register_tool read_file

# =====================================================================
# Fixture: respuesta típica de Anthropic con un único tool_use
# =====================================================================
FIXTURE_TOOL_USE=$(cat <<'EOF'
{
  "id": "msg_01ABC",
  "type": "message",
  "role": "assistant",
  "model": "claude-haiku-4-5-20251001",
  "content": [
    {"type": "text", "text": "Voy a leer el archivo para listarte las funciones."},
    {"type": "tool_use", "id": "toolu_01XYZ", "name": "read_file", "input": {"path": "tests/fixtures/sample_config.sh", "limit": 50}}
  ],
  "stop_reason": "tool_use",
  "stop_sequence": null
}
EOF
)

FIXTURE_END_TURN=$(cat <<'EOF'
{
  "id": "msg_02DEF",
  "type": "message",
  "role": "assistant",
  "model": "claude-haiku-4-5-20251001",
  "content": [
    {"type": "text", "text": "Las funciones son: init_config_directories, detect_system_language, load_language."}
  ],
  "stop_reason": "end_turn"
}
EOF
)

FIXTURE_API_ERROR=$(cat <<'EOF'
{"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}
EOF
)

echo "=== _anthropic_extract_text"
text=$(_anthropic_extract_text "$FIXTURE_TOOL_USE")
assert_contains "extrae texto de tool_use response" "Voy a leer el archivo" "$text"

text2=$(_anthropic_extract_text "$FIXTURE_END_TURN")
assert_contains "extrae texto de end_turn response" "Las funciones son" "$text2"

echo "=== _anthropic_extract_stop_reason"
sr=$(_anthropic_extract_stop_reason "$FIXTURE_TOOL_USE")
assert_eq "stop_reason tool_use" "tool_use" "$sr"

sr2=$(_anthropic_extract_stop_reason "$FIXTURE_END_TURN")
assert_eq "stop_reason end_turn" "end_turn" "$sr2"

sr3=$(_anthropic_extract_stop_reason '{"id":"x"}')
assert_eq "stop_reason ausente => unknown" "unknown" "$sr3"

echo "=== _anthropic_extract_tool_uses"
tu=$(_anthropic_extract_tool_uses "$FIXTURE_TOOL_USE")
tu_lines=$(echo "$tu" | grep -c .)
assert_eq "una sola línea de tool_use" "1" "$tu_lines"

# Parse fields. Separator es Unit Separator (0x1f), no TAB — @tsv corrompía
# strings multi-línea con `\n` JSON-encoded (escape de `\` -> `\\`).
tu_id=$(printf '%s' "$tu"   | awk -F$'\x1f' '{print $1}')
tu_name=$(printf '%s' "$tu" | awk -F$'\x1f' '{print $2}')
tu_input=$(printf '%s' "$tu" | awk -F$'\x1f' '{print $3}')
assert_eq "tool_use id parseado" "toolu_01XYZ" "$tu_id"
assert_eq "tool_use name parseado" "read_file" "$tu_name"
# input es JSON compacto, ambos campos presentes
if echo "$tu_input" | jq -e '.path == "tests/fixtures/sample_config.sh" and .limit == 50' >/dev/null; then
    pass "tool_use input parseado como JSON válido"
else
    fail "tool_use input no parseó como JSON esperado (got: $tu_input)"
fi

tu_none=$(_anthropic_extract_tool_uses "$FIXTURE_END_TURN")
if [ -z "$tu_none" ]; then
    pass "end_turn response no tiene tool_uses"
else
    fail "end_turn response debió no tener tool_uses (got: $tu_none)"
fi

# Regression: multi-línea en input.new_string debe llegar al handler con
# newline REAL (0x0a), no `\n` literal. Antes del fix iter 18, @tsv escapaba
# el `\` JSON-encoded volviéndolo `\\n` y el handler recibía `\n` literal.
echo "=== _anthropic_extract_tool_uses: preserva strings multi-línea (regression iter 18)"
FIXTURE_MULTILINE=$(jq -nc --arg multi $'line1\nline2 with "quotes"\nline3' '{
  id: "msg_x", type: "message", role: "assistant", model: "x",
  content: [{type: "tool_use", id: "toolu_ml", name: "write_file",
             input: {path: "out.txt", content: $multi}}],
  stop_reason: "tool_use"
}')
ml_record=$(_anthropic_extract_tool_uses "$FIXTURE_MULTILINE")
ml_input=$(printf '%s' "$ml_record" | awk -F$'\x1f' '{print $3}')
ml_content=$(jq -r '.content' <<<"$ml_input")
if [ "$ml_content" = $'line1\nline2 with "quotes"\nline3' ]; then
    pass "multi-línea decodifica con newlines reales (0x0a)"
else
    fail "multi-línea corrupted (esperado line1\\nline2... got bytes: $(printf '%s' "$ml_content" | xxd | head -3))"
fi

echo "=== _anthropic_is_api_error"
if _anthropic_is_api_error "$FIXTURE_API_ERROR"; then
    pass "detecta API error"
else
    fail "no detectó API error en fixture explícito"
fi

if _anthropic_is_api_error "$FIXTURE_END_TURN"; then
    fail "marcó respuesta normal como API error"
else
    pass "no marca respuesta normal como error"
fi

echo "=== _anthropic_build_tool_result"
tr=$(_anthropic_build_tool_result "toolu_01" "hello world" "false")
if echo "$tr" | jq -e '.type == "tool_result" and .tool_use_id == "toolu_01" and .content == "hello world" and .is_error == false' >/dev/null; then
    pass "tool_result shape OK (success)"
else
    fail "tool_result shape inválido: $tr"
fi

tr_err=$(_anthropic_build_tool_result "toolu_02" "boom" "true")
if echo "$tr_err" | jq -e '.is_error == true and .content == "boom"' >/dev/null; then
    pass "tool_result shape OK (error)"
else
    fail "tool_result error shape inválido: $tr_err"
fi

echo "=== _anthropic_build_payload"
tools_json=$(get_all_tool_definitions_json)
messages_json='[{"role":"user","content":"hola"}]'
payload=$(_anthropic_build_payload "claude-test" "1024" "$tools_json" "$messages_json")
if echo "$payload" | jq -e '.model == "claude-test" and .max_tokens == 1024 and (.tools | length) >= 1 and (.messages | length) == 1' >/dev/null; then
    pass "payload shape OK"
else
    fail "payload shape inválido: $payload"
fi

echo "=== _anthropic_append_assistant"
initial='[{"role":"user","content":"x"}]'
appended=$(_anthropic_append_assistant "$initial" "$FIXTURE_TOOL_USE")
if echo "$appended" | jq -e 'length == 2 and .[1].role == "assistant" and (.[1].content | length) == 2' >/dev/null; then
    pass "assistant message apendido con content intacto"
else
    fail "assistant append falló: $appended"
fi

echo "=== _anthropic_append_tool_results"
trs='[{"type":"tool_result","tool_use_id":"toolu_01","content":"ok","is_error":false}]'
with_tr=$(_anthropic_append_tool_results "$appended" "$trs")
if echo "$with_tr" | jq -e 'length == 3 and .[2].role == "user" and (.[2].content | length) == 1 and .[2].content[0].tool_use_id == "toolu_01"' >/dev/null; then
    pass "tool_results apendidos como user message"
else
    fail "tool_results append falló: $with_tr"
fi

echo "=== agentic_loop_anthropic: missing prompt"
set +e
err=$(agentic_loop_anthropic "" 2>&1)
rc=$?
set -e
assert_eq "exit 2 si prompt vacío" "2" "$rc"
assert_contains "mensaje 'missing prompt'" "missing prompt" "$err"

echo "=== agentic_loop_anthropic: key faltante"
set +e
no_key_out=$(
    unset ANTHROPIC_API_KEY
    unset claude_api_key
    agentic_loop_anthropic "hi" 2>&1
)
no_key_rc=$?
set -e
assert_eq "exit 1 sin api key" "1" "$no_key_rc"
assert_contains "mensaje 'ANTHROPIC_API_KEY not set'" "ANTHROPIC_API_KEY not set" "$no_key_out"

# =====================================================================
# Loop body tests — stub _anthropic_call_api con fixtures prerecorded.
# Cubre el control flow del while-loop (multi-turn, cap, errores, stops)
# sin tocar la red. Complementa los unit tests de helpers y es
# independiente de live verification (que sigue gated por env real).
# =====================================================================
echo ""
echo "==============================="
echo "Loop body (mocked _anthropic_call_api)"
echo "==============================="

# Snapshot impl real + env. Se restauran antes del bloque live.
_SAVED_CALL_API_DEF=$(declare -f _anthropic_call_api)
_SAVED_ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"
export ANTHROPIC_API_KEY="test-stub-key-not-real"

# Estado del mock backed por filesystem para sobrevivir el subshell de `$(...)`.
# Sin esto, _MOCK_COUNT++ dentro del subshell se pierde al salir y el stub
# devuelve siempre fixture[0] (el loop nunca avanza).
_MOCK_STATE_DIR=$(mktemp -d -t agentic_mock.XXXXXX)
trap 'rm -rf "$_MOCK_STATE_DIR"' EXIT INT TERM

_setup_mock_api() {
    rm -rf "$_MOCK_STATE_DIR"
    mkdir -p "$_MOCK_STATE_DIR/fixtures" "$_MOCK_STATE_DIR/captured"
    echo 0 > "$_MOCK_STATE_DIR/count"
    local i=0
    for f in "$@"; do
        printf '%s' "$f" > "$_MOCK_STATE_DIR/fixtures/$i"
        i=$((i + 1))
    done
}

_mock_count() { cat "$_MOCK_STATE_DIR/count"; }
_mock_captured() { cat "$_MOCK_STATE_DIR/captured/$1" 2>/dev/null; }

# shellcheck disable=SC2317  # invocada indirectamente vía agentic_loop_anthropic
_anthropic_call_api() {
    local count next
    count=$(cat "$_MOCK_STATE_DIR/count")
    printf '%s' "$1" > "$_MOCK_STATE_DIR/captured/$count"
    next=$((count + 1))
    echo "$next" > "$_MOCK_STATE_DIR/count"
    if [ -f "$_MOCK_STATE_DIR/fixtures/$count" ]; then
        cat "$_MOCK_STATE_DIR/fixtures/$count"
        return 0
    fi
    echo "mock: out of fixtures after $next call(s)" >&2
    return 1
}

echo "=== 2-turn flow: tool_use → tool_result → end_turn"
_setup_mock_api "$FIXTURE_TOOL_USE" "$FIXTURE_END_TURN"
set +e
two_turn_out=$(agentic_loop_anthropic "lista funciones" 2>&1)
two_turn_rc=$?
set -e
assert_eq "exit 0 al completar 2 turnos" "0" "$two_turn_rc"
assert_eq "loop hizo 2 llamadas a la API" "2" "$(_mock_count)"
assert_contains "stdout incluye texto del primer turn" "Voy a leer el archivo" "$two_turn_out"
assert_contains "stdout incluye texto del end_turn" "Las funciones son" "$two_turn_out"
second_payload=$(_mock_captured 1)
if echo "$second_payload" | jq -e '.messages | length == 3 and .[2].role == "user" and (.[2].content[0].type == "tool_result")' >/dev/null 2>&1; then
    pass "segundo payload threadea tool_result como user message"
else
    fail "threading incorrecto en segundo payload (roles: $(echo "$second_payload" | jq -c '.messages | map(.role)' 2>/dev/null))"
fi

echo "=== API error en response → exit 1"
_setup_mock_api "$FIXTURE_API_ERROR"
set +e
api_err_out=$(agentic_loop_anthropic "x" 2>&1)
api_err_rc=$?
set -e
assert_eq "API error → exit 1" "1" "$api_err_rc"
assert_contains "stderr menciona 'API error'" "API error" "$api_err_out"

echo "=== stop_reason=stop_sequence → exit 0"
FIXTURE_STOP_SEQ='{"id":"x","type":"message","role":"assistant","model":"x","content":[{"type":"text","text":"sequence done"}],"stop_reason":"stop_sequence"}'
_setup_mock_api "$FIXTURE_STOP_SEQ"
set +e
sseq_out=$(agentic_loop_anthropic "x" 2>&1)
sseq_rc=$?
set -e
assert_eq "stop_sequence → exit 0" "0" "$sseq_rc"
assert_contains "stdout emite el texto del turno" "sequence done" "$sseq_out"

echo "=== stop_reason=max_tokens → exit 0"
FIXTURE_MAX_TOK='{"id":"x","type":"message","role":"assistant","model":"x","content":[{"type":"text","text":"truncated"}],"stop_reason":"max_tokens"}'
_setup_mock_api "$FIXTURE_MAX_TOK"
set +e
mt_out=$(agentic_loop_anthropic "x" 2>&1)
mt_rc=$?
set -e
assert_eq "max_tokens → exit 0" "0" "$mt_rc"
assert_contains "stdout emite texto truncado" "truncated" "$mt_out"

echo "=== iteration cap (always tool_use) → exit 1"
_SAVED_MAX_ITER="${TOOL_LOOP_MAX_ITERATIONS:-}"
export TOOL_LOOP_MAX_ITERATIONS=3
_setup_mock_api "$FIXTURE_TOOL_USE" "$FIXTURE_TOOL_USE" "$FIXTURE_TOOL_USE"
set +e
cap_out=$(agentic_loop_anthropic "x" 2>&1)
cap_rc=$?
set -e
if [ -n "$_SAVED_MAX_ITER" ]; then
    export TOOL_LOOP_MAX_ITERATIONS="$_SAVED_MAX_ITER"
else
    unset TOOL_LOOP_MAX_ITERATIONS
fi
assert_eq "iteration cap → exit 1" "1" "$cap_rc"
assert_eq "loop ejecutó exactamente max_iter (3) llamadas" "3" "$(_mock_count)"
assert_contains "stderr menciona 'iteration cap'" "iteration cap" "$cap_out"

echo "=== stop_reason=tool_use sin bloques tool_use → exit 1"
FIXTURE_TU_EMPTY='{"id":"x","type":"message","role":"assistant","model":"x","content":[{"type":"text","text":"think"}],"stop_reason":"tool_use"}'
_setup_mock_api "$FIXTURE_TU_EMPTY"
set +e
tue_out=$(agentic_loop_anthropic "x" 2>&1)
tue_rc=$?
set -e
assert_eq "tool_use sin bloques → exit 1" "1" "$tue_rc"
assert_contains "stderr menciona 'no tool_use blocks parsed'" "no tool_use blocks parsed" "$tue_out"

echo "=== stop_reason desconocido → exit 1"
FIXTURE_WEIRD='{"id":"x","type":"message","role":"assistant","model":"x","content":[{"type":"text","text":"weird"}],"stop_reason":"refusal"}'
_setup_mock_api "$FIXTURE_WEIRD"
set +e
weird_out=$(agentic_loop_anthropic "x" 2>&1)
weird_rc=$?
set -e
assert_eq "stop_reason desconocido → exit 1" "1" "$weird_rc"
assert_contains "stderr menciona 'unexpected stop_reason'" "unexpected stop_reason" "$weird_out"

echo "=== tool dispatch error → is_error=true reinyectado en messages"
FIXTURE_TU_BADPATH='{"id":"x","type":"message","role":"assistant","model":"x","content":[{"type":"tool_use","id":"toolu_bad","name":"read_file","input":{"path":"NONEXISTENT_FILE_xyz_for_iter9_test.txt"}}],"stop_reason":"tool_use"}'
_setup_mock_api "$FIXTURE_TU_BADPATH" "$FIXTURE_END_TURN"
set +e
disp_err_out=$(agentic_loop_anthropic "x" 2>&1)
disp_err_rc=$?
set -e
assert_eq "loop sigue tras dispatch fail y termina 0" "0" "$disp_err_rc"
disp_second_payload=$(_mock_captured 1)
if echo "$disp_second_payload" | jq -e '.messages[].content[]? | select(.type=="tool_result" and .is_error == true)' >/dev/null 2>&1; then
    pass "is_error=true reinyectado en messages tras dispatch failure"
else
    fail "tool_result is_error=true ausente del segundo payload (messages: $(echo "$disp_second_payload" | jq -c '.messages' 2>/dev/null))"
fi
# Silencia uso supuestamente innecesario de disp_err_out (lo capturamos por symmetry y diagnostic on failure).
: "$disp_err_out"

# Restaurar impl real + env antes del bloque live.
eval "$_SAVED_CALL_API_DEF"
unset _SAVED_CALL_API_DEF
if [ -n "$_SAVED_ANTHROPIC_KEY" ]; then
    export ANTHROPIC_API_KEY="$_SAVED_ANTHROPIC_KEY"
else
    unset ANTHROPIC_API_KEY
fi
unset _SAVED_ANTHROPIC_KEY
rm -rf "$_MOCK_STATE_DIR"
trap - EXIT INT TERM

# =====================================================================
# Smoke test end-to-end (live) — gated por ANTHROPIC_API_KEY presente.
# =====================================================================
echo ""
echo "==============================="
echo "Live E2E (Anthropic /v1/messages)"
echo "==============================="

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "  SKIP: ANTHROPIC_API_KEY no presente en env — saltando smoke test live."
    echo "        (los unit tests pasaron; M1.3 requiere live verification antes de marcar done)"
else
    echo "  Corriendo prompt real: 'lista las primeras 3 funciones definidas en tests/fixtures/sample_config.sh'..."
    set +e
    live_out=$(agentic_loop_anthropic "Usa la tool read_file para leer tests/fixtures/sample_config.sh y dime los nombres de las primeras 3 funciones que se definen ahí. Responde sólo con los nombres." 2>&1)
    live_rc=$?
    set -e

    if [ "$live_rc" -eq 0 ]; then
        pass "agentic_loop_anthropic salió 0 en live"
    else
        fail "agentic_loop_anthropic salió $live_rc en live. Output: $live_out"
    fi

    # El LLM debió llamar read_file => ver al menos una de las funciones reales de config.sh.
    # Funciones presentes en tests/fixtures/sample_config.sh (referencia): init_config_directories,
    # detect_system_language, load_language, save_language, select_language.
    if echo "$live_out" | grep -qE '(init_config_directories|detect_system_language|load_language)'; then
        pass "respuesta menciona funciones reales de config.sh (=> read_file ejecutado y output usado)"
    else
        fail "respuesta NO menciona funciones reales — el LLM puede haber inventado. Output: $live_out"
    fi
fi

echo ""
echo "==============================="
echo "Resultado: $PASS pass, $FAIL fail"
echo "==============================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
