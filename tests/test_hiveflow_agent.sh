#!/bin/bash
#
# Tests del shim hiveflow ↔ motor agentic (fase 0 del PLAN.md):
#   - CODER_SYSTEM_PROMPT en los payloads de los 3 providers (opt-in)
#   - CODER_AGENT_TOOLS restringe el registro de tools (plan mode)
#   - _agentic_track_usage acumula tokens (3 shapes de usage)
#   - hf_agent_project_context construye el system prompt desde AGENTS.md
#   - router: native como candidato y fallback
#
# Offline: no toca red.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/agent/tool_calling.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then pass "$desc"; else fail "$desc (expected='$expected' actual='$actual')"; fi
}

assert_jq() {
    local desc="$1" filter="$2" json="$3"
    if echo "$json" | jq -e "$filter" >/dev/null 2>&1; then pass "$desc"; else fail "$desc (filter='$filter' json='$json')"; fi
}

# =====================================================
echo "=== system prompt en payloads (opt-in, vacío = legacy) ==="

unset CODER_SYSTEM_PROMPT
out=$(_anthropic_build_payload "m" 100 '[]' '[{"role":"user","content":"hola"}]')
assert_jq "anthropic sin CODER_SYSTEM_PROMPT no lleva system" 'has("system") | not' "$out"

export CODER_SYSTEM_PROMPT="contexto del proyecto"
out=$(_anthropic_build_payload "m" 100 '[]' '[{"role":"user","content":"hola"}]')
assert_jq "anthropic con CODER_SYSTEM_PROMPT lleva system" '.system == "contexto del proyecto"' "$out"
assert_jq "anthropic: messages intactos" '.messages | length == 1' "$out"

unset CODER_SYSTEM_PROMPT
out=$(_openai_build_payload "m" '[]' '[{"role":"user","content":"hola"}]')
assert_jq "openai sin sys: 1 mensaje" '.messages | length == 1' "$out"

export CODER_SYSTEM_PROMPT="ctx"
out=$(_openai_build_payload "m" '[]' '[{"role":"user","content":"hola"}]')
assert_jq "openai con sys: prepend role=system" '.messages[0] == {role:"system", content:"ctx"}' "$out"
assert_jq "openai con sys: user preservado" '.messages[1].role == "user"' "$out"
out=$(_openai_build_payload "m" '[]' '[{"role":"user","content":"hola"}]' 50)
assert_jq "openai con sys + max_tokens" '(.messages | length == 2) and .max_tokens == 50' "$out"

unset CODER_SYSTEM_PROMPT
out=$(_gemini_build_payload '[]' '[{"role":"user","parts":[{"text":"hola"}]}]')
assert_jq "gemini sin sys no lleva systemInstruction" 'has("systemInstruction") | not' "$out"

export CODER_SYSTEM_PROMPT="ctx gemini"
out=$(_gemini_build_payload '[]' '[{"role":"user","parts":[{"text":"hola"}]}]')
assert_jq "gemini con sys lleva systemInstruction" '.systemInstruction.parts[0].text == "ctx gemini"' "$out"
out=$(_gemini_build_payload '[]' '[{"role":"user","parts":[{"text":"hola"}]}]' 50)
assert_jq "gemini con sys + max_tokens" '(.systemInstruction != null) and .generationConfig.maxOutputTokens == 50' "$out"
unset CODER_SYSTEM_PROMPT

# =====================================================
echo "=== CODER_AGENT_TOOLS restringe el registro (plan mode) ==="

REGISTERED_TOOLS=()
CODER_AGENT_TOOLS="read_file grep_search glob_files web_fetch" _register_agentic_tools "test" >/dev/null 2>&1
rc=$?
assert_eq "registro restringido -> 0" "0" "$rc"
assert_eq "4 tools registradas" "4" "${#REGISTERED_TOOLS[@]}"
case " ${REGISTERED_TOOLS[*]} " in
    *" write_file "*|*" bash_exec "*|*" edit_file "*|*" subagent "*)
        fail "no debe registrar tools mutantes en modo restringido" ;;
    *)  pass "sin tools mutantes en modo restringido" ;;
esac

REGISTERED_TOOLS=()
_register_agentic_tools "test" >/dev/null 2>&1
assert_eq "sin CODER_AGENT_TOOLS registra las 8" "8" "${#REGISTERED_TOOLS[@]}"
REGISTERED_TOOLS=()

# =====================================================
echo "=== _agentic_track_usage acumula (3 shapes) ==="

CODER_TOKENS_IN=0; CODER_TOKENS_OUT=0
_agentic_track_usage '{"usage":{"input_tokens":100,"output_tokens":20}}'
assert_eq "anthropic in" "100" "$CODER_TOKENS_IN"
assert_eq "anthropic out" "20" "$CODER_TOKENS_OUT"
_agentic_track_usage '{"usage":{"prompt_tokens":30,"completion_tokens":5}}'
assert_eq "openai acumula in" "130" "$CODER_TOKENS_IN"
assert_eq "openai acumula out" "25" "$CODER_TOKENS_OUT"
_agentic_track_usage '{"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":2}}'
assert_eq "gemini acumula in" "140" "$CODER_TOKENS_IN"
assert_eq "gemini acumula out" "27" "$CODER_TOKENS_OUT"
_agentic_track_usage '{"sin":"usage"}'
_agentic_track_usage 'esto no es json'
assert_eq "respuestas sin usage no rompen ni suman" "140" "$CODER_TOKENS_IN"

# =====================================================
echo "=== hf_agent_project_context (shim) ==="

WORK=$(mktemp -d)
export HIVEFLOW_CONFIG_DIR="$WORK/hfconfig"
HIVEFLOW_ROOT="$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core/ui.sh" 2>/dev/null || true
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core/config.sh"
# Solo las funciones del shim (el motor ya está sourceado arriba):
eval "$(sed -n '/^hf_agent_project_context()/,/^}/p' "$REPO_ROOT/lib/core/agent.sh")"

mkdir -p "$WORK/proj" && cd "$WORK/proj"
echo "# Reglas del proyecto de prueba" > AGENTS.md
echo "linea2" >> AGENTS.md
touch archivo_a.txt archivo_b.txt

unset CODER_SYSTEM_PROMPT HIVEFLOW_NO_PROJECT_CONTEXT
hf_agent_project_context
case "${CODER_SYSTEM_PROMPT:-}" in
    *"Reglas del proyecto de prueba"*) pass "incluye AGENTS.md" ;;
    *) fail "incluye AGENTS.md (got: ${CODER_SYSTEM_PROMPT:-vacío})" ;;
esac
case "${CODER_SYSTEM_PROMPT:-}" in
    *archivo_a.txt*) pass "incluye estructura del repo" ;;
    *) fail "incluye estructura del repo" ;;
esac

export CODER_SYSTEM_PROMPT="preexistente"
hf_agent_project_context
assert_eq "respeta CODER_SYSTEM_PROMPT preexistente" "preexistente" "$CODER_SYSTEM_PROMPT"

unset CODER_SYSTEM_PROMPT
export HIVEFLOW_NO_PROJECT_CONTEXT=1
hf_agent_project_context
assert_eq "opt-out con HIVEFLOW_NO_PROJECT_CONTEXT" "" "${CODER_SYSTEM_PROMPT:-}"
unset HIVEFLOW_NO_PROJECT_CONTEXT

cd "$REPO_ROOT"
rm -rf "$WORK"

# =====================================================
echo "=== provider hiveflow: agente vía cuenta + proxy ==="

# Extraer hf_agent_env + hf_agent_available del shim, con deps stubeadas
eval "$(sed -n '/^hf_agent_env()/,/^}/p' "$REPO_ROOT/lib/core/agent.sh")"
eval "$(sed -n '/^hf_agent_available()/,/^}/p' "$REPO_ROOT/lib/core/agent.sh")"
hf_err() { :; }
hf_agent_project_context() { :; }
hf_auth_token() { echo "hf_test123.abc"; }
hf_config_get() {
    case "$1" in
        '.llm.provider') echo "hiveflow" ;;
        '.llm.model')    echo "" ;;
        *) echo "" ;;
    esac
}
HIVEFLOW_API_URL="https://api.test.local"
HF_AGENT_LOADED=1
unset HIVEFLOW_LLM_PROVIDER HIVEFLOW_LLM_KEY HIVEFLOW_LLM_MODEL
unset ANTHROPIC_MESSAGES_URL ANTHROPIC_API_KEY CODER_CLAUDE_MODEL llm_choice

hf_agent_env
rc=$?
assert_eq "hf_agent_env hiveflow -> 0" "0" "$rc"
assert_eq "llm_choice mapea a claude" "claude" "${llm_choice:-}"
assert_eq "ANTHROPIC_API_KEY = token de cuenta" "hf_test123.abc" "${ANTHROPIC_API_KEY:-}"
assert_eq "URL apunta al proxy" "https://api.test.local/api/cli/llm/v1/messages" "${ANTHROPIC_MESSAGES_URL:-}"
assert_eq "modelo default sonnet-5" "claude-sonnet-5" "${CODER_CLAUDE_MODEL:-}"

if hf_agent_available; then pass "hf_agent_available con hiveflow + sesión"; else fail "hf_agent_available con hiveflow + sesión"; fi
hf_auth_token() { echo ""; }
if hf_agent_available; then fail "hf_agent_available hiveflow sin sesión -> no"; else pass "hf_agent_available hiveflow sin sesión -> no"; fi

# Env override HIVEFLOW_LLM_KEY funciona también con provider hiveflow (CI)
hf_auth_token() { echo ""; }
export HIVEFLOW_LLM_KEY="hf_ci_key"
hf_agent_env
assert_eq "HIVEFLOW_LLM_KEY gana sin sesión" "hf_ci_key" "${ANTHROPIC_API_KEY:-}"
unset HIVEFLOW_LLM_KEY ANTHROPIC_MESSAGES_URL ANTHROPIC_API_KEY CODER_CLAUDE_MODEL llm_choice

# =====================================================
echo "=== device flow del login (curl mockeado) ==="

eval "$(sed -n '/^hf_auth_device_flow()/,/^}/p' "$REPO_ROOT/lib/core/auth.sh")"
HF_C_BOLD=""; HF_C_RESET=""
hf_ok() { :; }; hf_info() { :; }; hf_dim() { :; }; hf_warn() { :; }
_DEV_STATE=$(mktemp -d)
echo 0 > "$_DEV_STATE/polls"
hf_config_set() { echo "$1=$2" >> "$_DEV_STATE/config"; }
sleep() { :; }                      # polling instantáneo
open() { return 1; }                # jamás abrir navegador real en tests
xdg-open() { return 1; } 2>/dev/null || true

curl() {
    local url="" a
    for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
    case "$url" in
        */device/start)
            printf '{"device_code":"dc123","user_code":"AAAA-BBBB","verification_url":"https://app.test/cli-login?code=AAAA-BBBB","expires_in":600,"interval":1}' ;;
        */device/poll)
            local n; n=$(cat "$_DEV_STATE/polls"); n=$((n+1)); echo "$n" > "$_DEV_STATE/polls"
            if [ "$n" -lt 3 ]; then printf '{"status":"pending","interval":1}'
            else printf '{"status":"approved","token":"hf_mock.tok"}'; fi ;;
        *) return 1 ;;
    esac
}

HIVEFLOW_API_URL="https://api.test.local"
hf_auth_device_flow >/dev/null 2>&1
rc=$?
assert_eq "device flow aprobado -> 0" "0" "$rc"
assert_eq "hizo 3 polls (2 pending + approved)" "3" "$(cat "$_DEV_STATE/polls")"
if grep -q '^.auth.token=hf_mock.tok$' "$_DEV_STATE/config"; then
    pass "guardó el token emitido"
else
    fail "guardó el token emitido (config: $(cat "$_DEV_STATE/config" 2>/dev/null))"
fi
if grep -q '^.auth.method=subscription$' "$_DEV_STATE/config"; then
    pass "method=subscription"
else
    fail "method=subscription"
fi

# Camino denied
echo 0 > "$_DEV_STATE/polls"
curl() {
    local url="" a
    for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
    case "$url" in
        */device/start)
            printf '{"device_code":"dc9","user_code":"CCCC-DDDD","verification_url":"https://app.test/x","expires_in":600,"interval":1}' ;;
        */device/poll)
            printf '{"status":"denied"}' ;;
        *) return 1 ;;
    esac
}
hf_auth_device_flow >/dev/null 2>&1
rc=$?
assert_eq "device flow denegado -> 1" "1" "$rc"

# Backend caído en start -> error limpio
curl() { return 1; }
hf_auth_device_flow >/dev/null 2>&1
rc=$?
assert_eq "start sin backend -> 1" "1" "$rc"
unset -f curl sleep open
rm -rf "$_DEV_STATE"

# =====================================================
echo "=== router: native como candidato ==="

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core/tools.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/core/router.sh"

chain=$(hf_routing_chain default)
case "$chain" in
    *native*) pass "cadena default incluye native" ;;
    *) fail "cadena default incluye native (got: $chain)" ;;
esac
chain=$(hf_routing_chain research)
case "$chain" in
    claude:native*) pass "research prioriza claude/native sobre gemini" ;;
    *) fail "research prioriza claude/native (got: $chain)" ;;
esac

# Stubs: sin CLIs instalados, agente disponible → native
hf_tool_installed() { return 1; }
hf_agent_available() { return 0; }
sel=$(hf_route quick-fix)
assert_eq "sin CLIs + key -> native" "native" "$sel"

# Sin CLIs y sin key → fallo limpio
hf_agent_available() { return 1; }
sel=$(hf_route quick-fix); rc=$?
assert_eq "sin nada -> exit 1" "1" "$rc"

# =====================================================
echo ""
echo "=================="
echo "Resultado: $PASS pass, $FAIL fail"
echo "=================="
[ "$FAIL" -eq 0 ]
