#!/bin/bash
#
# Remote Control · credenciales rechazadas (lib/core/remote.sh):
#   · _hf_rc_split_status separa cuerpo y código HTTP
#   · el sondeo y el latido anotan el código de cada respuesta
#   · el daemon se DETIENE solo tras HF_RC_AUTH_FAIL_MAX rechazos seguidos (401/403),
#     deja el motivo en <estado>/stopped, quita su pid y avisa
#   · un rechazo aislado no lo detiene; con respuestas normales sigue vivo
#   · backend caído (000/5xx) no lo detiene: espera más entre intentos
#   · worker de tablero: un rechazo del backend corta la pasada sin mandar el latido
#
# Regresión de noviembre de 2026: una API key revocada dejaba al espejo preguntando
# cada 2 s para siempre (~30 errores por minuto en el backend).
# Todo con curl stubeado (sin red). Compatible con bash 3.2.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT" || exit 1

TMP_DIR=$(mktemp -d)
export HF_CONFIG_DIR="$TMP_DIR/cfg"
export HF_CONFIG_FILE="$HF_CONFIG_DIR/config.json"
mkdir -p "$HF_CONFIG_DIR"
cat > "$HF_CONFIG_FILE" <<'EOF'
{"remote":{"relay":"http:https://api.test/api/rc"},"auth":{"token":"tok"},
 "workers":{"w1":{"board_id":"b1","chat_id":"","every":5,"playbook":"x","parallel":false,
   "columns":{"trigger":"To Do","working":"In Progress","review":"QA","human":"Human in the loop","error":"Error Auto"}}}}
EOF
export HF_LANG=es
export HF_RC_POLL=1
export HOSTNAME="${HOSTNAME:-testhost}"
export USER="${USER:-tester}"
unset HF_REPL_SESSION HF_RC_AGENT_ID HF_RC_REQUEST_ID HF_RC_AGENT_NAME

DAEMON_PID=""
_cleanup() {
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
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
hf_metric() { echo "metric $*" >> "$TMP_DIR/metrics.log"; }
hf_env_tag() { echo test; }
hf_prompt_label() { echo '❯'; }
hf_prompt() { return 1; }

# shellcheck source=../lib/core/remote.sh disable=SC1091
source "$REPO_ROOT/lib/core/remote.sh"

# ── curl stub ────────────────────────────────────────────────────────
# Responde según una cola de códigos en $TMP_DIR/codes (uno por línea; el último se
# repite). Si la llamada pide -w, añade "\n<código>" como hace curl de verdad.
CURL_LOG="$TMP_DIR/curl.log"
: > "$CURL_LOG"
curl() {
  local url="" a want_code=0
  for a in "$@"; do
    case "$a" in http*) url="$a" ;; -w) want_code=1 ;; esac
  done
  local kind=other
  case "$url" in */poll*) kind=poll ;; */heartbeat) kind=heartbeat ;; */register) kind=register ;; */disconnect) kind=disconnect ;; esac
  printf '%s\n' "$kind" >> "$CURL_LOG"
  local code=200
  if [ "$kind" = poll ] || [ "$kind" = heartbeat ]; then
    if [ -s "$TMP_DIR/codes" ]; then
      code="$(head -1 "$TMP_DIR/codes")"
      [ "$(wc -l < "$TMP_DIR/codes" | tr -d ' ')" -gt 1 ] && { tail -n +2 "$TMP_DIR/codes" > "$TMP_DIR/codes.t" && mv "$TMP_DIR/codes.t" "$TMP_DIR/codes"; }
    fi
  fi
  local body='{}'
  case "$code" in
    401) body='{"success":false,"messageKey":"middleware.invalidToken","message":"Token inválido","error":"API Key inválida"}' ;;
    403) body='{"success":false,"message":"IP not allowed"}' ;;
    500) body='{"success":false,"message":"boom"}' ;;
    000) body='' ;;
    200) [ "$kind" = poll ] && [ -s "$TMP_DIR/poll.json" ] && body="$(cat "$TMP_DIR/poll.json")"
         [ "$kind" = heartbeat ] && body='{"ok":true}' ;;
  esac
  printf '%s' "$body"
  [ "$want_code" = 1 ] && printf '\n%s' "$code"
  return 0
}
_calls() { grep -c "^$1\$" "$CURL_LOG" 2>/dev/null; }

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
_assert_true() {
  local desc="$1"; shift
  if "$@"; then echo "  PASS: $desc"; PASS=$((PASS + 1)); else echo "  FAIL: $desc"; FAIL=$((FAIL + 1)); fi
}

export HF_RC_SID="sess-test"
SDIR="$(_hf_rc_state_dir)"
mkdir -p "$SDIR"

# Arranca el daemon como lo hace hf_remote_control y espera a que termine o venza el plazo.
_start_daemon() {
  : > "$CURL_LOG"; : > "$SDIR/daemon.log"; rm -f "$SDIR/stopped" "$SDIR/last_status" "$TMP_DIR/metrics.log"
  ( _hf_rc_daemon "sess-test" ) </dev/null >> "$SDIR/daemon.log" 2>&1 &
  DAEMON_PID=$!
  printf '%s' "$DAEMON_PID" > "$SDIR/daemon.pid"
}
_wait_exit() { # <segundos> → 0 si el daemon terminó solo
  local i=0
  while [ "$i" -lt "$(( $1 * 5 ))" ]; do
    kill -0 "$DAEMON_PID" 2>/dev/null || return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}
_alive() { kill -0 "$DAEMON_PID" 2>/dev/null; }
_stop_daemon() { kill "$DAEMON_PID" 2>/dev/null; wait "$DAEMON_PID" 2>/dev/null; DAEMON_PID=""; }

echo "== _hf_rc_split_status"
_hf_rc_split_status "$(printf '{"a":1}\n200')"
_assert "cuerpo con código" "$_HF_RC_BODY|$_HF_RC_CODE" '{"a":1}|200'
_hf_rc_split_status "$(printf '\n401')"
_assert "cuerpo vacío con código" "$_HF_RC_BODY|$_HF_RC_CODE" '|401'
_hf_rc_split_status '{"a":1}'
_assert "sin código deja el cuerpo intacto (curl viejo o stub)" "$_HF_RC_BODY|$_HF_RC_CODE" '{"a":1}|'
_hf_rc_split_status "$(printf 'línea 1\nlínea 2\n500')"
_assert "cuerpo de varias líneas" "$_HF_RC_BODY|$_HF_RC_CODE" "$(printf 'línea 1\nlínea 2')|500"
_hf_rc_split_status ''
_assert "vacío" "$_HF_RC_BODY|$_HF_RC_CODE" '|'

echo "== el sondeo y el latido anotan el código"
echo 401 > "$TMP_DIR/codes"
_assert "sondeo rechazado no imprime nada" "$(_hf_relay_poll sess-test)" ""
_assert "sondeo anota 401" "$(_hf_rc_last_status)" "401"
echo 200 > "$TMP_DIR/codes"
printf '%s' '{"msg_id":"m1","text":"hola","origin":{"kind":"web"}}' > "$TMP_DIR/poll.json"
_assert "sondeo normal sigue entregando el mensaje" "$(_hf_relay_poll sess-test)" "$(printf 'm1\tweb\t\thola')"
_assert "sondeo anota 200" "$(_hf_rc_last_status)" "200"
rm -f "$TMP_DIR/poll.json"
echo 403 > "$TMP_DIR/codes"; : > "$CURL_LOG"
_hf_relay_heartbeat sess-test
_assert "latido anota 403" "$(_hf_rc_last_status)" "403"
_assert "latido rechazado no intenta re-registrarse" "$(_calls register)" "0"
_assert_true "401 y 403 son rechazo de credenciales" _hf_rc_is_auth_rejection 401
_assert_true "403 también" _hf_rc_is_auth_rejection 403
if _hf_rc_is_auth_rejection 500 || _hf_rc_is_auth_rejection 200 || _hf_rc_is_auth_rejection ""; then
  echo "  FAIL: 500/200/vacío no son rechazo de credenciales"; FAIL=$((FAIL + 1))
else echo "  PASS: 500/200/vacío no son rechazo de credenciales"; PASS=$((PASS + 1)); fi

echo "== API key revocada: el daemon se detiene solo"
echo 401 > "$TMP_DIR/codes"
_start_daemon
_assert_true "termina por sí mismo en pocos segundos" _wait_exit 12
_assert "preguntó exactamente 3 veces y paró" "$(_calls poll)" "3"
_assert "deja el motivo" "$(cat "$SDIR/stopped" 2>/dev/null)" "auth_rejected:401"
_assert "quita su pid (la terminal ya no figura como conectada)" "$([ -f "$SDIR/daemon.pid" ] && echo si || echo no)" "no"
_assert_contains "lo explica en su log" "rechazó las credenciales de esta terminal (HTTP 401)" "$(cat "$SDIR/daemon.log")"
_assert_contains "registra la métrica" "rc_auth_stop" "$(cat "$TMP_DIR/metrics.log" 2>/dev/null)"
sleep 2
_assert "después de parar no hace ni una llamada más" "$(_calls poll)" "3"
DAEMON_PID=""

echo "== fuera de permisos o de la lista de IPs (403): también se detiene"
echo 403 > "$TMP_DIR/codes"
_start_daemon
_assert_true "termina por sí mismo" _wait_exit 12
_assert "motivo 403" "$(cat "$SDIR/stopped" 2>/dev/null)" "auth_rejected:403"
DAEMON_PID=""

echo "== HF_RC_AUTH_FAIL_MAX ajusta el umbral"
echo 401 > "$TMP_DIR/codes"
HF_RC_AUTH_FAIL_MAX=1 _start_daemon
_assert_true "con umbral 1 termina" _wait_exit 8
_assert "y pregunta una sola vez" "$(_calls poll)" "1"
DAEMON_PID=""

echo "== un rechazo aislado no lo detiene"
printf '401\n401\n200\n' > "$TMP_DIR/codes"
_start_daemon
sleep 6
_assert_true "sigue vivo tras 401, 401, 200…" _alive
_assert "sin motivo de parada" "$([ -f "$SDIR/stopped" ] && echo si || echo no)" "no"
_stop_daemon

echo "== respuestas normales: sigue vivo"
echo 200 > "$TMP_DIR/codes"
_start_daemon
sleep 4
_assert_true "sigue vivo" _alive
_assert_true "y sigue preguntando" [ "$(_calls poll)" -ge 3 ]
_stop_daemon

echo "== backend caído (500 / sin red): no se detiene, espera más"
echo 500 > "$TMP_DIR/codes"
_start_daemon
sleep 7
_assert_true "sigue vivo con 500" _alive
N500="$(_calls poll)"
_assert_true "pregunta menos que una vez por segundo (espera creciente): $N500 en 7 s" [ "$N500" -le 4 ]
_assert "sin motivo de parada" "$([ -f "$SDIR/stopped" ] && echo si || echo no)" "no"
_stop_daemon
echo 000 > "$TMP_DIR/codes"
_start_daemon
sleep 4
_assert_true "sigue vivo sin red" _alive
_stop_daemon

echo "== worker de tablero: un rechazo corta la pasada"
# shellcheck source=../lib/core/tools.sh disable=SC1091
source "$REPO_ROOT/lib/core/tools.sh"
# shellcheck source=../lib/core/tickets.sh disable=SC1091
source "$REPO_ROOT/lib/core/tickets.sh"
# shellcheck source=../lib/core/workers.sh disable=SC1091
source "$REPO_ROOT/lib/core/workers.sh"
API_LOG="$TMP_DIR/api.log"; : > "$API_LOG"
cat > "$TMP_DIR/api_stub.sh" <<EOF
#!/bin/bash
printf '%s %s\n' "\$1" "\$2" >> "$API_LOG"
printf '%s' '{"success":false,"messageKey":"middleware.invalidToken","message":"Token inválido","error":"API Key inválida"}'
EOF
chmod +x "$TMP_DIR/api_stub.sh"
OUT="$(HF_API_STUB="$TMP_DIR/api_stub.sh" _hf_worker_run_inner w1 2>&1)"; RC=$?
_assert "la pasada falla" "$RC" "1"
_assert_contains "dice por qué" "el backend rechazó la petición: API Key inválida" "$OUT"
_assert_contains "y qué hacer" "/login" "$OUT"
_assert "solo leyó el tablero: no mandó el latido ni nada más" "$(cat "$API_LOG")" "GET /app-instances/b1"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
