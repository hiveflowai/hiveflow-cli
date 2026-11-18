#!/bin/bash
#
# Actualización automática al abrir (lib/core/update.sh):
#   · con versión nueva en el origen, el CLI la baja y se relanza con los
#     mismos argumentos
#   · un checkout de desarrollo (otra rama, cambios locales) no se toca
#   · se puede apagar (env o config) y no se repite más de una vez por hora,
#     salvo "force"
#   · sin red o con el pull rechazado, el CLI sigue con la versión que hay
#   · no hay bucle: tras relanzarse no vuelve a comprobar
#   · un espejo de servicio se detiene cuando hay versión nueva (remote.sh)
# Con repos git de verdad en una carpeta temporal (sin red). Compatible con bash 3.2.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT" || exit 1

TMP_DIR="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
export HF_CONFIG_DIR="$TMP_DIR/cfg"
export HF_CONFIG_FILE="$HF_CONFIG_DIR/config.json"
mkdir -p "$HF_CONFIG_DIR"
export HF_LANG=es
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset HIVEFLOW_NO_AUTO_UPDATE HF_AUTO_UPDATED HF_RC_RESTART_ON_UPDATE HIVEFLOW_AUTO_UPDATE_INTERVAL

# ── stubs de la base del CLI ─────────────────────────────────────────
HIVEFLOW_VERSION="1.0.0"
hf_t() { if [ "$HF_LANG" = "es" ] && [ $# -ge 2 ] && [ -n "$2" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
hf_config_get() { jq -r "$1 // empty" "$HF_CONFIG_FILE" 2>/dev/null; }
hf_config_set() { local t; t="$(mktemp)"; jq --arg v "$2" "$1 = \$v" "$HF_CONFIG_FILE" > "$t" && mv "$t" "$HF_CONFIG_FILE"; }
hf_ok() { echo "  ✓ $*"; }
hf_err() { echo "  ✗ $*" >&2; }
hf_info() { echo "  › $*"; }
hf_warn() { echo "  ! $*"; }

# shellcheck source=../lib/core/update.sh disable=SC1091
source "$REPO_ROOT/lib/core/update.sh"

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

# ── un "origen" y una instalación clonada de él ──────────────────────
# El punto de entrada imprime su versión y sus argumentos: así se ve qué
# código corrió tras relanzarse.
ORIGIN="$TMP_DIR/origin.git"
SEED="$TMP_DIR/seed"
_entry() { printf '#!/bin/bash\necho "ENTRY v%s args=$* updated=${HF_AUTO_UPDATED:-}"\n' "$1"; }
git init -q --bare -b master "$ORIGIN"
git init -q -b master "$SEED"
_entry 1 > "$SEED/hiveflow.sh"; chmod +x "$SEED/hiveflow.sh"
git -C "$SEED" add -A && git -C "$SEED" commit -q -m v1
git -C "$SEED" remote add origin "$ORIGIN" && git -C "$SEED" push -q origin master

_publish() {   # deja una versión nueva en el origen
  _entry "$1" > "$SEED/hiveflow.sh"
  git -C "$SEED" commit -q -am "v$1" && git -C "$SEED" push -q origin master
}
_install() {   # instalación limpia, igual al origen de ESTE momento
  rm -rf "$TMP_DIR/install"
  git clone -q "$ORIGIN" "$TMP_DIR/install"
  HIVEFLOW_ROOT="$TMP_DIR/install"
  HF_ENTRY="$HIVEFLOW_ROOT/hiveflow.sh"
  echo '{}' > "$HF_CONFIG_FILE"
}
# Corre hf_auto_update como lo hace hiveflow.sh; "SIGUE" = no se relanzó.
_open() { ( hf_auto_update "$@"; echo "SIGUE" ) 2>&1; }
_local_version() { sed -n 's/.*ENTRY v\([0-9]*\).*/\1/p' "$HIVEFLOW_ROOT/hiveflow.sh"; }

echo "== ya está al día: arranca normal"
_install
OUT="$(_open "" uno dos)"
_assert "no se relanza" "$OUT" "SIGUE"

echo "== hay versión nueva: la baja y se relanza con los mismos argumentos"
_install; _publish 2
OUT="$(_open "" remote control)"
_assert_contains "avisa que actualiza" "actualizando" "$OUT"
_assert_contains "corre el código nuevo con sus argumentos" "ENTRY v2 args=remote control updated=1" "$OUT"
_assert_not_contains "el proceso viejo no sigue" "SIGUE" "$OUT"
_assert "la instalación quedó en la versión nueva" "$(_local_version)" "2"

echo "== tras relanzarse no vuelve a comprobar (sin bucle)"
_install; _publish 3
OUT="$(HF_AUTO_UPDATED=1; export HF_AUTO_UPDATED; _open force)"
_assert "no se relanza otra vez" "$OUT" "SIGUE"
_assert "ni toca la instalación" "$(_local_version)" "2"

echo "== se puede apagar"
OUT="$(HIVEFLOW_NO_AUTO_UPDATE=1 _open force)"
_assert "HIVEFLOW_NO_AUTO_UPDATE=1" "$OUT:$(_local_version)" "SIGUE:2"
hf_config_set '.update.auto' "false"
OUT="$(_open force)"
_assert ".update.auto = false en la config" "$OUT:$(_local_version)" "SIGUE:2"
echo '{}' > "$HF_CONFIG_FILE"

echo "== un checkout de desarrollo no se toca"
git -C "$HIVEFLOW_ROOT" checkout -q -b mi-rama
OUT="$(_open force)"
_assert "en otra rama" "$OUT:$(_local_version)" "SIGUE:2"
git -C "$HIVEFLOW_ROOT" checkout -q master
echo "# cambio local" >> "$HIVEFLOW_ROOT/hiveflow.sh"
OUT="$(_open force)"
_assert_contains "con cambios locales sigue sin actualizar" "SIGUE" "$OUT"
_assert_contains "y conserva el cambio local" "# cambio local" "$(cat "$HIVEFLOW_ROOT/hiveflow.sh")"
git -C "$HIVEFLOW_ROOT" checkout -q -- hiveflow.sh

echo "== como mucho una comprobación por hora, salvo force"
echo '{}' > "$HF_CONFIG_FILE"
hf_config_set '.update.auto_checked_at' "$(date +%s)"
OUT="$(_open "")"
_assert "recién comprobado: no pregunta al origen" "$OUT:$(_local_version)" "SIGUE:2"
OUT="$(_open force x)"
_assert_contains "force sí comprueba y actualiza" "ENTRY v3 args=x" "$OUT"

echo "== sin red: arranca igual, sin tardar"
_install; _publish 4
git -C "$HIVEFLOW_ROOT" remote set-url origin "$TMP_DIR/no-existe.git"
T0=$SECONDS
OUT="$(_open force)"
_assert "sigue con la versión que hay" "$OUT:$(_local_version)" "SIGUE:3"
_assert "sin colgarse" "$([ $((SECONDS - T0)) -le 10 ] && echo rapido || echo lento)" "rapido"

echo "== el pull falla (historias divergidas): avisa y sigue"
_install; _publish 5
( cd "$HIVEFLOW_ROOT" && echo "# local" >> hiveflow.sh && git commit -q -am "local" )
OUT="$(_open force)"
_assert_contains "avisa que no pudo" "No se pudo actualizar solo" "$OUT"
_assert_contains "y arranca con lo que hay" "SIGUE" "$OUT"

echo "== _hf_timeout corta un comando colgado"
T0=$SECONDS
_hf_timeout 1 sleep 30; RC=$?
_assert "no espera al comando" "$([ $((SECONDS - T0)) -le 5 ] && echo cortado || echo colgado)" "cortado"
_assert "devuelve error" "$([ "$RC" -ne 0 ] && echo error || echo ok)" "error"
_assert "y deja pasar la salida de uno que termina" "$(_hf_timeout 5 echo hola)" "hola"

echo "== espejo de servicio: se detiene cuando hay versión nueva"
HF_C_BOLD=''; HF_C_RESET=''
hf_auth_ok() { return 0; }
hf_auth_token() { echo tok; }
hf_metric() { :; }
hf_dim() { echo "  $*"; }
# shellcheck source=../lib/core/remote.sh disable=SC1091
source "$REPO_ROOT/lib/core/remote.sh"
_install; _publish 6
_HF_RC_UPDATE_LAST=0
_hf_rc_update_due; _assert "sin HF_RC_RESTART_ON_UPDATE nunca" "$?" "1"
export HF_RC_RESTART_ON_UPDATE=1 HF_RC_UPDATE_CHECK_SECS=0
_hf_rc_update_due; _assert "recién arrancado no comprueba (ya se actualizó al abrir)" "$?" "1"
_hf_rc_update_due; _assert "después sí: hay versión nueva" "$?" "0"
( cd "$HIVEFLOW_ROOT" && git pull -q --ff-only )
_hf_rc_update_due; _assert "ya al día: sigue encendido" "$?" "1"
export HF_RC_SID="sess-test"; mkdir -p "$HF_CONFIG_DIR/rc/sess-test"; echo $$ > "$HF_CONFIG_DIR/rc/sess-test/daemon.pid"
LOG="$(_hf_rc_update_stop)"
_assert "deja el motivo para el supervisor" "$(cat "$HF_CONFIG_DIR/rc/sess-test/stopped")" "update"
_assert "y suelta el pid" "$([ -f "$HF_CONFIG_DIR/rc/sess-test/daemon.pid" ] && echo sigue || echo suelto)" "suelto"
_assert_contains "lo deja escrito en el log" "versión nueva del CLI" "$LOG"

echo ""
echo "Resultado: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
