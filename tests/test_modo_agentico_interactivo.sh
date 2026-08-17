#!/bin/bash
# tests/test_modo_agentico_interactivo.sh
# P1.1c — valida el loop multi-turn de `modo_agentico_interactivo`:
# input parsing + comandos especiales + routing por provider + threading
# del messages[] entre turnos vía CODER_AGENTIC_MESSAGES.
#
# Estrategia: stubear los 3 `agentic_loop_<provider>_continue` con
# implementaciones bash puras que capturan el messages_json recibido a un
# tmpfile y emiten un assistant turn fijo en CODER_AGENTIC_MESSAGES. Stub
# de `register_tool` que NO sourcea handlers reales — sólo marca registry.
# Los read del usuario se alimentan vía here-doc, sin subshell, para que
# CODER_AGENTIC_MESSAGES propague al shell padre.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT" || exit 1

# shellcheck source=../lib/tool_calling.sh disable=SC1091
source "$REPO_ROOT/lib/agent/tool_calling.sh"

pass=0
fail=0
note() { printf '%s\n' "$1"; }
assert_eq() {
    local got="$1" want="$2" label="$3"
    if [ "$got" = "$want" ]; then
        note "  PASS $label"
        pass=$((pass + 1))
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
        note "  PASS $label"
        pass=$((pass + 1))
    else
        note "  FAIL $label"
        note "    needle: '$needle'"
        note "    hay:    '$hay'"
        fail=$((fail + 1))
    fi
}
assert_jq() {
    local label="$1" expr="$2" json="$3"
    local got
    got=$(printf '%s' "$json" | jq -r "$expr" 2>/dev/null)
    assert_eq "$got" "true" "$label"
}

# tmpfiles reutilizables. Usamos `>` (no `>>`) en run_modo para no acumular.
_TMPOUT=$(mktemp -t modo_agentic_stdout.XXXXXX)
_TMPERR=$(mktemp -t modo_agentic_stderr.XXXXXX)
_CAPTURE_DIR=$(mktemp -d -t modo_agentic_cap.XXXXXX)
trap 'rm -f "$_TMPOUT" "$_TMPERR"; rm -rf "$_CAPTURE_DIR"' EXIT INT TERM

reset_capture() {
    rm -rf "$_CAPTURE_DIR"
    mkdir -p "$_CAPTURE_DIR"
    echo 0 > "$_CAPTURE_DIR/count"
}

# shellcheck disable=SC2317  # invocado indirectamente desde los stubs de los adapters
_record() {
    local n
    n=$(cat "$_CAPTURE_DIR/count")
    printf '%s' "$1" > "$_CAPTURE_DIR/msg-$n"
    printf '%s' "$2" > "$_CAPTURE_DIR/provider-$n"
    echo "$((n + 1))" > "$_CAPTURE_DIR/count"
}
_calls() { cat "$_CAPTURE_DIR/count"; }
_call_msg() { cat "$_CAPTURE_DIR/msg-$1" 2>/dev/null; }
_call_provider() { cat "$_CAPTURE_DIR/provider-$1" 2>/dev/null; }

# Stubs de los 3 adapters. Cada uno apenda un assistant turn fijo al
# messages_in y lo escribe en CODER_AGENTIC_MESSAGES, simulando el contrato
# real (happy path con assistant apendido) sin tocar red.
# shellcheck disable=SC2317
agentic_loop_anthropic_continue() {
    _record "$1" "anthropic"
    echo "anthropic-reply"
    CODER_AGENTIC_MESSAGES=$(jq -nc --argjson m "$1" \
        '$m + [{role: "assistant", content: [{type: "text", text: "anthropic-reply"}]}]')
    return 0
}
# shellcheck disable=SC2317
agentic_loop_openai_continue() {
    _record "$1" "openai"
    echo "openai-reply"
    CODER_AGENTIC_MESSAGES=$(jq -nc --argjson m "$1" \
        '$m + [{role: "assistant", content: "openai-reply"}]')
    return 0
}
# shellcheck disable=SC2317
agentic_loop_gemini_continue() {
    _record "$1" "gemini"
    echo "gemini-reply"
    CODER_AGENTIC_MESSAGES=$(jq -nc --argjson m "$1" \
        '$m + [{role: "model", parts: [{text: "gemini-reply"}]}]')
    return 0
}

# Stub de register_tool — no source archivos reales, sólo marca registry.
# REGISTER_FAIL_TARGET (global, opt-in) hace que la tool nombrada falle con
# return 1; vacío = todo registra OK. Reutilizamos el mismo stub para los
# tests de éxito y de falla.
REGISTER_FAIL_TARGET=""
# shellcheck disable=SC2317
register_tool() {
    if [ -z "${1:-}" ]; then return 2; fi
    if [ "$1" = "${REGISTER_FAIL_TARGET:-}" ]; then return 1; fi
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
    reset_capture
}

# run_modo <stdin_string>
# Ejecuta modo_agentico_interactivo con el here-string como stdin, sin
# crear subshell, y persiste rc/out/err para asserts.
LAST_RC=0
LAST_OUT=""
LAST_ERR=""
run_modo() {
    local input="$1"
    set +e
    modo_agentico_interactivo >"$_TMPOUT" 2>"$_TMPERR" <<<"$input"
    LAST_RC=$?
    set -e
    LAST_OUT="$(cat "$_TMPOUT")"
    LAST_ERR="$(cat "$_TMPERR")"
}

note "## Validación: provider"

reset_state
# shellcheck disable=SC2034
llm_choice=""
run_modo ""
assert_eq "$LAST_RC" "2" "llm_choice vacío → exit 2"
assert_contains "$LAST_ERR" "llm_choice is not configured" "stderr menciona llm_choice"

reset_state
llm_choice="bogus"
run_modo ""
assert_eq "$LAST_RC" "2" "unsupported provider → exit 2"
assert_contains "$LAST_ERR" "unsupported provider" "stderr menciona unsupported provider"

note "## Side-effects: tool registration"

reset_state
llm_choice="claude"
run_modo "/exit"
assert_eq "$LAST_RC" "0" "claude + /exit → exit 0"
found_read=0; found_write=0; found_edit=0; found_bash=0; found_web=0; found_grep=0; found_glob=0; found_subagent=0
if [ "${#REGISTERED_TOOLS[@]}" -gt 0 ]; then
    for t in "${REGISTERED_TOOLS[@]}"; do
        case "$t" in
            read_file)   found_read=1 ;;
            write_file)  found_write=1 ;;
            edit_file)   found_edit=1 ;;
            bash_exec)   found_bash=1 ;;
            web_fetch)   found_web=1 ;;
            grep_search) found_grep=1 ;;
            glob_files)  found_glob=1 ;;
            subagent)    found_subagent=1 ;;
        esac
    done
fi
assert_eq "$found_read" "1"  "read_file registrada"
assert_eq "$found_write" "1" "write_file registrada"
assert_eq "$found_edit" "1"  "edit_file registrada"
assert_eq "$found_bash" "1"  "bash_exec registrada"
assert_eq "$found_web" "1"   "web_fetch registrada"
assert_eq "$found_grep" "1"  "grep_search registrada"
assert_eq "$found_glob" "1"  "glob_files registrada"
assert_eq "$found_subagent" "1" "subagent registrada"

note "## Failure path: register_tool falla"

reset_state
llm_choice="claude"
REGISTER_FAIL_TARGET="read_file"
run_modo "/exit"
assert_eq "$LAST_RC" "1" "register_tool read_file falla → exit 1"
assert_contains "$LAST_ERR" "failed to register tool read_file" "stderr menciona falló read_file"

reset_state
llm_choice="claude"
REGISTER_FAIL_TARGET="bash_exec"
run_modo "/exit"
assert_eq "$LAST_RC" "1" "register_tool bash_exec falla → exit 1"
assert_contains "$LAST_ERR" "failed to register tool bash_exec" "stderr menciona falló bash_exec"

reset_state
llm_choice="claude"
REGISTER_FAIL_TARGET="web_fetch"
run_modo "/exit"
assert_eq "$LAST_RC" "1" "register_tool web_fetch falla → exit 1"
assert_contains "$LAST_ERR" "failed to register tool web_fetch" "stderr menciona falló web_fetch"

reset_state
llm_choice="claude"
REGISTER_FAIL_TARGET="grep_search"
run_modo "/exit"
assert_eq "$LAST_RC" "1" "register_tool grep_search falla → exit 1"
assert_contains "$LAST_ERR" "failed to register tool grep_search" "stderr menciona falló grep_search"

reset_state
llm_choice="claude"
REGISTER_FAIL_TARGET="glob_files"
run_modo "/exit"
assert_eq "$LAST_RC" "1" "register_tool glob_files falla → exit 1"
assert_contains "$LAST_ERR" "failed to register tool glob_files" "stderr menciona falló glob_files"

reset_state
llm_choice="claude"
REGISTER_FAIL_TARGET="subagent"
run_modo "/exit"
assert_eq "$LAST_RC" "1" "register_tool subagent falla → exit 1"
assert_contains "$LAST_ERR" "failed to register tool subagent" "stderr menciona falló subagent"

# Restore: no fail target for the rest of the suite (mismo stub register_tool
# se reutiliza con REGISTER_FAIL_TARGET vacío).
REGISTER_FAIL_TARGET=""

note "## Comandos de salida — adapter no se invoca"

for cmd in "/exit" "/quit" "/salir" "exit" "quit" "salir"; do
    reset_state
    llm_choice="claude"
    run_modo "$cmd"
    assert_eq "$LAST_RC" "0" "input '$cmd' → exit 0"
    assert_eq "$(_calls)" "0" "input '$cmd' → adapter NO invocado"
done

note "## EOF cierra limpio"

reset_state
llm_choice="claude"
run_modo ""
assert_eq "$LAST_RC" "0" "EOF (input vacío) → exit 0"
assert_eq "$(_calls)" "0" "EOF sin user turn → adapter NO invocado"

note "## /reset y /help no llaman al adapter"

reset_state
llm_choice="claude"
run_modo "/help
/reset
/exit"
assert_eq "$LAST_RC" "0" "/help + /reset + /exit → exit 0"
assert_eq "$(_calls)" "0" "/help y /reset no invocan adapter"
assert_contains "$LAST_OUT" "modo_agentico_interactivo — commands" "/help imprime header"
assert_contains "$LAST_OUT" "/exit | /quit | /salir" "/help lista comandos de salida"

note "## Líneas vacías y whitespace se ignoran"

reset_state
llm_choice="claude"
# Tres líneas: blank, espacios, /exit
run_modo "


/exit"
assert_eq "$LAST_RC" "0" "líneas vacías + /exit → exit 0"
assert_eq "$(_calls)" "0" "líneas vacías no invocan adapter"

note "## Single turn — claude (anthropic)"

reset_state
llm_choice="claude"
run_modo "hola mundo
/exit"
assert_eq "$LAST_RC" "0" "claude single turn → exit 0"
assert_eq "$(_calls)" "1" "claude single turn → 1 call al adapter"
assert_eq "$(_call_provider 0)" "anthropic" "claude → agentic_loop_anthropic_continue"
msg=$(_call_msg 0)
assert_jq "messages[] es array length 1" 'type == "array" and length == 1' "$msg"
assert_jq "messages[0].role == user" '.[0].role == "user"' "$msg"
assert_jq "messages[0].content == hola mundo" '.[0].content == "hola mundo"' "$msg"
assert_contains "$LAST_OUT" "anthropic-reply" "stdout muestra texto del modelo"

note "## Single turn — chatgpt (openai)"

reset_state
llm_choice="chatgpt"
run_modo "openai prompt
/exit"
assert_eq "$LAST_RC" "0" "chatgpt single turn → exit 0"
assert_eq "$(_call_provider 0)" "openai" "chatgpt → agentic_loop_openai_continue"
msg=$(_call_msg 0)
assert_jq "openai messages[0].role == user" '.[0].role == "user"' "$msg"
assert_jq "openai messages[0].content string" '.[0].content == "openai prompt"' "$msg"

note "## Single turn — gemini (parts shape)"

reset_state
llm_choice="gemini"
run_modo "gemini prompt
/exit"
assert_eq "$LAST_RC" "0" "gemini single turn → exit 0"
assert_eq "$(_call_provider 0)" "gemini" "gemini → agentic_loop_gemini_continue"
msg=$(_call_msg 0)
assert_jq "gemini contents[0].role == user" '.[0].role == "user"' "$msg"
assert_jq "gemini contents[0].parts[0].text" '.[0].parts[0].text == "gemini prompt"' "$msg"

note "## Multi-turn threading — segundo turno ve assistant del primero"

reset_state
llm_choice="claude"
run_modo "primer mensaje
segundo mensaje
/exit"
assert_eq "$LAST_RC" "0" "claude 2 turns → exit 0"
assert_eq "$(_calls)" "2" "claude 2 turns → 2 calls al adapter"
msg0=$(_call_msg 0)
msg1=$(_call_msg 1)
assert_jq "turn 0 messages.length == 1" 'length == 1' "$msg0"
assert_jq "turn 1 messages.length == 3" 'length == 3' "$msg1"
assert_jq "turn 1 m[0] user primer mensaje" '.[0].role == "user" and .[0].content == "primer mensaje"' "$msg1"
assert_jq "turn 1 m[1] role == assistant" '.[1].role == "assistant"' "$msg1"
assert_jq "turn 1 m[2] user segundo mensaje" '.[2].role == "user" and .[2].content == "segundo mensaje"' "$msg1"

note "## /reset vacía el historial entre turnos"

reset_state
llm_choice="claude"
run_modo "uno
/reset
dos
/exit"
assert_eq "$LAST_RC" "0" "/reset middle → exit 0"
assert_eq "$(_calls)" "2" "/reset no consume turn; sigue habiendo 2 calls"
post_reset=$(_call_msg 1)
assert_jq "post-/reset messages.length == 1" 'length == 1' "$post_reset"
assert_jq "post-/reset content == dos" '.[0].content == "dos"' "$post_reset"

note "## Multi-turn gemini con parts shape preservada"

reset_state
llm_choice="gemini"
run_modo "uno
dos
/exit"
assert_eq "$LAST_RC" "0" "gemini 2 turns → exit 0"
msg1=$(_call_msg 1)
assert_jq "gemini turn1.length == 3" 'length == 3' "$msg1"
assert_jq "gemini turn1[0] user parts" '.[0].role == "user" and .[0].parts[0].text == "uno"' "$msg1"
assert_jq "gemini turn1[1] model role" '.[1].role == "model"' "$msg1"
assert_jq "gemini turn1[2] user parts dos" '.[2].role == "user" and .[2].parts[0].text == "dos"' "$msg1"

note "## Adapter error — loop continúa, mensaje a stderr"

# Override anthropic adapter para fallar en la primera call, succeed en la segunda.
# shellcheck disable=SC2317
agentic_loop_anthropic_continue() {
    _record "$1" "anthropic"
    local n
    n=$(($(cat "$_CAPTURE_DIR/count") - 1))
    if [ "$n" = "0" ]; then
        echo "adapter error simulado" >&2
        CODER_AGENTIC_MESSAGES="$1"
        return 1
    fi
    echo "anthropic-reply"
    CODER_AGENTIC_MESSAGES=$(jq -nc --argjson m "$1" \
        '$m + [{role: "assistant", content: [{type: "text", text: "anthropic-reply"}]}]')
    return 0
}

reset_state
llm_choice="claude"
run_modo "uno
dos
/exit"
assert_eq "$LAST_RC" "0" "adapter error pero loop sigue → exit 0"
assert_eq "$(_calls)" "2" "loop hace 2 calls a pesar de rc=1 en primera"
assert_contains "$LAST_ERR" "adapter rc=1" "stderr menciona el rc del adapter"

# Restaurar el stub happy path para no contaminar suite si se extiende.
# shellcheck disable=SC2317,SC2034  # CODER_AGENTIC_MESSAGES leído por modo_agentico_interactivo
agentic_loop_anthropic_continue() {
    _record "$1" "anthropic"
    echo "anthropic-reply"
    CODER_AGENTIC_MESSAGES=$(jq -nc --argjson m "$1" \
        '$m + [{role: "assistant", content: [{type: "text", text: "anthropic-reply"}]}]')
    return 0
}

note "## Input con caracteres especiales escapados correctamente"

reset_state
# shellcheck disable=SC2034  # llm_choice leído por modo_agentico_interactivo
llm_choice="claude"
# Doble-quotes y backslashes en el input — jq --arg debería escapar.
run_modo 'dime "hola \"mundo\"" con backslash \\test
/exit'
assert_eq "$LAST_RC" "0" "input con quotes/backslash → exit 0"
msg=$(_call_msg 0)
assert_jq "messages[0] es JSON válido" 'type == "array"' "$msg"
assert_jq "content preserva quotes" '.[0].content | contains("\"hola")' "$msg"

note "## Slash commands traducibles (P1.1d) — happy paths"

# Cada slash translated debe (a) producir 1 call al adapter, (b) tener el prompt
# expandido (no el literal "/foo") en messages[0].content. Probamos con claude
# (anthropic-style content string) — la traducción es provider-agnostic en el
# helper, así que cubrir un provider cierra el caso para los 3.

run_translate() {
    # run_translate <input-line>  → ejecuta input + /exit, deja msg en LAST_MSG.
    local input="$1"
    reset_state
    # shellcheck disable=SC2034
    llm_choice="claude"
    run_modo "$input
/exit"
    LAST_MSG=$(_call_msg 0)
}

run_translate "/analyze"
assert_eq "$LAST_RC" "0" "/analyze → exit 0"
assert_eq "$(_calls)" "1" "/analyze → 1 call al adapter"
assert_jq "/analyze content NO es literal /analyze" '.[0].content != "/analyze"' "$LAST_MSG"
assert_jq "/analyze content menciona análisis" '.[0].content | contains("Analyze")' "$LAST_MSG"
assert_jq "/analyze content menciona bash_exec" '.[0].content | contains("bash_exec")' "$LAST_MSG"

run_translate "/refactor"
assert_eq "$LAST_RC" "0" "/refactor (sin args) → exit 0"
assert_eq "$(_calls)" "1" "/refactor → 1 call"
assert_jq "/refactor menciona refactorización" '.[0].content | contains("refactor")' "$LAST_MSG"
assert_jq "/refactor menciona dry_run" '.[0].content | contains("dry_run")' "$LAST_MSG"

run_translate "/refactor tests/fixtures/sample_config.sh"
assert_eq "$(_calls)" "1" "/refactor con target → 1 call"
assert_jq "/refactor con target incluye target" '.[0].content | contains("tests/fixtures/sample_config.sh")' "$LAST_MSG"

run_translate "/review"
assert_eq "$(_calls)" "1" "/review → 1 call"
assert_jq "/review menciona revisión" '.[0].content | contains("code review")' "$LAST_MSG"

run_translate "/security"
assert_eq "$(_calls)" "1" "/security → 1 call"
assert_jq "/security menciona seguridad" '.[0].content | contains("security")' "$LAST_MSG"

run_translate "/performance"
assert_eq "$(_calls)" "1" "/performance → 1 call"
assert_jq "/performance menciona rendimiento" '.[0].content | contains("performance")' "$LAST_MSG"

run_translate "/test"
assert_eq "$(_calls)" "1" "/test → 1 call"
assert_jq "/test menciona write_file" '.[0].content | contains("write_file")' "$LAST_MSG"
assert_jq "/test menciona tests" '.[0].content | contains("tests")' "$LAST_MSG"

run_translate "/docs"
assert_eq "$(_calls)" "1" "/docs → 1 call"
assert_jq "/docs menciona documentación" '.[0].content | contains("documentation")' "$LAST_MSG"

run_translate "/think el diseño de la denylist"
assert_eq "$(_calls)" "1" "/think con tema → 1 call"
assert_jq "/think incluye el tema" '.[0].content | contains("denylist")' "$LAST_MSG"
assert_jq "/think menciona paso a paso" '.[0].content | contains("step by step")' "$LAST_MSG"

run_translate "/files"
assert_eq "$(_calls)" "1" "/files → 1 call"
assert_jq "/files menciona bash_exec" '.[0].content | contains("bash_exec")' "$LAST_MSG"

run_translate "/focus lib/permissions.sh"
assert_eq "$(_calls)" "1" "/focus con archivo → 1 call"
assert_jq "/focus incluye el archivo" '.[0].content | contains("lib/permissions.sh")' "$LAST_MSG"
assert_jq "/focus menciona read_file" '.[0].content | contains("read_file")' "$LAST_MSG"

run_translate "/summary"
assert_eq "$(_calls)" "1" "/summary → 1 call"
assert_jq "/summary menciona resumen" '.[0].content | contains("summary")' "$LAST_MSG"

run_translate "/fix el regex en jq escapa mal los slashes"
assert_eq "$(_calls)" "1" "/fix con descripción → 1 call"
assert_jq "/fix incluye la descripción" '.[0].content | contains("jq escapa")' "$LAST_MSG"
assert_jq "/fix menciona dry_run" '.[0].content | contains("dry_run")' "$LAST_MSG"

run_translate "/agent corre 'ls' y dime cuántos archivos hay"
assert_eq "$(_calls)" "1" "/agent con prompt → 1 call"
# /agent <prompt> en modo agentic = pasar el prompt directo (sin envoltorio).
assert_jq "/agent pasa el prompt directo" '.[0].content == "corre '\''ls'\'' y dime cuántos archivos hay"' "$LAST_MSG"

note "## Slash commands con args faltantes — mensaje + skip"

reset_state
llm_choice="claude"
run_modo "/think
/exit"
assert_eq "$LAST_RC" "0" "/think sin args → exit 0 (loop sigue)"
assert_eq "$(_calls)" "0" "/think sin args → adapter NO invocado"
assert_contains "$LAST_ERR" "/think requires a topic" "stderr menciona uso de /think"

reset_state
llm_choice="claude"
run_modo "/focus
/exit"
assert_eq "$LAST_RC" "0" "/focus sin args → exit 0"
assert_eq "$(_calls)" "0" "/focus sin args → adapter NO invocado"
assert_contains "$LAST_ERR" "/focus requires a file" "stderr menciona uso de /focus"

reset_state
llm_choice="claude"
run_modo "/fix
/exit"
assert_eq "$LAST_RC" "0" "/fix sin args → exit 0"
assert_eq "$(_calls)" "0" "/fix sin args → adapter NO invocado"
assert_contains "$LAST_ERR" "/fix requires a problem description" "stderr menciona uso de /fix"

reset_state
llm_choice="claude"
run_modo "/agent
/exit"
assert_eq "$LAST_RC" "0" "/agent sin args → exit 0"
assert_eq "$(_calls)" "0" "/agent sin args → adapter NO invocado"
assert_contains "$LAST_ERR" "/agent requires a prompt" "stderr menciona uso de /agent"

note "## Slash desconocido — skip, no adapter, loop sigue"

reset_state
llm_choice="claude"
run_modo "/unknownslash arg1 arg2
hola
/exit"
assert_eq "$LAST_RC" "0" "/unknown → exit 0"
assert_eq "$(_calls)" "1" "tras /unknown, 'hola' SÍ invoca adapter (1 call)"
msg=$(_call_msg 0)
assert_jq "el call es 'hola', NO el slash desconocido" '.[0].content == "hola"' "$msg"

note "## /help nuevo lista los slash translated"

reset_state
llm_choice="claude"
run_modo "/help
/exit"
assert_eq "$(_calls)" "0" "/help no invoca adapter"
assert_contains "$LAST_OUT" "/analyze" "/help lista /analyze"
assert_contains "$LAST_OUT" "/refactor" "/help lista /refactor"
assert_contains "$LAST_OUT" "/fix" "/help lista /fix"
assert_contains "$LAST_OUT" "P1.1d" "/help marca sección con tag de iter"

note "## Multi-turn con slash translated + texto plano

# Verifica que un slash translated y un mensaje plano threadean correctamente
# (el segundo turn ve el primer prompt expandido + assistant reply en messages)."

reset_state
llm_choice="claude"
run_modo "/files
ahora resume lo que viste
/exit"
assert_eq "$(_calls)" "2" "slash + plain → 2 calls"
msg1=$(_call_msg 1)
assert_jq "turn 1 length == 3" 'length == 3' "$msg1"
assert_jq "turn 1[0] role user" '.[0].role == "user"' "$msg1"
assert_jq "turn 1[0] tiene el prompt expandido de /files" '.[0].content | contains("bash_exec")' "$msg1"
assert_jq "turn 1[1] assistant" '.[1].role == "assistant"' "$msg1"
assert_jq "turn 1[2] user con texto plano" '.[2].content == "ahora resume lo que viste"' "$msg1"

note "## Slash translated funciona en gemini (parts shape)"

reset_state
# shellcheck disable=SC2034  # llm_choice leído por modo_agentico_interactivo
llm_choice="gemini"
run_modo "/analyze
/exit"
assert_eq "$(_call_provider 0)" "gemini" "gemini → adapter gemini"
msg=$(_call_msg 0)
assert_jq "gemini /analyze parts shape" '.[0].role == "user" and (.[0].parts[0].text | contains("Analyze"))' "$msg"

note ""
note "## Resultado"
note "  pass: $pass"
note "  fail: $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
