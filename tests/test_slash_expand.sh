#!/bin/bash
# tests/test_slash_expand.sh
# Cobertura unitaria de `_modo_agentico_expand_slash` en lib/tool_calling.sh.
#
# La función traduce slash commands del modo agentic a prompts ricos en
# guidance de tool-use. Los comandos control (/exit /quit /salir /reset /help)
# NO pasan por aquí — el loop los intercepta antes. /agent ya tiene su propia
# suite (tests/test_slash_agent.sh) — aquí cubrimos:
#
#   /analyze /refactor /review /security /performance /test /docs
#   /think <tema>   (requiere args)
#   /files
#   /focus <ruta>   (requiere args)
#   /summary
#   /fix <descr>    (requiere args)
#   /agent <prompt> (requiere args — passthrough)
#   /<desconocido>  (exit 1, sin stderr)
#
# Test es offline y no depende de ningún provider/API key.

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
    local haystack="$1" needle="$2" label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        note "  PASS $label"
        pass=$((pass + 1))
    else
        note "  FAIL $label"
        note "    needle missing: '$needle'"
        note "    haystack head:  '${haystack:0:200}'"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        note "  PASS $label"
        pass=$((pass + 1))
    else
        note "  FAIL $label"
        note "    needle present (should not be): '$needle'"
        fail=$((fail + 1))
    fi
}

# ----------------------------------------------------------------------
note "## Comandos sin args: expansion a prompt fijo, exit 0"
# ----------------------------------------------------------------------

# Cada comando produce un prompt no-vacío y exit 0. Validamos también que
# el prompt mencione tools relevantes para que el LLM las invoque.

for case in \
    "/analyze|read_file" \
    "/refactor|edit_file" \
    "/review|read_file" \
    "/security|read_file" \
    "/performance|read_file" \
    "/test|write_file" \
    "/docs|read_file" \
    "/files|bash_exec" \
    "/summary|read_file"
do
    cmd="${case%|*}"
    hint="${case#*|}"
    ec=0
    out=$(_modo_agentico_expand_slash "$cmd") || ec=$?
    assert_eq "$ec" "0" "$cmd → exit 0"
    if [ -n "$out" ]; then
        note "  PASS $cmd → stdout no vacío"
        pass=$((pass + 1))
    else
        note "  FAIL $cmd → stdout no vacío"
        fail=$((fail + 1))
    fi
    assert_contains "$out" "$hint" "$cmd menciona tool '$hint'"
done

# ----------------------------------------------------------------------
note "## /refactor: con y sin target"
# ----------------------------------------------------------------------

out=$(_modo_agentico_expand_slash "/refactor")
assert_contains "$out" "current project" "/refactor sin args → wording 'current project'"

out=$(_modo_agentico_expand_slash "/refactor tests/fixtures/sample_config.sh")
assert_contains "$out" "tests/fixtures/sample_config.sh" "/refactor <target> incrusta el target"
assert_contains "$out" "dry_run=true" "/refactor <target> sugiere dry_run para preview"

# ----------------------------------------------------------------------
note "## /think <tema>: requiere args"
# ----------------------------------------------------------------------

ec=0
out=$(_modo_agentico_expand_slash "/think" 2>&1) || ec=$?
assert_eq "$ec" "2" "/think sin args → exit 2"
assert_contains "$out" "Usage: /think" "/think sin args → mensaje de uso"

ec=0
out=$(_modo_agentico_expand_slash "/think arquitectura modular bash") || ec=$?
assert_eq "$ec" "0" "/think con tema → exit 0"
assert_contains "$out" "arquitectura modular bash" "/think preserva tema multi-palabra"

# ----------------------------------------------------------------------
note "## /focus <ruta>: requiere args"
# ----------------------------------------------------------------------

ec=0
out=$(_modo_agentico_expand_slash "/focus" 2>&1) || ec=$?
assert_eq "$ec" "2" "/focus sin args → exit 2"
assert_contains "$out" "Usage: /focus" "/focus sin args → mensaje de uso"

ec=0
out=$(_modo_agentico_expand_slash "/focus lib/permissions.sh") || ec=$?
assert_eq "$ec" "0" "/focus con ruta → exit 0"
assert_contains "$out" "lib/permissions.sh" "/focus preserva la ruta"

# ----------------------------------------------------------------------
note "## /fix <descripción>: requiere args"
# ----------------------------------------------------------------------

ec=0
out=$(_modo_agentico_expand_slash "/fix" 2>&1) || ec=$?
assert_eq "$ec" "2" "/fix sin args → exit 2"
assert_contains "$out" "Usage: /fix" "/fix sin args → mensaje de uso"

ec=0
out=$(_modo_agentico_expand_slash "/fix race condition en el lock file") || ec=$?
assert_eq "$ec" "0" "/fix con descr → exit 0"
assert_contains "$out" "race condition en el lock file" "/fix preserva descr multi-palabra"
assert_contains "$out" "dry_run=true" "/fix sugiere dry_run para preview"

# ----------------------------------------------------------------------
note "## /agent <prompt>: passthrough del prompt"
# ----------------------------------------------------------------------

ec=0
out=$(_modo_agentico_expand_slash "/agent" 2>&1) || ec=$?
assert_eq "$ec" "2" "/agent sin args → exit 2 (en expand)"
assert_contains "$out" "/agent" "/agent sin args → mensaje menciona el comando"

ec=0
out=$(_modo_agentico_expand_slash "/agent lista las funciones en tests/fixtures/sample_config.sh") || ec=$?
assert_eq "$ec" "0" "/agent con prompt → exit 0"
assert_eq "$out" "lista las funciones en tests/fixtures/sample_config.sh" "/agent es passthrough literal del prompt"

# ----------------------------------------------------------------------
note "## Comando desconocido: exit 1 silencioso"
# ----------------------------------------------------------------------

ec=0
out=$(_modo_agentico_expand_slash "/desconocido foo bar" 2>&1) || ec=$?
assert_eq "$ec" "1" "/desconocido → exit 1"
assert_eq "$out" "" "/desconocido → stdout+stderr vacíos (sin ruido)"

ec=0
out=$(_modo_agentico_expand_slash "/" 2>&1) || ec=$?
assert_eq "$ec" "1" "/ solo → exit 1"

ec=0
out=$(_modo_agentico_expand_slash "/notacommand" 2>&1) || ec=$?
assert_eq "$ec" "1" "/notacommand → exit 1"

# ----------------------------------------------------------------------
note "## Whitespace handling: args trimmed"
# ----------------------------------------------------------------------

# /focus con espacios al inicio y final del arg → los espacios externos al
# arg deben recortarse pero el contenido interno preservarse.
out=$(_modo_agentico_expand_slash "/focus    lib/tool_calling.sh   ")
assert_contains "$out" "lib/tool_calling.sh" "/focus trimea whitespace external del arg"
assert_not_contains "$out" "   lib/tool_calling.sh" "/focus no deja prefix spaces en el arg"

out=$(_modo_agentico_expand_slash "/think    foo bar baz   ")
assert_contains "$out" "foo bar baz" "/think trimea pero preserva spaces internos"

# ----------------------------------------------------------------------
note "## Comandos parametrizables vs fixed: cmd + args vacíos"
# ----------------------------------------------------------------------

# /refactor acepta vacío (cae a la rama sin args). /analyze ignora args:
# se mantiene el prompt fijo independientemente.
out_no=$(_modo_agentico_expand_slash "/analyze")
out_with=$(_modo_agentico_expand_slash "/analyze ignored args")
assert_eq "$out_no" "$out_with" "/analyze ignora args y mantiene prompt fijo"

# ----------------------------------------------------------------------
note ""
note "Resultado: $pass pass, $fail fail"

[ "$fail" -eq 0 ] || exit 1
exit 0
