#!/bin/bash
#
# Reemplazos literales en plantillas (lib/core/tools.sh hf_tool_cmd,
# lib/core/prompts.sh hf_prompt, lib/agent/skills.sh skills_render) y
# adjuntos de Remote Control (lib/core/remote.sh _hf_rc_collect_files):
#   · con bash ≥ 5.2 (patsub_replacement) ${x//pat/$rep} cambiaba cada & del
#     reemplazo por el patrón: una URL firmada (?a=1&b=2) llegaba rota al motor
#   · el prompt llega intacto con &, \, comillas simples/dobles, $ y `
#   · solo se suben archivos marcados con HF_SEND o generados en el turno
# Debe pasar igual en bash 3.2 (macOS) y bash ≥ 5.2:
#   bash tests/test_literal_replace.sh
#   /opt/homebrew/bin/bash tests/test_literal_replace.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT" || exit 1

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
export HF_CONFIG_DIR="$TMP_DIR/cfg"
export HF_CONFIG_FILE="$HF_CONFIG_DIR/config.json"
mkdir -p "$HF_CONFIG_DIR"
printf '%s' '{"remote":{"relay":"http:https://api.test/api/rc"},"auth":{"token":"tok"}}' > "$HF_CONFIG_FILE"
export HF_LANG=en

hf_err() { echo "  ✗ $*" >&2; }
hf_warn() { echo "  ! $*" >&2; }
hf_auth_token() { echo tok; }
hf_auth_ok() { return 0; }
hf_config_get() { jq -r "$1 // empty" "$HF_CONFIG_FILE" 2>/dev/null; }

# shellcheck source=../lib/core/tools.sh disable=SC1091
source "$REPO_ROOT/lib/core/tools.sh"
# shellcheck source=../lib/core/prompts.sh disable=SC1091
source "$REPO_ROOT/lib/core/prompts.sh"
# shellcheck source=../lib/core/remote.sh disable=SC1091
source "$REPO_ROOT/lib/core/remote.sh"
export CODER_SKILLS_USER_DIR="$TMP_DIR/skills"
export CODER_SKILLS_BUILTIN_DIR=""
# shellcheck source=../lib/agent/skills.sh disable=SC1091
source "$REPO_ROOT/lib/agent/skills.sh"

PASS=0; FAIL=0
_assert() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then echo "  PASS: $desc"; PASS=$((PASS + 1))
  else echo "  FAIL: $desc"; echo "    expected: $expected"; echo "    got:      $actual"; FAIL=$((FAIL + 1)); fi
}

echo "== bash $BASH_VERSION (patsub_replacement: $(shopt -q patsub_replacement 2>/dev/null && echo on || echo n/a-or-off))"

URL='https://bucket.s3.amazonaws.com/rc/a%20b.png?X-Amz-Algorithm=AWS4&X-Amz-Credential=AK%2F1&X-Amz-Date=2026&X-Amz-Signature=ab&cd'
TRICKY="mira esto: $URL
y esto: back\\slash \\& \\\\ 'simple' \"doble\" \$HOME \`id\` & && fin&"

echo "== hf_str_replace_into"
r=""
hf_str_replace_into r 'a{P}b{P}c' '{P}' 'x&y'
_assert "& literal, varias apariciones" "$r" 'ax&ybx&yc'
hf_str_replace_into r 'pre {P} post' '{P}' "$TRICKY"
_assert "texto con &, \\ y comillas" "$r" "pre $TRICKY post"
hf_str_replace_into r 'sin marcador' '{P}' 'x&y'
_assert "sin el patrón no cambia" "$r" 'sin marcador'
hf_str_replace_into r '{P}' '{P}' ''
_assert "reemplazo vacío" "$r" ''
hf_str_replace_into r '{P}{P}' '{P}' '{P}'
_assert "el reemplazo que contiene el patrón no se re-expande" "$r" '{P}{P}'
hf_str_replace_into r 'a*b?c[d]' '*' '&'
_assert "patrón con comodines es literal" "$r" 'a&b?c[d]'
hf_str_replace_into r $'linea\n{P}\n' '{P}' 'v'
_assert "conserva el salto final" "$r" $'linea\nv\n'

echo "== hf_tool_cmd: el motor recibe el prompt intacto"
for tool in claude gemini codex aider; do
  cmd="$(hf_tool_cmd "$tool" "$TRICKY" auto)"
  # Ejecuta el comando con el binario sustituido por uno que imprime su
  # argumento entrecomillado: lo que recibe es exactamente el prompt.
  bin="${cmd%% *}"
  got="$(eval "$bin() { local a; for a in \"\$@\"; do case \"\$a\" in mira*) printf '%s' \"\$a\" ;; esac; done; }; $cmd")"
  _assert "$tool recibe el prompt sin cambios" "$got" "$TRICKY"
done
cmd="$(hf_tool_cmd claude "x" auto)"
_assert "OPTIONS se sustituye" "$cmd" "claude -p 'x' --dangerously-skip-permissions"

echo "== hf_prompt: variables con & y \\"
hf_prompts_sync() { :; }
printf '%s' '{"prompts":{"k":"Archivo: {{url}} | otra vez {{url}} | {{n}}"}}' > "$HF_CONFIG_DIR/prompts.json"
_assert "plantilla del pack con URL firmada" "$(hf_prompt k "url=$URL" 'n=a\b&c')" "Archivo: $URL | otra vez $URL | a\\b&c"

echo "== skills_render: {{args}} con &"
mkdir -p "$CODER_SKILLS_USER_DIR"
printf -- '---\nname: s1\ndescription: d\n---\nRevisa {{args}} y luego {{args}}.\n' > "$CODER_SKILLS_USER_DIR/s1.md"
_assert "args con URL y \\" "$(skills_render s1 "$URL" 'c:\dir &x')" "Revisa $URL c:\\dir &x y luego $URL c:\\dir &x."

echo "== adjuntos de Remote Control: solo lo pedido o generado"
UPLOADS="$TMP_DIR/uploads.log"; : > "$UPLOADS"
_hf_rc_upload_one() { echo "$1" >> "$UPLOADS"; printf '{"name":"%s","url":"u","type":"t","size":1}' "$(basename "$1")"; }
mkdir -p "$TMP_DIR/w/skills"
echo x > "$TMP_DIR/w/skills/analyze.md"; echo x > "$TMP_DIR/w/skills/carrusel.md"
touch -t 202001010000 "$TMP_DIR/w/skills/analyze.md" "$TMP_DIR/w/skills/carrusel.md"
OUT="Usé las skills $TMP_DIR/w/skills/analyze.md y '$TMP_DIR/w/skills/carrusel.md'.
Listo."
_assert "archivos solo mencionados no se suben" "$(_hf_rc_collect_files "$OUT" "$(date +%s)")" "[]"
_assert "sin inicio de turno ni marcadores no se sube nada" "$(_hf_rc_collect_files "$OUT")" "[]"
start=$(date +%s)
echo png > "$TMP_DIR/w/grafica.png"
OUT2="Generé la gráfica en $TMP_DIR/w/grafica.png (leí $TMP_DIR/w/skills/analyze.md)"
: > "$UPLOADS"
_hf_rc_collect_files "$OUT2" "$start" >/dev/null
_assert "lo generado en el turno sí se sube (y solo eso)" "$(cat "$UPLOADS")" "$TMP_DIR/w/grafica.png"
OUT3="Aquí está.
HF_SEND: $TMP_DIR/w/skills/carrusel.md"
: > "$UPLOADS"
_hf_rc_collect_files "$OUT3" >/dev/null
_assert "con HF_SEND se sube lo marcado aunque sea viejo" "$(cat "$UPLOADS")" "$TMP_DIR/w/skills/carrusel.md"

echo "== avance en vivo: sin el marcador HF_SEND"
PROG="$TMP_DIR/progress.log"; : > "$PROG"
# shellcheck disable=SC2317  # llamada indirecta desde _hf_relay_progress
curl() { local prev="" a; for a in "$@"; do [ "$prev" = "-d" ] && printf '%s\n' "$a" >> "$PROG"; prev="$a"; done; }
_hf_relay_progress m1 "$(printf 'Listo.\n  HF_SEND: /tmp/x.png')"
_assert "el avance lleva el texto sin la línea HF_SEND" "$(jq -c '.lines' "$PROG")" '["Listo."]'
: > "$PROG"
_hf_relay_progress m1 "HF_SEND: /tmp/x.png"
_assert "un avance que solo trae el marcador no se manda" "$(cat "$PROG")" ""
unset -f curl

echo ""
echo "Resultado: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
