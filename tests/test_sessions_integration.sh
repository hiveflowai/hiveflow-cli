#!/bin/bash
# tests/test_sessions_integration.sh
# P1.sessions-2 — valida la integración de `lib/sessions.sh` con
# `modo_agentico_interactivo`: auto-persist al final de cada turno + creación
# de session al entrar + reanudación vía `CODER_RESUME_SESSION_ID` + graceful
# degradation cuando `sessions.sh` no está cargado.
#
# Estrategia: igual que test_modo_agentico_interactivo.sh — stubs de los 3
# adapters que apenan un assistant turn fijo. Aquí además sourceamos
# `lib/sessions.sh` y aislamos el storage vía CODER_SESSIONS_DIR.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT" || exit 1

# Isolation: tmpdir per run.
TMPROOT=$(mktemp -d -t coder_sessions_int.XXXXXX)
export CODER_SESSIONS_DIR="$TMPROOT/sessions"
export CONFIG_DIR="$TMPROOT/cfg"
mkdir -p "$CODER_SESSIONS_DIR" "$CONFIG_DIR"
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

# shellcheck source=../lib/sessions.sh disable=SC1091
source "$REPO_ROOT/lib/agent/sessions.sh"
# shellcheck source=../lib/tool_calling.sh disable=SC1091
source "$REPO_ROOT/lib/agent/tool_calling.sh"

pass=0
fail=0
note() { printf '%s\n' "$1"; }
assert_eq() {
    local got="$1" want="$2" label="$3"
    if [ "$got" = "$want" ]; then
        note "  PASS $label"; pass=$((pass + 1))
    else
        note "  FAIL $label"
        note "    got:  '$got'"
        note "    want: '$want'"
        fail=$((fail + 1))
    fi
}
assert_contains() {
    local hay="$1" needle="$2" label="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        note "  PASS $label"; pass=$((pass + 1))
    else
        note "  FAIL $label"
        note "    needle: '$needle'"
        note "    hay:    '$hay'"
        fail=$((fail + 1))
    fi
}
assert_not_contains() {
    local hay="$1" needle="$2" label="$3"
    if [[ "$hay" != *"$needle"* ]]; then
        note "  PASS $label"; pass=$((pass + 1))
    else
        note "  FAIL $label"
        note "    unexpected needle: '$needle'"
        fail=$((fail + 1))
    fi
}

_TMPOUT=$(mktemp -t modo_sess_stdout.XXXXXX)
_TMPERR=$(mktemp -t modo_sess_stderr.XXXXXX)
# add to existing trap
trap 'rm -rf "$TMPROOT"; rm -f "$_TMPOUT" "$_TMPERR"' EXIT INT TERM

# Stub adapter: appends fixed assistant turn, returns 0.
# shellcheck disable=SC2317
agentic_loop_anthropic_continue() {
    CODER_AGENTIC_MESSAGES=$(jq -nc --argjson m "$1" \
        '$m + [{role: "assistant", content: [{type: "text", text: "anthropic-reply"}]}]')
    return 0
}
# shellcheck disable=SC2317
agentic_loop_openai_continue() {
    CODER_AGENTIC_MESSAGES=$(jq -nc --argjson m "$1" \
        '$m + [{role: "assistant", content: "openai-reply"}]')
    return 0
}
# shellcheck disable=SC2317
agentic_loop_gemini_continue() {
    CODER_AGENTIC_MESSAGES=$(jq -nc --argjson m "$1" \
        '$m + [{role: "model", parts: [{text: "gemini-reply"}]}]')
    return 0
}

# Stub register_tool: no source real handlers; only mark registry.
# shellcheck disable=SC2317
register_tool() {
    [ -z "${1:-}" ] && return 2
    local existing
    if [ "${#REGISTERED_TOOLS[@]}" -gt 0 ]; then
        for existing in "${REGISTERED_TOOLS[@]}"; do
            [ "$existing" = "$1" ] && return 0
        done
    fi
    REGISTERED_TOOLS+=("$1")
    return 0
}

reset_state() {
    REGISTERED_TOOLS=()
    CODER_AGENTIC_MESSAGES='[]'
    unset CODER_RESUME_SESSION_ID
    # Wipe sessions dir between cases for clean assertions.
    rm -rf "$CODER_SESSIONS_DIR"
    mkdir -p "$CODER_SESSIONS_DIR"
}

LAST_RC=0; LAST_OUT=""; LAST_ERR=""
run_modo() {
    local input="$1"
    set +e
    modo_agentico_interactivo >"$_TMPOUT" 2>"$_TMPERR" <<<"$input"
    LAST_RC=$?
    set -e
    LAST_OUT="$(cat "$_TMPOUT")"
    LAST_ERR="$(cat "$_TMPERR")"
}

# ============================================================
note "## Session se crea on entry"
# ============================================================

reset_state
# shellcheck disable=SC2034
llm_choice="claude"
# shellcheck disable=SC2034
model="claude-opus-4-7"
run_modo "/exit"
assert_eq "$LAST_RC" "0" "claude + /exit (sin resume) → rc 0"

# Debe existir exactamente 1 session en disco.
created_count=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
assert_eq "$created_count" "1" "exactly 1 session creada on entry"

# meta.json del nuevo session debe tener provider=claude y model setteado.
new_session_dir=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
new_id=$(basename "$new_session_dir")
meta_provider=$(jq -r '.provider' "$new_session_dir/meta.json")
meta_model=$(jq -r '.model' "$new_session_dir/meta.json")
meta_turn=$(jq -r '.turn_count' "$new_session_dir/meta.json")
assert_eq "$meta_provider" "claude" "meta.json.provider == claude"
assert_eq "$meta_model" "claude-opus-4-7" "meta.json.model == claude-opus-4-7"
assert_eq "$meta_turn" "0" "turn_count = 0 (no turn ejecutado, sólo /exit)"

# /exit antes de turno → messages.json sigue []
init_msgs=$(cat "$new_session_dir/messages.json")
assert_eq "$init_msgs" "[]" "messages.json inicial = []"

# ============================================================
note "## Auto-persist tras un turno"
# ============================================================

reset_state
llm_choice="claude"
model="claude-opus-4-7"
run_modo "hello
/exit"
assert_eq "$LAST_RC" "0" "claude + turn + /exit → rc 0"
created_count=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
assert_eq "$created_count" "1" "exactly 1 session tras 1 turno"
new_session_dir=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
meta_turn=$(jq -r '.turn_count' "$new_session_dir/meta.json")
assert_eq "$meta_turn" "1" "turn_count = 1 tras un turno"
msgs=$(cat "$new_session_dir/messages.json")
# Debe contener tanto user ("hello") como assistant ("anthropic-reply")
msg_count=$(printf '%s' "$msgs" | jq 'length')
assert_eq "$msg_count" "2" "messages.json contiene user + assistant"
got_user=$(printf '%s' "$msgs" | jq -r '.[0].content')
got_assistant=$(printf '%s' "$msgs" | jq -r '.[1].content[0].text')
assert_eq "$got_user" "hello" "user message persistido"
assert_eq "$got_assistant" "anthropic-reply" "assistant message persistido"

# updated_at debe haber cambiado de created_at (al menos por bump).
created_at=$(jq -r '.created_at' "$new_session_dir/meta.json")
updated_at=$(jq -r '.updated_at' "$new_session_dir/meta.json")
assert_contains "$updated_at" "Z" "updated_at en formato ISO Z"
# created_at != "" siempre, updated_at != ""
assert_not_contains "$created_at" "null" "created_at no es null"
assert_not_contains "$updated_at" "null" "updated_at no es null"

# ============================================================
note "## Auto-persist multi-turno acumula"
# ============================================================

reset_state
llm_choice="claude"
model="claude-opus-4-7"
run_modo "first
second
/exit"
assert_eq "$LAST_RC" "0" "2 turnos + /exit → rc 0"
new_session_dir=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
meta_turn=$(jq -r '.turn_count' "$new_session_dir/meta.json")
assert_eq "$meta_turn" "2" "turn_count = 2 tras 2 turnos"
msg_count=$(jq 'length' "$new_session_dir/messages.json")
# 2 user + 2 assistant
assert_eq "$msg_count" "4" "messages.json contiene 4 entries"

# ============================================================
note "## Banner imprime Session ID cuando TTY"
# ============================================================
# El banner se imprime sólo en TTY (run_modo no es TTY → no debe imprimir).
# Verificamos que NO está en LAST_OUT (negative assertion: el contrato vigente).

assert_not_contains "$LAST_OUT" "Session:" "banner Session NO se imprime fuera de TTY"

# ============================================================
note "## Resume vía CODER_RESUME_SESSION_ID"
# ============================================================

reset_state
llm_choice="claude"
model="claude-opus-4-7"

# Setup: crear session manualmente con 1 mensaje previo.
seed_id=$(sessions_new "claude" "claude-opus-4-7" "seed")
seed_msgs='[{"role":"user","content":"previously"},{"role":"assistant","content":[{"type":"text","text":"prev-reply"}]}]'
sessions_save "$seed_id" "$seed_msgs" "claude" "claude-opus-4-7"
seed_turn_before=$(jq -r '.turn_count' "$CODER_SESSIONS_DIR/$seed_id/meta.json")
assert_eq "$seed_turn_before" "1" "seed turn_count == 1 antes del resume"

# Resume:
export CODER_RESUME_SESSION_ID="$seed_id"
run_modo "now
/exit"
assert_eq "$LAST_RC" "0" "resume + turno + /exit → rc 0"

# No debe haber sessions adicionales — sólo el seed.
total_count=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
assert_eq "$total_count" "1" "resume NO crea session nueva"

# El seed debe haber crecido: turn_count == 2, messages == 4
seed_turn_after=$(jq -r '.turn_count' "$CODER_SESSIONS_DIR/$seed_id/meta.json")
assert_eq "$seed_turn_after" "2" "seed turn_count == 2 tras resume + 1 turno"
seed_msg_count=$(jq 'length' "$CODER_SESSIONS_DIR/$seed_id/messages.json")
assert_eq "$seed_msg_count" "4" "seed messages.json contiene 4 entries (prev 2 + new 2)"
# El primer mensaje sigue siendo "previously"
first_user=$(jq -r '.[0].content' "$CODER_SESSIONS_DIR/$seed_id/messages.json")
assert_eq "$first_user" "previously" "primer user message preservado del seed"
last_user=$(jq -r '.[2].content' "$CODER_SESSIONS_DIR/$seed_id/messages.json")
assert_eq "$last_user" "now" "nuevo user message append-eado"

# ============================================================
note "## Resume con session inexistente: crea nueva + warning"
# ============================================================

reset_state
llm_choice="claude"
model="claude-opus-4-7"
export CODER_RESUME_SESSION_ID="nonexistent-123"
run_modo "/exit"
assert_eq "$LAST_RC" "0" "resume con session inexistente → rc 0 (no fatal)"
assert_contains "$LAST_ERR" "session not found: nonexistent-123" "stderr menciona session no encontrada"
# Debe haberse creado una session nueva con un id auto-generado (distinto de "nonexistent-123")
created_count=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
assert_eq "$created_count" "1" "session nueva creada como fallback"
new_id=$(basename "$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)")
[ "$new_id" != "nonexistent-123" ] && { note "  PASS new id != requested"; pass=$((pass+1)); } \
    || { note "  FAIL new id == requested ($new_id)"; fail=$((fail+1)); }

# ============================================================
note "## OpenAI provider persiste igualmente"
# ============================================================

reset_state
llm_choice="chatgpt"
model="gpt-4o-mini"
run_modo "hola
/exit"
assert_eq "$LAST_RC" "0" "openai turn → rc 0"
new_session_dir=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
meta_provider=$(jq -r '.provider' "$new_session_dir/meta.json")
meta_model=$(jq -r '.model' "$new_session_dir/meta.json")
assert_eq "$meta_provider" "chatgpt" "openai session provider == chatgpt"
assert_eq "$meta_model" "gpt-4o-mini" "openai session model == gpt-4o-mini"
msg_count=$(jq 'length' "$new_session_dir/messages.json")
assert_eq "$msg_count" "2" "openai persiste user+assistant"

# ============================================================
note "## Gemini provider persiste con parts shape"
# ============================================================

reset_state
llm_choice="gemini"
model="gemini-2.0-flash"
run_modo "hello
/exit"
assert_eq "$LAST_RC" "0" "gemini turn → rc 0"
new_session_dir=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
meta_provider=$(jq -r '.provider' "$new_session_dir/meta.json")
assert_eq "$meta_provider" "gemini" "gemini session provider == gemini"
# La shape de gemini usa .parts[0].text
first_part_text=$(jq -r '.[0].parts[0].text' "$new_session_dir/messages.json")
assert_eq "$first_part_text" "hello" "gemini user message en .parts[0].text"

# ============================================================
note "## /reset NO crea nueva session (sólo limpia in-memory)"
# ============================================================

reset_state
llm_choice="claude"
model="claude-opus-4-7"
run_modo "first
/reset
second
/exit"
assert_eq "$LAST_RC" "0" "reset flow → rc 0"
# Sigue habiendo exactamente 1 session
total_count=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
assert_eq "$total_count" "1" "/reset NO genera nueva session"
new_session_dir=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
# Después de /reset, el segundo turno persiste sobre la session original,
# pisando los messages anteriores. turn_count se incrementa con cada save.
meta_turn=$(jq -r '.turn_count' "$new_session_dir/meta.json")
assert_eq "$meta_turn" "2" "turn_count = 2 (1 turn pre-reset + 1 post-reset persisted)"
# Tras /reset + 1 turno, messages.json sólo contiene el último round: 2 entries
final_msg_count=$(jq 'length' "$new_session_dir/messages.json")
assert_eq "$final_msg_count" "2" "messages.json tras /reset+turno = 2 entries (no acumula reset)"
last_user=$(jq -r '.[0].content' "$new_session_dir/messages.json")
assert_eq "$last_user" "second" "primer message post-reset es 'second'"

# ============================================================
note "## adapter rc != 0 persiste lo que haya en messages igualmente"
# ============================================================

# Override stub para devolver rc 1 con messages parcial.
# shellcheck disable=SC2317
agentic_loop_anthropic_continue() {
    CODER_AGENTIC_MESSAGES=$(jq -nc --argjson m "$1" \
        '$m + [{role: "assistant", content: [{type: "text", text: "partial"}]}]')
    return 1
}

reset_state
llm_choice="claude"
model="claude-opus-4-7"
run_modo "boom
/exit"
assert_eq "$LAST_RC" "0" "adapter rc!=0 → loop continúa, /exit rc 0"
assert_contains "$LAST_ERR" "adapter rc=1" "stderr propaga warning adapter rc"
new_session_dir=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
msg_count=$(jq 'length' "$new_session_dir/messages.json")
assert_eq "$msg_count" "2" "messages parcial persistido incluso con adapter rc 1"
# Restore happy adapter.
# shellcheck disable=SC2317
agentic_loop_anthropic_continue() {
    CODER_AGENTIC_MESSAGES=$(jq -nc --argjson m "$1" \
        '$m + [{role: "assistant", content: [{type: "text", text: "anthropic-reply"}]}]')
    return 0
}

# ============================================================
note "## Graceful degradation: sin sessions_save → no persiste, no crashea"
# ============================================================

reset_state
llm_choice="claude"
model="claude-opus-4-7"

# Unset las funciones del módulo sessions y wipe registry de sessions
_backup_sessions_save=$(declare -f sessions_save)
_backup_sessions_new=$(declare -f sessions_new)
_backup_sessions_exists=$(declare -f sessions_exists)
_backup_sessions_load=$(declare -f sessions_load)
unset -f sessions_save sessions_new sessions_exists sessions_load

run_modo "msg
/exit"
restore_rc=$LAST_RC

# Restaurar fns sin importar lo que pasó.
eval "$_backup_sessions_save"
eval "$_backup_sessions_new"
eval "$_backup_sessions_exists"
eval "$_backup_sessions_load"

assert_eq "$restore_rc" "0" "loop funciona sin sessions_save (rc 0)"
# No debe haber sessions persistidas.
total_count=$(find "$CODER_SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$total_count" "0" "sin sessions_save → ninguna session creada"

# ============================================================
note "## Resultado"
# ============================================================
echo "  pass: $pass"
echo "  fail: $fail"
[ "$fail" -eq 0 ]
