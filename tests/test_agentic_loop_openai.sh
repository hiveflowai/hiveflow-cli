#!/bin/bash
#
# Tests para lib/tool_calling.sh :: agentic_loop_openai (M1.4)
#
# Dos capas:
#   1) Unit tests sobre helpers `_openai_*` con fixtures JSON (offline, sin API).
#   2) Smoke test end-to-end contra /v1/chat/completions — sólo si OPENAI_API_KEY
#      (o $chatgpt_api_key del config legacy) está disponible. Si no, lo skipea.
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
# Fixtures: respuestas típicas del endpoint /v1/chat/completions
# =====================================================================
FIXTURE_TOOL_CALLS=$(cat <<'EOF'
{
  "id": "chatcmpl-001",
  "object": "chat.completion",
  "model": "gpt-4o-mini",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": null,
        "tool_calls": [
          {
            "id": "call_abc123",
            "type": "function",
            "function": {
              "name": "read_file",
              "arguments": "{\"path\":\"tests/fixtures/sample_config.sh\",\"limit\":50}"
            }
          }
        ]
      },
      "finish_reason": "tool_calls"
    }
  ]
}
EOF
)

FIXTURE_STOP=$(cat <<'EOF'
{
  "id": "chatcmpl-002",
  "object": "chat.completion",
  "model": "gpt-4o-mini",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Las funciones son: init_config_directories, detect_system_language, load_language."
      },
      "finish_reason": "stop"
    }
  ]
}
EOF
)

FIXTURE_API_ERROR=$(cat <<'EOF'
{"error": {"message": "Incorrect API key provided", "type": "invalid_request_error", "code": "invalid_api_key"}}
EOF
)

FIXTURE_MULTI_TOOL_CALLS=$(cat <<'EOF'
{
  "id": "chatcmpl-003",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": null,
        "tool_calls": [
          {"id": "call_1", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\":\"a.sh\"}"}},
          {"id": "call_2", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\":\"b.sh\"}"}}
        ]
      },
      "finish_reason": "tool_calls"
    }
  ]
}
EOF
)

echo "=== _openai_transform_tools"
tools_internal=$(get_all_tool_definitions_json)
tools_openai=$(_openai_transform_tools "$tools_internal")
if echo "$tools_openai" | jq -e '
    type == "array" and length >= 1 and
    .[0].type == "function" and
    .[0].function.name == "read_file" and
    (.[0].function.parameters | type == "object") and
    (.[0].function.parameters.properties.path | type == "object")
' >/dev/null; then
    pass "tool transform: shape OpenAI con function.parameters = input_schema"
else
    fail "tool transform shape inválido: $tools_openai"
fi

# input_schema NO debe aparecer (se renombró a parameters)
if echo "$tools_openai" | jq -e '.[0].function.input_schema' >/dev/null 2>&1; then
    fail "tool transform: input_schema fue copiado en vez de renombrado"
else
    pass "tool transform: input_schema removido (correcto)"
fi

echo "=== _openai_extract_text"
text_null=$(_openai_extract_text "$FIXTURE_TOOL_CALLS")
assert_eq "content null => string vacío" "" "$text_null"

text_stop=$(_openai_extract_text "$FIXTURE_STOP")
assert_contains "extrae texto de stop response" "Las funciones son" "$text_stop"

echo "=== _openai_extract_finish_reason"
fr1=$(_openai_extract_finish_reason "$FIXTURE_TOOL_CALLS")
assert_eq "finish_reason tool_calls" "tool_calls" "$fr1"

fr2=$(_openai_extract_finish_reason "$FIXTURE_STOP")
assert_eq "finish_reason stop" "stop" "$fr2"

fr3=$(_openai_extract_finish_reason '{"choices":[{}]}')
assert_eq "finish_reason ausente => unknown" "unknown" "$fr3"

echo "=== _openai_extract_tool_calls"
tc=$(_openai_extract_tool_calls "$FIXTURE_TOOL_CALLS")
tc_lines=$(echo "$tc" | grep -c .)
assert_eq "una sola línea de tool_call" "1" "$tc_lines"

# Separator es Unit Separator (0x1f), no TAB — @tsv corrompía multi-línea.
tc_id=$(printf '%s' "$tc"   | awk -F$'\x1f' '{print $1}')
tc_name=$(printf '%s' "$tc" | awk -F$'\x1f' '{print $2}')
tc_args=$(printf '%s' "$tc" | awk -F$'\x1f' '{print $3}')
assert_eq "tool_call id parseado" "call_abc123" "$tc_id"
assert_eq "tool_call name parseado" "read_file" "$tc_name"
if echo "$tc_args" | jq -e '.path == "tests/fixtures/sample_config.sh" and .limit == 50' >/dev/null; then
    pass "tool_call arguments parseado como JSON válido"
else
    fail "tool_call arguments no parseó como JSON esperado (got: $tc_args)"
fi

tc_multi=$(_openai_extract_tool_calls "$FIXTURE_MULTI_TOOL_CALLS")
multi_lines=$(echo "$tc_multi" | grep -c .)
assert_eq "dos líneas para dos tool_calls" "2" "$multi_lines"

tc_none=$(_openai_extract_tool_calls "$FIXTURE_STOP")
if [ -z "$tc_none" ]; then
    pass "stop response no tiene tool_calls"
else
    fail "stop response debió no tener tool_calls (got: $tc_none)"
fi

echo "=== _openai_is_api_error"
if _openai_is_api_error "$FIXTURE_API_ERROR"; then
    pass "detecta API error"
else
    fail "no detectó API error en fixture explícito"
fi

if _openai_is_api_error "$FIXTURE_STOP"; then
    fail "marcó respuesta normal como API error"
else
    pass "no marca respuesta normal como error"
fi

echo "=== _openai_build_payload"
messages_json='[{"role":"user","content":"hola"}]'
payload=$(_openai_build_payload "gpt-test" "$tools_openai" "$messages_json")
if echo "$payload" | jq -e '
    .model == "gpt-test" and
    (.messages | length) == 1 and
    (.tools | length) >= 1 and
    .tool_choice == "auto" and
    (has("max_tokens") | not)
' >/dev/null; then
    pass "payload shape OK (sin max_tokens)"
else
    fail "payload shape inválido: $payload"
fi

payload_mt=$(_openai_build_payload "gpt-test" "$tools_openai" "$messages_json" "512")
if echo "$payload_mt" | jq -e '.max_tokens == 512' >/dev/null; then
    pass "payload incluye max_tokens cuando se pasa"
else
    fail "payload max_tokens missing: $payload_mt"
fi

echo "=== _openai_append_assistant"
initial='[{"role":"user","content":"x"}]'
appended=$(_openai_append_assistant "$initial" "$FIXTURE_TOOL_CALLS")
if echo "$appended" | jq -e '
    length == 2 and
    .[1].role == "assistant" and
    (.[1].tool_calls | length) == 1 and
    .[1].tool_calls[0].id == "call_abc123"
' >/dev/null; then
    pass "assistant message apendido con tool_calls intactos"
else
    fail "assistant append falló: $appended"
fi

echo "=== _openai_append_tool_result"
with_tr=$(_openai_append_tool_result "$appended" "call_abc123" "contenido del archivo")
if echo "$with_tr" | jq -e '
    length == 3 and
    .[2].role == "tool" and
    .[2].tool_call_id == "call_abc123" and
    .[2].content == "contenido del archivo"
' >/dev/null; then
    pass "tool_result apendido como role=tool"
else
    fail "tool_result append falló: $with_tr"
fi

# Múltiples tool_results en secuencia
seq_msgs=$(_openai_append_tool_result "$with_tr" "call_2" "otro contenido")
if echo "$seq_msgs" | jq -e 'length == 4 and .[3].tool_call_id == "call_2"' >/dev/null; then
    pass "múltiples tool_results en secuencia"
else
    fail "secuencia de tool_results falló: $seq_msgs"
fi

echo "=== agentic_loop_openai: missing prompt"
set +e
err=$(agentic_loop_openai "" 2>&1)
rc=$?
set -e
assert_eq "exit 2 si prompt vacío" "2" "$rc"
assert_contains "mensaje 'missing prompt'" "missing prompt" "$err"

echo "=== agentic_loop_openai: key faltante"
set +e
no_key_out=$(
    unset OPENAI_API_KEY
    unset chatgpt_api_key
    agentic_loop_openai "hi" 2>&1
)
no_key_rc=$?
set -e
assert_eq "exit 1 sin api key" "1" "$no_key_rc"
assert_contains "mensaje 'OPENAI_API_KEY not set'" "OPENAI_API_KEY not set" "$no_key_out"

# =====================================================================
# Loop body tests — stub _openai_call_api con fixtures prerecorded.
# Cubre el control flow del while-loop (multi-turn, cap, errores, finish_reasons)
# sin tocar la red. Mismo patrón que test_agentic_loop_anthropic.sh: estado
# del mock backed por filesystem para sobrevivir el subshell de `$(...)`
# (un contador en variable bash queda atrapado en el subshell y el stub
# devuelve siempre fixtures[0]).
# =====================================================================
echo ""
echo "==============================="
echo "Loop body (mocked _openai_call_api)"
echo "==============================="

# Snapshot impl real + env. Se restauran antes del bloque live.
_SAVED_CALL_API_DEF=$(declare -f _openai_call_api)
_SAVED_OPENAI_KEY="${OPENAI_API_KEY:-}"
_SAVED_CHATGPT_KEY="${chatgpt_api_key:-}"
export OPENAI_API_KEY="test-stub-key-not-real"
unset chatgpt_api_key

_MOCK_STATE_DIR=$(mktemp -d -t agentic_mock_openai.XXXXXX)
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

# shellcheck disable=SC2317  # invocada indirectamente vía agentic_loop_openai
_openai_call_api() {
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

echo "=== 2-turn flow: tool_calls → tool message → stop"
_setup_mock_api "$FIXTURE_TOOL_CALLS" "$FIXTURE_STOP"
set +e
two_turn_out=$(agentic_loop_openai "lista funciones" 2>&1)
two_turn_rc=$?
set -e
assert_eq "exit 0 al completar 2 turnos" "0" "$two_turn_rc"
assert_eq "loop hizo 2 llamadas a la API" "2" "$(_mock_count)"
assert_contains "stdout incluye texto del stop turn" "Las funciones son" "$two_turn_out"
second_payload=$(_mock_captured 1)
# Threading OpenAI: el segundo payload debe traer 3 messages (user, assistant
# con tool_calls, tool con tool_call_id matching). Mantener el assistant
# verbatim es requisito para que el tool_call_id resuelva downstream.
if echo "$second_payload" | jq -e '
    .messages | length == 3 and
    .[1].role == "assistant" and (.[1].tool_calls | length) == 1 and .[1].tool_calls[0].id == "call_abc123" and
    .[2].role == "tool" and .[2].tool_call_id == "call_abc123"
' >/dev/null 2>&1; then
    pass "segundo payload threadea tool message con tool_call_id correcto"
else
    fail "threading incorrecto en segundo payload (roles: $(echo "$second_payload" | jq -c '.messages | map(.role)' 2>/dev/null))"
fi

echo "=== 2-turn flow con multi tool_calls: cada call_id genera su tool message"
FIXTURE_STOP_AFTER_MULTI='{"id":"chatcmpl-004","choices":[{"index":0,"message":{"role":"assistant","content":"listo"},"finish_reason":"stop"}]}'
_setup_mock_api "$FIXTURE_MULTI_TOOL_CALLS" "$FIXTURE_STOP_AFTER_MULTI"
set +e
multi_out=$(agentic_loop_openai "lee dos" 2>&1)
multi_rc=$?
set -e
assert_eq "multi tool_calls → exit 0 cuando 2do turno es stop" "0" "$multi_rc"
multi_second_payload=$(_mock_captured 1)
if echo "$multi_second_payload" | jq -e '
    .messages | length == 4 and
    .[2].role == "tool" and .[2].tool_call_id == "call_1" and
    .[3].role == "tool" and .[3].tool_call_id == "call_2"
' >/dev/null 2>&1; then
    pass "ambos tool_call_id reinyectados como tool messages individuales"
else
    fail "multi tool messages threading falló (got: $(echo "$multi_second_payload" | jq -c '.messages | map({role, tool_call_id})' 2>/dev/null))"
fi
: "$multi_out"

echo "=== API error en response → exit 1"
_setup_mock_api "$FIXTURE_API_ERROR"
set +e
api_err_out=$(agentic_loop_openai "x" 2>&1)
api_err_rc=$?
set -e
assert_eq "API error → exit 1" "1" "$api_err_rc"
assert_contains "stderr menciona 'API error'" "API error" "$api_err_out"

echo "=== finish_reason=length → exit 0"
FIXTURE_LENGTH='{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":"cortado"},"finish_reason":"length"}]}'
_setup_mock_api "$FIXTURE_LENGTH"
set +e
len_out=$(agentic_loop_openai "x" 2>&1)
len_rc=$?
set -e
assert_eq "length → exit 0" "0" "$len_rc"
assert_contains "stdout emite texto del turno" "cortado" "$len_out"

echo "=== finish_reason=content_filter → exit 0"
FIXTURE_CF='{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":"filtrado"},"finish_reason":"content_filter"}]}'
_setup_mock_api "$FIXTURE_CF"
set +e
cf_out=$(agentic_loop_openai "x" 2>&1)
cf_rc=$?
set -e
assert_eq "content_filter → exit 0" "0" "$cf_rc"
assert_contains "stdout emite texto del turno" "filtrado" "$cf_out"

echo "=== iteration cap (always tool_calls) → exit 1"
_SAVED_MAX_ITER="${TOOL_LOOP_MAX_ITERATIONS:-}"
export TOOL_LOOP_MAX_ITERATIONS=3
_setup_mock_api "$FIXTURE_TOOL_CALLS" "$FIXTURE_TOOL_CALLS" "$FIXTURE_TOOL_CALLS"
set +e
cap_out=$(agentic_loop_openai "x" 2>&1)
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

echo "=== finish_reason=tool_calls sin tool_calls parseables → exit 1"
FIXTURE_TC_EMPTY='{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":null},"finish_reason":"tool_calls"}]}'
_setup_mock_api "$FIXTURE_TC_EMPTY"
set +e
tce_out=$(agentic_loop_openai "x" 2>&1)
tce_rc=$?
set -e
assert_eq "tool_calls sin entradas → exit 1" "1" "$tce_rc"
assert_contains "stderr menciona 'no tool_calls parsed'" "no tool_calls parsed" "$tce_out"

echo "=== finish_reason desconocido → exit 1"
FIXTURE_WEIRD='{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":"weird"},"finish_reason":"refusal"}]}'
_setup_mock_api "$FIXTURE_WEIRD"
set +e
weird_out=$(agentic_loop_openai "x" 2>&1)
weird_rc=$?
set -e
assert_eq "finish_reason desconocido → exit 1" "1" "$weird_rc"
assert_contains "stderr menciona 'unexpected finish_reason'" "unexpected finish_reason" "$weird_out"

echo "=== tool dispatch error → content prefijado con 'ERROR:' reinyectado"
FIXTURE_TC_BADPATH='{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_bad","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"NONEXISTENT_FILE_xyz_for_iter10_test.txt\"}"}}]},"finish_reason":"tool_calls"}]}'
_setup_mock_api "$FIXTURE_TC_BADPATH" "$FIXTURE_STOP"
set +e
disp_err_out=$(agentic_loop_openai "x" 2>&1)
disp_err_rc=$?
set -e
assert_eq "loop sigue tras dispatch fail y termina 0" "0" "$disp_err_rc"
disp_second_payload=$(_mock_captured 1)
if echo "$disp_second_payload" | jq -e '
    .messages[] | select(.role == "tool" and .tool_call_id == "call_bad") | .content | startswith("ERROR:")
' >/dev/null 2>&1; then
    pass "content del tool message prefijado con 'ERROR:' tras dispatch failure"
else
    fail "tool message no contiene 'ERROR:' prefix (messages: $(echo "$disp_second_payload" | jq -c '.messages' 2>/dev/null))"
fi
: "$disp_err_out"

# Restaurar impl real + env antes del bloque live.
eval "$_SAVED_CALL_API_DEF"
unset _SAVED_CALL_API_DEF
if [ -n "$_SAVED_OPENAI_KEY" ]; then
    export OPENAI_API_KEY="$_SAVED_OPENAI_KEY"
else
    unset OPENAI_API_KEY
fi
if [ -n "$_SAVED_CHATGPT_KEY" ]; then
    # shellcheck disable=SC2034  # leído indirectamente por _openai_get_api_key
    chatgpt_api_key="$_SAVED_CHATGPT_KEY"
fi
unset _SAVED_OPENAI_KEY _SAVED_CHATGPT_KEY
rm -rf "$_MOCK_STATE_DIR"
trap - EXIT INT TERM

# =====================================================================
# Smoke test end-to-end (live) — gated por API key disponible.
# Acepta OPENAI_API_KEY del env o chatgpt_api_key del config legacy
# (~/.config/coder-cli/config.json sourceable).
# =====================================================================
echo ""
echo "==============================="
echo "Live E2E (OpenAI /v1/chat/completions)"
echo "==============================="

# Cargar config legacy si existe (define chatgpt_api_key como var de shell).
LEGACY_CFG="$HOME/.config/coder-cli/config.json"
if [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${chatgpt_api_key:-}" ] && [ -f "$LEGACY_CFG" ]; then
    # shellcheck source=/dev/null
    source "$LEGACY_CFG" 2>/dev/null || true
fi

if [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${chatgpt_api_key:-}" ]; then
    echo "  SKIP: no OPENAI_API_KEY ni chatgpt_api_key disponible — saltando smoke test live."
    echo "        (los unit tests pasaron; M1.4 requiere live verification antes de marcar done)"
else
    echo "  Corriendo prompt real: 'lista las primeras 3 funciones definidas en tests/fixtures/sample_config.sh'..."
    set +e
    live_out=$(agentic_loop_openai "Usa la tool read_file para leer tests/fixtures/sample_config.sh y dime los nombres de las primeras 3 funciones que se definen ahí. Responde sólo con los nombres." 2>&1)
    live_rc=$?
    set -e

    if [ "$live_rc" -eq 0 ]; then
        pass "agentic_loop_openai salió 0 en live"
    else
        fail "agentic_loop_openai salió $live_rc en live. Output: $live_out"
    fi

    # El LLM debió llamar read_file => ver al menos una función real de config.sh.
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
