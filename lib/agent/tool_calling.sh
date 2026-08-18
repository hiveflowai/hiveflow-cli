#!/bin/bash

# ==========================================
# MÓDULO DE TOOL CALLING - tool_calling.sh
# ==========================================
# Registry + dispatcher para tools agentic (scaffolding M1.1).
# Canonical internal format: Anthropic-style tool definitions
# ({name, description, input_schema}). Adapters por provider llegan en M1.3+
# como funciones agentic_loop_<provider>.
#
# Cada tool vive en lib/tools/<name>.sh y debe definir:
#   tool_<name>_definition  -> emite JSON schema a stdout
#   tool_<name>_handler     -> recibe input JSON como $1, emite resultado a stdout

# Guard contra doble-source (este módulo puede ser sourceado desde coder.sh
# y también desde scripts de test).
if [ -n "${_TOOL_CALLING_LOADED:-}" ]; then
    return 0
fi
_TOOL_CALLING_LOADED=1

# i18n fallback: hf_t existe aunque i18n.sh no esté cargado (tests sourcean directo).
type hf_t >/dev/null 2>&1 || hf_t() { if [ "${HF_LANG:-en}" = "es" ] && [ -n "${2:-}" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# Resolver TOOLS_DIR relativo a este archivo. Override via variable de entorno.
_TOOL_CALLING_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
TOOLS_DIR="${TOOLS_DIR:-$_TOOL_CALLING_SELF_DIR/tools}"

# Registry de tools cargadas. Inicializar vacío.
REGISTERED_TOOLS=()

# Cap por defecto de iteraciones del loop ReAct (consumido por agentic_loop_*).
TOOL_LOOP_MAX_ITERATIONS="${TOOL_LOOP_MAX_ITERATIONS:-25}"

# Estado de salida de los `agentic_loop_<provider>_continue`: contiene el JSON
# array final de messages/contents tras cada invocación. Lo consumen callers
# multi-turn (futuro `modo_agentico_interactivo`, P1.1c) leyendo el valor
# inmediatamente después del return.
# shellcheck disable=SC2034
CODER_AGENTIC_MESSAGES="${CODER_AGENTIC_MESSAGES:-[]}"

# register_tool <name>
# Sourcea lib/tools/<name>.sh y registra el nombre.
# Retorna 0 si OK, 1 si archivo/funciones faltan, 2 si argumento inválido.
register_tool() {
    local name="$1"
    local handler_file="$TOOLS_DIR/${name}.sh"
    local existing

    if [ -z "$name" ]; then
        echo "register_tool: missing tool name" >&2
        return 2
    fi

    if [ ! -f "$handler_file" ]; then
        echo "register_tool: handler file not found: $handler_file" >&2
        return 1
    fi

    # shellcheck disable=SC1090
    source "$handler_file"

    if ! declare -f "tool_${name}_definition" >/dev/null; then
        echo "register_tool: missing function tool_${name}_definition in $handler_file" >&2
        return 1
    fi

    if ! declare -f "tool_${name}_handler" >/dev/null; then
        echo "register_tool: missing function tool_${name}_handler in $handler_file" >&2
        return 1
    fi

    # Evitar duplicados.
    if [ "${#REGISTERED_TOOLS[@]}" -gt 0 ]; then
        for existing in "${REGISTERED_TOOLS[@]}"; do
            if [ "$existing" = "$name" ]; then
                return 0
            fi
        done
    fi

    REGISTERED_TOOLS+=("$name")
    return 0
}

# get_tool_definition <name>
# Emite el JSON definition de la tool. Retorna 1 si no está registrada.
get_tool_definition() {
    local name="$1"
    local fn="tool_${name}_definition"

    if [ -z "$name" ]; then
        echo "get_tool_definition: missing tool name" >&2
        return 2
    fi

    if ! declare -f "$fn" >/dev/null; then
        echo "get_tool_definition: tool not registered: $name" >&2
        return 1
    fi

    "$fn"
}

# get_all_tool_definitions_json
# Emite un array JSON con todas las definitions registradas.
# Si no hay tools registradas, emite "[]".
get_all_tool_definitions_json() {
    local name

    if [ "${#REGISTERED_TOOLS[@]}" -eq 0 ]; then
        echo "[]"
        return 0
    fi

    {
        for name in "${REGISTERED_TOOLS[@]}"; do
            "tool_${name}_definition"
        done
    } | jq -s '.'
}

# dispatch_tool <name> <input_json>
# Invoca tool_<name>_handler con el input JSON. Retorna el exit code del handler.
# Si input_json es vacío, se pasa "{}". Si no es JSON válido, falla con código 2.
#
# Si lib/hooks.sh está cargado (función `hooks_run` definida), se invoca
# `hooks_run tool_pre <name> <input>` antes del handler y
# `hooks_run tool_post <name> <input> <rc> <output>` después. Los hooks son
# observability-only: fallos en hooks NUNCA bloquean ni cambian el rc del
# handler. Cuando hooks_run está disponible, stdout del handler se buferea
# en un tmpfile (para poder pasarlo al post-hook) y luego se re-emite verbatim
# — stderr sigue pasthrough para preservar la semántica original para callers
# que no usan `2>&1`. Cuando hooks_run NO está cargado, el path es idéntico al
# pre-P1.hooks-2 (zero overhead).
#
# Internal-only env var `_CODER_DISPATCH_SKIP_HOOKS`: cuando está set a un
# valor no-vacío, dispatch_tool ejecuta el handler SIN invocar pre/post
# hooks. Esto lo usa `_dispatch_tools_parallel` para serializar las
# invocaciones de hooks fuera de los subshells paralelos (P2.parallel-5):
# evita concurrent appends a logs y garantiza orden determinista de eventos
# pre/post. NO está pensado para uso público — la variable se setea dentro
# del subshell `()` y no leak al shell del usuario.
dispatch_tool() {
    local name="$1"
    local input_json="${2:-}"
    local fn="tool_${name}_handler"

    if [ -z "$name" ]; then
        echo "dispatch_tool: missing tool name" >&2
        return 2
    fi

    if ! declare -f "$fn" >/dev/null; then
        echo "dispatch_tool: tool not registered: $name" >&2
        return 1
    fi

    if [ -z "$input_json" ]; then
        input_json='{}'
    elif ! echo "$input_json" | jq -e . >/dev/null 2>&1; then
        echo "dispatch_tool: invalid JSON input for tool '$name'" >&2
        return 2
    fi

    if [ -n "${_CODER_DISPATCH_SKIP_HOOKS:-}" ] || ! declare -f hooks_run >/dev/null 2>&1; then
        "$fn" "$input_json"
        return $?
    fi

    hooks_run tool_pre "$name" "$input_json" >/dev/null 2>&1 || true

    local stdout_file rc output
    stdout_file=$(mktemp 2>/dev/null) || stdout_file=""
    if [ -z "$stdout_file" ]; then
        "$fn" "$input_json"
        rc=$?
        hooks_run tool_post "$name" "$input_json" "$rc" "" >/dev/null 2>&1 || true
        return "$rc"
    fi

    "$fn" "$input_json" >"$stdout_file"
    rc=$?
    output=$(cat "$stdout_file")
    cat "$stdout_file"
    rm -f "$stdout_file"

    hooks_run tool_post "$name" "$input_json" "$rc" "$output" >/dev/null 2>&1 || true
    return "$rc"
}

# list_registered_tools
# Emite cada nombre de tool registrada en su propia línea.
list_registered_tools() {
    local name
    if [ "${#REGISTERED_TOOLS[@]}" -eq 0 ]; then
        return 0
    fi
    for name in "${REGISTERED_TOOLS[@]}"; do
        echo "$name"
    done
}

# _dispatch_tools_parallel <max_workers>
#
# Helper bash-nativo para dispatch paralelo de N tools. Lee jobs desde stdin,
# uno por línea, con separador ASCII Unit Separator (\x1f):
#     <id><US><tool_name><US><input_json>
#   - id:         identificador opaco devuelto en el output (puede ser tool_use_id
#                 de Anthropic, tool_call_id de OpenAI, o un índice para Gemini).
#   - tool_name:  nombre del tool registrado en REGISTERED_TOOLS.
#   - input_json: JSON literal pasado al handler. Empty → dispatch_tool lo
#                 normaliza a "{}".
#
# Emite stdout, una línea por job EN MISMO ORDEN QUE INPUT:
#     <id><US><rc><US><output_b64>
#   - rc:         exit code del handler (0..255).
#   - output_b64: stdout+stderr combinado del handler, base64-encoded
#                 (single-line, sin \n) para sobrevivir el line-delimited
#                 protocol con contenido multi-línea. Decoder: `base64 -d`.
#
# Concurrency: `max_workers` controla paralelismo.
#   - max_workers <= 1 → path SECUENCIAL puro (zero-overhead, sin tmpfiles,
#     sin subshells extras — mantiene el path histórico para callers que no
#     quieran paralelismo).
#   - max_workers > 1 → spawn N subshells por batch, `wait` el batch, siguiente
#     batch. Portable a bash 3.2 (no usa `wait -n`).
#
# Exit codes:
#   0 — todos los jobs ejecutaron (rc individual de cada handler queda en stdout).
#   2 — stdin vacío / `max_workers` no-entero.
#
# NOTE: la base64 encoding del output es intencional. El alternative (escapar
# US/LF dentro del payload con sed) es más frágil y produce un protocolo
# asimétrico (encode aquí, decode allá con misma sed inversa). Base64 es
# simétrico y bytewise-exact.
#
# Hooks bajo paralelismo (P2.parallel-5):
#   - Sequential path (max_workers <= 1): dispatch_tool corre los hooks
#     inline como siempre — pre/post intercalados por job, orden histórico
#     preservado para back-compat.
#   - Parallel path (max_workers > 1): los hooks SE SERIALIZAN FUERA del
#     subshell. Antes de spawn dispatchamos `hooks_run tool_pre` para los
#     N jobs en orden de input; los handlers corren en paralelo con
#     `_CODER_DISPATCH_SKIP_HOOKS=1` (skip de hooks dentro del subshell);
#     después de colectar resultados dispatchamos `hooks_run tool_post`
#     en orden de input con el rc/output exacto de cada job. Esto evita
#     concurrent appends al hooks log y garantiza orden determinista de
#     eventos para observadores externos.
_dispatch_tools_parallel() {
    local max_workers="${1:-1}"

    if ! [[ "$max_workers" =~ ^[0-9]+$ ]]; then
        echo "_dispatch_tools_parallel: invalid max_workers: $max_workers" >&2
        return 2
    fi

    local -a job_ids=() job_names=() job_inputs=()
    local id name input
    # `|| [ -n "$id" ]` captura la última línea cuando viene sin \n final
    # (común si el caller pasa stdin con `$(printf ...)` que strippea trailing
    # newlines).
    while IFS=$'\x1f' read -r id name input || [ -n "$id" ]; do
        [ -z "$id" ] && continue
        job_ids+=("$id")
        job_names+=("$name")
        job_inputs+=("$input")
    done

    local n=${#job_ids[@]}
    if [ "$n" -eq 0 ]; then
        echo "_dispatch_tools_parallel: no jobs received on stdin" >&2
        return 2
    fi

    # Sequential path: zero overhead, sin tmpfiles ni subshells extras.
    if [ "$max_workers" -le 1 ]; then
        local i=0 out rc b64
        while [ "$i" -lt "$n" ]; do
            if out=$(dispatch_tool "${job_names[$i]}" "${job_inputs[$i]}" 2>&1); then
                rc=0
            else
                rc=$?
            fi
            b64=$(printf '%s' "$out" | base64 | tr -d '\n')
            printf '%s\x1f%s\x1f%s\n' "${job_ids[$i]}" "$rc" "$b64"
            i=$((i+1))
        done
        return 0
    fi

    # Parallel path: tmpdir + batched waits.
    local tmpdir
    tmpdir=$(mktemp -d 2>/dev/null) || {
        echo "_dispatch_tools_parallel: mktemp failed; falling back to sequential" >&2
        local i=0 out rc b64
        while [ "$i" -lt "$n" ]; do
            if out=$(dispatch_tool "${job_names[$i]}" "${job_inputs[$i]}" 2>&1); then
                rc=0
            else
                rc=$?
            fi
            b64=$(printf '%s' "$out" | base64 | tr -d '\n')
            printf '%s\x1f%s\x1f%s\n' "${job_ids[$i]}" "$rc" "$b64"
            i=$((i+1))
        done
        return 0
    }

    # Phase 1: fire tool_pre hooks serialmente en orden de input, ANTES del
    # spawn paralelo. Los hooks corren en este shell padre (no en subshells),
    # así que evita concurrent appends al log y los observadores ven los
    # eventos en orden estable. No-op si hooks_run no está cargado.
    if declare -f hooks_run >/dev/null 2>&1; then
        local k=0
        while [ "$k" -lt "$n" ]; do
            hooks_run tool_pre "${job_names[$k]}" "${job_inputs[$k]}" >/dev/null 2>&1 || true
            k=$((k+1))
        done
    fi

    # Phase 2: dispatch paralelo de handlers SIN hooks (skip via env var
    # interna `_CODER_DISPATCH_SKIP_HOOKS`). Se setea dentro del subshell
    # `()` así que no leak al shell padre ni a procesos no relacionados.
    local i=0
    while [ "$i" -lt "$n" ]; do
        local batch_end=$((i + max_workers))
        [ "$batch_end" -gt "$n" ] && batch_end="$n"

        local j="$i"
        local -a pids=()
        while [ "$j" -lt "$batch_end" ]; do
            (
                _CODER_DISPATCH_SKIP_HOOKS=1
                local sub_out sub_rc
                if sub_out=$(dispatch_tool "${job_names[$j]}" "${job_inputs[$j]}" 2>&1); then
                    sub_rc=0
                else
                    sub_rc=$?
                fi
                # Escribir output + rc atomically a tmpfiles dedicados.
                printf '%s' "$sub_out" >"$tmpdir/$j.out"
                printf '%s' "$sub_rc" >"$tmpdir/$j.rc"
            ) &
            pids+=("$!")
            j=$((j+1))
        done

        local pid
        for pid in "${pids[@]}"; do
            wait "$pid" || true
        done

        i="$batch_end"
    done

    # Phase 3: leer resultados en orden de input, disparar tool_post hooks
    # serialmente con rc/output exactos de cada job, y emitir línea de
    # output. Hooks corren en este shell padre antes de cada línea emit
    # — el orden de post-events es estable, y ningún append concurre.
    i=0
    local out rc b64
    while [ "$i" -lt "$n" ]; do
        if [ -f "$tmpdir/$i.out" ]; then
            out=$(cat "$tmpdir/$i.out")
        else
            out=""
        fi
        if [ -f "$tmpdir/$i.rc" ]; then
            rc=$(cat "$tmpdir/$i.rc")
        else
            rc=1
        fi
        if declare -f hooks_run >/dev/null 2>&1; then
            hooks_run tool_post "${job_names[$i]}" "${job_inputs[$i]}" "$rc" "$out" >/dev/null 2>&1 || true
        fi
        b64=$(printf '%s' "$out" | base64 | tr -d '\n')
        printf '%s\x1f%s\x1f%s\n' "${job_ids[$i]}" "$rc" "$b64"
        i=$((i+1))
    done

    rm -rf "$tmpdir"
    return 0
}

# ==========================================
# Anthropic adapter (M1.3)
# ==========================================
# Funciones helper + agentic_loop_anthropic.
# Endpoint: POST https://api.anthropic.com/v1/messages
# Header: x-api-key, anthropic-version: 2023-06-01, content-type: application/json
#
# Modelo y caps configurables vía env:
#   ANTHROPIC_API_KEY            - api key (también acepta $claude_api_key del config legacy)
#   CODER_CLAUDE_MODEL           - default claude-haiku-4-5-20251001
#   CODER_CLAUDE_MAX_TOKENS      - default 4096
#   TOOL_LOOP_MAX_ITERATIONS     - default 10 (heredado del módulo)
#
# Convención de stdout:
#   - Cada bloque de texto del assistant se emite a stdout tal cual.
#   - Mensajes diagnósticos del loop van a stderr.
#   - Exit code 0 si terminó con end_turn / stop_sequence / max_tokens.
#   - Exit code != 0 si API error, key faltante, cap excedido o stop_reason desconocido.

ANTHROPIC_MESSAGES_URL="${ANTHROPIC_MESSAGES_URL:-https://api.anthropic.com/v1/messages}"

# ==========================================
# Tracking de tokens (los 3 providers)
# ==========================================
# Acumuladores de sesión, actualizados por los loops `*_continue` en el shell
# padre (los `_call_api` corren en subshell y perderían el estado). Consumidos
# por `/cost` y por `agent --json`.
CODER_TOKENS_IN="${CODER_TOKENS_IN:-0}"
CODER_TOKENS_OUT="${CODER_TOKENS_OUT:-0}"

# _agentic_track_usage <response_json>
# Suma input/output tokens de la respuesta (shape anthropic/openai/gemini).
# Silencioso y best-effort: una respuesta sin usage no rompe el loop.
_agentic_track_usage() {
    local resp="$1" tin tout
    tin=$(echo "$resp" | jq -r '.usage.input_tokens // .usage.prompt_tokens // .usageMetadata.promptTokenCount // 0' 2>/dev/null)
    tout=$(echo "$resp" | jq -r '.usage.output_tokens // .usage.completion_tokens // .usageMetadata.candidatesTokenCount // 0' 2>/dev/null)
    case "$tin" in ''|*[!0-9]*) tin=0 ;; esac
    case "$tout" in ''|*[!0-9]*) tout=0 ;; esac
    CODER_TOKENS_IN=$((CODER_TOKENS_IN + tin))
    CODER_TOKENS_OUT=$((CODER_TOKENS_OUT + tout))
}
ANTHROPIC_VERSION_HEADER="${ANTHROPIC_VERSION_HEADER:-2023-06-01}"

# _anthropic_get_api_key
# Resuelve la API key desde env o config legacy. Stdout = key. Exit 1 si missing.
_anthropic_get_api_key() {
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        echo "$ANTHROPIC_API_KEY"
        return 0
    fi
    if [ -n "${claude_api_key:-}" ]; then
        echo "$claude_api_key"
        return 0
    fi
    return 1
}

# _anthropic_extract_text <response_json>
# Concatena todos los bloques content[].type=="text" en stdout.
_anthropic_extract_text() {
    local resp="$1"
    echo "$resp" | jq -r '.content[]? | select(.type == "text") | .text'
}

# _anthropic_extract_stop_reason <response_json>
# Stdout = stop_reason (o "unknown" si missing).
_anthropic_extract_stop_reason() {
    local resp="$1"
    echo "$resp" | jq -r '.stop_reason // "unknown"'
}

# _anthropic_extract_tool_uses <response_json>
# Una línea por tool_use: id<US>name<US>input_json_compact, donde <US> = 0x1f.
# tojson emite single-line JSON sin newlines literales pero CON `\n` JSON-escape
# (bytes `\` + `n`). @tsv escapa `\` -> `\\`, lo cual rompe el decode posterior
# (vuelve `\n` LITERAL). Usamos Unit Separator (US, 0x1f) + join() para evitar
# cualquier escape del payload — read -r con IFS=$'\x1f' lo recupera intacto y
# multi-line strings (write_file content, edit_file old/new_string) llegan
# correctamente al handler.
_anthropic_extract_tool_uses() {
    local resp="$1"
    echo "$resp" | jq -r --arg sep $'\x1f' '.content[]? | select(.type == "tool_use") | [.id, .name, (.input | tojson)] | join($sep)'
}

# _anthropic_is_api_error <response_json>
# Exit 0 si la respuesta es un error de API ({"type":"error",...}), 1 si no.
_anthropic_is_api_error() {
    local resp="$1"
    echo "$resp" | jq -e '.type == "error"' >/dev/null 2>&1
}

# _anthropic_build_payload <model> <max_tokens> <tools_json> <messages_json>
# Stdout = payload JSON compacto.
_anthropic_build_payload() {
    local model="$1"
    local max_tokens="$2"
    local tools_json="$3"
    local messages_json="$4"
    # CODER_SYSTEM_PROMPT (opt-in): system prompt con contexto del proyecto.
    # Vacío = payload idéntico al legacy (los tests no-streaming lo asumen).
    jq -nc \
        --arg model "$model" \
        --arg sys "${CODER_SYSTEM_PROMPT:-}" \
        --argjson max_tokens "$max_tokens" \
        --argjson tools "$tools_json" \
        --argjson messages "$messages_json" \
        '{model: $model, max_tokens: $max_tokens, tools: $tools, messages: $messages}
         + (if $sys != "" then {system: $sys} else {} end)'
}

# _anthropic_append_assistant <messages_json> <response_json>
# Apenda al array messages un {role:"assistant", content: response.content}.
_anthropic_append_assistant() {
    local messages="$1"
    local response="$2"
    jq -nc \
        --argjson msgs "$messages" \
        --argjson content "$(echo "$response" | jq -c '.content')" \
        '$msgs + [{role: "assistant", content: $content}]'
}

# _anthropic_append_tool_results <messages_json> <tool_results_array_json>
# Apenda {role:"user", content: tool_results}.
_anthropic_append_tool_results() {
    local messages="$1"
    local tool_results="$2"
    jq -nc \
        --argjson msgs "$messages" \
        --argjson tr "$tool_results" \
        '$msgs + [{role: "user", content: $tr}]'
}

# _anthropic_build_tool_result <tool_use_id> <content_string> <is_error_bool>
# Stdout = un object {type:"tool_result", tool_use_id, content, is_error}.
_anthropic_build_tool_result() {
    local id="$1"
    local content="$2"
    local is_error="${3:-false}"
    jq -nc \
        --arg id "$id" \
        --arg content "$content" \
        --argjson is_error "$is_error" \
        '{type: "tool_result", tool_use_id: $id, content: $content, is_error: $is_error}'
}

# _anthropic_call_api <payload_json> <api_key>
# POST payload a $ANTHROPIC_MESSAGES_URL. Stdout = response body. Exit != 0 si curl falla
# (en cuyo caso stdout contiene el mensaje de error de curl, no JSON).
# Aislada como helper para que los tests puedan overridearla con stubs y ejercitar la
# máquina del loop sin tocar la red.
_anthropic_call_api() {
    local payload="$1"
    local api_key="$2"
    curl -sS -X POST "$ANTHROPIC_MESSAGES_URL" \
        -H "x-api-key: $api_key" \
        -H "anthropic-version: $ANTHROPIC_VERSION_HEADER" \
        -H "content-type: application/json" \
        -d "$payload" 2>&1
}

# agentic_loop_anthropic_continue <messages_json>
# Variante multi-turn de agentic_loop_anthropic: toma un array JSON de mensajes
# Anthropic-style ya construido (incluyendo el último user turn) y corre el loop
# ReAct hasta que el modelo termine naturalmente (end_turn/stop_sequence/max_tokens)
# o pida tools que el dispatcher pueda satisfacer. Al regresar, escribe el estado
# final de la conversación (incluyendo el último turno del asistente) en la global
# CODER_AGENTIC_MESSAGES para que el caller pueda persistirlo y reanudar.
#
# Foundation para modo agentic interactivo (P1.1c) — habilita conversaciones
# multi-turn donde el usuario, el modelo y las tools se intercalan a través de
# varias invocaciones del loop, preservando contexto.
#
# Exit codes:
#   0   end_turn / stop_sequence / max_tokens (messages incluye el último assistant)
#   1   API error, key faltante, stop_reason desconocido, cap excedido
#       (messages refleja el último estado bueno antes del error)
#   2   argumento inválido (messages refleja la entrada, o "[]" si la entrada
#       no era parseable)
# _anthropic_repair_history <messages_json>
# Si una interrupción (Ctrl+C/Z, crash) dejó un assistant con tool_use sin su
# tool_result en el mensaje siguiente, la API rechaza TODO el historial con 400.
# Inserta tool_results sintéticos (is_error) para los ids huérfanos, dejando el
# historial válido y al modelo enterado de que la tool no llegó a correr.
_anthropic_repair_history() {
    printf '%s' "$1" | jq -c '
        def tu_ids: [ (.content // []) | if type=="array" then .[] else empty end
                      | select(.type? == "tool_use") | .id ];
        def tr_ids: [ (.content // []) | if type=="array" then .[] else empty end
                      | select(.type? == "tool_result") | .tool_use_id ];
        . as $m
        | reduce range(0; $m|length) as $i ([];
            . + [$m[$i]]
            + ( if ($m[$i].role == "assistant") then
                  ( ($m[$i] | tu_ids)
                    - (if $i + 1 < ($m|length) then ($m[$i+1] | tr_ids) else [] end)
                  ) as $missing
                  | if ($missing|length) > 0 then
                      [{role: "user",
                        content: [ $missing[] | {type: "tool_result", tool_use_id: .,
                                   content: "(interrupted by the user before this tool could run)",
                                   is_error: true} ]}]
                    else [] end
                else [] end ))
    ' 2>/dev/null || printf '%s' "$1"
}

# _anthropic_summarize_text <texto> <api_key>
# Una llamada sin tools que devuelve un resumen denso de la conversación.
_anthropic_summarize_text() {
    local text="$1" api_key="$2" model payload resp
    model="${CODER_CLAUDE_MODEL:-claude-sonnet-4-5-20250929}"
    payload=$(jq -nc --arg m "$model" --arg t "$text" \
        '{model: $m, max_tokens: 1500, messages: [{role: "user",
          content: ("Resume de forma densa y fiel esta conversación entre un usuario y un agente de código. Conserva: objetivos, decisiones tomadas, archivos/rutas tocados, comandos ejecutados y lo que queda pendiente. Devuelve SOLO el resumen.\n\n" + $t)}]}')
    resp=$(_anthropic_call_api "$payload" "$api_key") || return 1
    printf '%s' "$resp" | jq -r '[.content[]? | select(.type == "text") | .text] | join("\n")' 2>/dev/null
}

# _anthropic_compact_history <messages_json> <api_key>
# Cuando el historial supera CODER_COMPACT_CHARS (~150KB ≈ 37K tokens), los
# mensajes viejos se convierten en UN resumen y se conservan los últimos
# CODER_COMPACT_KEEP intactos (estilo auto-compact de Claude Code).
_anthropic_compact_history() {
    local messages="$1" api_key="$2"
    local limit="${CODER_COMPACT_CHARS:-150000}" keep="${CODER_COMPACT_KEEP:-10}"
    [ "${#messages}" -le "$limit" ] && { printf '%s' "$messages"; return 0; }
    local total older rest summary
    total=$(printf '%s' "$messages" | jq 'length' 2>/dev/null) || { printf '%s' "$messages"; return 0; }
    [ "$total" -le $((keep + 4)) ] && { printf '%s' "$messages"; return 0; }
    if [ -t 2 ]; then
        printf '  \033[2m%s\033[0m\n' "$(hf_t "compacting conversation ($total messages → summary + last $keep)…" "compactando conversación ($total mensajes → resumen + últimos $keep)…")" >&2
    fi
    older=$(printf '%s' "$messages" | jq -c ".[0:$((total - keep))]")
    # El resto no puede empezar con tool_results huérfanos (su tool_use se resumió)
    rest=$(printf '%s' "$messages" | jq -c "
        .[$((total - keep)):] as \$r
        | (\$r | map(.content | if type == \"array\" then any(.[]; .type? == \"tool_result\") else false end) | index(false)) as \$i
        | if \$i == null then [] else \$r[\$i:] end")
    summary=$(_anthropic_summarize_text "$(printf '%s' "$older" | head -c 100000)" "$api_key")
    if [ -z "$summary" ]; then
        printf '%s' "$messages"
        return 0
    fi
    jq -nc --arg s "$summary" --argjson rest "$rest" \
        '[{role: "user", content: ("[Resumen de la conversación previa — el detalle completo fue compactado]\n" + $s)}] + $rest'
}

# _agentic_check_user_input
# Solo en modo interactivo (CODER_AGENT_INTERACTIVE=1) y con stdin TTY.
# Drena sin bloquear lo que el usuario tecleó mientras el agente trabajaba:
#   - Esc suelto        → rc 3 (stop limpio)
#   - línea(s) completas → quedan en _AGENTIC_QUEUED para inyectar al modelo
#   - línea a medias     → se conserva en _AGENTIC_PENDING para el siguiente chequeo
_agentic_check_user_input() {
    _AGENTIC_QUEUED=""
    [ "${CODER_AGENT_INTERACTIVE:-0}" = "1" ] || return 0
    [ -t 0 ] || return 0
    local saved chunk cleaned line esc=$'\x1b'
    saved=$(stty -g 2>/dev/null) || return 0
    stty -icanon -echo min 0 time 0 2>/dev/null
    chunk=$(dd bs=4096 count=1 2>/dev/null)
    stty "$saved" 2>/dev/null
    [ -z "$chunk" ] && [ -z "${_AGENTIC_PENDING:-}" ] && return 0
    _AGENTIC_PENDING="${_AGENTIC_PENDING:-}$chunk"
    # Las flechas mandan ESC [ letra: no cuentan como stop
    cleaned="${_AGENTIC_PENDING//$esc\[[A-D]/}"
    case "$cleaned" in
        *"$esc"*) _AGENTIC_PENDING=""; return 3 ;;
    esac
    while [ "${cleaned#*$'\n'}" != "$cleaned" ]; do
        line="${cleaned%%$'\n'*}"
        cleaned="${cleaned#*$'\n'}"
        line="${line%$'\r'}"
        [ -n "$line" ] && _AGENTIC_QUEUED="${_AGENTIC_QUEUED:+$_AGENTIC_QUEUED$'\n'}$line"
    done
    _AGENTIC_PENDING="$cleaned"
    return 0
}

agentic_loop_anthropic_continue() {
    local messages_in="$1"
    local api_key model max_tokens max_iter tools_json messages iter
    local payload response stop_reason text assistant_appended tool_results
    local tu_id result_content is_error tu_count _tu_id _tu_name _tu_input _tu_arg
    local max_workers tool_uses_output rc out_b64

    if [ -z "${messages_in:-}" ]; then
        echo "agentic_loop_anthropic_continue: missing messages" >&2
        CODER_AGENTIC_MESSAGES='[]'
        return 2
    fi

    if ! echo "$messages_in" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
        echo "agentic_loop_anthropic_continue: messages must be a non-empty JSON array" >&2
        CODER_AGENTIC_MESSAGES="$messages_in"
        return 2
    fi

    # Repara tool_use huérfanos de interrupciones previas (Ctrl+C/Z, crash)
    messages=$(_anthropic_repair_history "$messages_in")

    if ! api_key=$(_anthropic_get_api_key); then
        echo "agentic_loop_anthropic_continue: ANTHROPIC_API_KEY not set (and no claude_api_key in config)" >&2
        CODER_AGENTIC_MESSAGES="$messages"
        return 1
    fi

    model="${CODER_CLAUDE_MODEL:-claude-haiku-4-5-20251001}"
    max_tokens="${CODER_CLAUDE_MAX_TOKENS:-4096}"
    max_iter="${TOOL_LOOP_MAX_ITERATIONS:-10}"

    # Auto-compactación al superar el umbral de tamaño del historial
    messages=$(_anthropic_compact_history "$messages" "$api_key")
    messages=$(_anthropic_repair_history "$messages")

    tools_json=$(get_all_tool_definitions_json)

    iter=0
    while [ "$iter" -lt "$max_iter" ]; do
        iter=$((iter + 1))

        # ¿El usuario escribió algo mientras el agente trabajaba?
        if _agentic_check_user_input; then
            if [ -n "${_AGENTIC_QUEUED:-}" ]; then
                messages=$(jq -nc --argjson msgs "$messages" --arg p "$_AGENTIC_QUEUED" \
                    '$msgs + [{role: "user", content: $p}]')
                [ -t 1 ] && printf '  ↪ %s\n' "$(hf_t "your message was added to the conversation" "tu mensaje se añadió a la conversación")"
                _AGENTIC_QUEUED=""
            fi
        else
            # Esc → stop limpio: el historial queda consistente en este punto
            CODER_AGENTIC_MESSAGES="$messages"
            [ -t 1 ] && printf '  ⏹ %s\n' "$(hf_t "stopped (Esc) — type to continue where it left off" "detenido (Esc) — escribe para continuar donde quedó")"
            return 3
        fi

        payload=$(_anthropic_build_payload "$model" "$max_tokens" "$tools_json" "$messages")

        # Spinner "pensando" mientras el modelo responde (solo interactivo+TTY)
        if [ "${CODER_AGENT_INTERACTIVE:-0}" = "1" ] && [ -t 2 ]; then
            local _sf _sp _si _st _crc _frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' _lbl
            _lbl="$(hf_t "thinking" "pensando")"
            _sf=$(mktemp)
            _anthropic_call_api "$payload" "$api_key" > "$_sf" 2>&1 &
            _sp=$!
            _si=0; _st=$SECONDS
            while kill -0 "$_sp" 2>/dev/null; do
                printf '\r  \033[38;5;99m%s\033[0m \033[2m%s… %ss\033[0m ' \
                    "${_frames:$(( _si % 10 )):1}" "$_lbl" "$(( SECONDS - _st ))" >&2
                _si=$((_si + 1))
                sleep 0.12
            done
            wait "$_sp"; _crc=$?
            printf '\r\033[K' >&2
            response=$(cat "$_sf"); rm -f "$_sf"
            if [ "$_crc" -ne 0 ]; then
                echo "agentic_loop_anthropic_continue: curl failed: $response" >&2
                CODER_AGENTIC_MESSAGES="$messages"
                return 1
            fi
        elif ! response=$(_anthropic_call_api "$payload" "$api_key"); then
            echo "agentic_loop_anthropic_continue: curl failed: $response" >&2
            CODER_AGENTIC_MESSAGES="$messages"
            return 1
        fi

        if ! echo "$response" | jq -e . >/dev/null 2>&1; then
            echo "agentic_loop_anthropic_continue: response is not valid JSON" >&2
            echo "$response" >&2
            CODER_AGENTIC_MESSAGES="$messages"
            return 1
        fi

        _agentic_track_usage "$response"

        if _anthropic_is_api_error "$response"; then
            local _err_type
            _err_type=$(echo "$response" | jq -r '.error.type // ""')
            if [ "$_err_type" = "billing_error" ]; then
                echo "$(hf_t "⚠ Your Hiveflow plan is out of credits. Top up at https://app.hiveflow.ai (billing), or switch the agent to your own API key with /llm." "⚠ Tu plan Hiveflow se quedó sin créditos. Recarga en https://app.hiveflow.ai (billing), o cambia el agente a tu propia API key con /llm.")" >&2
            else
                echo "agentic_loop_anthropic_continue: API error: $(echo "$response" | jq -r '.error.message // .error.type // "unknown"')" >&2
            fi
            CODER_AGENTIC_MESSAGES="$messages"
            return 1
        fi

        text=$(_anthropic_extract_text "$response")
        if [ -n "$text" ]; then
            echo "$text"
        fi

        stop_reason=$(_anthropic_extract_stop_reason "$response")

        case "$stop_reason" in
            end_turn|stop_sequence|max_tokens)
                messages=$(_anthropic_append_assistant "$messages" "$response")
                if [ "$stop_reason" = "max_tokens" ]; then
                    # Un corte por max_tokens puede dejar un tool_use truncado
                    # sin ejecutar: cerrarlo ya con tool_result sintético para
                    # que el historial quede válido, y avisar.
                    messages=$(_anthropic_repair_history "$messages")
                    echo "(agentic_loop: $(hf_t "response truncated by max_tokens=$max_tokens — the last action may be incomplete; ask it to continue" "respuesta cortada por max_tokens=$max_tokens — la última acción puede quedar incompleta; pídele continuar"))" >&2
                fi
                CODER_AGENTIC_MESSAGES="$messages"
                return 0
                ;;
            tool_use)
                : ;;
            *)
                echo "agentic_loop_anthropic_continue: unexpected stop_reason: $stop_reason" >&2
                CODER_AGENTIC_MESSAGES="$messages"
                return 1
                ;;
        esac

        assistant_appended=$(_anthropic_append_assistant "$messages" "$response")
        messages="$assistant_appended"

        # Dispatch todos los tool_use blocks de este turno via _dispatch_tools_parallel.
        # CODER_TOOL_PARALLEL controla concurrency (default 1 = sequential, zero-overhead).
        # El helper preserva orden de input → tool_results sale alineado con el orden
        # de los tool_use blocks en content[], que es lo que Anthropic espera.
        max_workers="${CODER_TOOL_PARALLEL:-1}"
        tool_uses_output=$(_anthropic_extract_tool_uses "$response")

        # Trace visible de tools (estilo Claude Code): ⏺ edit_file ruta
        # A stderr para no contaminar stdout en modo embebible/--json.
        if [ -n "$tool_uses_output" ] && { [ -t 2 ] || [ "${CODER_AGENT_TRACE:-0}" = "1" ]; }; then
            while IFS=$'\x1f' read -r _tu_id _tu_name _tu_input; do
                [ -z "$_tu_name" ] && continue
                _tu_arg=$(printf '%s' "$_tu_input" | jq -r '.path // .file_path // .command // .pattern // .url // .prompt // empty' 2>/dev/null | head -1 | cut -c1-80)
                printf '  \033[38;5;99m⏺\033[0m %s \033[2m%s\033[0m\n' "$_tu_name" "$_tu_arg" >&2
            done <<< "$tool_uses_output"
        fi

        tool_results='[]'
        tu_count=0
        if [ -n "$tool_uses_output" ]; then
            while IFS=$'\x1f' read -r tu_id rc out_b64 || [ -n "$tu_id" ]; do
                [ -z "$tu_id" ] && continue
                tu_count=$((tu_count + 1))

                if [ "$rc" = "0" ]; then
                    is_error=false
                else
                    is_error=true
                fi
                result_content=$(printf '%s' "$out_b64" | base64 -d 2>/dev/null || true)

                tool_results=$(jq -nc \
                    --argjson trs "$tool_results" \
                    --arg id "$tu_id" \
                    --arg content "$result_content" \
                    --argjson is_error "$is_error" \
                    '$trs + [{type: "tool_result", tool_use_id: $id, content: $content, is_error: $is_error}]')
            done < <(printf '%s\n' "$tool_uses_output" | _dispatch_tools_parallel "$max_workers")
        fi

        if [ "$tu_count" -eq 0 ]; then
            echo "agentic_loop_anthropic_continue: stop_reason=tool_use but no tool_use blocks parsed" >&2
            CODER_AGENTIC_MESSAGES="$messages"
            return 1
        fi

        messages=$(_anthropic_append_tool_results "$messages" "$tool_results")
    done

    echo "agentic_loop_anthropic_continue: iteration cap ($max_iter) reached" >&2
    CODER_AGENTIC_MESSAGES="$messages"
    return 1
}

# agentic_loop_anthropic <prompt>
# Loop ReAct one-shot. Construye el messages[] inicial con el user prompt y
# delega a agentic_loop_anthropic_continue. Compat con call sites previos.
#
# Exit codes idénticos a agentic_loop_anthropic_continue.
agentic_loop_anthropic() {
    local user_prompt="$1"
    local messages

    if [ -z "${user_prompt:-}" ]; then
        echo "agentic_loop_anthropic: missing prompt" >&2
        return 2
    fi

    messages=$(jq -nc --arg p "$user_prompt" '[{role: "user", content: $p}]')
    agentic_loop_anthropic_continue "$messages"
}

# ==========================================
# OpenAI adapter (M1.4)
# ==========================================
# Funciones helper + agentic_loop_openai.
# Endpoint: POST https://api.openai.com/v1/chat/completions
# Header: Authorization: Bearer <key>, Content-Type: application/json
#
# Diferencias clave vs Anthropic:
#   - Tool definitions: wrap Anthropic-style en {type:"function", function:{name,description,parameters}}.
#     "parameters" ocupa el lugar de "input_schema".
#   - Tool calls vienen en choices[0].message.tool_calls[]; cada uno con
#     id + function.name + function.arguments (STRING JSON, no objeto).
#   - finish_reason: "stop" / "length" / "tool_calls" / "content_filter".
#   - Tool results se reinjectan como N mensajes separados {role:"tool", tool_call_id, content},
#     no como un único user message con array (como Anthropic).
#
# Env vars:
#   OPENAI_API_KEY               - api key (también acepta $chatgpt_api_key del config legacy)
#   CODER_OPENAI_MODEL           - default gpt-4o-mini
#   CODER_OPENAI_MAX_TOKENS      - opcional; si vacío, no se envía (default del modelo)
#   TOOL_LOOP_MAX_ITERATIONS     - default 10 (heredado del módulo)
#   OPENAI_CHAT_COMPLETIONS_URL  - override para mock servers en tests

OPENAI_CHAT_COMPLETIONS_URL="${OPENAI_CHAT_COMPLETIONS_URL:-https://api.openai.com/v1/chat/completions}"

# _openai_get_api_key
# Resuelve la API key desde env o config legacy. Stdout = key. Exit 1 si missing.
_openai_get_api_key() {
    if [ -n "${OPENAI_API_KEY:-}" ]; then
        echo "$OPENAI_API_KEY"
        return 0
    fi
    if [ -n "${chatgpt_api_key:-}" ]; then
        echo "$chatgpt_api_key"
        return 0
    fi
    return 1
}

# _openai_transform_tools <anthropic_tools_json>
# Convierte el array canónico interno (Anthropic-style) al wrapping de OpenAI.
# {name, description, input_schema} -> {type:"function", function:{name, description, parameters}}.
_openai_transform_tools() {
    local tools_json="$1"
    echo "$tools_json" | jq -c '
        map({
            type: "function",
            function: {
                name: .name,
                description: .description,
                parameters: .input_schema
            }
        })
    '
}

# _openai_extract_text <response_json>
# Stdout = choices[0].message.content (vacío si null o ausente).
_openai_extract_text() {
    local resp="$1"
    echo "$resp" | jq -r '.choices[0].message.content // ""'
}

# _openai_extract_finish_reason <response_json>
# Stdout = finish_reason (o "unknown" si missing).
_openai_extract_finish_reason() {
    local resp="$1"
    echo "$resp" | jq -r '.choices[0].finish_reason // "unknown"'
}

# _openai_extract_tool_calls <response_json>
# Una línea por tool_call: id<US>name<US>arguments_string, donde <US> = 0x1f.
# arguments ya es un string JSON-encoded en la respuesta de OpenAI. @tsv escapa
# `\` interno -> `\\`, lo cual corrompe `\n` (JSON-escape) volviéndolo `\n`
# LITERAL al re-decodificar. Usamos Unit Separator (US, 0x1f) + join() para que
# multi-line arguments lleguen al handler intactos.
_openai_extract_tool_calls() {
    local resp="$1"
    echo "$resp" | jq -r --arg sep $'\x1f' '
        .choices[0].message.tool_calls[]?
        | [.id, .function.name, .function.arguments]
        | join($sep)
    '
}

# _openai_is_api_error <response_json>
# Exit 0 si la respuesta es un error de API ({"error":{...}}), 1 si no.
_openai_is_api_error() {
    local resp="$1"
    echo "$resp" | jq -e '.error != null' >/dev/null 2>&1
}

# _openai_build_payload <model> <tools_json_openai_shape> <messages_json> [max_tokens]
# Stdout = payload JSON compacto. Si max_tokens vacío, se omite.
_openai_build_payload() {
    local model="$1"
    local tools_json="$2"
    local messages_json="$3"
    local max_tokens="${4:-}"

    # CODER_SYSTEM_PROMPT (opt-in): se antepone como mensaje role=system.
    if [ -z "$max_tokens" ]; then
        jq -nc \
            --arg model "$model" \
            --arg sys "${CODER_SYSTEM_PROMPT:-}" \
            --argjson tools "$tools_json" \
            --argjson messages "$messages_json" \
            '{model: $model,
              messages: ((if $sys != "" then [{role: "system", content: $sys}] else [] end) + $messages),
              tools: $tools, tool_choice: "auto"}'
    else
        jq -nc \
            --arg model "$model" \
            --arg sys "${CODER_SYSTEM_PROMPT:-}" \
            --argjson tools "$tools_json" \
            --argjson messages "$messages_json" \
            --argjson max_tokens "$max_tokens" \
            '{model: $model,
              messages: ((if $sys != "" then [{role: "system", content: $sys}] else [] end) + $messages),
              tools: $tools, tool_choice: "auto", max_tokens: $max_tokens}'
    fi
}

# _openai_append_assistant <messages_json> <response_json>
# Apenda al array messages el choices[0].message tal cual (incluye tool_calls
# si los hay; OpenAI requiere mantener el message del assistant intacto para
# que los tool_call_id subsecuentes resuelvan).
_openai_append_assistant() {
    local messages="$1"
    local response="$2"
    jq -nc \
        --argjson msgs "$messages" \
        --argjson assistant "$(echo "$response" | jq -c '.choices[0].message')" \
        '$msgs + [$assistant]'
}

# _openai_append_tool_result <messages_json> <tool_call_id> <content_string>
# Apenda un {role:"tool", tool_call_id, content}. OpenAI espera UN mensaje por
# tool_call (no un array agrupado como Anthropic).
_openai_append_tool_result() {
    local messages="$1"
    local tool_call_id="$2"
    local content="$3"
    jq -nc \
        --argjson msgs "$messages" \
        --arg id "$tool_call_id" \
        --arg content "$content" \
        '$msgs + [{role: "tool", tool_call_id: $id, content: $content}]'
}

# _openai_call_api <payload_json> <api_key>
# POST payload a $OPENAI_CHAT_COMPLETIONS_URL. Stdout = response body. Exit != 0
# si curl falla (en cuyo caso stdout contiene el mensaje de error de curl, no JSON).
# Aislada como helper para que los tests puedan overridearla con stubs y ejercitar
# la máquina del loop sin tocar la red.
_openai_call_api() {
    local payload="$1"
    local api_key="$2"
    curl -sS -X POST "$OPENAI_CHAT_COMPLETIONS_URL" \
        -H "Authorization: Bearer $api_key" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1
}

# agentic_loop_openai_continue <messages_json>
# Variante multi-turn de agentic_loop_openai: toma un array JSON de mensajes
# OpenAI-style ya construido (incluyendo el último user turn) y corre el loop
# ReAct hasta finish_reason terminal o tools que el dispatcher pueda satisfacer.
# Al regresar, escribe el estado final en CODER_AGENTIC_MESSAGES.
#
# Foundation para modo agentic interactivo (P1.1c).
#
# Exit codes:
#   0   stop / length / content_filter (messages incluye el último assistant)
#   1   API error, key faltante, finish_reason desconocido, cap excedido
#   2   argumento inválido
agentic_loop_openai_continue() {
    local messages_in="$1"
    local api_key model max_tokens max_iter max_workers
    local tools_anthropic tools_openai messages iter
    local payload response finish_reason text
    local tc_id rc out_b64 result_content tc_count tool_calls_output

    if [ -z "${messages_in:-}" ]; then
        echo "agentic_loop_openai_continue: missing messages" >&2
        CODER_AGENTIC_MESSAGES='[]'
        return 2
    fi

    if ! echo "$messages_in" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
        echo "agentic_loop_openai_continue: messages must be a non-empty JSON array" >&2
        CODER_AGENTIC_MESSAGES="$messages_in"
        return 2
    fi

    messages="$messages_in"

    if ! api_key=$(_openai_get_api_key); then
        echo "agentic_loop_openai_continue: OPENAI_API_KEY not set (and no chatgpt_api_key in config)" >&2
        CODER_AGENTIC_MESSAGES="$messages"
        return 1
    fi

    model="${CODER_OPENAI_MODEL:-gpt-4o-mini}"
    max_tokens="${CODER_OPENAI_MAX_TOKENS:-}"
    max_iter="${TOOL_LOOP_MAX_ITERATIONS:-10}"

    tools_anthropic=$(get_all_tool_definitions_json)
    tools_openai=$(_openai_transform_tools "$tools_anthropic")

    iter=0
    while [ "$iter" -lt "$max_iter" ]; do
        iter=$((iter + 1))

        payload=$(_openai_build_payload "$model" "$tools_openai" "$messages" "$max_tokens")

        if ! response=$(_openai_call_api "$payload" "$api_key"); then
            echo "agentic_loop_openai_continue: curl failed: $response" >&2
            CODER_AGENTIC_MESSAGES="$messages"
            return 1
        fi

        if ! echo "$response" | jq -e . >/dev/null 2>&1; then
            echo "agentic_loop_openai_continue: response is not valid JSON" >&2
            echo "$response" >&2
            CODER_AGENTIC_MESSAGES="$messages"
            return 1
        fi

        _agentic_track_usage "$response"

        if _openai_is_api_error "$response"; then
            echo "agentic_loop_openai_continue: API error: $(echo "$response" | jq -r '.error.message // .error.type // "unknown"')" >&2
            CODER_AGENTIC_MESSAGES="$messages"
            return 1
        fi

        text=$(_openai_extract_text "$response")
        if [ -n "$text" ]; then
            echo "$text"
        fi

        finish_reason=$(_openai_extract_finish_reason "$response")

        case "$finish_reason" in
            stop|length|content_filter)
                messages=$(_openai_append_assistant "$messages" "$response")
                CODER_AGENTIC_MESSAGES="$messages"
                return 0
                ;;
            tool_calls)
                : ;;
            *)
                echo "agentic_loop_openai_continue: unexpected finish_reason: $finish_reason" >&2
                CODER_AGENTIC_MESSAGES="$messages"
                return 1
                ;;
        esac

        messages=$(_openai_append_assistant "$messages" "$response")

        # Dispatch todos los tool_calls de este turno via _dispatch_tools_parallel.
        # CODER_TOOL_PARALLEL controla concurrency (default 1 = sequential, zero-overhead).
        # El helper preserva orden de input → los mensajes role=tool salen en el
        # mismo orden en que el modelo emitió tool_calls[], que es lo que OpenAI
        # espera para resolver cada tool_call_id.
        max_workers="${CODER_TOOL_PARALLEL:-1}"
        tool_calls_output=$(_openai_extract_tool_calls "$response")

        tc_count=0
        if [ -n "$tool_calls_output" ]; then
            while IFS=$'\x1f' read -r tc_id rc out_b64 || [ -n "$tc_id" ]; do
                [ -z "$tc_id" ] && continue
                tc_count=$((tc_count + 1))

                result_content=$(printf '%s' "$out_b64" | base64 -d 2>/dev/null || true)
                if [ "$rc" != "0" ]; then
                    # OpenAI no tiene flag is_error explícito; el modelo razona sobre
                    # el contenido. Prefijo el mensaje para señal clara.
                    result_content="ERROR: $result_content"
                fi

                messages=$(_openai_append_tool_result "$messages" "$tc_id" "$result_content")
            done < <(printf '%s\n' "$tool_calls_output" | _dispatch_tools_parallel "$max_workers")
        fi

        if [ "$tc_count" -eq 0 ]; then
            echo "agentic_loop_openai_continue: finish_reason=tool_calls but no tool_calls parsed" >&2
            CODER_AGENTIC_MESSAGES="$messages"
            return 1
        fi
    done

    echo "agentic_loop_openai_continue: iteration cap ($max_iter) reached" >&2
    CODER_AGENTIC_MESSAGES="$messages"
    return 1
}

# agentic_loop_openai <prompt>
# Loop ReAct one-shot. Construye messages[] inicial y delega a _continue.
# Compat con call sites previos.
agentic_loop_openai() {
    local user_prompt="$1"
    local messages

    if [ -z "${user_prompt:-}" ]; then
        echo "agentic_loop_openai: missing prompt" >&2
        return 2
    fi

    messages=$(jq -nc --arg p "$user_prompt" '[{role: "user", content: $p}]')
    agentic_loop_openai_continue "$messages"
}

# ==========================================
# Gemini adapter (M1.4 — Gemini portion)
# ==========================================
# Funciones helper + agentic_loop_gemini.
# Endpoint: POST https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent
# Header: x-goog-api-key: <key>, Content-Type: application/json
#
# Diferencias clave vs Anthropic / OpenAI:
#   - Tools: top-level array con UN object wrap conteniendo function_declarations:
#     [{"function_declarations": [{name, description, parameters}, ...]}].
#     `parameters` reemplaza `input_schema` (igual que OpenAI).
#   - Schema types: Gemini espera tipos en MAYÚSCULA (OBJECT, STRING, etc) en su
#     proto canónico. La REST API moderna acepta lowercase, pero transformamos
#     a uppercase defensivamente para portabilidad.
#   - Tool calls: parts[].functionCall = {name, args}. args es OBJETO JSON
#     (no string como OpenAI). NO hay tool_call_id; matching es por name (y
#     orden si hay múltiples llamadas a la misma function).
#   - finishReason: STOP / MAX_TOKENS / SAFETY / RECITATION / OTHER. Importante:
#     cuando hay function calls, finishReason típicamente sigue siendo STOP — la
#     detección de "el modelo quiere llamar tools" es por presencia de
#     `functionCall` parts, NO por finishReason.
#   - Tool results: re-inyectados como UN único user message con N parts
#     {functionResponse: {name, response: {content: <output>}}}.
#   - Roles: "user" y "model" (no "assistant"). El campo es `contents`, no `messages`.
#
# Env vars:
#   GEMINI_API_KEY               - api key (también acepta $gemini_api_key del config legacy)
#   CODER_GEMINI_MODEL           - default gemini-2.5-flash
#   CODER_GEMINI_MAX_TOKENS      - opcional; si vacío, no se envía
#   TOOL_LOOP_MAX_ITERATIONS     - default 10 (heredado del módulo)
#   GEMINI_BASE_URL              - override para mock servers en tests

GEMINI_BASE_URL="${GEMINI_BASE_URL:-https://generativelanguage.googleapis.com/v1beta}"

# _gemini_get_api_key
# Resuelve la API key desde env o config legacy. Stdout = key. Exit 1 si missing.
_gemini_get_api_key() {
    if [ -n "${GEMINI_API_KEY:-}" ]; then
        echo "$GEMINI_API_KEY"
        return 0
    fi
    if [ -n "${gemini_api_key:-}" ]; then
        echo "$gemini_api_key"
        return 0
    fi
    return 1
}

# _gemini_build_url <model>
# Stdout = URL completa para :generateContent.
_gemini_build_url() {
    local model="$1"
    echo "${GEMINI_BASE_URL}/models/${model}:generateContent"
}

# _gemini_transform_tools <anthropic_tools_json>
# Convierte el array canónico interno (Anthropic-style) al wrap de Gemini.
# [{name, description, input_schema}, ...] ->
# [{function_declarations: [{name, description, parameters}, ...]}].
# Hace uppercase de todos los .type strings recursivamente (defensivo: la REST
# API moderna acepta lowercase, pero el proto canónico es uppercase).
_gemini_transform_tools() {
    local tools_json="$1"
    echo "$tools_json" | jq -c '
        def upper_types:
            walk(
                if (type == "object") and (.type? | type == "string")
                then .type |= ascii_upcase
                else .
                end
            );
        [{
            function_declarations: map({
                name: .name,
                description: .description,
                parameters: (.input_schema | upper_types)
            })
        }]
    '
}

# _gemini_extract_text <response_json>
# Stdout = una línea por cada parts[].text en candidates[0].content.parts.
_gemini_extract_text() {
    local resp="$1"
    echo "$resp" | jq -r '.candidates[0]?.content.parts[]? | select(.text != null) | .text'
}

# _gemini_extract_finish_reason <response_json>
# Stdout = finishReason (o "unknown" si missing).
_gemini_extract_finish_reason() {
    local resp="$1"
    echo "$resp" | jq -r '.candidates[0]?.finishReason // "unknown"'
}

# _gemini_extract_function_calls <response_json>
# Una línea por functionCall: idx<US>name<US>args_compact_json, donde <US> = 0x1f.
# `idx` es 0-based, en orden de aparición — Gemini no tiene tool_call_id, así
# que el matching downstream para `functionResponse` es por orden de input. El
# idx también funciona como `id` opaco que `_dispatch_tools_parallel` echo-back
# en su output, permitiéndole al caller recuperar el `name` correspondiente
# vía una array indexada paralela (los providers Anthropic/OpenAI no necesitan
# este truco porque sus id intrínsecos coinciden con el id del helper).
#
# Se evita @tsv por el mismo motivo que en _anthropic/_openai_extract: @tsv
# escapa `\` interno, corrompiendo `\n` JSON-encoded en args multi-línea.
_gemini_extract_function_calls() {
    local resp="$1"
    echo "$resp" | jq -r --arg sep $'\x1f' '
        [.candidates[0]?.content.parts[]? | select(.functionCall != null)]
        | to_entries
        | .[]
        | [(.key | tostring), .value.functionCall.name, (.value.functionCall.args // {} | tojson)]
        | join($sep)
    '
}

# _gemini_has_function_calls <response_json>
# Exit 0 si hay al menos un part con functionCall, 1 si no.
_gemini_has_function_calls() {
    local resp="$1"
    echo "$resp" | jq -e '
        [.candidates[0]?.content.parts[]? | select(.functionCall != null)] | length > 0
    ' >/dev/null 2>&1
}

# _gemini_is_api_error <response_json>
# Exit 0 si la respuesta es un error de API ({"error":{...}}), 1 si no.
_gemini_is_api_error() {
    local resp="$1"
    echo "$resp" | jq -e '.error != null' >/dev/null 2>&1
}

# _gemini_build_payload <tools_gemini_json> <contents_json> [max_tokens]
# Stdout = payload JSON compacto. Si max_tokens vacío, no se incluye generationConfig.
_gemini_build_payload() {
    local tools_json="$1"
    local contents_json="$2"
    local max_tokens="${3:-}"

    # CODER_SYSTEM_PROMPT (opt-in): systemInstruction de Gemini.
    if [ -z "$max_tokens" ]; then
        jq -nc \
            --arg sys "${CODER_SYSTEM_PROMPT:-}" \
            --argjson tools "$tools_json" \
            --argjson contents "$contents_json" \
            '{contents: $contents, tools: $tools}
             + (if $sys != "" then {systemInstruction: {parts: [{text: $sys}]}} else {} end)'
    else
        jq -nc \
            --arg sys "${CODER_SYSTEM_PROMPT:-}" \
            --argjson tools "$tools_json" \
            --argjson contents "$contents_json" \
            --argjson max_tokens "$max_tokens" \
            '{contents: $contents, tools: $tools, generationConfig: {maxOutputTokens: $max_tokens}}
             + (if $sys != "" then {systemInstruction: {parts: [{text: $sys}]}} else {} end)'
    fi
}

# _gemini_append_model <contents_json> <response_json>
# Apenda al array contents el candidates[0].content tal cual (role:"model" + parts,
# preservando functionCall parts para que el modelo vea su propia llamada).
_gemini_append_model() {
    local contents="$1"
    local response="$2"
    jq -nc \
        --argjson c "$contents" \
        --argjson model_content "$(echo "$response" | jq -c '.candidates[0].content')" \
        '$c + [$model_content]'
}

# _gemini_build_function_response_part <name> <content_string>
# Stdout = un object {functionResponse: {name, response: {content}}}.
_gemini_build_function_response_part() {
    local name="$1"
    local content="$2"
    jq -nc \
        --arg name "$name" \
        --arg content "$content" \
        '{functionResponse: {name: $name, response: {content: $content}}}'
}

# _gemini_append_function_responses <contents_json> <fr_parts_array_json>
# Apenda un único {role:"user", parts: [<functionResponse>, ...]} al contents.
# Gemini agrupa todas las respuestas a llamadas paralelas en UN solo user turn.
_gemini_append_function_responses() {
    local contents="$1"
    local fr_parts="$2"
    jq -nc \
        --argjson c "$contents" \
        --argjson parts "$fr_parts" \
        '$c + [{role: "user", parts: $parts}]'
}

# agentic_loop_gemini_continue <contents_json>
# Variante multi-turn de agentic_loop_gemini: toma un array JSON de contents
# Gemini-style (roles user/model, parts[]) ya construido y corre el loop ReAct.
# Al regresar, escribe el estado final en CODER_AGENTIC_MESSAGES.
#
# Foundation para modo agentic interactivo (P1.1c). Aunque internamente Gemini
# usa "contents" (no "messages"), exponemos la misma global CODER_AGENTIC_MESSAGES
# para que el caller multi-turn tenga una API uniforme contra los 3 providers.
#
# Exit codes:
#   0   STOP / MAX_TOKENS sin function calls pendientes
#   1   API error, key faltante, finishReason terminal/desconocido, cap excedido
#   2   argumento inválido
agentic_loop_gemini_continue() {
    local contents_in="$1"
    local api_key model max_tokens max_iter url
    local tools_anthropic tools_gemini contents iter
    local payload response finish_reason text
    local result_content fc_count fr_parts fr_part
    local max_workers function_calls_output fc_idx fc_name rc out_b64
    local -a fc_names_by_idx=()

    if [ -z "${contents_in:-}" ]; then
        echo "agentic_loop_gemini_continue: missing contents" >&2
        CODER_AGENTIC_MESSAGES='[]'
        return 2
    fi

    if ! echo "$contents_in" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
        echo "agentic_loop_gemini_continue: contents must be a non-empty JSON array" >&2
        CODER_AGENTIC_MESSAGES="$contents_in"
        return 2
    fi

    contents="$contents_in"

    if ! api_key=$(_gemini_get_api_key); then
        echo "agentic_loop_gemini_continue: GEMINI_API_KEY not set (and no gemini_api_key in config)" >&2
        CODER_AGENTIC_MESSAGES="$contents"
        return 1
    fi

    model="${CODER_GEMINI_MODEL:-gemini-2.5-flash}"
    max_tokens="${CODER_GEMINI_MAX_TOKENS:-}"
    max_iter="${TOOL_LOOP_MAX_ITERATIONS:-10}"

    tools_anthropic=$(get_all_tool_definitions_json)
    tools_gemini=$(_gemini_transform_tools "$tools_anthropic")

    url=$(_gemini_build_url "$model")

    iter=0
    while [ "$iter" -lt "$max_iter" ]; do
        iter=$((iter + 1))

        payload=$(_gemini_build_payload "$tools_gemini" "$contents" "$max_tokens")

        if ! response=$(curl -sS -X POST "$url" \
                -H "x-goog-api-key: $api_key" \
                -H "Content-Type: application/json" \
                -d "$payload" 2>&1); then
            echo "agentic_loop_gemini_continue: curl failed: $response" >&2
            CODER_AGENTIC_MESSAGES="$contents"
            return 1
        fi

        if ! echo "$response" | jq -e . >/dev/null 2>&1; then
            echo "agentic_loop_gemini_continue: response is not valid JSON" >&2
            echo "$response" >&2
            CODER_AGENTIC_MESSAGES="$contents"
            return 1
        fi

        _agentic_track_usage "$response"

        if _gemini_is_api_error "$response"; then
            echo "agentic_loop_gemini_continue: API error: $(echo "$response" | jq -r '.error.message // .error.status // "unknown"')" >&2
            CODER_AGENTIC_MESSAGES="$contents"
            return 1
        fi

        text=$(_gemini_extract_text "$response")
        if [ -n "$text" ]; then
            echo "$text"
        fi

        # Detección de function calls: por presencia de parts[].functionCall.
        # En Gemini, finishReason típicamente sigue siendo STOP aún con calls
        # pendientes — no podemos usarlo como señal de "hay tools que ejecutar".
        if _gemini_has_function_calls "$response"; then
            contents=$(_gemini_append_model "$contents" "$response")

            # Dispatch todos los functionCall parts de este turno via
            # _dispatch_tools_parallel. CODER_TOOL_PARALLEL controla concurrency
            # (default 1 = sequential, zero-overhead).
            #
            # Gemini no tiene tool_call_id; el helper requiere un `id` opaco —
            # usamos el idx 0-based emitido por _gemini_extract_function_calls.
            # Construimos `fc_names_by_idx[]` en una primera pasada para poder
            # recuperar el `name` que functionResponse necesita downstream
            # (Anthropic/OpenAI no tienen este truco porque sus id intrínsecos
            # son los mismos que el helper echo-back).
            #
            # El helper preserva orden de input → fr_parts sale alineado con
            # functionCall parts, que es lo que Gemini espera para resolver
            # cada call por orden de aparición.
            max_workers="${CODER_TOOL_PARALLEL:-1}"
            function_calls_output=$(_gemini_extract_function_calls "$response")

            fc_names_by_idx=()
            while IFS=$'\x1f' read -r fc_idx fc_name _ || [ -n "$fc_idx" ]; do
                [ -z "$fc_idx" ] && continue
                fc_names_by_idx[fc_idx]="$fc_name"
            done <<<"$function_calls_output"

            fr_parts='[]'
            fc_count=0
            if [ -n "$function_calls_output" ]; then
                while IFS=$'\x1f' read -r fc_idx rc out_b64 || [ -n "$fc_idx" ]; do
                    [ -z "$fc_idx" ] && continue
                    fc_count=$((fc_count + 1))

                    result_content=$(printf '%s' "$out_b64" | base64 -d 2>/dev/null || true)
                    if [ "$rc" != "0" ]; then
                        # Gemini no tiene flag is_error explícito; prefijo en el content.
                        result_content="ERROR: $result_content"
                    fi

                    fc_name="${fc_names_by_idx[fc_idx]}"
                    fr_part=$(_gemini_build_function_response_part "$fc_name" "$result_content")
                    fr_parts=$(jq -nc \
                        --argjson arr "$fr_parts" \
                        --argjson part "$fr_part" \
                        '$arr + [$part]')
                done < <(printf '%s\n' "$function_calls_output" | _dispatch_tools_parallel "$max_workers")
            fi

            if [ "$fc_count" -eq 0 ]; then
                echo "agentic_loop_gemini_continue: $(hf_t "has_function_calls=true but none parsed" "has_function_calls=true pero ninguna parseada")" >&2
                CODER_AGENTIC_MESSAGES="$contents"
                return 1
            fi

            contents=$(_gemini_append_function_responses "$contents" "$fr_parts")
            continue
        fi

        # Sin function calls => terminar según finishReason.
        finish_reason=$(_gemini_extract_finish_reason "$response")

        case "$finish_reason" in
            STOP|MAX_TOKENS)
                contents=$(_gemini_append_model "$contents" "$response")
                CODER_AGENTIC_MESSAGES="$contents"
                return 0
                ;;
            SAFETY|RECITATION|OTHER)
                echo "agentic_loop_gemini_continue: terminated with finishReason=$finish_reason" >&2
                CODER_AGENTIC_MESSAGES="$contents"
                return 1
                ;;
            *)
                echo "agentic_loop_gemini_continue: unexpected finishReason: $finish_reason" >&2
                CODER_AGENTIC_MESSAGES="$contents"
                return 1
                ;;
        esac
    done

    echo "agentic_loop_gemini_continue: iteration cap ($max_iter) reached" >&2
    CODER_AGENTIC_MESSAGES="$contents"
    return 1
}

# agentic_loop_gemini <prompt>
# Loop ReAct one-shot. Construye contents[] inicial y delega a _continue.
# Compat con call sites previos.
agentic_loop_gemini() {
    local user_prompt="$1"
    local contents

    if [ -z "${user_prompt:-}" ]; then
        echo "agentic_loop_gemini: missing prompt" >&2
        return 2
    fi

    contents=$(jq -nc --arg p "$user_prompt" '[{role: "user", parts: [{text: $p}]}]')
    agentic_loop_gemini_continue "$contents"
}

# ==========================================
# Public dispatcher (M1.5)
# ==========================================
# Entry point para coder.sh. Selecciona el adapter por provider activo
# (`$llm_choice` proveniente de config.sh) y registra las tools del milestone
# vigente. Llamar DESPUÉS de `get_api_config` para que `$llm_choice` y las
# api keys legacy (`chatgpt_api_key` / `claude_api_key` / `gemini_api_key`)
# estén sourceadas en el shell actual.
#
# Exit codes:
#   0   loop completó con stop natural del provider
#   1   error propagado del adapter (API error, key faltante, cap excedido…)
#   2   argumento inválido o provider no soportado / no configurado

# _register_agentic_tools <caller_label>
# Centraliza la registración de las tools del agentic loop. Llamado por
# `consultar_llm_agentic` (one-shot) y `modo_agentico_interactivo` (multi-turn)
# para garantizar que ambos entry points exponen exactamente el mismo set al
# modelo. Cuando se añada una nueva tool al stack agentic, esta es la única
# función que debe tocarse (más el handler en lib/tools/<name>.sh).
#
# Orden canónico: lecturas → mutaciones simples → mutaciones quirúrgicas →
# ejecución de comandos → red → búsqueda. No afecta a los adapters (consumen
# el array indistintamente) — sólo es secuencia mental coherente para el modelo.
#
# Args:
#   $1 - caller_label: prefijo usado en mensajes de stderr (ej: "modo_agentico_interactivo").
#
# Exit codes:
#   0 - todas las tools registradas OK
#   1 - alguna tool falló al registrarse (stderr ya emitió mensaje contextual)
_register_agentic_tools() {
    local caller="${1:-_register_agentic_tools}"
    local tool
    # CODER_AGENT_TOOLS (opt-in): lista space-separated que restringe el set
    # registrado (p.ej. plan mode = solo tools de lectura). Vacío = set completo.
    local tool_set="${CODER_AGENT_TOOLS:-read_file write_file edit_file bash_exec web_fetch grep_search glob_files subagent}"
    for tool in $tool_set; do
        if ! register_tool "$tool" >/dev/null 2>&1; then
            echo "${caller}: $(hf_t "failed to register tool ${tool}" "falló registrando tool ${tool}")" >&2
            return 1
        fi
    done
    # P1.mcp-4b: si lib/mcp_client.sh está cargado, abre primero las conexiones
    # a los servers MCP marcados como `enabled: true` en $CODER_MCP_CONFIG. Cada
    # fallo es non-fatal (warn a stderr + continúa). Después auto-registra las
    # tools de cada conexión activa como proxies en REGISTERED_TOOLS.
    if declare -f mcp_autoconnect_enabled_servers >/dev/null 2>&1; then
        mcp_autoconnect_enabled_servers || true
    fi
    if declare -f mcp_register_all_tools >/dev/null 2>&1; then
        mcp_register_all_tools || true
    fi
    return 0
}

# CODER_AGENTIC_TOOLS_BANNER
# Lista legible (CSV) de las tools registradas por `_register_agentic_tools`,
# en orden canónico. Consumida por banners y `/help` para no duplicar la lista
# en strings hardcoded a lo largo del módulo.
CODER_AGENTIC_TOOLS_BANNER="read_file, write_file, edit_file, bash_exec, web_fetch, grep_search, glob_files, subagent"

consultar_llm_agentic() {
    local user_prompt="$1"
    local provider="${llm_choice:-}"

    if [ -z "$user_prompt" ]; then
        echo "consultar_llm_agentic: missing prompt" >&2
        return 2
    fi

    if [ -z "$provider" ]; then
        echo "consultar_llm_agentic: $(hf_t "llm_choice is not configured" "llm_choice no está configurado")" >&2
        echo "Hint: ./coder.sh -setup" >&2
        return 2
    fi

    if ! _register_agentic_tools "consultar_llm_agentic"; then
        return 1
    fi

    case "$provider" in
        claude)
            agentic_loop_anthropic "$user_prompt"
            ;;
        chatgpt)
            agentic_loop_openai "$user_prompt"
            ;;
        gemini)
            agentic_loop_gemini "$user_prompt"
            ;;
        *)
            echo "consultar_llm_agentic: $(hf_t "unsupported provider: $provider" "provider no soportado: $provider")" >&2
            return 2
            ;;
    esac
}

# ==========================================
# Modo agentico interactivo (P1.1c)
# ==========================================
# Loop multi-turn que mantiene messages[] entre user inputs. Cada turno apenda
# el input del usuario al messages[] previo en el formato del provider activo
# y delega al `agentic_loop_<provider>_continue` correspondiente, que reanuda
# la conversación y al regresar deja el estado actualizado en
# CODER_AGENTIC_MESSAGES (incluyendo el último assistant turn).
#
# Stdout del adapter (texto del modelo + tool results en stderr) pasa directo
# al terminal — esta función NO captura con $(...) porque eso crearía un
# subshell y `CODER_AGENTIC_MESSAGES` se perdería en el padre.
#
# Comandos especiales:
#   /exit /quit /salir (o exit/quit/salir)  → salir limpio
#   /reset                                  → vaciar messages[]
#   /help                                   → mostrar ayuda
#
# Exit codes:
#   0   usuario salió limpiamente (/exit o EOF)
#   1   estado interno roto (tool registration falló)
#   2   provider no configurado / no soportado

# _modo_agentico_expand_slash <input>
# Traduce un slash command del modo interactivo legacy a un prompt natural-language
# que el agentic loop puede procesar con tools (P1.1d). Stdout = prompt expandido,
# exit 0. Si el comando es desconocido → exit 1 (sin stderr). Si requiere args y
# faltan → mensaje de uso a stderr, exit 2.
#
# Los comandos control (/exit /quit /salir /reset /help) NO pasan por aquí — el
# loop los intercepta antes. /agent es traducible (el arg se manda como prompt
# directo, redundante en este modo pero útil para muscle-memory desde -i).
_modo_agentico_expand_slash() {
    local input="$1"
    local cmd args
    cmd="${input%% *}"
    if [ "$cmd" = "$input" ]; then
        args=""
    else
        args="${input#* }"
        # strip leading/trailing whitespace (consistente con el loop)
        args="${args#"${args%%[![:space:]]*}"}"
        args="${args%"${args##*[![:space:]]}"}"
    fi

    case "$cmd" in
        /analyze)
            printf '%s' "$(hf_t 'Analyze the project code in the current directory thoroughly. Use bash_exec to explore the structure (ls, limited find, etc.) and read_file to inspect key files (entrypoints, main modules, configuration). Report architecture, patterns, dependencies and risk areas.' 'Analiza completamente el código del proyecto en el directorio actual. Usa bash_exec para explorar la estructura (ls, find limitado, etc.) y read_file para inspeccionar archivos clave (entrypoints, módulos principales, configuración). Reporta arquitectura, patrones, dependencias y áreas de riesgo.')"
            ;;
        /refactor)
            if [ -n "$args" ]; then
                printf '%s' "$(hf_t "Identify refactoring opportunities in: $args. Read the code with read_file before proposing changes and use edit_file with dry_run=true to preview the diff before applying." "Identifica oportunidades de refactorización en: $args. Lee el código con read_file antes de proponer cambios y usa edit_file con dry_run=true para previsualizar el diff antes de aplicar.")"
            else
                printf '%s' "$(hf_t 'Identify refactoring opportunities in the current project. Use read_file/bash_exec to explore and edit_file with dry_run=true to preview concrete changes before applying.' 'Identifica oportunidades de refactorización en el proyecto actual. Usa read_file/bash_exec para explorar y edit_file con dry_run=true para previsualizar cambios concretos antes de aplicar.')"
            fi
            ;;
        /review)
            printf '%s' "$(hf_t 'Perform a code review of the current project. Use read_file and bash_exec to inspect. Report potential bugs, code smells, style inconsistencies and actionable suggestions.' 'Realiza una revisión de código del proyecto actual. Usa read_file y bash_exec para inspeccionar. Reporta bugs potenciales, code smells, inconsistencias de estilo y sugerencias accionables.')"
            ;;
        /security)
            printf '%s' "$(hf_t 'Analyze the security of the project code. Read files with read_file and explore with bash_exec. Look for injections (SQL/command/path), hardcoded secrets, unsafe input handling and incorrect permissions. Report findings with severity.' 'Analiza la seguridad del código del proyecto. Lee archivos con read_file y explora con bash_exec. Busca inyecciones (SQL/command/path), secretos hardcodeados, manejo inseguro de inputs y permisos incorrectos. Reporta hallazgos con severidad.')"
            ;;
        /performance)
            printf '%s' "$(hf_t 'Analyze the performance of the project. Use read_file/bash_exec to inspect. Look for algorithmic bottlenecks, inefficient I/O, costly loops and leaks. Suggest concrete optimizations.' 'Analiza el rendimiento del proyecto. Usa read_file/bash_exec para inspeccionar. Busca cuellos de botella algorítmicos, I/O ineficiente, loops costosos y leaks. Sugiere optimizaciones concretas.')"
            ;;
        /test)
            printf '%s' "$(hf_t 'Generate automated tests for the current project code. Read the functions to test with read_file, then create test files with write_file. Cover happy path, edge cases and error paths.' 'Genera tests automáticos para el código del proyecto actual. Lee las funciones a testear con read_file, luego crea archivos de test con write_file. Cubre happy path, edge cases y error paths.')"
            ;;
        /docs)
            printf '%s' "$(hf_t 'Generate documentation for the project code. Read the public functions with read_file, then use edit_file/write_file to add docstrings or create README/docs files.' 'Genera documentación para el código del proyecto. Lee las funciones públicas con read_file, luego usa edit_file/write_file para añadir docstrings o crear archivos README/docs.')"
            ;;
        /think)
            if [ -z "$args" ]; then
                printf '%s\n' "$(hf_t '/think requires a topic. Usage: /think <topic or question>' '/think requiere un tema. Uso: /think <tema o pregunta>')" >&2
                return 2
            fi
            printf '%s' "$(hf_t "Think deeply about: $args. Use read_file/bash_exec if you need repo context. Reason step by step before concluding." "Piensa profundamente sobre: $args. Usa read_file/bash_exec si necesitas contexto del repo. Razona paso a paso antes de concluir.")"
            ;;
        /files)
            printf '%s' "$(hf_t 'List the files of the current project using bash_exec (for example: find . -type f excluding .git and node_modules, limited to the first ~50). Summarize the structure by directory.' 'Lista los archivos del proyecto actual usando bash_exec (por ejemplo: find . -type f no en .git y no en node_modules, limitado a los primeros ~50). Resume la estructura por directorio.')"
            ;;
        /focus)
            if [ -z "$args" ]; then
                printf '%s\n' "$(hf_t '/focus requires a file. Usage: /focus <path>' '/focus requiere un archivo. Uso: /focus <ruta>')" >&2
                return 2
            fi
            printf '%s' "$(hf_t "Focus on the file: $args. Use read_file to read it in full, then answer questions or suggest improvements about its content." "Enfócate en el archivo: $args. Usa read_file para leerlo completo y luego responde preguntas o sugiere mejoras sobre su contenido.")"
            ;;
        /summary)
            printf '%s' "$(hf_t 'Generate a summary of the current project. Read README/CLAUDE.md/package.json/manifest.json if they exist with read_file, and use bash_exec to list the structure. Summarize purpose, stack, main modules and status.' 'Genera un resumen del proyecto actual. Lee README/CLAUDE.md/package.json/manifest.json si existen con read_file, y usa bash_exec para listar la estructura. Resume propósito, stack, módulos principales y estado.')"
            ;;
        /fix)
            if [ -z "$args" ]; then
                printf '%s\n' "$(hf_t '/fix requires a problem description. Usage: /fix <description>' '/fix requiere una descripción del problema. Uso: /fix <descripción>')" >&2
                return 2
            fi
            printf '%s' "$(hf_t "Fix this problem: $args. Read the relevant code with read_file, preview the fix with edit_file dry_run=true, validate the diff and apply with edit_file (without dry_run)." "Arregla este problema: $args. Lee el código relevante con read_file, previsualiza la corrección con edit_file dry_run=true, valida el diff y aplica con edit_file (sin dry_run).")"
            ;;
        /agent)
            if [ -z "$args" ]; then
                printf '%s\n' "$(hf_t '/agent requires a prompt. (In agentic mode you are already in the loop — just type the prompt directly, without /agent.)' '/agent requiere un prompt. (En modo agentic ya estás en el loop — basta escribir el prompt directo sin /agent.)')" >&2
                return 2
            fi
            printf '%s' "$args"
            ;;
        *)
            return 1
            ;;
    esac
}

modo_agentico_interactivo() {
    local provider="${llm_choice:-}"
    local messages='[]'
    local user_input adapter_rc

    if [ -z "$provider" ]; then
        echo "modo_agentico_interactivo: $(hf_t "llm_choice is not configured" "llm_choice no está configurado")" >&2
        echo "Hint: ./coder.sh -setup" >&2
        return 2
    fi

    case "$provider" in
        claude|chatgpt|gemini) : ;;
        *)
            echo "modo_agentico_interactivo: $(hf_t "unsupported provider: $provider" "provider no soportado: $provider")" >&2
            return 2
            ;;
    esac

    if ! _register_agentic_tools "modo_agentico_interactivo"; then
        return 1
    fi

    # P1.sessions-2: auto-persist messages a una session por cada turno.
    # Gated en `sessions_save` disponible — instalaciones sin `lib/sessions.sh`
    # (o tests que sólo sourcean tool_calling.sh) degradan a la semántica
    # legacy sin persistencia. Si `CODER_RESUME_SESSION_ID` viene del caller
    # (typically `coder --session <id>`) se reanuda esa session; si no, se
    # crea una nueva.
    local session_id="" session_status="off"
    if declare -f sessions_save >/dev/null 2>&1; then
        if [ -n "${CODER_RESUME_SESSION_ID:-}" ]; then
            if sessions_exists "$CODER_RESUME_SESSION_ID" >/dev/null 2>&1; then
                session_id="$CODER_RESUME_SESSION_ID"
                local _loaded
                _loaded=$(sessions_load "$session_id" 2>/dev/null) || _loaded=""
                if [ -n "$_loaded" ] && printf '%s' "$_loaded" | jq empty >/dev/null 2>&1; then
                    messages="$_loaded"
                    CODER_AGENTIC_MESSAGES="$messages"
                    session_status="resumed"
                else
                    session_status="resumed-empty"
                fi
            else
                echo "(modo_agentico_interactivo: $(hf_t "session not found: $CODER_RESUME_SESSION_ID — creating a new one" "session no encontrada: $CODER_RESUME_SESSION_ID — creando nueva"))" >&2
            fi
        fi
        if [ -z "$session_id" ]; then
            session_id=$(sessions_new "$provider" "${model:-}" "${CODER_SESSION_LABEL:-}" 2>/dev/null) || session_id=""
            [ -n "$session_id" ] && session_status="new"
        fi
    fi

    if [ -t 1 ]; then
        # Header estilo hiveflow: "agent" + proveedor·modelo debajo
        local _model_label="" _prov_label="$provider"
        case "$provider" in
            claude)  _model_label="${CODER_CLAUDE_MODEL:-}" ;;
            chatgpt) _model_label="${CODER_OPENAI_MODEL:-}" ;;
            gemini)  _model_label="${CODER_GEMINI_MODEL:-}" ;;
        esac
        [ -n "${ANTHROPIC_MESSAGES_URL:-}" ] && _prov_label="hiveflow"
        printf '\n  \033[38;5;99m⏺\033[0m \033[1magent\033[0m\n'
        printf '  \033[2m%s · %s\033[0m\n' "$_prov_label" "${_model_label:-?}"
        if [ -n "$session_id" ]; then
            printf '  \033[2m%s\033[0m\n' "$(hf_t "session $session_id ($session_status) · resume: hiveflow agent --session $session_id" "sesión $session_id ($session_status) · reanudar: hiveflow agent --session $session_id")"
        fi
        printf '  \033[2m%s\033[0m\n\n' "$(hf_t '/exit · /reset · /help · type+Enter queues while working · Esc stops' '/exit · /reset · /help · escribe+Enter encola mientras trabaja · Esc detiene')"
    fi

    while true; do
        if [ -t 0 ] && [ -t 1 ]; then
            printf '\033[38;5;51myou\033[0m \033[2m❯\033[0m '
        fi
        if ! IFS= read -r user_input; then
            if [ -t 1 ]; then printf '\n'; fi
            break
        fi

        # Strip leading/trailing whitespace para que entradas en blanco no
        # disparen un round-trip vacío.
        user_input="${user_input#"${user_input%%[![:space:]]*}"}"
        user_input="${user_input%"${user_input##*[![:space:]]}"}"

        [ -z "$user_input" ] && continue

        case "$user_input" in
            exit|quit|salir|/exit|/quit|/salir)
                break
                ;;
            /reset)
                messages='[]'
                if [ -t 1 ]; then printf '%s\n' "$(hf_t "(agentic history cleared)" "(historial agentic limpiado)")"; fi
                continue
                ;;
            /help)
                if [ "${HF_LANG:-en}" = "es" ]; then
                    cat <<'EOF'
modo_agentico_interactivo — comandos:
  /exit | /quit | /salir   salir del modo
  /reset                   limpiar historial (messages[] vacío)
  /help                    mostrar esta ayuda

Slash commands traducibles a prompts agentic (P1.1d):
  /analyze                 análisis completo del proyecto
  /refactor [target]       oportunidades de refactorización
  /review                  revisión de código
  /security                análisis de seguridad
  /performance             análisis de rendimiento
  /test                    generar tests
  /docs                    generar documentación
  /think <tema>            pensamiento profundo sobre un tema
  /files                   listar archivos del proyecto
  /focus <ruta>            enfocar en un archivo específico
  /summary                 resumen del proyecto
  /fix <descripción>       arreglar un problema
  /agent <prompt>          equivalente a escribir <prompt> directo

Cualquier otra entrada se envía al modelo activo con el historial completo.
EOF
                else
                    cat <<'EOF'
modo_agentico_interactivo — commands:
  /exit | /quit | /salir   leave this mode
  /reset                   clear history (empty messages[])
  /help                    show this help

Slash commands expanded into agentic prompts (P1.1d):
  /analyze                 full project analysis
  /refactor [target]       refactoring opportunities
  /review                  code review
  /security                security analysis
  /performance             performance analysis
  /test                    generate tests
  /docs                    generate documentation
  /think <topic>           deep thinking about a topic
  /files                   list project files
  /focus <path>            focus on a specific file
  /summary                 project summary
  /fix <description>       fix a problem
  /agent <prompt>          same as typing <prompt> directly

Any other input is sent to the active model with the full history.
EOF
                fi
                printf '%s\n' "$(hf_t "Available tools: $CODER_AGENTIC_TOOLS_BANNER." "Tools disponibles: $CODER_AGENTIC_TOOLS_BANNER.")"
                continue
                ;;
        esac

        # Slash commands traducibles a prompts agentic (P1.1d). Los controles
        # (/exit /quit /salir /reset /help) se interceptan arriba; cualquier
        # otro /foo pasa por el dispatcher: si se expande, reemplaza el input
        # antes de enviar al modelo; si es desconocido o requiere args, salta
        # el round-trip y vuelve al prompt.
        if [[ "$user_input" == /* ]]; then
            local expanded expand_rc
            expanded=$(_modo_agentico_expand_slash "$user_input")
            expand_rc=$?
            if [ "$expand_rc" -eq 0 ]; then
                user_input="$expanded"
            else
                if [ "$expand_rc" -eq 1 ] && [ -t 1 ]; then
                    echo "(modo_agentico_interactivo: $(hf_t "unknown command: ${user_input%% *} — try /help" "comando no reconocido: ${user_input%% *} — usa /help"))"
                fi
                # rc == 2: el helper ya emitió mensaje de uso en stderr.
                continue
            fi
        fi

        case "$provider" in
            claude|chatgpt)
                messages=$(jq -nc --argjson msgs "$messages" --arg p "$user_input" \
                    '$msgs + [{role: "user", content: $p}]')
                ;;
            gemini)
                messages=$(jq -nc --argjson msgs "$messages" --arg p "$user_input" \
                    '$msgs + [{role: "user", parts: [{text: $p}]}]')
                ;;
        esac

        CODER_AGENT_INTERACTIVE=1
        case "$provider" in
            claude)  agentic_loop_anthropic_continue "$messages" ;;
            chatgpt) agentic_loop_openai_continue    "$messages" ;;
            gemini)  agentic_loop_gemini_continue    "$messages" ;;
        esac
        adapter_rc=$?
        CODER_AGENT_INTERACTIVE=0

        messages="${CODER_AGENTIC_MESSAGES:-$messages}"

        # Persist messages al final del turno (incluso si adapter falló — el
        # user puede querer reanudar y editar). Errores de save son no-fatal:
        # se reportan a stderr y el loop continúa.
        if [ -n "$session_id" ] && declare -f sessions_save >/dev/null 2>&1; then
            if ! sessions_save "$session_id" "$messages" "$provider" "${model:-}" >/dev/null 2>&1; then
                echo "(modo_agentico_interactivo: $(hf_t "sessions_save failed for $session_id — turn not persisted" "sessions_save falló para $session_id — turno no persistido"))" >&2
            fi
        fi

        if [ "$adapter_rc" -ne 0 ] && [ "$adapter_rc" -ne 3 ]; then
            echo "(modo_agentico_interactivo: $(hf_t "adapter rc=$adapter_rc; use /reset if the history is inconsistent" "adapter rc=$adapter_rc; usa /reset si el historial quedó inconsistente"))" >&2
        fi
    done

    return 0
}
