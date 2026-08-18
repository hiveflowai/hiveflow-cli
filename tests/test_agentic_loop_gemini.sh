#!/bin/bash
#
# Tests para lib/tool_calling.sh :: agentic_loop_gemini (M1.4 — Gemini portion)
#
# Dos capas:
#   1) Unit tests sobre helpers `_gemini_*` con fixtures JSON (offline, sin API).
#   2) Smoke test end-to-end contra :generateContent — sólo si GEMINI_API_KEY
#      (o $gemini_api_key del config legacy) está disponible. Si no, lo skipea.
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
# Fixtures: respuestas típicas del endpoint :generateContent
# =====================================================================
FIXTURE_FUNCTION_CALL=$(cat <<'EOF'
{
  "candidates": [
    {
      "content": {
        "role": "model",
        "parts": [
          {
            "functionCall": {
              "name": "read_file",
              "args": {"path": "tests/fixtures/sample_config.sh", "limit": 50}
            }
          }
        ]
      },
      "finishReason": "STOP",
      "index": 0
    }
  ],
  "modelVersion": "gemini-2.5-flash"
}
EOF
)

FIXTURE_STOP=$(cat <<'EOF'
{
  "candidates": [
    {
      "content": {
        "role": "model",
        "parts": [
          {"text": "Las funciones son: init_config_directories, detect_system_language, load_language."}
        ]
      },
      "finishReason": "STOP",
      "index": 0
    }
  ]
}
EOF
)

FIXTURE_API_ERROR=$(cat <<'EOF'
{"error": {"code": 400, "message": "API key not valid. Please pass a valid API key.", "status": "INVALID_ARGUMENT"}}
EOF
)

FIXTURE_MULTI_FUNCTION_CALLS=$(cat <<'EOF'
{
  "candidates": [
    {
      "content": {
        "role": "model",
        "parts": [
          {"functionCall": {"name": "read_file", "args": {"path": "a.sh"}}},
          {"functionCall": {"name": "read_file", "args": {"path": "b.sh"}}}
        ]
      },
      "finishReason": "STOP",
      "index": 0
    }
  ]
}
EOF
)

FIXTURE_MIXED_TEXT_AND_CALL=$(cat <<'EOF'
{
  "candidates": [
    {
      "content": {
        "role": "model",
        "parts": [
          {"text": "Voy a leer el archivo."},
          {"functionCall": {"name": "read_file", "args": {"path": "x.sh"}}}
        ]
      },
      "finishReason": "STOP",
      "index": 0
    }
  ]
}
EOF
)

FIXTURE_MAX_TOKENS=$(cat <<'EOF'
{
  "candidates": [
    {
      "content": {"role": "model", "parts": [{"text": "Respuesta truncada..."}]},
      "finishReason": "MAX_TOKENS",
      "index": 0
    }
  ]
}
EOF
)

FIXTURE_SAFETY=$(cat <<'EOF'
{
  "candidates": [
    {
      "content": {"role": "model", "parts": []},
      "finishReason": "SAFETY",
      "index": 0
    }
  ]
}
EOF
)

# =====================================================================
# _gemini_transform_tools
# =====================================================================
echo "=== _gemini_transform_tools"
tools_internal=$(get_all_tool_definitions_json)
tools_gemini=$(_gemini_transform_tools "$tools_internal")

# Shape: array de 1 elemento con function_declarations adentro.
if echo "$tools_gemini" | jq -e '
    type == "array" and length == 1 and
    (.[0].function_declarations | type == "array") and
    (.[0].function_declarations | length >= 1) and
    .[0].function_declarations[0].name == "read_file" and
    (.[0].function_declarations[0].parameters | type == "object")
' >/dev/null; then
    pass "tool transform: shape Gemini con function_declarations wrap"
else
    fail "tool transform shape inválido: $tools_gemini"
fi

# input_schema NO debe aparecer (se renombró a parameters).
if echo "$tools_gemini" | jq -e '.[0].function_declarations[0].input_schema' >/dev/null 2>&1; then
    fail "tool transform: input_schema fue copiado en vez de renombrado"
else
    pass "tool transform: input_schema removido (correcto)"
fi

# Types deben estar en MAYÚSCULA (defensivo).
top_type=$(echo "$tools_gemini" | jq -r '.[0].function_declarations[0].parameters.type')
assert_eq "tool transform: type top-level en uppercase" "OBJECT" "$top_type"

prop_type=$(echo "$tools_gemini" | jq -r '.[0].function_declarations[0].parameters.properties.path.type')
assert_eq "tool transform: type de property en uppercase" "STRING" "$prop_type"

# =====================================================================
# _gemini_extract_text
# =====================================================================
echo "=== _gemini_extract_text"
text_none=$(_gemini_extract_text "$FIXTURE_FUNCTION_CALL")
assert_eq "function-only response => texto vacío" "" "$text_none"

text_stop=$(_gemini_extract_text "$FIXTURE_STOP")
assert_contains "extrae texto de STOP response" "Las funciones son" "$text_stop"

text_mixed=$(_gemini_extract_text "$FIXTURE_MIXED_TEXT_AND_CALL")
assert_contains "extrae texto cuando coexiste con functionCall" "Voy a leer" "$text_mixed"

# =====================================================================
# _gemini_extract_finish_reason
# =====================================================================
echo "=== _gemini_extract_finish_reason"
fr1=$(_gemini_extract_finish_reason "$FIXTURE_STOP")
assert_eq "finishReason STOP" "STOP" "$fr1"

fr2=$(_gemini_extract_finish_reason "$FIXTURE_MAX_TOKENS")
assert_eq "finishReason MAX_TOKENS" "MAX_TOKENS" "$fr2"

fr3=$(_gemini_extract_finish_reason '{"candidates":[{}]}')
assert_eq "finishReason ausente => unknown" "unknown" "$fr3"

fr4=$(_gemini_extract_finish_reason "$FIXTURE_SAFETY")
assert_eq "finishReason SAFETY" "SAFETY" "$fr4"

# =====================================================================
# _gemini_extract_function_calls
# =====================================================================
echo "=== _gemini_extract_function_calls"
fc=$(_gemini_extract_function_calls "$FIXTURE_FUNCTION_CALL")
fc_lines=$(echo "$fc" | grep -c .)
assert_eq "una sola línea de functionCall" "1" "$fc_lines"

# Separator es Unit Separator (0x1f), no TAB — @tsv corrompía multi-línea.
# Formato actual: <idx><US><name><US><args> (P2.parallel-4 — idx 0-based para
# habilitar _dispatch_tools_parallel; previo era <name><US><args>).
fc_idx=$(printf '%s' "$fc" | awk -F$'\x1f' '{print $1}')
fc_name=$(printf '%s' "$fc" | awk -F$'\x1f' '{print $2}')
fc_args=$(printf '%s' "$fc" | awk -F$'\x1f' '{print $3}')
assert_eq "functionCall idx 0-based" "0" "$fc_idx"
assert_eq "functionCall name parseado" "read_file" "$fc_name"
if echo "$fc_args" | jq -e '.path == "tests/fixtures/sample_config.sh" and .limit == 50' >/dev/null; then
    pass "functionCall args parseado como JSON válido"
else
    fail "functionCall args no parseó como JSON esperado (got: $fc_args)"
fi

fc_multi=$(_gemini_extract_function_calls "$FIXTURE_MULTI_FUNCTION_CALLS")
multi_lines=$(echo "$fc_multi" | grep -c .)
assert_eq "dos líneas para dos functionCalls" "2" "$multi_lines"

# Verificar idx 0,1 emitidos en orden para multi-call.
multi_idx0=$(printf '%s' "$fc_multi" | sed -n '1p' | awk -F$'\x1f' '{print $1}')
multi_idx1=$(printf '%s' "$fc_multi" | sed -n '2p' | awk -F$'\x1f' '{print $1}')
assert_eq "multi-call: primer idx=0" "0" "$multi_idx0"
assert_eq "multi-call: segundo idx=1" "1" "$multi_idx1"

fc_none=$(_gemini_extract_function_calls "$FIXTURE_STOP")
if [ -z "$fc_none" ]; then
    pass "STOP response sin functionCalls"
else
    fail "STOP response debió no tener functionCalls (got: $fc_none)"
fi

# Mixed: debe extraer el functionCall ignorando text.
fc_mixed=$(_gemini_extract_function_calls "$FIXTURE_MIXED_TEXT_AND_CALL")
mixed_lines=$(echo "$fc_mixed" | grep -c .)
assert_eq "una sola línea en mixed (text + functionCall)" "1" "$mixed_lines"

# =====================================================================
# _gemini_has_function_calls
# =====================================================================
echo "=== _gemini_has_function_calls"
if _gemini_has_function_calls "$FIXTURE_FUNCTION_CALL"; then
    pass "detecta function call único"
else
    fail "no detectó function call en fixture"
fi

if _gemini_has_function_calls "$FIXTURE_MULTI_FUNCTION_CALLS"; then
    pass "detecta múltiples function calls"
else
    fail "no detectó multi function calls"
fi

if _gemini_has_function_calls "$FIXTURE_STOP"; then
    fail "marcó STOP response (solo text) como con function calls"
else
    pass "STOP response detectada sin function calls"
fi

if _gemini_has_function_calls "$FIXTURE_MIXED_TEXT_AND_CALL"; then
    pass "detecta functionCall en respuesta mixed (text + call)"
else
    fail "no detectó functionCall cuando coexiste con text"
fi

# =====================================================================
# _gemini_is_api_error
# =====================================================================
echo "=== _gemini_is_api_error"
if _gemini_is_api_error "$FIXTURE_API_ERROR"; then
    pass "detecta API error"
else
    fail "no detectó API error en fixture explícito"
fi

if _gemini_is_api_error "$FIXTURE_STOP"; then
    fail "marcó respuesta normal como API error"
else
    pass "no marca respuesta normal como error"
fi

# =====================================================================
# _gemini_build_payload
# =====================================================================
echo "=== _gemini_build_payload"
contents_initial='[{"role":"user","parts":[{"text":"hola"}]}]'
payload=$(_gemini_build_payload "$tools_gemini" "$contents_initial")
if echo "$payload" | jq -e '
    (.contents | length) == 1 and
    .contents[0].role == "user" and
    (.contents[0].parts[0].text == "hola") and
    (.tools | length) == 1 and
    (.tools[0].function_declarations | length) >= 1 and
    (has("generationConfig") | not)
' >/dev/null; then
    pass "payload shape OK (sin max_tokens)"
else
    fail "payload shape inválido: $payload"
fi

payload_mt=$(_gemini_build_payload "$tools_gemini" "$contents_initial" "512")
if echo "$payload_mt" | jq -e '.generationConfig.maxOutputTokens == 512' >/dev/null; then
    pass "payload incluye generationConfig.maxOutputTokens cuando se pasa"
else
    fail "payload max_tokens missing: $payload_mt"
fi

# =====================================================================
# _gemini_append_model
# =====================================================================
echo "=== _gemini_append_model"
initial='[{"role":"user","parts":[{"text":"x"}]}]'
appended=$(_gemini_append_model "$initial" "$FIXTURE_FUNCTION_CALL")
if echo "$appended" | jq -e '
    length == 2 and
    .[1].role == "model" and
    (.[1].parts | length) == 1 and
    .[1].parts[0].functionCall.name == "read_file"
' >/dev/null; then
    pass "model content apendido con functionCall preservado"
else
    fail "append_model falló: $appended"
fi

# =====================================================================
# _gemini_build_function_response_part
# =====================================================================
echo "=== _gemini_build_function_response_part"
fr_part=$(_gemini_build_function_response_part "read_file" "contenido del archivo")
if echo "$fr_part" | jq -e '
    .functionResponse.name == "read_file" and
    .functionResponse.response.content == "contenido del archivo"
' >/dev/null; then
    pass "functionResponse part shape correcta"
else
    fail "functionResponse part inválida: $fr_part"
fi

# =====================================================================
# _gemini_append_function_responses
# =====================================================================
echo "=== _gemini_append_function_responses"
fr_parts_array=$(jq -nc \
    --argjson p1 "$(_gemini_build_function_response_part "read_file" "salida 1")" \
    --argjson p2 "$(_gemini_build_function_response_part "read_file" "salida 2")" \
    '[$p1, $p2]')
with_fr=$(_gemini_append_function_responses "$appended" "$fr_parts_array")
if echo "$with_fr" | jq -e '
    length == 3 and
    .[2].role == "user" and
    (.[2].parts | length) == 2 and
    .[2].parts[0].functionResponse.response.content == "salida 1" and
    .[2].parts[1].functionResponse.response.content == "salida 2"
' >/dev/null; then
    pass "N functionResponses agrupadas en UN user message"
else
    fail "append_function_responses falló: $with_fr"
fi

# =====================================================================
# Error paths del loop
# =====================================================================
echo "=== agentic_loop_gemini: missing prompt"
set +e
err=$(agentic_loop_gemini "" 2>&1)
rc=$?
set -e
assert_eq "exit 2 si prompt vacío" "2" "$rc"
assert_contains "mensaje 'missing prompt'" "missing prompt" "$err"

echo "=== agentic_loop_gemini: key faltante"
set +e
no_key_out=$(
    unset GEMINI_API_KEY
    unset gemini_api_key
    agentic_loop_gemini "hi" 2>&1
)
no_key_rc=$?
set -e
assert_eq "exit 1 sin api key" "1" "$no_key_rc"
assert_contains "mensaje 'GEMINI_API_KEY not set'" "GEMINI_API_KEY not set" "$no_key_out"

# =====================================================================
# _gemini_build_url
# =====================================================================
echo "=== _gemini_build_url"
url=$(_gemini_build_url "gemini-2.5-flash")
assert_contains "URL contiene model y :generateContent" "models/gemini-2.5-flash:generateContent" "$url"
assert_contains "URL parte de GEMINI_BASE_URL" "generativelanguage.googleapis.com" "$url"

# =====================================================================
# Smoke test end-to-end (live) — gated por API key disponible.
# Acepta GEMINI_API_KEY del env o gemini_api_key del config legacy.
# =====================================================================
echo ""
echo "==============================="
echo "Live E2E (Gemini :generateContent)"
echo "==============================="

LEGACY_CFG="$HOME/.config/coder-cli/config.json"
if [ -z "${GEMINI_API_KEY:-}" ] && [ -z "${gemini_api_key:-}" ] && [ -f "$LEGACY_CFG" ]; then
    # shellcheck source=/dev/null
    source "$LEGACY_CFG" 2>/dev/null || true
fi

if [ -z "${GEMINI_API_KEY:-}" ] && [ -z "${gemini_api_key:-}" ]; then
    echo "  SKIP: no GEMINI_API_KEY ni gemini_api_key disponible — saltando smoke test live."
    echo "        (los unit tests pasaron; M1.4 Gemini requiere live verification antes de marcar done)"
else
    echo "  Corriendo prompt real: 'lista las primeras 3 funciones definidas en tests/fixtures/sample_config.sh'..."
    set +e
    live_out=$(agentic_loop_gemini "Usa la tool read_file para leer tests/fixtures/sample_config.sh y dime los nombres de las primeras 3 funciones que se definen ahí. Responde sólo con los nombres." 2>&1)
    live_rc=$?
    set -e

    if [ "$live_rc" -eq 0 ]; then
        pass "agentic_loop_gemini salió 0 en live"
    else
        fail "agentic_loop_gemini salió $live_rc en live. Output: $live_out"
    fi

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
