#!/bin/bash
#
# Remote Control · el agente conectado a tu computadora (lib/core/remote.sh):
#   · _hf_relay_register manda agent_id / request_id y lee agent_name
#   · _hf_relay_poll expone el origen (web | agent + nombre)
#   · _hf_rc_prompt_with_files usa la instrucción para agentes
#   · _hf_rc_resolve_agent resuelve por id o nombre (sin mayúsculas)
#   · /remote control --agent vincula; si el registro falla con HF_RC_REQUEST_ID
#     manda start-ack ok:false
# Todo con curl stubeado (sin red). Compatible con bash 3.2.

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
export HF_RC_POLL=1
export HOSTNAME="${HOSTNAME:-testhost}"
export USER="${USER:-tester}"
unset HF_REPL_SESSION HF_RC_AGENT_ID HF_RC_REQUEST_ID HF_RC_AGENT_NAME

_cleanup() {
  local p
  for p in "$HF_CONFIG_DIR"/rc/*/daemon.pid; do
    [ -f "$p" ] && kill "$(cat "$p" 2>/dev/null)" 2>/dev/null
  done
  rm -rf "$TMP_DIR"
}
trap _cleanup EXIT INT TERM

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

# shellcheck source=../lib/core/remote.sh disable=SC1091
source "$REPO_ROOT/lib/core/remote.sh"
hf_remote_session() { echo "sess-test"; }

# ── curl stub: registra cada llamada (url + body) y responde por fixture ──
CURL_LOG="$TMP_DIR/curl.log"
: > "$CURL_LOG"
curl() {
  local url="" body="" a prev=""
  for a in "$@"; do
    case "$prev" in -d) body="$a" ;; esac
    case "$a" in http*) url="$a" ;; esac
    prev="$a"
  done
  printf '%s\t%s\n' "$url" "$body" >> "$CURL_LOG"
  case "$url" in
    */register)  cat "$TMP_DIR/register.json" 2>/dev/null ;;
    */poll*)     cat "$TMP_DIR/poll.json" 2>/dev/null ;;
    */agents)    cat "$TMP_DIR/agents.json" 2>/dev/null ;;
    */start-ack) echo '{"ok":true}' ;;
    *)           echo '{}' ;;
  esac
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
  if [[ "$haystack" == *"$needle"* ]]; then echo "  FAIL: $desc (unexpected: '$needle')"; FAIL=$((FAIL + 1))
  else echo "  PASS: $desc"; PASS=$((PASS + 1)); fi
}
_last_body() { tail -1 "$CURL_LOG" | cut -f2; }

echo "== _hf_relay_register: agent_id / request_id / agent_name"
printf '%s' '{"session_id":"sess-test","status":"connected","agent_id":"64aaaaaaaaaaaaaaaaaaaaaa","agent_name":"Cobranza"}' > "$TMP_DIR/register.json"
HF_RC_AGENT_ID="64aaaaaaaaaaaaaaaaaaaaaa" HF_RC_REQUEST_ID="req-1" _hf_relay_register "sess-test"
_assert "agent_id viaja en el registro" "$(_last_body | jq -r '.agent_id')" "64aaaaaaaaaaaaaaaaaaaaaa"
_assert "request_id viaja en el registro" "$(_last_body | jq -r '.request_id')" "req-1"
_assert "agent_name se lee de la respuesta" "$HF_RC_AGENT_NAME" "Cobranza"
_assert "registro aceptado" "$HF_RC_REGISTERED" "1"
HF_RC_AGENT_NAME=""
_hf_relay_register "sess-test"
_assert "sin HF_RC_AGENT_ID no se manda agent_id" "$(_last_body | jq -r 'has("agent_id")')" "false"
_assert "sin HF_RC_REQUEST_ID no se manda request_id" "$(_last_body | jq -r 'has("request_id")')" "false"

echo "== _hf_relay_poll: origen"
printf '%s' '{"msg_id":"m1","text":"lista los archivos","origin":{"kind":"agent","agentId":"64a","name":"Cobranza"}}' > "$TMP_DIR/poll.json"
_assert "poll con origen agente" "$(_hf_relay_poll sess-test)" "$(printf 'm1\tagent\tCobranza\tlista los archivos')"
printf '%s' '{"msg_id":"m2","text":"hola","origin":{"kind":"web"}}' > "$TMP_DIR/poll.json"
_assert "poll con origen web" "$(_hf_relay_poll sess-test)" "$(printf 'm2\tweb\t\thola')"
printf '%s' '{"msg_id":"m3","text":"legacy"}' > "$TMP_DIR/poll.json"
_assert "poll sin origen = web (relay viejo)" "$(_hf_relay_poll sess-test)" "$(printf 'm3\tweb\t\tlegacy')"
printf '%s' '{}' > "$TMP_DIR/poll.json"
_assert "poll vacío no imprime nada" "$(_hf_relay_poll sess-test)" ""
printf '%s' '{"error":"unauthorized"}' > "$TMP_DIR/poll.json"
_assert "poll con error no imprime nada" "$(_hf_relay_poll sess-test)" ""

echo "== _hf_rc_prompt_with_files: instrucción por origen"
P_AGENT="$(_hf_rc_prompt_with_files "haz X" agent Cobranza)"
_assert_contains "prompt agente menciona al agente" 'agente de HiveFlow "Cobranza"' "$P_AGENT"
_assert_contains "prompt agente pide resultados" "RESULTADOS" "$P_AGENT"
_assert_contains "prompt agente conserva HF_SEND" "HF_SEND: /ruta/absoluta" "$P_AGENT"
_assert_contains "prompt agente conserva la tarea" "haz X" "$P_AGENT"
P_WEB="$(_hf_rc_prompt_with_files "haz X" web)"
_assert_contains "prompt web sigue hablando del chat web" "chat web" "$P_WEB"
_assert_not_contains "prompt web no menciona agente autónomo" "agente autónomo" "$P_WEB"
HF_LANG=en
P_AGENT_EN="$(_hf_rc_prompt_with_files "do X" agent Sales)"
_assert_contains "prompt agente EN" "autonomous agent" "$P_AGENT_EN"
HF_LANG=es

echo "== _hf_rc_resolve_agent"
printf '%s' '{"success":true,"data":[{"_id":"64b0000000000000000000b1","name":"Cobranza"},{"_id":"64b0000000000000000000b2","name":"Ventas MX"}]}' > "$TMP_DIR/agents.json"
unset HF_RC_AGENT_ID HF_RC_AGENT_NAME
_hf_rc_resolve_agent "cobranza"; rc=$?
_assert "resuelve por nombre sin mayúsculas" "$rc:$HF_RC_AGENT_ID:$HF_RC_AGENT_NAME" "0:64b0000000000000000000b1:Cobranza"
_assert_contains "consulta GET /api/agents (del relay)" "https://api.test/api/agents" "$(tail -1 "$CURL_LOG" | cut -f1)"
_hf_rc_resolve_agent "64b0000000000000000000b2"; rc=$?
_assert "resuelve por id" "$rc:$HF_RC_AGENT_ID:$HF_RC_AGENT_NAME" "0:64b0000000000000000000b2:Ventas MX"
_hf_rc_resolve_agent "no-existe"; rc=$?
_assert "agente inexistente falla" "$rc" "1"
unset HF_RC_AGENT_ID HF_RC_AGENT_NAME

echo "== /remote control: registro fallido con HF_RC_REQUEST_ID → start-ack ok:false"
printf '%s' '{"success":false,"message":"token inválido"}' > "$TMP_DIR/register.json"
: > "$CURL_LOG"
OUT="$(HF_RC_REQUEST_ID="req-9" hf_remote_control 2>&1)"; rc=$?
_assert "falla con código 1" "$rc" "1"
ACK_LINE="$(grep 'start-ack' "$CURL_LOG" | tail -1)"
_assert_contains "manda start-ack" "/api/rc/start-ack" "$ACK_LINE"
_assert "start-ack lleva requestId y ok:false" "$(printf '%s' "$ACK_LINE" | cut -f2 | jq -c '[.requestId, .ok]')" '["req-9",false]'
_assert_contains "start-ack lleva el error" "token inválido" "$(printf '%s' "$ACK_LINE" | cut -f2 | jq -r '.error')"
_assert_contains "avisa el error" "No se pudo conectar al relay" "$OUT"

echo "== /remote control sin HF_RC_REQUEST_ID no manda start-ack"
: > "$CURL_LOG"
hf_remote_control >/dev/null 2>&1
_assert "sin start-ack" "$(grep -c 'start-ack' "$CURL_LOG")" "0"

echo "== /remote control --agent <nombre>: registra con agent_id y anuncia el agente"
printf '%s' '{"session_id":"sess-test","status":"connected","agent_id":"64b0000000000000000000b1","agent_name":"Cobranza","conversation_id":"c1","conversation_title":"CLI"}' > "$TMP_DIR/register.json"
printf '%s' '{}' > "$TMP_DIR/poll.json"
: > "$CURL_LOG"
OUT="$(hf_remote_control --agent cobranza 2>&1)"; rc=$?
_assert "conecta" "$rc" "0"
REG_BODY="$(grep '/api/rc/register' "$CURL_LOG" | tail -1 | cut -f2)"
_assert "registro con agent_id resuelto" "$(printf '%s' "$REG_BODY" | jq -r '.agent_id')" "64b0000000000000000000b1"
_assert_contains "anuncia 'Conectada al agente'" "Conectada al agente 🤖 Cobranza" "$OUT"
# Parar el daemon que arrancó (curl stubeado: no hay red)
hf_rc_stop >/dev/null 2>&1
unset HF_RC_AGENT_ID HF_RC_AGENT_NAME

echo "== /remote control --agent desconocido: no registra"
: > "$CURL_LOG"
OUT="$(hf_remote_control --agent nadie 2>&1)"; rc=$?
_assert "falla" "$rc" "1"
_assert "no registró" "$(grep -c '/api/rc/register' "$CURL_LOG")" "0"
_assert_contains "explica" "No encontré el agente" "$OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
