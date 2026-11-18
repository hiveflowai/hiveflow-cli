#!/usr/bin/env bash
# ── Updates: check pasivo + /update ───────────────────────────
# Canales según cómo se instaló:
#   git — clone con ./install.sh (symlinks al repo) → git pull
#   npm — npm install -g @hiveflow/cli
#
# Al abrir el CLI (REPL o `remote control`) se comprueba si hay versión nueva
# y, si la hay, se baja y el CLI se relanza ya actualizado (hf_auto_update).
# La comprobación tiene tope de tiempo: sin red, el CLI arranca igual.
# Apagarlo: HIVEFLOW_NO_AUTO_UPDATE=1 o `.update.auto = "false"` en la config;
# entonces queda el aviso de siempre ("Ejecuta /update").

HF_UPDATE_INTERVAL="${HIVEFLOW_UPDATE_INTERVAL:-86400}"
HF_AUTO_UPDATE_INTERVAL="${HIVEFLOW_AUTO_UPDATE_INTERVAL:-3600}"   # como mucho una comprobación por hora
HF_NPM_REGISTRY="https://registry.npmjs.org/@hiveflow%2fcli/latest"

# Corre un comando con tope de tiempo (macOS no trae `timeout`).
_hf_timeout() {
  local secs="$1" pid watchdog rc
  shift
  "$@" &
  pid=$!
  # El vigilante no hereda la salida: si no, un $(...) esperaría a su sleep.
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$watchdog" 2>/dev/null
  return $rc
}

# Pregunta al origen cuál es la última versión y la guarda en la config.
# Síncrono pero con tope: 0 si obtuvo respuesta.
hf_update_refresh() {
  if [ "$(hf_update_channel)" = "git" ]; then
    local sha
    sha="$(GIT_TERMINAL_PROMPT=0 _hf_timeout 8 git -C "$HIVEFLOW_ROOT" ls-remote --quiet origin HEAD 2>/dev/null | awk '{print $1}')"
    [ -n "$sha" ] || return 1
    hf_config_set '.update.remote_sha' "$sha"
  else
    local latest
    latest="$(curl -s -m 8 "$HF_NPM_REGISTRY" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)"
    [ -n "$latest" ] || return 1
    hf_config_set '.update.latest_version' "$latest"
  fi
}

# Un clon de git solo se actualiza solo si es una instalación "de usuario":
# parado en la rama por defecto del origen y sin cambios locales. Un checkout
# de desarrollo (otra rama, archivos tocados) no se toca nunca.
_hf_update_git_safe() {
  local def cur
  def="$(git -C "$HIVEFLOW_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  def="${def#origin/}"
  cur="$(git -C "$HIVEFLOW_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null)"
  [ -n "$def" ] && [ "$cur" = "$def" ] || return 1
  [ -z "$(git -C "$HIVEFLOW_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]
}

# Baja la versión nueva sin preguntar ni pintar el detalle. 0 si quedó instalada.
_hf_update_apply_quiet() {
  case "$(hf_update_channel)" in
    git)     GIT_TERMINAL_PROMPT=0 _hf_timeout 120 git -C "$HIVEFLOW_ROOT" pull --ff-only --quiet >/dev/null 2>&1 ;;
    npm)     _hf_timeout 180 npm install -g @hiveflow/cli@latest >/dev/null 2>&1 ;;
    tarball) _hf_timeout 180 bash -c 'curl -fsSL https://hiveflow.ai/install.sh | bash' >/dev/null 2>&1 ;;
  esac
}

# ¿Está encendida la actualización automática?
hf_auto_update_enabled() {
  [ "${HIVEFLOW_NO_AUTO_UPDATE:-0}" = "1" ] && return 1
  [ "$(hf_config_get '.update.auto')" = "false" ] && return 1
  if [ "$(hf_update_channel)" = "git" ]; then _hf_update_git_safe || return 1; fi
  return 0
}

# Al abrir: si hay versión nueva, bajarla y relanzar el CLI con los mismos
# argumentos. $1 = "force" salta el tope de una comprobación por hora (lo usa
# `remote control`, que es como arrancan los servicios). Si algo falla —sin
# red, pull rechazado— se sigue con la versión que hay, sin bloquear.
hf_auto_update() {
  local force="${1:-}"
  shift
  [ -n "${HF_AUTO_UPDATED:-}" ] && return 0          # ya nos relanzamos una vez
  [ -n "${HF_ENTRY:-}" ] || return 0
  hf_auto_update_enabled || return 0
  local now last
  now="$(date +%s)"
  last="$(hf_config_get '.update.auto_checked_at')"
  if [ "$force" != "force" ] && [ -n "$last" ] && [ $((now - last)) -lt "$HF_AUTO_UPDATE_INTERVAL" ]; then
    return 0
  fi
  hf_config_set '.update.auto_checked_at' "$now"
  hf_update_refresh || return 0
  local latest
  latest="$(hf_update_available)" || return 0
  hf_info "$(hf_t "New version available ($latest): updating…" "Hay una versión nueva ($latest): actualizando…")"
  if ! _hf_update_apply_quiet; then
    hf_warn "$(hf_t "Could not update automatically; continuing with the current version. Try /update" "No se pudo actualizar solo; sigo con la versión actual. Prueba /update")"
    return 0
  fi
  hf_ok "$(hf_t "Updated." "Actualizado.")"
  export HF_AUTO_UPDATED=1
  exec "$HF_ENTRY" "$@"
}

hf_update_channel() {
  # -e y no -d: en un worktree de git, .git es un archivo.
  if [ -e "$HIVEFLOW_ROOT/.git" ]; then
    echo "git"
  elif case "$HIVEFLOW_ROOT" in "$HOME/.hiveflow/cli"*) true ;; *) false ;; esac; then
    # Instalado con `curl hiveflow.ai/install.sh | bash` (sin git ni npm)
    echo "tarball"
  else
    echo "npm"
  fi
}

# Lanza el check en background si el último fue hace > HF_UPDATE_INTERVAL
hf_update_bg_check() {
  [ "${HIVEFLOW_NO_UPDATE_CHECK:-0}" = "1" ] && return 0
  local now last
  now="$(date +%s)"
  last="$(hf_config_get '.update.checked_at')"
  [ -n "$last" ] && [ $((now - last)) -lt "$HF_UPDATE_INTERVAL" ] && return 0
  hf_config_set '.update.checked_at' "$now"
  (
    if [ "$(hf_update_channel)" = "git" ]; then
      local sha
      sha="$(git -C "$HIVEFLOW_ROOT" ls-remote --quiet origin HEAD 2>/dev/null | awk '{print $1}')"
      [ -n "$sha" ] && hf_config_set '.update.remote_sha' "$sha"
    else
      local latest
      latest="$(curl -s -m 8 "$HF_NPM_REGISTRY" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)"
      [ -n "$latest" ] && hf_config_set '.update.latest_version' "$latest"
    fi
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# Imprime la versión nueva si la hay (exit 0) o nada (exit 1)
hf_update_available() {
  local cur="$HIVEFLOW_VERSION"
  if [ "$(hf_update_channel)" = "git" ]; then
    local remote local_sha
    remote="$(hf_config_get '.update.remote_sha')"
    local_sha="$(git -C "$HIVEFLOW_ROOT" rev-parse HEAD 2>/dev/null)"
    if [ -n "$remote" ] && [ -n "$local_sha" ] && [ "$remote" != "$local_sha" ]; then
      # Si el commit remoto ya está en el historial local, vamos por delante (dev): no hay update
      if git -C "$HIVEFLOW_ROOT" merge-base --is-ancestor "$remote" "$local_sha" 2>/dev/null; then
        return 1
      fi
      echo "${remote:0:7}"
      return 0
    fi
    return 1
  fi
  local latest
  latest="$(hf_config_get '.update.latest_version')"
  [ -z "$latest" ] || [ "$latest" = "$cur" ] && return 1
  if [ "$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -1)" = "$latest" ]; then
    echo "$latest"
    return 0
  fi
  return 1
}

# Aviso en la bienvenida (solo si el check cacheado encontró algo)
hf_update_notice() {
  local latest
  latest="$(hf_update_available)" || return 0
  if [ "$(hf_update_channel)" = "git" ]; then
    hf_info "$(hf_t "Update available (new commits on origin: $latest). Run /update" "Hay una actualización (commits nuevos en origin: $latest). Ejecuta /update")"
  else
    hf_info "$(hf_t "Update available: v$HIVEFLOW_VERSION → v$latest. Run /update" "Hay una actualización: v$HIVEFLOW_VERSION → v$latest. Ejecuta /update")"
  fi
}

hf_update_cmd() {
  local channel
  channel="$(hf_update_channel)"
  if [ "${1:-}" = "check" ]; then
    hf_info "$(hf_t "Checking..." "Comprobando...")"
    hf_update_refresh
    if hf_update_available >/dev/null; then
      hf_update_notice
    else
      hf_ok "$(hf_t "You are on the latest version (v$HIVEFLOW_VERSION, $channel)." "Estás en la última versión (v$HIVEFLOW_VERSION, $channel).")"
    fi
    return 0
  fi

  case "$channel" in
    git)
      hf_info "$(hf_t "Updating from git ($HIVEFLOW_ROOT)..." "Actualizando desde git ($HIVEFLOW_ROOT)...")"
      if git -C "$HIVEFLOW_ROOT" pull --ff-only; then
        hf_ok "$(hf_t "Updated. Restart hiveflow to load the new version." "Actualizado. Reinicia hiveflow para cargar la nueva versión.")"
      else
        hf_err "$(hf_t "git pull failed (local changes or diverged branch). Update manually in $HIVEFLOW_ROOT" "git pull falló (cambios locales o rama divergida). Actualiza a mano en $HIVEFLOW_ROOT")"
        return 1
      fi ;;
    npm)
      hf_info "$(hf_t "Updating via npm..." "Actualizando vía npm...")"
      if npm install -g @hiveflow/cli@latest; then
        hf_ok "$(hf_t "Updated. Restart hiveflow to load the new version." "Actualizado. Reinicia hiveflow para cargar la nueva versión.")"
      else
        hf_err "$(hf_t "npm install failed. Try: npm install -g @hiveflow/cli@latest" "npm install falló. Prueba: npm install -g @hiveflow/cli@latest")"
        return 1
      fi ;;
    tarball)
      hf_info "$(hf_t "Updating via the installer..." "Actualizando vía el instalador...")"
      if curl -fsSL https://hiveflow.ai/install.sh | bash; then
        hf_ok "$(hf_t "Updated. Restart hiveflow to load the new version." "Actualizado. Reinicia hiveflow para cargar la nueva versión.")"
      else
        hf_err "$(hf_t "Installer failed. Try: curl -fsSL https://hiveflow.ai/install.sh | bash" "El instalador falló. Prueba: curl -fsSL https://hiveflow.ai/install.sh | bash")"
        return 1
      fi ;;
  esac
}
