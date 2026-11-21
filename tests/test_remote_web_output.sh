#!/bin/bash
#
# Remote Control · lo que llega al chat web cuando la tarea viene de la web
# (lib/core/repl.sh hf_run_request + lib/core/remote.sh):
#   · la web recibe SOLO la respuesta del motor: ni la línea del router, ni el
#     eco del comando, ni el bloque de skills, ni "terminó (exit 0)"
#   · el router clasifica lo que escribió la persona, no las instrucciones
#   · el motor sí recibe las instrucciones (skills + nota de Remote Control)
#   · el historial del hilo guarda solo lo que escribió la persona
#   · la respuesta no se manda dos veces (/append además de /respond)
#   · las rutas de las skills no se suben como adjuntos
# Todo con curl y el motor stubeados (sin red). Compatible con bash 3.2.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT" || exit 1

TMP_DIR=$(mktemp -d)
export HF_CONFIG_DIR="$TMP_DIR/cfg"
export HF_CONFIG_FILE="$HF_CONFIG_DIR/config.json"
mkdir -p "$HF_CONFIG_DIR"
printf '%s' '{"remote":{"relay":"http:https://api.test/api/rc"},"auth":{"token":"tok"}}' > "$HF_CONFIG_FILE"
export HF_LANG=es
export HOSTNAME="${HOSTNAME:-testhost}"
export USER="${USER:-tester}"
unset HF_REPL_SESSION HF_RC_AGENT_ID HF_RC_REQUEST_ID HF_RC_AGENT_NAME HF_RUN_FROM_RC HF_RUN_INSTRUCTIONS
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# ── stubs de la base del CLI ─────────────────────────────────────────
HF_C_BOLD=''; HF_C_RESET=''; HF_C_DIM=''; HF_C_GREEN=''; HF_C_RED=''; HF_C_CYAN=''; HF_C_YELLOW=''
hf_t() { if [ "$HF_LANG" = "es" ] && [ $# -ge 2 ] && [ -n "$2" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
hf_config_get() { jq -r "$1 // empty" "$HF_CONFIG_FILE" 2>/dev/null; }
hf_auth_ok() { return 0; }
hf_auth_token() { echo tok; }
hf_ok() { echo "  ✓ $*"; }
hf_err() { echo "  ✗ $*" >&2; }
hf_info() { echo "  › $*"; }
hf_warn() { echo "  ! $*"; }
hf_dim() { echo "  $*"; }
hf_metric() { :; }
hf_env_tag() { echo test; }
hf_prompt_label() { echo '❯'; }

# shellcheck source=../lib/core/router.sh disable=SC1091
source "$REPO_ROOT/lib/core/router.sh"
# shellcheck source=../lib/core/remote.sh disable=SC1091
source "$REPO_ROOT/lib/core/remote.sh"
# shellcheck source=../lib/core/repl.sh disable=SC1091
source "$REPO_ROOT/lib/core/repl.sh"

# Skills de la máquina: el bloque trae la palabra "Security" y rutas .md, que
# es justo lo que antes confundía al router y al detector de adjuntos.
hf_skills_prompt_block() {
  printf '## Skills\nStep-by-step playbooks installed on this machine.\n- security: Security analysis. (%s/skills/security.md)\n- docs: Generates docs. (%s/skills/docs.md)' "$TMP_DIR" "$TMP_DIR"
}
mkdir -p "$TMP_DIR/skills"; echo x > "$TMP_DIR/skills/security.md"; echo x > "$TMP_DIR/skills/docs.md"

# Motor: un "claude" de mentira que guarda el prompt recibido y contesta fijo.
ENGINE_PROMPT="$TMP_DIR/engine-prompt.txt"
ROUTE_LOG="$TMP_DIR/route.log"
SESSION_LOG="$TMP_DIR/session.log"
hf_active_tool() { echo auto; }
hf_active_mode() { echo auto; }
hf_tool_installed() { [ "$1" = "claude" ]; }
hf_agent_available() { return 1; }
hf_tool_cmd() { printf "fake_engine '%s'" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"; }
fake_engine() { printf '%s' "$1" > "$ENGINE_PROMPT"; echo "En el escritorio hay 3 archivos."; }
hf_route() { echo "$1" >> "$ROUTE_LOG"; echo claude; }
hf_repl_session_ensure() { return 0; }
hf_session_context() { :; }
hf_session_append_exchange() { printf '%s' "$2" > "$SESSION_LOG"; }
HF_REPL_SESSION="thread-test"

# Espejo activo: daemon.pid apunta a este mismo proceso.
export HF_RC_SID="sess-test"
mkdir -p "$HF_CONFIG_DIR/rc/sess-test"
echo $$ > "$HF_CONFIG_DIR/rc/sess-test/daemon.pid"
echo "sess-test" > "$HF_CONFIG_DIR/rc/sess-test/session"

CURL_LOG="$TMP_DIR/curl.log"; : > "$CURL_LOG"
curl() {
  local url="" a
  for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
  echo "$url" >> "$CURL_LOG"
  echo '{}'
}

PASS=0; FAIL=0
_assert() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then echo "  PASS: $desc"; PASS=$((PASS + 1))
  else echo "  FAIL: $desc (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1)); fi
}
_assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  PASS: $desc"; PASS=$((PASS + 1))
  else echo "  FAIL: $desc (missing: '$needle' in: ${haystack:0:300})"; FAIL=$((FAIL + 1)); fi
}
_assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  FAIL: $desc (unexpected: '$needle' in: ${haystack:0:300})"; FAIL=$((FAIL + 1))
  else echo "  PASS: $desc"; PASS=$((PASS + 1)); fi
}

ASK="que hay en el escritorio?"

echo "== tarea que viene de la web (como la corre el daemon)"
# Sin terminal de control (como bajo launchd): el adorno no tiene a dónde ir.
OUT="$( ( HIVEFLOW_NO_SPINNER=1 HF_RUN_FROM_RC=1 HF_RUN_INSTRUCTIONS="$(_hf_rc_instructions web)" hf_run_request "$ASK" ) 2>&1 < /dev/null )"
wait 2>/dev/null
CLEAN="$(printf '%s\n' "$OUT" | grep -v '^[[:space:]]*$')"
_assert "la web recibe solo la respuesta del motor" "$CLEAN" "En el escritorio hay 3 archivos."
_assert_not_contains "sin línea del router" "Router" "$OUT"
_assert_not_contains "sin eco del comando" "fake_engine" "$OUT"
_assert_not_contains "sin bloque de skills" "Skills" "$OUT"
_assert_not_contains "sin nota de Remote Control" "[Hiveflow Remote Control]" "$OUT"
_assert_not_contains "sin 'terminó (exit 0)'" "exit 0" "$OUT"
_assert_not_contains "sin errores de /dev/tty" "/dev/tty" "$OUT"
_assert "el router clasifica lo que escribió la persona" "$(tail -1 "$ROUTE_LOG")" "default"

ENGINE="$(cat "$ENGINE_PROMPT")"
_assert_contains "el motor recibe la pregunta" "$ASK" "$ENGINE"
_assert_contains "el motor recibe las skills" "## Skills" "$ENGINE"
_assert_contains "el motor recibe la nota de Remote Control" "HF_SEND: /ruta/absoluta" "$ENGINE"
_assert "el historial guarda solo la pregunta" "$(cat "$SESSION_LOG")" "$ASK"
sleep 1
_assert "la respuesta no se manda también por /append" "$(grep -c '/append' "$CURL_LOG")" "0"
_assert "las rutas de las skills no se adjuntan" "$(_hf_rc_collect_files "$OUT")" "[]"

echo "== una pregunta de seguridad sí se clasifica como tal"
( HIVEFLOW_NO_SPINNER=1 HF_RUN_FROM_RC=1 HF_RUN_INSTRUCTIONS="$(_hf_rc_instructions web)" hf_run_request "haz una auditoría de seguridad" ) >/dev/null 2>&1 < /dev/null
_assert "router: security-audit" "$(tail -1 "$ROUTE_LOG")" "security-audit"

echo "== el motor falla: la web se entera"
fake_engine() { echo "Failed to authenticate"; return 1; }
OUT_FAIL="$( ( HIVEFLOW_NO_SPINNER=1 HF_RUN_FROM_RC=1 HF_RUN_INSTRUCTIONS="x" hf_run_request "$ASK" ) 2>&1 < /dev/null )"
_assert_contains "llega el error del motor" "Failed to authenticate" "$OUT_FAIL"
_assert_contains "llega el código de salida" "código 1" "$OUT_FAIL"
fake_engine() { printf '%s' "$1" > "$ENGINE_PROMPT"; echo "En el escritorio hay 3 archivos."; }

echo "== tarea tecleada en la terminal (sin Remote Control de por medio)"
: > "$CURL_LOG"
OUT_LOCAL="$( ( HIVEFLOW_NO_SPINNER=1 hf_run_request "$ASK" ) 2>&1 < /dev/null )"
sleep 1
_assert_contains "la terminal sí ve la línea del router" "Router: tarea 'default'" "$OUT_LOCAL"
_assert_contains "la terminal sí ve el comando" "fake_engine '$ASK'" "$OUT_LOCAL"
_assert_contains "la terminal sí ve el cierre" "terminó (exit 0)" "$OUT_LOCAL"
_assert "sin instrucciones el motor recibe la pregunta tal cual" "$(cat "$ENGINE_PROMPT")" "$ASK"
_assert "lo tecleado en la terminal sí se refleja en la web (/append)" "$(grep -c '/append' "$CURL_LOG")" "1"

echo "== _hf_rc_prompt_with_files sigue armando tarea + instrucciones"
P="$(_hf_rc_prompt_with_files "haz X" web)"
_assert_contains "empieza por la tarea" "haz X" "${P:0:5}"
_assert_contains "trae las skills" "## Skills" "$P"
_assert_contains "trae la nota" "chat web" "$P"

echo "== HF_SEND: nunca viaja al backend (ni la ruta local)"
BODY_LOG="$TMP_DIR/body.log"; : > "$BODY_LOG"; : > "$CURL_LOG"
curl() {
  local url="" a prev=""
  for a in "$@"; do
    case "$a" in http*) url="$a" ;; esac
    [ "$prev" = "-d" ] && printf '%s\t%s\n' "$url" "$a" >> "$BODY_LOG"
    prev="$a"
  done
  echo "$url" >> "$CURL_LOG"
  echo '{}'
}
RAW="$(printf 'Listo, aquí está.\nHF_SEND: /Users/alguien/Desktop/reporte.pdf\n  HF_SEND: /tmp/x.png')"
_hf_relay_respond "sess-test" "m1" "$RAW" "[]"
_assert_not_contains "respond sin adjuntos: sin HF_SEND" "HF_SEND" "$(cat "$BODY_LOG")"
_assert_not_contains "respond sin adjuntos: sin ruta local" "/Users/alguien" "$(cat "$BODY_LOG")"
_assert_contains "respond conserva el texto" "Listo, aquí está." "$(cat "$BODY_LOG")"
: > "$BODY_LOG"
_hf_relay_progress "m1" "$RAW"
_assert_not_contains "progress: sin HF_SEND" "HF_SEND" "$(cat "$BODY_LOG")"
: > "$BODY_LOG"
_hf_rc_append assistant "$RAW"
_assert_not_contains "append (turno local): sin HF_SEND" "HF_SEND" "$(cat "$BODY_LOG")"
_assert_contains "append (turno local) sí se manda" "/append" "$(cat "$BODY_LOG")"
: > "$BODY_LOG"
_hf_rc_append assistant "HF_SEND: /tmp/solo.png"
_assert "append que solo traía HF_SEND no se manda" "$(grep -c '/append' "$BODY_LOG")" "0"

echo "== turno de la web: el CLI no manda /append de texto (solo /respond)"
: > "$BODY_LOG"
( HF_RUN_FROM_RC=1 _hf_rc_append assistant "respuesta" )
_assert "HF_RUN_FROM_RC: sin /append de texto" "$(grep -c '/append' "$BODY_LOG")" "0"
( HF_RUN_FROM_RC=1 _hf_rc_append assistant "foto.png" '[{"url":"https://x/f.png","name":"foto.png"}]' )
_assert "HF_RUN_FROM_RC: /send con adjunto sí pasa" "$(grep -c '/append' "$BODY_LOG")" "1"

echo "== el daemon marca también los slash de la web (HF_RUN_FROM_RC)"
_assert_contains "slash del daemon corre con HF_RUN_FROM_RC=1" 'HF_RUN_FROM_RC=1 hf_handle_slash "$text"' "$(declare -f _hf_rc_daemon)"

echo "== agente nativo pedido desde la web: no hay /append"
: > "$BODY_LOG"
hf_agent_turn() { :; }
hf_session_last_assistant() { echo "respuesta nativa"; }
( HF_RUN_FROM_RC=1 _hf_native_turn "hola" ) >/dev/null 2>&1
sleep 1
_assert "nativo desde la web: sin /append" "$(grep -c '/append' "$BODY_LOG")" "0"
( _hf_native_turn "hola" ) >/dev/null 2>&1
sleep 1
_assert "nativo tecleado en la terminal: un /append" "$(grep -c '/append' "$BODY_LOG")" "1"

echo ""
echo "Resultado: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
