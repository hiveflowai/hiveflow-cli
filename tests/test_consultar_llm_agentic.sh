#!/bin/bash
# tests/test_consultar_llm_agentic.sh
# M1.5 wire-up: valida que `consultar_llm_agentic` despache al adapter correcto
# según $llm_choice, valide argumentos, y registre las tools del milestone.
#
# No requiere API keys: los adapters reales se stubean antes de invocar.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT" || exit 1

# shellcheck source=../lib/tool_calling.sh disable=SC1091
source "$REPO_ROOT/lib/agent/tool_calling.sh"

# Override adapters con stubs — son invocados indirectamente vía
# `consultar_llm_agentic`, shellcheck no lo ve y marca SC2317.
# shellcheck disable=SC2317
agentic_loop_anthropic() { echo "stub:anthropic|$1"; return 0; }
# shellcheck disable=SC2317
agentic_loop_openai()    { echo "stub:openai|$1";    return 0; }
# shellcheck disable=SC2317
agentic_loop_gemini()    { echo "stub:gemini|$1";    return 0; }

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

reset_registry() {
    REGISTERED_TOOLS=()
}

note "## Routing por llm_choice"

reset_registry
llm_choice="claude"
out=$(consultar_llm_agentic "hola mundo" 2>/dev/null) || true
assert_eq "$out" "stub:anthropic|hola mundo" "claude → agentic_loop_anthropic"

reset_registry
llm_choice="chatgpt"
out=$(consultar_llm_agentic "hola mundo" 2>/dev/null) || true
assert_eq "$out" "stub:openai|hola mundo" "chatgpt → agentic_loop_openai"

reset_registry
llm_choice="gemini"
out=$(consultar_llm_agentic "hola mundo" 2>/dev/null) || true
assert_eq "$out" "stub:gemini|hola mundo" "gemini → agentic_loop_gemini"

note "## Validación de argumentos (exit codes)"

reset_registry
llm_choice="claude"
ec=0
consultar_llm_agentic "" >/dev/null 2>&1 || ec=$?
assert_eq "$ec" "2" "prompt vacío → exit 2"

reset_registry
# shellcheck disable=SC2034 # consumido por consultar_llm_agentic (read indirectamente)
llm_choice=""
ec=0
consultar_llm_agentic "hola" >/dev/null 2>&1 || ec=$?
assert_eq "$ec" "2" "llm_choice vacío → exit 2"

reset_registry
llm_choice="bogus"
ec=0
consultar_llm_agentic "hola" >/dev/null 2>&1 || ec=$?
assert_eq "$ec" "2" "unsupported provider → exit 2"

note "## Side-effects: tool registration"

reset_registry
llm_choice="claude"
consultar_llm_agentic "ping" >/dev/null 2>&1 || true
found_read=0
found_write=0
found_edit=0
found_bash=0
found_web=0
found_grep=0
found_glob=0
found_subagent=0
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
assert_eq "$found_read" "1"  "read_file queda registrada tras consultar_llm_agentic"
assert_eq "$found_write" "1" "write_file queda registrada tras consultar_llm_agentic"
assert_eq "$found_edit" "1"  "edit_file queda registrada tras consultar_llm_agentic"
assert_eq "$found_bash" "1"  "bash_exec queda registrada tras consultar_llm_agentic"
assert_eq "$found_web" "1"   "web_fetch queda registrada tras consultar_llm_agentic"
assert_eq "$found_grep" "1"  "grep_search queda registrada tras consultar_llm_agentic"
assert_eq "$found_glob" "1"  "glob_files queda registrada tras consultar_llm_agentic"
assert_eq "$found_subagent" "1" "subagent queda registrada tras consultar_llm_agentic"

# Verifica que la definition de subagent llegue al JSON entregado al LLM.
all_defs=$(get_all_tool_definitions_json 2>/dev/null)
if echo "$all_defs" | jq -e '.[] | select(.name == "subagent")' >/dev/null 2>&1; then
    assert_eq "ok" "ok" "get_all_tool_definitions_json incluye subagent"
else
    assert_eq "$all_defs" "<contains name=subagent>" "get_all_tool_definitions_json incluye subagent"
fi

note "## Mensaje de error informativo (stderr)"

reset_registry
llm_choice="bogus"
err=$(consultar_llm_agentic "hola" 2>&1 >/dev/null) || true
case "$err" in
    *"unsupported provider"*) assert_eq "ok" "ok" "stderr menciona 'unsupported provider'" ;;
    *)                         assert_eq "$err" "*unsupported provider*" "stderr menciona 'unsupported provider'" ;;
esac

reset_registry
# shellcheck disable=SC2034 # consumido por consultar_llm_agentic (read indirectamente)
llm_choice=""
err=$(consultar_llm_agentic "hola" 2>&1 >/dev/null) || true
case "$err" in
    *"llm_choice is not configured"*) assert_eq "ok" "ok" "stderr menciona 'llm_choice is not configured'" ;;
    *)                                  assert_eq "$err" "*llm_choice is not configured*" "stderr menciona 'llm_choice is not configured'" ;;
esac

note "## Failure path: register_tool write_file falla"

# Stub register_tool: write_file devuelve 1, otros marcan como registrada sin
# tocar el filesystem. Simula tools/write_file.sh ausente o roto.
# shellcheck disable=SC2317
register_tool() {
    case "$1" in
        write_file) return 1 ;;
        *)
            # No queremos sourcear archivos reales — sólo marcar como registrada.
            local n
            if [ "${#REGISTERED_TOOLS[@]}" -gt 0 ]; then
                for n in "${REGISTERED_TOOLS[@]}"; do
                    if [ "$n" = "$1" ]; then return 0; fi
                done
            fi
            REGISTERED_TOOLS+=("$1")
            return 0
            ;;
    esac
}

reset_registry
# shellcheck disable=SC2034 # consumido por consultar_llm_agentic (read indirectamente)
llm_choice="claude"
ec=0
err=$(consultar_llm_agentic "hola" 2>&1 >/dev/null) || ec=$?
assert_eq "$ec" "1" "register_tool write_file falla → exit 1"
case "$err" in
    *"failed to register tool write_file"*) assert_eq "ok" "ok" "stderr menciona 'failed to register tool write_file'" ;;
    *)                                     assert_eq "$err" "*failed to register tool write_file*" "stderr menciona 'failed to register tool write_file'" ;;
esac

unset -f register_tool

note "## Failure path: register_tool edit_file falla"

# Stub selectivo: sólo edit_file falla; read_file y write_file se "registran"
# sin tocar disco. Verifica que el orden de evaluación (read → write → edit)
# se respete y el primer error después de write_file sea propagado con su
# propio mensaje contextual.
# shellcheck disable=SC2317
register_tool() {
    case "$1" in
        edit_file) return 1 ;;
        *)
            local n
            if [ "${#REGISTERED_TOOLS[@]}" -gt 0 ]; then
                for n in "${REGISTERED_TOOLS[@]}"; do
                    if [ "$n" = "$1" ]; then return 0; fi
                done
            fi
            REGISTERED_TOOLS+=("$1")
            return 0
            ;;
    esac
}

reset_registry
# shellcheck disable=SC2034 # consumido por consultar_llm_agentic (read indirectamente)
llm_choice="claude"
ec=0
err=$(consultar_llm_agentic "hola" 2>&1 >/dev/null) || ec=$?
assert_eq "$ec" "1" "register_tool edit_file falla → exit 1"
case "$err" in
    *"failed to register tool edit_file"*) assert_eq "ok" "ok" "stderr menciona 'failed to register tool edit_file'" ;;
    *)                                    assert_eq "$err" "*failed to register tool edit_file*" "stderr menciona 'failed to register tool edit_file'" ;;
esac

# Restaurar el dispatcher para que el resto del test (si lo hay) no quede stub.
unset -f register_tool

note "## Failure path: register_tool bash_exec falla"

# Stub selectivo: sólo bash_exec falla; read_file/write_file/edit_file se
# "registran" sin tocar disco. Verifica que el orden de evaluación
# (read → write → edit → bash) se respete y el error de bash_exec sea el
# que se propaga con su propio mensaje contextual.
# shellcheck disable=SC2317
register_tool() {
    case "$1" in
        bash_exec) return 1 ;;
        *)
            local n
            if [ "${#REGISTERED_TOOLS[@]}" -gt 0 ]; then
                for n in "${REGISTERED_TOOLS[@]}"; do
                    if [ "$n" = "$1" ]; then return 0; fi
                done
            fi
            REGISTERED_TOOLS+=("$1")
            return 0
            ;;
    esac
}

reset_registry
# shellcheck disable=SC2034 # consumido por consultar_llm_agentic (read indirectamente)
llm_choice="claude"
ec=0
err=$(consultar_llm_agentic "hola" 2>&1 >/dev/null) || ec=$?
assert_eq "$ec" "1" "register_tool bash_exec falla → exit 1"
case "$err" in
    *"failed to register tool bash_exec"*) assert_eq "ok" "ok" "stderr menciona 'failed to register tool bash_exec'" ;;
    *)                                    assert_eq "$err" "*failed to register tool bash_exec*" "stderr menciona 'failed to register tool bash_exec'" ;;
esac

unset -f register_tool

note "## Failure path: register_tool web_fetch falla"

# Stub selectivo: sólo web_fetch falla; read_file/write_file/edit_file/bash_exec
# se "registran" sin tocar disco. Verifica que el orden de evaluación
# (read → write → edit → bash → web_fetch) se respete y el error de web_fetch
# sea el que se propaga con su propio mensaje contextual.
# shellcheck disable=SC2317
register_tool() {
    case "$1" in
        web_fetch) return 1 ;;
        *)
            local n
            if [ "${#REGISTERED_TOOLS[@]}" -gt 0 ]; then
                for n in "${REGISTERED_TOOLS[@]}"; do
                    if [ "$n" = "$1" ]; then return 0; fi
                done
            fi
            REGISTERED_TOOLS+=("$1")
            return 0
            ;;
    esac
}

reset_registry
# shellcheck disable=SC2034 # consumido por consultar_llm_agentic (read indirectamente)
llm_choice="claude"
ec=0
err=$(consultar_llm_agentic "hola" 2>&1 >/dev/null) || ec=$?
assert_eq "$ec" "1" "register_tool web_fetch falla → exit 1"
case "$err" in
    *"failed to register tool web_fetch"*) assert_eq "ok" "ok" "stderr menciona 'failed to register tool web_fetch'" ;;
    *)                                    assert_eq "$err" "*failed to register tool web_fetch*" "stderr menciona 'failed to register tool web_fetch'" ;;
esac

unset -f register_tool

note "## Failure path: register_tool grep_search falla"

# Stub selectivo: sólo grep_search falla; las 5 anteriores se "registran" sin
# tocar disco. Verifica que el orden canónico
# (read → write → edit → bash → web_fetch → grep_search) se respete y que
# grep_search, como última tool del helper compartido, también propague su
# propio mensaje contextual.
# shellcheck disable=SC2317
register_tool() {
    case "$1" in
        grep_search) return 1 ;;
        *)
            local n
            if [ "${#REGISTERED_TOOLS[@]}" -gt 0 ]; then
                for n in "${REGISTERED_TOOLS[@]}"; do
                    if [ "$n" = "$1" ]; then return 0; fi
                done
            fi
            REGISTERED_TOOLS+=("$1")
            return 0
            ;;
    esac
}

reset_registry
# shellcheck disable=SC2034 # consumido por consultar_llm_agentic (read indirectamente)
llm_choice="claude"
ec=0
err=$(consultar_llm_agentic "hola" 2>&1 >/dev/null) || ec=$?
assert_eq "$ec" "1" "register_tool grep_search falla → exit 1"
case "$err" in
    *"failed to register tool grep_search"*) assert_eq "ok" "ok" "stderr menciona 'failed to register tool grep_search'" ;;
    *)                                      assert_eq "$err" "*failed to register tool grep_search*" "stderr menciona 'failed to register tool grep_search'" ;;
esac

unset -f register_tool

note "## Failure path: register_tool glob_files falla"

# Stub selectivo: sólo glob_files falla; las 6 anteriores se "registran" sin
# tocar disco. Verifica que el orden canónico
# (read → write → edit → bash → web_fetch → grep_search → glob_files) se respete
# y que glob_files, como última tool del helper compartido, propague su propio
# mensaje contextual.
# shellcheck disable=SC2317
register_tool() {
    case "$1" in
        glob_files) return 1 ;;
        *)
            local n
            if [ "${#REGISTERED_TOOLS[@]}" -gt 0 ]; then
                for n in "${REGISTERED_TOOLS[@]}"; do
                    if [ "$n" = "$1" ]; then return 0; fi
                done
            fi
            REGISTERED_TOOLS+=("$1")
            return 0
            ;;
    esac
}

reset_registry
# shellcheck disable=SC2034 # consumido por consultar_llm_agentic (read indirectamente)
llm_choice="claude"
ec=0
err=$(consultar_llm_agentic "hola" 2>&1 >/dev/null) || ec=$?
assert_eq "$ec" "1" "register_tool glob_files falla → exit 1"
case "$err" in
    *"failed to register tool glob_files"*) assert_eq "ok" "ok" "stderr menciona 'failed to register tool glob_files'" ;;
    *)                                     assert_eq "$err" "*failed to register tool glob_files*" "stderr menciona 'failed to register tool glob_files'" ;;
esac

unset -f register_tool

note "## Failure path: register_tool subagent falla"

# Stub selectivo: sólo subagent falla; las 7 anteriores se "registran" sin
# tocar disco. Verifica que el orden canónico
# (read → write → edit → bash → web_fetch → grep_search → glob_files → subagent)
# se respete y que subagent, como última tool del helper compartido, propague su
# propio mensaje contextual.
# shellcheck disable=SC2317
register_tool() {
    case "$1" in
        subagent) return 1 ;;
        *)
            local n
            if [ "${#REGISTERED_TOOLS[@]}" -gt 0 ]; then
                for n in "${REGISTERED_TOOLS[@]}"; do
                    if [ "$n" = "$1" ]; then return 0; fi
                done
            fi
            REGISTERED_TOOLS+=("$1")
            return 0
            ;;
    esac
}

reset_registry
# shellcheck disable=SC2034 # consumido por consultar_llm_agentic (read indirectamente)
llm_choice="claude"
ec=0
err=$(consultar_llm_agentic "hola" 2>&1 >/dev/null) || ec=$?
assert_eq "$ec" "1" "register_tool subagent falla → exit 1"
case "$err" in
    *"failed to register tool subagent"*) assert_eq "ok" "ok" "stderr menciona 'failed to register tool subagent'" ;;
    *)                                   assert_eq "$err" "*failed to register tool subagent*" "stderr menciona 'failed to register tool subagent'" ;;
esac

unset -f register_tool

note ""
note "Resultado: $pass pass, $fail fail"
if [ "$fail" -eq 0 ]; then
    exit 0
else
    exit 1
fi
