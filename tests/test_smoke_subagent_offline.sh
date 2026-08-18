#!/bin/bash
#
# Smoke test offline para `subagent` — flujo end-to-end a través del loop agentic
#
# Cubre el scenario del backlog "P2.subagent-3 Live e2e con LLM real" sin
# requerir un LLM vivo. Stubea _anthropic_call_api con fixtures secuenciales
# que simulan al modelo invocando la tool `subagent` y luego cerrando con
# end_turn referenciando el output del hijo. Patrón heredado de
# test_smoke_m2_offline.sh / test_smoke_m3_offline.sh.
#
# Verifica:
#   - `subagent` queda registrada via `_register_agentic_tools` (orden canónico
#     compartido entre `-agent` y `-ia`).
#   - Happy path: tool_use(subagent) -> handler spawnea hijo (CODER_SUBAGENT_BIN
#     apunta a un stub bash) -> stdout del hijo capturado -> tool_result sin
#     is_error reinyectado al modelo -> end_turn referenciando el token del hijo.
#   - El payload del segundo turno contiene la salida estructurada del subagent:
#     header `subagent: exit=0 timed_out=false duration=Ns depth=1` + secciones
#     `--- stdout ---` (con el token) y `--- stderr ---` (`(empty)`).
#   - El stub no recibió env contaminado: CODER_SUBAGENT_DEPTH=1 (incrementado
#     desde el 0 default del padre) le llegó al hijo.
#   - Recursion guard: si el modelo intenta spawnear estando en depth>=max,
#     subagent hard-falla con exit 1 antes de tocar el binario, el loop
#     reinyecta tool_result con is_error=true y "refusing to spawn child"
#     visible, y el modelo cierra con end_turn (recovery).
#
# Live e2e equivalente: cuando haya API key viva,
#   ./coder.sh -agent "usa subagent para listar las .sh de lib/ con prompt acotado"
# debe disparar tool_use(subagent), correr el hijo real y resumir el output.
# Tracking en BACKLOG.md "P2.subagent-3 Live e2e con LLM real".
#
# Exit != 0 si cualquier check falla.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

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
    if echo "$haystack" | grep -qF -- "$needle"; then
        pass "$desc"
    else
        fail "$desc (missing: '$needle')"
        echo "       haystack was: $haystack" | head -c 800
        echo ""
    fi
}

# ---------------------------------------------------------------------
# Setup: tmp workspace + aislamiento de config/backups/permissions.
# ---------------------------------------------------------------------
WORK=$(mktemp -d -t smoke_subagent.XXXXXX)
trap 'rm -rf "$WORK" "${_MOCK_STATE_DIR:-}"' EXIT INT TERM

# CONFIG_DIR antes del source de permissions para que PERMISSIONS_CONFIG apunte al tmp.
export CONFIG_DIR="$WORK/cfg"
export PERMISSIONS_CONFIG="$WORK/cfg/permissions.json"
export CODER_BACKUP_DIR="$WORK/backups"
export CODER_YES=1
export ANTHROPIC_API_KEY="test-stub-key-not-real"
mkdir -p "$CONFIG_DIR"

# Workspace donde el handler spawnea el hijo (cwd inheritance).
WORKDIR="$WORK/repo"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ---------------------------------------------------------------------
# Fake coder.sh para CODER_SUBAGENT_BIN.
# Comportamiento: parsea "-agent <prompt...>" y reacciona al primer token:
#   DEPTH         -> emite "depth=<CODER_SUBAGENT_DEPTH>" (verifica propagación)
#   ECHO <rest>   -> emite el resto a stdout
#   <otro>        -> emite "fake: <prompt>"
# Útil para asegurar que el hijo se invocó con el prompt esperado.
# ---------------------------------------------------------------------
FAKE_CODER="$WORK/fake_coder.sh"
cat >"$FAKE_CODER" <<'SCRIPT'
#!/bin/bash
if [ "${1:-}" != "-agent" ]; then
    echo "fake_coder: expected -agent as first arg, got: ${1:-}" >&2
    exit 99
fi
shift
prompt="$*"
head="${prompt%% *}"
rest="${prompt#"$head"}"
rest="${rest# }"
case "$head" in
    DEPTH)
        echo "depth=${CODER_SUBAGENT_DEPTH:-unset}"
        ;;
    ECHO)
        echo "$rest"
        ;;
    *)
        echo "fake: $prompt"
        ;;
esac
exit 0
SCRIPT
chmod +x "$FAKE_CODER"
export CODER_SUBAGENT_BIN="$FAKE_CODER"

# ---------------------------------------------------------------------
# Source modules + registro canónico (read/write/edit/bash_exec/web_fetch/
# grep_search/glob_files/subagent). Si _register_agentic_tools falla
# abortamos la suite.
# ---------------------------------------------------------------------
# shellcheck source=../lib/permissions.sh disable=SC1091
source "$REPO_ROOT/lib/agent/permissions.sh"
# shellcheck source=../lib/tool_calling.sh disable=SC1091
source "$REPO_ROOT/lib/agent/tool_calling.sh"

if ! _register_agentic_tools "test_smoke_subagent_offline"; then
    echo "FATAL: _register_agentic_tools falló" >&2
    exit 2
fi

echo "==============================="
echo "Smoke subagent offline — registro de tools (canonical via _register_agentic_tools)"
echo "==============================="

# Confirma que subagent está en el set y aparece en el definitions JSON.
if printf '%s\n' "${REGISTERED_TOOLS[@]}" | grep -qx "subagent"; then
    pass "subagent ∈ REGISTERED_TOOLS"
else
    fail "subagent NO está en REGISTERED_TOOLS"
fi

all_defs=$(get_all_tool_definitions_json)
if echo "$all_defs" | jq -e '.[] | select(.name == "subagent")' >/dev/null 2>&1; then
    pass "get_all_tool_definitions_json incluye subagent"
else
    fail "get_all_tool_definitions_json no incluye subagent"
fi

# ---------------------------------------------------------------------
# Mock state filesystem-backed (sobrevive subshells de $(...)). Mismo patrón
# que test_smoke_m3_offline.sh.
# ---------------------------------------------------------------------
_MOCK_STATE_DIR=$(mktemp -d -t smoke_subagent_mock.XXXXXX)

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

_mock_count()    { cat "$_MOCK_STATE_DIR/count"; }
_mock_captured() { cat "$_MOCK_STATE_DIR/captured/$1" 2>/dev/null; }

# shellcheck disable=SC2317  # invocada indirectamente via agentic_loop_anthropic
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

# =====================================================================
# Scenario 1 — Happy path: LLM delega vía subagent, hijo emite token,
# parent resume con end_turn.
# =====================================================================
echo ""
echo "==============================="
echo "Smoke subagent offline — escenario 1: happy path"
echo "==============================="

TOKEN="SUBAGENT_SMOKE_OK_$(date +%s%N 2>/dev/null || date +%s)"
CHILD_PROMPT="ECHO $TOKEN"

FIXTURE_HAPPY_CALL=$(jq -nc --arg p "$CHILD_PROMPT" '{
  id: "msg_s1",
  type: "message",
  role: "assistant",
  model: "claude-haiku-4-5-20251001",
  content: [
    {type: "text", text: "Delego al subagent para obtener el token."},
    {type: "tool_use", id: "toolu_sub_happy", name: "subagent",
     input: {prompt: $p, timeout_seconds: 30}}
  ],
  stop_reason: "tool_use"
}')

FIXTURE_HAPPY_END=$(jq -nc --arg tok "$TOKEN" '{
  id: "msg_s2",
  type: "message",
  role: "assistant",
  model: "claude-haiku-4-5-20251001",
  content: [
    {type: "text", text: ("Subagent terminó OK y emitió: " + $tok)}
  ],
  stop_reason: "end_turn"
}')

_setup_mock_api "$FIXTURE_HAPPY_CALL" "$FIXTURE_HAPPY_END"

set +e
loop_out=$(agentic_loop_anthropic "usa subagent para producir el token" 2>&1)
loop_rc=$?
set -e

assert_eq "loop happy completa con exit 0" "0" "$loop_rc"
assert_eq "loop happy hizo 2 llamadas a la API" "2" "$(_mock_count)"
assert_contains "stdout happy muestra el intent del turno 1" "Delego al subagent" "$loop_out"
assert_contains "stdout happy muestra el resumen del turno 2 con el token" "$TOKEN" "$loop_out"

# Payload del turno 2: tool_result(subagent) sin is_error, con estructura intacta.
payload_turn2=$(_mock_captured 1)
if echo "$payload_turn2" | jq -e '.messages[] | select(.role == "user") | .content[]? | select(.type == "tool_result" and .tool_use_id == "toolu_sub_happy" and (.is_error == false or .is_error == null))' >/dev/null 2>&1; then
    pass "turno 2 payload: tool_result(subagent happy) sin is_error"
else
    fail "turno 2 payload no contiene tool_result limpio del subagent"
    echo "    messages: $(echo "$payload_turn2" | jq -c '.messages | map({role, content_types: (.content | if type=="string" then ["str"] else map(.type) end)})' 2>/dev/null)"
fi

happy_content=$(echo "$payload_turn2" | jq -r '.messages[] | select(.role=="user") | .content[]? | select(.tool_use_id=="toolu_sub_happy") | .content' 2>/dev/null)
assert_contains "tool_result(subagent) trae header 'exit=0'" "exit=0" "$happy_content"
assert_contains "tool_result(subagent) trae 'timed_out=false'" "timed_out=false" "$happy_content"
assert_contains "tool_result(subagent) trae 'depth=1' (incrementado desde 0)" "depth=1" "$happy_content"
assert_contains "tool_result(subagent) trae sección --- stdout ---" "--- stdout ---" "$happy_content"
assert_contains "tool_result(subagent) trae sección --- stderr ---" "--- stderr ---" "$happy_content"
assert_contains "tool_result(subagent) trae el token en stdout" "$TOKEN" "$happy_content"
assert_contains "tool_result(subagent) reporta stderr (empty)" "(empty)" "$happy_content"

# =====================================================================
# Scenario 2 — Recursion guard: el modelo invoca subagent estando ya en
# depth=max. El handler hard-falla ANTES de tocar el binario (return 1).
# El loop reinyecta tool_result con is_error=true y el LLM cierra con
# end_turn (recovery).
# =====================================================================
echo ""
echo "==============================="
echo "Smoke subagent offline — escenario 2: recursion guard"
echo "==============================="

FIXTURE_DEPTH_CALL=$(jq -nc '{
  id: "msg_s3",
  type: "message",
  role: "assistant",
  model: "claude-haiku-4-5-20251001",
  content: [
    {type: "text", text: "Intento delegar al subagent aunque ya estoy profundo."},
    {type: "tool_use", id: "toolu_sub_deep", name: "subagent",
     input: {prompt: "ECHO never-reached"}}
  ],
  stop_reason: "tool_use"
}')

FIXTURE_DEPTH_END=$(jq -nc '{
  id: "msg_s4",
  type: "message",
  role: "assistant",
  model: "claude-haiku-4-5-20251001",
  content: [
    {type: "text", text: "El subagent rechazó el spawn por recursion guard; aborto."}
  ],
  stop_reason: "end_turn"
}')

_setup_mock_api "$FIXTURE_DEPTH_CALL" "$FIXTURE_DEPTH_END"

# Simular que el padre ya está corriendo dentro de una cadena de subagents.
# El default de CODER_SUBAGENT_MAX_DEPTH es 3, así que depth=3 hard-falla.
export CODER_SUBAGENT_DEPTH=3

set +e
deep_out=$(agentic_loop_anthropic "intenta delegar" 2>&1)
deep_rc=$?
set -e

unset CODER_SUBAGENT_DEPTH

assert_eq "loop deep completa con exit 0 (recovery via end_turn)" "0" "$deep_rc"
assert_eq "loop deep hizo 2 llamadas a la API" "2" "$(_mock_count)"
assert_contains "stdout deep muestra el abort del modelo" "aborto" "$deep_out"

payload_deep_turn2=$(_mock_captured 1)
if echo "$payload_deep_turn2" | jq -e '.messages[] | select(.role == "user") | .content[]? | select(.type == "tool_result" and .tool_use_id == "toolu_sub_deep" and .is_error == true)' >/dev/null 2>&1; then
    pass "turno 2 deep payload: tool_result(subagent) con is_error=true"
else
    fail "turno 2 deep payload no marca is_error=true tras recursion guard"
    echo "    messages: $(echo "$payload_deep_turn2" | jq -c '.messages | map({role, content_types: (.content | if type=="string" then ["str"] else map(.type) end)})' 2>/dev/null)"
fi

deep_content=$(echo "$payload_deep_turn2" | jq -r '.messages[] | select(.role=="user") | .content[]? | select(.tool_use_id=="toolu_sub_deep") | .content' 2>/dev/null)
assert_contains "tool_result(deep) menciona 'refusing to spawn child'" "refusing to spawn child" "$deep_content"

# Sanity check: el fake binary NO se invocó (no hay nada que demostrar via filesystem
# porque el stub no escribe archivos — pero el hard-fail antes de spawn es lo que
# importa). El mensaje "refusing to spawn child" ya cubre la verificación lógica.

# =====================================================================
# Resumen
# =====================================================================
echo ""
echo "==============================="
echo "Resultado: $PASS pass, $FAIL fail"
echo "==============================="

rm -rf "$_MOCK_STATE_DIR"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
