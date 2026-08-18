#!/bin/bash

# ==========================================
# TOOL AGENTIC: subagent
# ==========================================
# Spawn a bounded child `coder.sh -agent <prompt>` invocation in a fresh
# process, capture its stdout/stderr/exit code and emit a structured summary
# for the parent agent. Sourceado por lib/tool_calling.sh::register_tool. NO
# setear strict mode global aqui (el archivo se sourcea en el shell padre y
# filtraria flags al resto).
#
# Proposito: preservar el contexto del agente padre delegando sub-tareas
# (busquedas amplias, refactors acotados, exploracion) a un proceso hijo cuyo
# output queda contenido y resumido. El hijo corre el agentic loop completo
# (con sus propias tools) y devuelve solo el resultado final, no su transcript
# turno-a-turno.
#
# Contrato:
#   - Inputs: { "prompt": string (required, no vacio, <= 32KB),
#               "timeout_seconds"?: integer (default 600, range [10, 3600]),
#               "working_directory"?: string (default cwd; debe existir y ser dir) }
#   - Permission check OBLIGATORIO via confirm_permission "subagent" "<prompt-prefix>".
#     subagent NO esta en _PERMISSIONS_READ_ONLY_TOOLS porque el hijo puede
#     ejecutar cualquier tool registrada (write_file, bash_exec, ...). El gating
#     de las tools internas lo hace el propio hijo cuando consulta su
#     permissions.json, asi que el confirm aqui es por la creacion del proceso
#     hijo (cost / context blast-radius), no por mutacion directa.
#   - Recursion guard hard-fail: CODER_SUBAGENT_DEPTH >= CODER_SUBAGENT_MAX_DEPTH
#     (default 3) hard-falla ANTES de tocar permissions. Evita fork-bombs por
#     LLM-llama-subagent recursivo. El hijo hereda CODER_SUBAGENT_DEPTH+1.
#   - Timeout enforcement bash-nativo (mismo patron que bash_exec): watchdog
#     polling envia SIGTERM al exceder, luego SIGKILL despues de grace seconds.
#   - stdout / stderr capturados a tmpfiles separados, truncados a 64KB cada uno
#     (override via CODER_SUBAGENT_MAX_OUTPUT_BYTES) con marca explicita si
#     se recorto.
#
# Salida (stdout, formato estructurado para el LLM):
#   subagent: exit=<N> timed_out=<true|false> duration=<Ns> depth=<N>
#   --- stdout ---
#   <content o "(empty)">
#   --- stderr ---
#   <content o "(empty)">
#
# Exit codes (de la TOOL, no del hijo):
#   0  hijo ejecutado y output emitido (cualquier exit code del hijo)
#   1  permission denied / recursion depth excedido / coder binario no
#      encontrado / permissions.sh no cargado / fallo de infraestructura
#      (mktemp, working_directory invalido, etc)
#   2  input JSON invalido o campos faltantes/fuera-de-rango
#
# Env vars:
#   CODER_YES                          - "1" => auto-aprueba needs-confirm
#   CODER_SUBAGENT_DEPTH               - profundidad de recursion actual (default 0)
#   CODER_SUBAGENT_MAX_DEPTH           - profundidad maxima permitida (default 3)
#   CODER_SUBAGENT_BIN                 - override path al binario coder.sh
#                                        (default: <dir-de-este-archivo>/../../coder.sh).
#                                        Usado por tests para inyectar un stub.
#   CODER_SUBAGENT_MAX_OUTPUT_BYTES    - cap por stream (default 65536 = 64KB)
#   CODER_SUBAGENT_KILL_GRACE_SECONDS  - segundos entre SIGTERM y SIGKILL (default 1)

# tool_subagent_definition
# Emite el JSON schema (formato Anthropic canonico interno).
tool_subagent_definition() {
    cat <<'EOF'
{
  "name": "subagent",
  "description": "Spawn a bounded child agentic session (`coder -agent <prompt>`) in a separate process and return its stdout, stderr, exit code, and duration. Use this to delegate self-contained sub-tasks (broad searches, exploratory passes, isolated refactors) so the parent agent's context window only sees the summary, not the child's turn-by-turn transcript. The child has access to the full tool registry (read_file, write_file, edit_file, bash_exec, web_fetch, grep_search, glob_files, ...) gated by the same permissions config as the parent. Requires permission (interactive confirm or persisted allowlist). Recursion is hard-capped at CODER_SUBAGENT_MAX_DEPTH (default 3) to prevent fork-bombs. A configurable timeout (default 600s, max 3600s) kills the child if exceeded. stdout and stderr are each truncated to 64KB.",
  "input_schema": {
    "type": "object",
    "properties": {
      "prompt": {
        "type": "string",
        "description": "Task description for the child agent. Should be self-contained: name files, paths, expected output format. The child does NOT see the parent's conversation history. Max 32KB."
      },
      "timeout_seconds": {
        "type": "integer",
        "description": "Maximum seconds the child is allowed to run before SIGTERM (then SIGKILL after a grace period). Defaults to 600 (10 min). Must be in [10, 3600].",
        "minimum": 10,
        "maximum": 3600
      },
      "working_directory": {
        "type": "string",
        "description": "Absolute or relative path to the directory in which the child should run. Defaults to the parent's cwd. Must exist and be a readable directory."
      }
    },
    "required": ["prompt"]
  }
}
EOF
}

# _subagent_truncate <file> <max_bytes>
# Trunca <file> a <max_bytes> bytes y agrega marker si recorto. In-place via tmpfile.
_subagent_truncate() {
    local file="$1"
    local max="$2"
    local size
    size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
    [ -z "$size" ] && size=0
    if [ "$size" -le "$max" ]; then
        return 0
    fi
    local tmp
    tmp=$(mktemp "${file}.trunc.XXXXXX") || return 1
    head -c "$max" "$file" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    printf '\n[...truncated %d of %d bytes...]\n' "$((size - max))" "$size" >> "$tmp"
    mv "$tmp" "$file"
}

# _subagent_emit_section <label> <file>
# Imprime "--- <label> ---" + contenido (o "(empty)" si vacio).
_subagent_emit_section() {
    local label="$1"
    local file="$2"
    echo "--- ${label} ---"
    if [ -s "$file" ]; then
        cat "$file"
    else
        echo "(empty)"
    fi
}

# _subagent_resolve_bin
# Resuelve la ruta al binario coder.sh que ejecutara el hijo. Prioridad:
#   1. $CODER_SUBAGENT_BIN (override explicito, usado por tests).
#   2. <dir-de-este-archivo>/../../coder.sh (resolucion via BASH_SOURCE).
# Echo de la ruta resuelta a stdout. Exit 1 si no encontrada / no ejecutable.
_subagent_resolve_bin() {
    local bin
    if [ -n "${CODER_SUBAGENT_BIN:-}" ]; then
        bin="$CODER_SUBAGENT_BIN"
    else
        local here
        here=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
        if [ -z "$here" ]; then
            return 1
        fi
        bin="$here/../../coder.sh"
    fi
    if [ ! -f "$bin" ]; then
        return 1
    fi
    if [ ! -x "$bin" ] && [ ! -r "$bin" ]; then
        return 1
    fi
    echo "$bin"
    return 0
}

# tool_subagent_handler <input_json>
tool_subagent_handler() {
    local input_json="$1"
    local prompt timeout_seconds working_directory
    local depth max_depth child_depth
    local max_bytes grace_seconds
    local coder_bin
    local stdout_file stderr_file wd_marker
    local cmd_pid wd_pid
    local cmd_exit timed_out
    local start_time end_time duration
    local prompt_len

    if [ -z "$input_json" ]; then
        echo "subagent: missing input JSON" >&2
        return 2
    fi

    if ! prompt=$(echo "$input_json" | jq -re '.prompt' 2>/dev/null); then
        echo "subagent: missing required field 'prompt'" >&2
        return 2
    fi
    if [ -z "$prompt" ]; then
        echo "subagent: field 'prompt' must be a non-empty string" >&2
        return 2
    fi
    prompt_len=$(printf '%s' "$prompt" | wc -c | tr -d ' ')
    if [ "$prompt_len" -gt 32768 ]; then
        echo "subagent: 'prompt' exceeds 32768 bytes (got ${prompt_len})" >&2
        return 2
    fi

    timeout_seconds=$(echo "$input_json" | jq -r '.timeout_seconds // 600' 2>/dev/null)
    if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
        echo "subagent: 'timeout_seconds' must be a positive integer (got: $timeout_seconds)" >&2
        return 2
    fi
    if [ "$timeout_seconds" -lt 10 ] || [ "$timeout_seconds" -gt 3600 ]; then
        echo "subagent: 'timeout_seconds' out of range [10, 3600] (got: $timeout_seconds)" >&2
        return 2
    fi

    working_directory=$(echo "$input_json" | jq -r '.working_directory // ""' 2>/dev/null)
    if [ -n "$working_directory" ]; then
        if [ ! -d "$working_directory" ]; then
            echo "subagent: 'working_directory' is not an existing directory: $working_directory" >&2
            return 2
        fi
        if [ ! -r "$working_directory" ]; then
            echo "subagent: 'working_directory' is not readable: $working_directory" >&2
            return 2
        fi
    fi

    max_bytes="${CODER_SUBAGENT_MAX_OUTPUT_BYTES:-65536}"
    if ! [[ "$max_bytes" =~ ^[1-9][0-9]*$ ]]; then
        echo "subagent: CODER_SUBAGENT_MAX_OUTPUT_BYTES must be a positive integer (got: $max_bytes)" >&2
        return 1
    fi

    grace_seconds="${CODER_SUBAGENT_KILL_GRACE_SECONDS:-1}"
    if ! [[ "$grace_seconds" =~ ^[0-9]+$ ]]; then
        echo "subagent: CODER_SUBAGENT_KILL_GRACE_SECONDS must be a non-negative integer (got: $grace_seconds)" >&2
        return 1
    fi

    # Recursion depth guard (hard-fail ANTES de permissions).
    depth="${CODER_SUBAGENT_DEPTH:-0}"
    if ! [[ "$depth" =~ ^[0-9]+$ ]]; then
        echo "subagent: CODER_SUBAGENT_DEPTH must be a non-negative integer (got: $depth)" >&2
        return 1
    fi
    max_depth="${CODER_SUBAGENT_MAX_DEPTH:-3}"
    if ! [[ "$max_depth" =~ ^[0-9]+$ ]]; then
        echo "subagent: CODER_SUBAGENT_MAX_DEPTH must be a non-negative integer (got: $max_depth)" >&2
        return 1
    fi
    if [ "$depth" -ge "$max_depth" ]; then
        echo "subagent: recursion depth $depth >= max $max_depth; refusing to spawn child" >&2
        return 1
    fi
    child_depth=$((depth + 1))

    if ! declare -f confirm_permission >/dev/null 2>&1; then
        echo "subagent: lib/permissions.sh not loaded (confirm_permission undefined); refusing to execute" >&2
        return 1
    fi

    # Resource pasada al permission system: primeros 80 chars del prompt en una
    # sola linea (legible en confirm prompt y en allowlist patterns).
    local resource
    resource=$(printf '%s' "$prompt" | tr '\n\r\t' '   ' | head -c 80)

    if ! confirm_permission "subagent" "$resource" "${CODER_YES:-0}"; then
        echo "subagent: permission denied" >&2
        return 1
    fi

    if ! coder_bin=$(_subagent_resolve_bin); then
        echo "subagent: cannot resolve coder binary (set CODER_SUBAGENT_BIN or check repo layout)" >&2
        return 1
    fi

    if ! stdout_file=$(mktemp 2>/dev/null); then
        echo "subagent: cannot create stdout tmpfile" >&2
        return 1
    fi
    if ! stderr_file=$(mktemp 2>/dev/null); then
        rm -f "$stdout_file"
        echo "subagent: cannot create stderr tmpfile" >&2
        return 1
    fi
    if ! wd_marker=$(mktemp 2>/dev/null); then
        rm -f "$stdout_file" "$stderr_file"
        echo "subagent: cannot create watchdog marker tmpfile" >&2
        return 1
    fi

    start_time=$(date +%s)

    # Lanzar hijo en background. Subshell para encapsular cd + env overrides
    # sin tocar el shell del caller. CODER_SUBAGENT_DEPTH se incrementa para
    # propagar el guard a invocaciones anidadas.
    (
        if [ -n "$working_directory" ]; then
            cd "$working_directory" || exit 127
        fi
        export CODER_SUBAGENT_DEPTH="$child_depth"
        "$coder_bin" -agent "$prompt"
    ) >"$stdout_file" 2>"$stderr_file" &
    cmd_pid=$!

    # Watchdog (mismo patron que bash_exec): polling cada 1s. Cuando el hijo
    # muere, exit limpio. Si excede timeout, marca + SIGTERM + grace + SIGKILL.
    (
        elapsed=0
        while [ "$elapsed" -lt "$timeout_seconds" ]; do
            sleep 1
            elapsed=$((elapsed + 1))
            if ! kill -0 "$cmd_pid" 2>/dev/null; then
                exit 0
            fi
        done
        echo "timeout" > "$wd_marker"
        kill -TERM "$cmd_pid" 2>/dev/null || true
        if [ "$grace_seconds" -gt 0 ]; then
            sleep "$grace_seconds"
        fi
        if kill -0 "$cmd_pid" 2>/dev/null; then
            kill -KILL "$cmd_pid" 2>/dev/null || true
        fi
    ) &
    wd_pid=$!

    wait "$cmd_pid" 2>/dev/null
    cmd_exit=$?

    wait "$wd_pid" 2>/dev/null || true

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    if [ -s "$wd_marker" ]; then
        timed_out=true
    else
        timed_out=false
    fi
    rm -f "$wd_marker"

    _subagent_truncate "$stdout_file" "$max_bytes" || true
    _subagent_truncate "$stderr_file" "$max_bytes" || true

    echo "subagent: exit=${cmd_exit} timed_out=${timed_out} duration=${duration}s depth=${child_depth}"
    _subagent_emit_section "stdout" "$stdout_file"
    _subagent_emit_section "stderr" "$stderr_file"

    rm -f "$stdout_file" "$stderr_file"
    return 0
}
