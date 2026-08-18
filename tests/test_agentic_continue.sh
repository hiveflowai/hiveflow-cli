#!/bin/bash
#
# Tests para `agentic_loop_<provider>_continue` (P1.1b) — variantes multi-turn
# de los adapters Anthropic/OpenAI/Gemini que aceptan messages[] externos y
# devuelven el estado final vía la global CODER_AGENTIC_MESSAGES.
#
# Cubre, por provider:
#   - función definida + signature correcta
#   - input validation: empty / non-array / empty array → exit 2
#   - missing API key → exit 1 + CODER_AGENTIC_MESSAGES preserva input
#   - happy path: messages[] con user msg → end_turn/stop/STOP →
#     CODER_AGENTIC_MESSAGES contiene el assistant final apendido
#   - tool round-trip: 2 calls (tool_use → tool_result → terminal) →
#     CODER_AGENTIC_MESSAGES contiene 4 entries threaded correctamente
#   - multi-turn threading: output de call N usado como input de call N+1
#   - regresión: `agentic_loop_<provider>(prompt)` continúa funcionando
#
# Exit != 0 si cualquier check falla.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT"

# shellcheck source=../lib/agent/tool_calling.sh disable=SC1091
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

assert_jq() {
    local desc="$1" filter="$2" input="$3"
    if echo "$input" | jq -e "$filter" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc (filter='$filter' failed against: $input)"
    fi
}

# Captura stdout/stderr a tmpfiles SIN crear subshell, para que las globales
# que el callee modifica (notablemente CODER_AGENTIC_MESSAGES) propaguen al
# shell padre. Set globals: LAST_RC, LAST_OUT.
_TMPOUT=$(mktemp -t agentic_cont_stdout.XXXXXX)
_TMPERR=$(mktemp -t agentic_cont_stderr.XXXXXX)
LAST_RC=0
LAST_OUT=""

run_capture() {
    set +e
    "$@" >"$_TMPOUT" 2>"$_TMPERR"
    LAST_RC=$?
    set -e
    LAST_OUT="$(cat "$_TMPOUT")$(cat "$_TMPERR")"
}

# Sólo necesitamos un tool registrado para que get_all_tool_definitions_json
# emita algo. read_file es read-only y no requiere permisos.
register_tool read_file >/dev/null

# Mock state: filesystem-backed para sobrevivir el subshell de $(...)
_MOCK_STATE_DIR=$(mktemp -d -t agentic_cont_mock.XXXXXX)
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

# Stubs comunes para los 3 _<provider>_call_api. Cada uno lee el mismo
# state dir secuencialmente.
# shellcheck disable=SC2317  # invocadas indirectamente vía agentic_loop_*_continue
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

# shellcheck disable=SC2317
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

# Gemini no aísla `_gemini_call_api`; el adapter llama curl inline. Para mockear
# necesitamos overridear curl en el shell del test — más invasivo. Sustituimos
# con stub local mediante function wrapping.
# shellcheck disable=SC2317
curl() {
    # Sólo interceptamos POSTs a $GEMINI_BASE_URL. Cualquier otro uso de curl
    # en el test (no esperado) falla loud.
    local found_url=""
    local payload=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -d) payload="$2"; shift 2 ;;
            -X|-H) shift 2 ;;
            -sS) shift ;;
            *)
                if [[ "$1" == http*://* ]]; then
                    found_url="$1"
                fi
                shift
                ;;
        esac
    done

    if [ -z "$found_url" ]; then
        echo "stub curl: no URL detected" >&2
        return 1
    fi

    local count next
    count=$(cat "$_MOCK_STATE_DIR/count")
    printf '%s' "$payload" > "$_MOCK_STATE_DIR/captured/$count"
    next=$((count + 1))
    echo "$next" > "$_MOCK_STATE_DIR/count"
    if [ -f "$_MOCK_STATE_DIR/fixtures/$count" ]; then
        cat "$_MOCK_STATE_DIR/fixtures/$count"
        return 0
    fi
    echo "stub curl: out of fixtures after $next call(s)" >&2
    return 1
}

# =====================================================================
# Fixtures comunes
# =====================================================================
ANTHROPIC_FIX_TOOL_USE=$(cat <<'EOF'
{
  "id": "msg_01",
  "type": "message",
  "role": "assistant",
  "model": "claude-haiku-4-5-20251001",
  "content": [
    {"type": "text", "text": "Voy a leer config.sh."},
    {"type": "tool_use", "id": "toolu_01", "name": "read_file", "input": {"path": "tests/fixtures/sample_config.sh", "limit": 30}}
  ],
  "stop_reason": "tool_use"
}
EOF
)

ANTHROPIC_FIX_END=$(cat <<'EOF'
{
  "id": "msg_02",
  "type": "message",
  "role": "assistant",
  "model": "claude-haiku-4-5-20251001",
  "content": [{"type": "text", "text": "Funciones encontradas: foo, bar, baz."}],
  "stop_reason": "end_turn"
}
EOF
)

OPENAI_FIX_TOOL_CALL=$(cat <<'EOF'
{
  "id": "chatcmpl-01",
  "object": "chat.completion",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "Voy a leer config.sh.",
      "tool_calls": [{
        "id": "call_01",
        "type": "function",
        "function": {"name": "read_file", "arguments": "{\"path\": \"tests/fixtures/sample_config.sh\", \"limit\": 30}"}
      }]
    },
    "finish_reason": "tool_calls"
  }]
}
EOF
)

OPENAI_FIX_END=$(cat <<'EOF'
{
  "id": "chatcmpl-02",
  "object": "chat.completion",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "Funciones encontradas: foo, bar, baz."},
    "finish_reason": "stop"
  }]
}
EOF
)

GEMINI_FIX_FCALL=$(cat <<'EOF'
{
  "candidates": [{
    "content": {
      "role": "model",
      "parts": [
        {"text": "Voy a leer config.sh."},
        {"functionCall": {"name": "read_file", "args": {"path": "tests/fixtures/sample_config.sh", "limit": 30}}}
      ]
    },
    "finishReason": "STOP"
  }]
}
EOF
)

GEMINI_FIX_END=$(cat <<'EOF'
{
  "candidates": [{
    "content": {
      "role": "model",
      "parts": [{"text": "Funciones encontradas: foo, bar, baz."}]
    },
    "finishReason": "STOP"
  }]
}
EOF
)

# =====================================================================
# Setup global: stub keys + state dir
# =====================================================================
_SAVED_ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"
_SAVED_OPENAI_KEY="${OPENAI_API_KEY:-}"
_SAVED_GEMINI_KEY="${GEMINI_API_KEY:-}"
export ANTHROPIC_API_KEY="test-anthropic-stub"
export OPENAI_API_KEY="test-openai-stub"
export GEMINI_API_KEY="test-gemini-stub"

# =====================================================================
# ANTHROPIC: agentic_loop_anthropic_continue
# =====================================================================
echo "==============================="
echo "agentic_loop_anthropic_continue"
echo "==============================="

echo "=== función definida"
if declare -f agentic_loop_anthropic_continue >/dev/null; then
    pass "agentic_loop_anthropic_continue está definida"
else
    fail "agentic_loop_anthropic_continue NO está definida"
fi

echo "=== input validation: messages vacío"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_anthropic_continue ""
assert_eq "messages vacío → exit 2" "2" "$LAST_RC"
assert_contains "stderr menciona 'missing messages'" "missing messages" "$LAST_OUT"
assert_eq "CODER_AGENTIC_MESSAGES reset a []" "[]" "$CODER_AGENTIC_MESSAGES"

echo "=== input validation: no es JSON array"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_anthropic_continue '{"role":"user"}'
assert_eq "non-array → exit 2" "2" "$LAST_RC"
assert_contains "stderr menciona 'non-empty JSON array'" "non-empty JSON array" "$LAST_OUT"

echo "=== input validation: array vacío"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_anthropic_continue '[]'
assert_eq "array vacío → exit 2" "2" "$LAST_RC"

echo "=== missing API key → exit 1 + estado preservado"
input='[{"role":"user","content":"hola"}]'
unset ANTHROPIC_API_KEY
unset claude_api_key
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_anthropic_continue "$input"
export ANTHROPIC_API_KEY="test-anthropic-stub"
assert_eq "missing key → exit 1" "1" "$LAST_RC"
assert_eq "CODER_AGENTIC_MESSAGES == input al fallar por key" "$input" "$CODER_AGENTIC_MESSAGES"
assert_contains "stderr menciona 'ANTHROPIC_API_KEY not set'" "ANTHROPIC_API_KEY not set" "$LAST_OUT"

echo "=== happy path: end_turn directo, sin tools"
_setup_mock_api "$ANTHROPIC_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_anthropic_continue '[{"role":"user","content":"hola"}]'
assert_eq "end_turn directo → exit 0" "0" "$LAST_RC"
assert_contains "stdout emite el texto del modelo" "Funciones encontradas" "$LAST_OUT"
assert_jq "CODER_AGENTIC_MESSAGES length == 2 (user + assistant)" \
    'length == 2 and .[0].role == "user" and .[1].role == "assistant"' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "último assistant tiene content[0].text con la respuesta" \
    '.[1].content[0].type == "text" and (.[1].content[0].text | contains("Funciones encontradas"))' \
    "$CODER_AGENTIC_MESSAGES"

echo "=== happy path: 2-turn tool_use → tool_result → end_turn"
_setup_mock_api "$ANTHROPIC_FIX_TOOL_USE" "$ANTHROPIC_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_anthropic_continue '[{"role":"user","content":"lista funciones de tests/fixtures/sample_config.sh"}]'
assert_eq "2-turn → exit 0" "0" "$LAST_RC"
assert_eq "loop hizo 2 llamadas" "2" "$(_mock_count)"
assert_jq "CODER_AGENTIC_MESSAGES length == 4 (user + assistant_tu + user_tr + assistant_end)" \
    'length == 4 and .[0].role=="user" and .[1].role=="assistant" and .[2].role=="user" and .[3].role=="assistant"' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "msg[1] contiene tool_use block" \
    '.[1].content | map(select(.type=="tool_use")) | length == 1' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "msg[2] contiene tool_result block con id matched" \
    '.[2].content[0].type == "tool_result" and .[2].content[0].tool_use_id == "toolu_01"' \
    "$CODER_AGENTIC_MESSAGES"

echo "=== multi-turn threading: feed back into _continue"
prior_state="$CODER_AGENTIC_MESSAGES"
next_state=$(jq -nc --argjson msgs "$prior_state" '$msgs + [{role:"user", content:"y los nombres en orden alfabético?"}]')
ANTHROPIC_FIX_END2='{"id":"msg_03","type":"message","role":"assistant","model":"x","content":[{"type":"text","text":"Alfabético: bar, baz, foo."}],"stop_reason":"end_turn"}'
_setup_mock_api "$ANTHROPIC_FIX_END2"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_anthropic_continue "$next_state"
assert_eq "segundo turno → exit 0" "0" "$LAST_RC"
assert_contains "stdout emite respuesta del segundo turno" "Alfabético" "$LAST_OUT"
assert_jq "CODER_AGENTIC_MESSAGES length == 6 tras segundo turn" \
    'length == 6' \
    "$CODER_AGENTIC_MESSAGES"
# El payload enviado al modelo debe incluir el historial completo.
second_payload=$(_mock_captured 0)
assert_jq "payload.messages length == 5 (history sin último assistant)" \
    '.messages | length == 5' \
    "$second_payload"

echo "=== P2.parallel-2: N tool_uses en un turno preservan orden (sequential, CODER_TOOL_PARALLEL=1)"
# Fixture con 3 read_file en una sola respuesta → debe producir 3 tool_results
# en el mismo orden (toolu_A, toolu_B, toolu_C) tanto en path sequential como parallel.
ANTHROPIC_FIX_3_TUS=$(cat <<'EOF'
{
  "id": "msg_parallel",
  "type": "message",
  "role": "assistant",
  "model": "claude-haiku-4-5-20251001",
  "content": [
    {"type": "text", "text": "Voy a leer tres archivos."},
    {"type": "tool_use", "id": "toolu_A", "name": "read_file", "input": {"path": "tests/fixtures/sample_config.sh", "limit": 2}},
    {"type": "tool_use", "id": "toolu_B", "name": "read_file", "input": {"path": "lib/agent/tool_calling.sh", "limit": 2}},
    {"type": "tool_use", "id": "toolu_C", "name": "read_file", "input": {"path": "README.md", "limit": 2}}
  ],
  "stop_reason": "tool_use"
}
EOF
)

_SAVED_PARALLEL="${CODER_TOOL_PARALLEL:-}"

export CODER_TOOL_PARALLEL=1
_setup_mock_api "$ANTHROPIC_FIX_3_TUS" "$ANTHROPIC_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_anthropic_continue '[{"role":"user","content":"lee tres"}]'
assert_eq "sequential 3-tu → exit 0" "0" "$LAST_RC"
assert_jq "sequential: msg[2] tiene 3 tool_results" \
    '.[2].content | length == 3 and all(.[]; .type == "tool_result")' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "sequential: orden preservado (A,B,C)" \
    '[.[2].content[].tool_use_id] == ["toolu_A","toolu_B","toolu_C"]' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "sequential: ningún is_error (todos los paths existen)" \
    '[.[2].content[].is_error] == [false,false,false]' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "sequential: cada content no vacío" \
    '[.[2].content[].content | length > 0] | all' \
    "$CODER_AGENTIC_MESSAGES"

echo "=== P2.parallel-2: N tool_uses en un turno preservan orden (parallel, CODER_TOOL_PARALLEL=4)"
export CODER_TOOL_PARALLEL=4
_setup_mock_api "$ANTHROPIC_FIX_3_TUS" "$ANTHROPIC_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_anthropic_continue '[{"role":"user","content":"lee tres en paralelo"}]'
assert_eq "parallel 3-tu → exit 0" "0" "$LAST_RC"
assert_jq "parallel: msg[2] tiene 3 tool_results" \
    '.[2].content | length == 3' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "parallel: orden preservado (A,B,C)" \
    '[.[2].content[].tool_use_id] == ["toolu_A","toolu_B","toolu_C"]' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "parallel: ningún is_error" \
    '[.[2].content[].is_error] == [false,false,false]' \
    "$CODER_AGENTIC_MESSAGES"

echo "=== P2.parallel-2: mixed success/failure preserva is_error por job (sequential)"
ANTHROPIC_FIX_MIXED_TUS=$(cat <<'EOF'
{
  "id": "msg_mixed",
  "type": "message",
  "role": "assistant",
  "model": "claude-haiku-4-5-20251001",
  "content": [
    {"type": "tool_use", "id": "toolu_OK1", "name": "read_file", "input": {"path": "tests/fixtures/sample_config.sh", "limit": 1}},
    {"type": "tool_use", "id": "toolu_BAD", "name": "read_file", "input": {"path": "NONEXISTENT_xxx_yyy_zzz.txt"}},
    {"type": "tool_use", "id": "toolu_OK2", "name": "read_file", "input": {"path": "README.md", "limit": 1}}
  ],
  "stop_reason": "tool_use"
}
EOF
)
export CODER_TOOL_PARALLEL=1
_setup_mock_api "$ANTHROPIC_FIX_MIXED_TUS" "$ANTHROPIC_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_anthropic_continue '[{"role":"user","content":"mixed"}]'
assert_eq "mixed sequential → exit 0" "0" "$LAST_RC"
assert_jq "mixed sequential: is_error=[false,true,false]" \
    '[.[2].content[].is_error] == [false,true,false]' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "mixed sequential: orden preservado (OK1, BAD, OK2)" \
    '[.[2].content[].tool_use_id] == ["toolu_OK1","toolu_BAD","toolu_OK2"]' \
    "$CODER_AGENTIC_MESSAGES"

echo "=== P2.parallel-2: mixed success/failure preserva is_error por job (parallel)"
export CODER_TOOL_PARALLEL=3
_setup_mock_api "$ANTHROPIC_FIX_MIXED_TUS" "$ANTHROPIC_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_anthropic_continue '[{"role":"user","content":"mixed parallel"}]'
assert_eq "mixed parallel → exit 0" "0" "$LAST_RC"
assert_jq "mixed parallel: is_error=[false,true,false]" \
    '[.[2].content[].is_error] == [false,true,false]' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "mixed parallel: orden preservado" \
    '[.[2].content[].tool_use_id] == ["toolu_OK1","toolu_BAD","toolu_OK2"]' \
    "$CODER_AGENTIC_MESSAGES"

# Restore CODER_TOOL_PARALLEL
if [ -n "$_SAVED_PARALLEL" ]; then
    export CODER_TOOL_PARALLEL="$_SAVED_PARALLEL"
else
    unset CODER_TOOL_PARALLEL
fi

echo "=== regression: agentic_loop_anthropic(prompt) sigue funcionando"
_setup_mock_api "$ANTHROPIC_FIX_END"
run_capture agentic_loop_anthropic "hola"
assert_eq "wrapper one-shot → exit 0" "0" "$LAST_RC"
assert_contains "stdout emite texto del modelo" "Funciones encontradas" "$LAST_OUT"

echo "=== regression: agentic_loop_anthropic con prompt vacío → exit 2"
run_capture agentic_loop_anthropic ""
assert_eq "prompt vacío → exit 2" "2" "$LAST_RC"
assert_contains "stderr menciona 'missing prompt'" "missing prompt" "$LAST_OUT"

# =====================================================================
# OPENAI: agentic_loop_openai_continue
# =====================================================================
echo ""
echo "==============================="
echo "agentic_loop_openai_continue"
echo "==============================="

echo "=== función definida"
if declare -f agentic_loop_openai_continue >/dev/null; then
    pass "agentic_loop_openai_continue está definida"
else
    fail "agentic_loop_openai_continue NO está definida"
fi

echo "=== input validation: vacío"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_openai_continue ""
assert_eq "vacío → exit 2" "2" "$LAST_RC"
assert_contains "stderr menciona 'missing messages'" "missing messages" "$LAST_OUT"

echo "=== input validation: non-array"
run_capture agentic_loop_openai_continue '"string"'
assert_eq "non-array → exit 2" "2" "$LAST_RC"

echo "=== missing API key → exit 1 + estado preservado"
input='[{"role":"user","content":"hola"}]'
unset OPENAI_API_KEY
_SAVED_CHATGPT_KEY="${chatgpt_api_key:-}"
chatgpt_api_key=""
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_openai_continue "$input"
chatgpt_api_key="$_SAVED_CHATGPT_KEY"
export OPENAI_API_KEY="test-openai-stub"
assert_eq "missing key → exit 1" "1" "$LAST_RC"
assert_eq "CODER_AGENTIC_MESSAGES preserva input" "$input" "$CODER_AGENTIC_MESSAGES"

echo "=== happy path: stop directo, sin tools"
_setup_mock_api "$OPENAI_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_openai_continue '[{"role":"user","content":"hola"}]'
assert_eq "stop directo → exit 0" "0" "$LAST_RC"
assert_contains "stdout emite texto del modelo" "Funciones encontradas" "$LAST_OUT"
assert_jq "CODER_AGENTIC_MESSAGES length == 2" \
    'length == 2 and .[0].role=="user" and .[1].role=="assistant"' \
    "$CODER_AGENTIC_MESSAGES"

echo "=== happy path: 2-turn tool_calls → tool result → stop"
_setup_mock_api "$OPENAI_FIX_TOOL_CALL" "$OPENAI_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_openai_continue '[{"role":"user","content":"lista funciones"}]'
assert_eq "2-turn → exit 0" "0" "$LAST_RC"
assert_eq "loop hizo 2 llamadas" "2" "$(_mock_count)"
assert_jq "CODER_AGENTIC_MESSAGES length == 4" \
    'length == 4 and .[0].role=="user" and .[1].role=="assistant" and .[2].role=="tool" and .[3].role=="assistant"' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "msg[2].tool_call_id matched a 'call_01'" \
    '.[2].tool_call_id == "call_01"' \
    "$CODER_AGENTIC_MESSAGES"

echo "=== multi-turn threading"
prior_state="$CODER_AGENTIC_MESSAGES"
next_state=$(jq -nc --argjson msgs "$prior_state" '$msgs + [{role:"user", content:"y en orden alfabético?"}]')
OPENAI_FIX_END2='{"id":"chatcmpl-03","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"Alfabético: bar, baz, foo."},"finish_reason":"stop"}]}'
_setup_mock_api "$OPENAI_FIX_END2"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_openai_continue "$next_state"
assert_eq "segundo turno → exit 0" "0" "$LAST_RC"
assert_contains "stdout emite respuesta del segundo turno" "Alfabético" "$LAST_OUT"
assert_jq "CODER_AGENTIC_MESSAGES length == 6" 'length == 6' "$CODER_AGENTIC_MESSAGES"

echo "=== regression: agentic_loop_openai(prompt) sigue funcionando"
_setup_mock_api "$OPENAI_FIX_END"
run_capture agentic_loop_openai "hola"
assert_eq "wrapper one-shot → exit 0" "0" "$LAST_RC"
assert_contains "stdout emite texto del modelo" "Funciones encontradas" "$LAST_OUT"

echo "=== P2.parallel-3: N tool_calls en un turno preservan orden (sequential, CODER_TOOL_PARALLEL=1)"
# Fixture con 3 read_file en una sola respuesta → debe producir 3 mensajes
# role=tool con tool_call_id en orden (call_A, call_B, call_C) en sequential y parallel.
OPENAI_FIX_3_TCS=$(cat <<'EOF'
{
  "id": "chatcmpl-parallel",
  "object": "chat.completion",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "Voy a leer tres archivos.",
      "tool_calls": [
        {"id": "call_A", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\": \"tests/fixtures/sample_config.sh\", \"limit\": 2}"}},
        {"id": "call_B", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\": \"lib/agent/tool_calling.sh\", \"limit\": 2}"}},
        {"id": "call_C", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\": \"README.md\", \"limit\": 2}"}}
      ]
    },
    "finish_reason": "tool_calls"
  }]
}
EOF
)

_SAVED_PARALLEL_OAI="${CODER_TOOL_PARALLEL:-}"

export CODER_TOOL_PARALLEL=1
_setup_mock_api "$OPENAI_FIX_3_TCS" "$OPENAI_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_openai_continue '[{"role":"user","content":"lee tres"}]'
assert_eq "sequential 3-tc → exit 0" "0" "$LAST_RC"
assert_jq "sequential: 3 role=tool messages, en orden A,B,C" \
    '[.[] | select(.role=="tool") | .tool_call_id] == ["call_A","call_B","call_C"]' \
    "$CODER_AGENTIC_MESSAGES"
# user + assistant_tc + 3 tool + assistant_end = 6
assert_jq "sequential: total length == 6 (user + assistant_tc + 3 tool + assistant_end)" \
    'length == 6 and .[0].role=="user" and .[1].role=="assistant" and .[2].role=="tool" and .[3].role=="tool" and .[4].role=="tool" and .[5].role=="assistant"' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "sequential: ningún content empieza con 'ERROR:'" \
    '[.[] | select(.role=="tool") | .content | startswith("ERROR:")] == [false,false,false]' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "sequential: cada content no vacío" \
    '[.[] | select(.role=="tool") | .content | length > 0] | all' \
    "$CODER_AGENTIC_MESSAGES"

echo "=== P2.parallel-3: N tool_calls en un turno preservan orden (parallel, CODER_TOOL_PARALLEL=4)"
export CODER_TOOL_PARALLEL=4
_setup_mock_api "$OPENAI_FIX_3_TCS" "$OPENAI_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_openai_continue '[{"role":"user","content":"lee tres en paralelo"}]'
assert_eq "parallel 3-tc → exit 0" "0" "$LAST_RC"
assert_jq "parallel: orden preservado A,B,C" \
    '[.[] | select(.role=="tool") | .tool_call_id] == ["call_A","call_B","call_C"]' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "parallel: ningún ERROR: prefix" \
    '[.[] | select(.role=="tool") | .content | startswith("ERROR:")] == [false,false,false]' \
    "$CODER_AGENTIC_MESSAGES"

echo "=== P2.parallel-3: mixed success/failure preserva ERROR: prefix por job (sequential)"
OPENAI_FIX_MIXED_TCS=$(cat <<'EOF'
{
  "id": "chatcmpl-mixed",
  "object": "chat.completion",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": null,
      "tool_calls": [
        {"id": "call_OK1", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\": \"tests/fixtures/sample_config.sh\", \"limit\": 1}"}},
        {"id": "call_BAD", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\": \"NONEXISTENT_xxx_yyy_zzz.txt\"}"}},
        {"id": "call_OK2", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\": \"README.md\", \"limit\": 1}"}}
      ]
    },
    "finish_reason": "tool_calls"
  }]
}
EOF
)
export CODER_TOOL_PARALLEL=1
_setup_mock_api "$OPENAI_FIX_MIXED_TCS" "$OPENAI_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_openai_continue '[{"role":"user","content":"mixed"}]'
assert_eq "mixed sequential → exit 0" "0" "$LAST_RC"
assert_jq "mixed sequential: ERROR: prefix solo en BAD" \
    '[.[] | select(.role=="tool") | .content | startswith("ERROR:")] == [false,true,false]' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "mixed sequential: orden preservado (OK1, BAD, OK2)" \
    '[.[] | select(.role=="tool") | .tool_call_id] == ["call_OK1","call_BAD","call_OK2"]' \
    "$CODER_AGENTIC_MESSAGES"

echo "=== P2.parallel-3: mixed success/failure preserva ERROR: prefix por job (parallel)"
export CODER_TOOL_PARALLEL=3
_setup_mock_api "$OPENAI_FIX_MIXED_TCS" "$OPENAI_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_openai_continue '[{"role":"user","content":"mixed parallel"}]'
assert_eq "mixed parallel → exit 0" "0" "$LAST_RC"
assert_jq "mixed parallel: ERROR: prefix solo en BAD" \
    '[.[] | select(.role=="tool") | .content | startswith("ERROR:")] == [false,true,false]' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "mixed parallel: orden preservado" \
    '[.[] | select(.role=="tool") | .tool_call_id] == ["call_OK1","call_BAD","call_OK2"]' \
    "$CODER_AGENTIC_MESSAGES"

# Restore CODER_TOOL_PARALLEL
if [ -n "$_SAVED_PARALLEL_OAI" ]; then
    export CODER_TOOL_PARALLEL="$_SAVED_PARALLEL_OAI"
else
    unset CODER_TOOL_PARALLEL
fi

# =====================================================================
# GEMINI: agentic_loop_gemini_continue
# =====================================================================
echo ""
echo "==============================="
echo "agentic_loop_gemini_continue"
echo "==============================="

echo "=== función definida"
if declare -f agentic_loop_gemini_continue >/dev/null; then
    pass "agentic_loop_gemini_continue está definida"
else
    fail "agentic_loop_gemini_continue NO está definida"
fi

echo "=== input validation: vacío"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_gemini_continue ""
assert_eq "vacío → exit 2" "2" "$LAST_RC"
assert_contains "stderr menciona 'missing contents'" "missing contents" "$LAST_OUT"

echo "=== input validation: non-array"
run_capture agentic_loop_gemini_continue 'null'
assert_eq "non-array → exit 2" "2" "$LAST_RC"

echo "=== missing API key → exit 1 + estado preservado"
input='[{"role":"user","parts":[{"text":"hola"}]}]'
unset GEMINI_API_KEY
_SAVED_GEMINI_LEGACY="${gemini_api_key:-}"
gemini_api_key=""
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_gemini_continue "$input"
gemini_api_key="$_SAVED_GEMINI_LEGACY"
export GEMINI_API_KEY="test-gemini-stub"
assert_eq "missing key → exit 1" "1" "$LAST_RC"
assert_eq "CODER_AGENTIC_MESSAGES preserva input" "$input" "$CODER_AGENTIC_MESSAGES"

echo "=== happy path: STOP sin function calls"
_setup_mock_api "$GEMINI_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_gemini_continue '[{"role":"user","parts":[{"text":"hola"}]}]'
assert_eq "STOP directo → exit 0" "0" "$LAST_RC"
assert_contains "stdout emite texto del modelo" "Funciones encontradas" "$LAST_OUT"
assert_jq "CODER_AGENTIC_MESSAGES length == 2 (user + model)" \
    'length == 2 and .[0].role=="user" and .[1].role=="model"' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "último model tiene parts[0].text con la respuesta" \
    '.[1].parts[0].text | contains("Funciones encontradas")' \
    "$CODER_AGENTIC_MESSAGES"

echo "=== happy path: 2-turn functionCall → functionResponse → STOP"
_setup_mock_api "$GEMINI_FIX_FCALL" "$GEMINI_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_gemini_continue '[{"role":"user","parts":[{"text":"lista funciones"}]}]'
assert_eq "2-turn → exit 0" "0" "$LAST_RC"
assert_eq "loop hizo 2 llamadas" "2" "$(_mock_count)"
assert_jq "CODER_AGENTIC_MESSAGES length == 4" \
    'length == 4 and .[0].role=="user" and .[1].role=="model" and .[2].role=="user" and .[3].role=="model"' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "msg[1] tiene part functionCall" \
    '.[1].parts | map(select(.functionCall != null)) | length == 1' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "msg[2] tiene part functionResponse con name=read_file" \
    '.[2].parts[0].functionResponse.name == "read_file"' \
    "$CODER_AGENTIC_MESSAGES"

echo "=== multi-turn threading"
prior_state="$CODER_AGENTIC_MESSAGES"
next_state=$(jq -nc --argjson msgs "$prior_state" '$msgs + [{role:"user", parts:[{text:"y en orden alfabético?"}]}]')
GEMINI_FIX_END2='{"candidates":[{"content":{"role":"model","parts":[{"text":"Alfabético: bar, baz, foo."}]},"finishReason":"STOP"}]}'
_setup_mock_api "$GEMINI_FIX_END2"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_gemini_continue "$next_state"
assert_eq "segundo turno → exit 0" "0" "$LAST_RC"
assert_contains "stdout emite respuesta del segundo turno" "Alfabético" "$LAST_OUT"
assert_jq "CODER_AGENTIC_MESSAGES length == 6" 'length == 6' "$CODER_AGENTIC_MESSAGES"

echo "=== regression: agentic_loop_gemini(prompt) sigue funcionando"
_setup_mock_api "$GEMINI_FIX_END"
run_capture agentic_loop_gemini "hola"
assert_eq "wrapper one-shot → exit 0" "0" "$LAST_RC"
assert_contains "stdout emite texto del modelo" "Funciones encontradas" "$LAST_OUT"

echo "=== P2.parallel-4: N functionCalls en un turno preservan orden (sequential, CODER_TOOL_PARALLEL=1)"
# Fixture con 3 read_file en una sola respuesta → debe producir 3 functionResponse
# parts en el mismo orden (paths A, B, C en parts[].functionResponse.response.content).
# Gemini no tiene tool_call_id; el matching es por orden de aparición.
GEMINI_FIX_3_FCS=$(cat <<'EOF'
{
  "candidates": [{
    "content": {
      "role": "model",
      "parts": [
        {"text": "Voy a leer tres archivos."},
        {"functionCall": {"name": "read_file", "args": {"path": "tests/fixtures/sample_config.sh", "limit": 4}}},
        {"functionCall": {"name": "read_file", "args": {"path": "lib/agent/tool_calling.sh", "limit": 4}}},
        {"functionCall": {"name": "read_file", "args": {"path": "README.md", "limit": 4}}}
      ]
    },
    "finishReason": "STOP"
  }]
}
EOF
)

_SAVED_PARALLEL_GEM="${CODER_TOOL_PARALLEL:-}"

export CODER_TOOL_PARALLEL=1
_setup_mock_api "$GEMINI_FIX_3_FCS" "$GEMINI_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_gemini_continue '[{"role":"user","parts":[{"text":"lee tres"}]}]'
assert_eq "sequential 3-fc → exit 0" "0" "$LAST_RC"
# user(0) + model_fc(1) + user_fr(2) + model_end(3) = 4
assert_jq "sequential: length == 4 (user + model_fc + user_fr + model_end)" \
    'length == 4 and .[0].role=="user" and .[1].role=="model" and .[2].role=="user" and .[3].role=="model"' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "sequential: msg[2] tiene 3 functionResponse parts" \
    '.[2].parts | length == 3 and all(.[]; .functionResponse != null)' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "sequential: orden preservado por nombre de cada call (los 3 son read_file)" \
    '[.[2].parts[].functionResponse.name] == ["read_file","read_file","read_file"]' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "sequential: ningún content empieza con 'ERROR:'" \
    '[.[2].parts[].functionResponse.response.content | startswith("ERROR:")] == [false,false,false]' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "sequential: cada content no vacío" \
    '[.[2].parts[].functionResponse.response.content | length > 0] | all' \
    "$CODER_AGENTIC_MESSAGES"

# Verificación fuerte de orden por contenido: el content del fr en posición k
# debe corresponder al fc en posición k. config.sh contiene "CONFIGURACIÓN"
# (header del módulo legacy en línea 4); tool_calling.sh contiene "TOOL CALLING";
# README.md contiene "Asis-coder". El order de input ↔ order de output debe
# coincidir porque _dispatch_tools_parallel preserva orden estable.
assert_jq "sequential: parts[0] (tests/fixtures/sample_config.sh) → content menciona CONFIGURACIÓN" \
    '.[2].parts[0].functionResponse.response.content | contains("CONFIGURACIÓN")' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "sequential: parts[1] (lib/agent/tool_calling.sh) → content menciona TOOL CALLING" \
    '.[2].parts[1].functionResponse.response.content | contains("TOOL CALLING")' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "sequential: parts[2] (README.md) → content menciona Hiveflow" \
    '.[2].parts[2].functionResponse.response.content | contains("Hiveflow")' \
    "$CODER_AGENTIC_MESSAGES"

echo "=== P2.parallel-4: N functionCalls en un turno preservan orden (parallel, CODER_TOOL_PARALLEL=4)"
export CODER_TOOL_PARALLEL=4
_setup_mock_api "$GEMINI_FIX_3_FCS" "$GEMINI_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_gemini_continue '[{"role":"user","parts":[{"text":"lee tres en paralelo"}]}]'
assert_eq "parallel 3-fc → exit 0" "0" "$LAST_RC"
assert_jq "parallel: msg[2] tiene 3 functionResponse parts" \
    '.[2].parts | length == 3' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "parallel: 3 nombres read_file" \
    '[.[2].parts[].functionResponse.name] == ["read_file","read_file","read_file"]' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "parallel: ningún ERROR: prefix" \
    '[.[2].parts[].functionResponse.response.content | startswith("ERROR:")] == [false,false,false]' \
    "$CODER_AGENTIC_MESSAGES"
# Orden estable bajo paralelismo: verificamos path→content mapping (mismo
# patrón que sequential). Si el helper devolviese resultados out-of-order,
# uno de estos 3 contains() fallaría.
assert_jq "parallel: parts[0] (tests/fixtures/sample_config.sh) → content menciona CONFIGURACIÓN" \
    '.[2].parts[0].functionResponse.response.content | contains("CONFIGURACIÓN")' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "parallel: parts[1] (lib/agent/tool_calling.sh) → content menciona TOOL CALLING" \
    '.[2].parts[1].functionResponse.response.content | contains("TOOL CALLING")' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "parallel: parts[2] (README.md) → content menciona Hiveflow" \
    '.[2].parts[2].functionResponse.response.content | contains("Hiveflow")' \
    "$CODER_AGENTIC_MESSAGES"

echo "=== P2.parallel-4: mixed success/failure preserva ERROR: prefix por job (sequential)"
# call middle apunta a path inexistente → read_file falla → rc!=0 → prefix ERROR:.
# Names mezclados (read_file, write_file, read_file) para validar que la lookup
# por idx recupera el nombre correcto incluso bajo dispatch en orden distinto.
GEMINI_FIX_MIXED_FCS=$(cat <<'EOF'
{
  "candidates": [{
    "content": {
      "role": "model",
      "parts": [
        {"functionCall": {"name": "read_file", "args": {"path": "tests/fixtures/sample_config.sh", "limit": 1}}},
        {"functionCall": {"name": "read_file", "args": {"path": "NONEXISTENT_xxx_yyy_zzz.txt"}}},
        {"functionCall": {"name": "read_file", "args": {"path": "README.md", "limit": 1}}}
      ]
    },
    "finishReason": "STOP"
  }]
}
EOF
)
export CODER_TOOL_PARALLEL=1
_setup_mock_api "$GEMINI_FIX_MIXED_FCS" "$GEMINI_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_gemini_continue '[{"role":"user","parts":[{"text":"mixed"}]}]'
assert_eq "mixed sequential → exit 0" "0" "$LAST_RC"
assert_jq "mixed sequential: ERROR: prefix solo en BAD (medio)" \
    '[.[2].parts[].functionResponse.response.content | startswith("ERROR:")] == [false,true,false]' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "mixed sequential: name lookup correcto (no se corrompió por idx swap)" \
    '[.[2].parts[].functionResponse.name] == ["read_file","read_file","read_file"]' \
    "$CODER_AGENTIC_MESSAGES"

echo "=== P2.parallel-4: mixed success/failure preserva ERROR: prefix por job (parallel)"
export CODER_TOOL_PARALLEL=3
_setup_mock_api "$GEMINI_FIX_MIXED_FCS" "$GEMINI_FIX_END"
CODER_AGENTIC_MESSAGES=""
run_capture agentic_loop_gemini_continue '[{"role":"user","parts":[{"text":"mixed parallel"}]}]'
assert_eq "mixed parallel → exit 0" "0" "$LAST_RC"
assert_jq "mixed parallel: ERROR: prefix solo en BAD" \
    '[.[2].parts[].functionResponse.response.content | startswith("ERROR:")] == [false,true,false]' \
    "$CODER_AGENTIC_MESSAGES"
assert_jq "mixed parallel: orden preservado" \
    '[.[2].parts[].functionResponse.name] == ["read_file","read_file","read_file"]' \
    "$CODER_AGENTIC_MESSAGES"

# Restore CODER_TOOL_PARALLEL
if [ -n "$_SAVED_PARALLEL_GEM" ]; then
    export CODER_TOOL_PARALLEL="$_SAVED_PARALLEL_GEM"
else
    unset CODER_TOOL_PARALLEL
fi

# =====================================================================
# Cleanup
# =====================================================================
unset -f curl
if [ -n "$_SAVED_ANTHROPIC_KEY" ]; then export ANTHROPIC_API_KEY="$_SAVED_ANTHROPIC_KEY"; else unset ANTHROPIC_API_KEY; fi
if [ -n "$_SAVED_OPENAI_KEY" ]; then export OPENAI_API_KEY="$_SAVED_OPENAI_KEY"; else unset OPENAI_API_KEY; fi
if [ -n "$_SAVED_GEMINI_KEY" ]; then export GEMINI_API_KEY="$_SAVED_GEMINI_KEY"; else unset GEMINI_API_KEY; fi
rm -rf "$_MOCK_STATE_DIR" "$_TMPOUT" "$_TMPERR"
trap - EXIT INT TERM

echo ""
echo "==============================="
echo "Resultado: $PASS pass, $FAIL fail"
echo "==============================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
