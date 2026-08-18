#!/usr/bin/env bash
# ── Updates: check pasivo + /update ───────────────────────────
# Canales según cómo se instaló:
#   git — clone con ./install.sh (symlinks al repo) → git pull
#   npm — npm install -g @hiveflow/cli
#
# El check corre en background como mucho una vez al día y cachea
# el resultado en config (.update.*); el aviso sale en el siguiente
# arranque. Nunca bloquea el arranque ni requiere red.

HF_UPDATE_INTERVAL="${HIVEFLOW_UPDATE_INTERVAL:-86400}"
HF_NPM_REGISTRY="https://registry.npmjs.org/@hiveflow%2fcli/latest"

hf_update_channel() {
  if [ -d "$HIVEFLOW_ROOT/.git" ]; then
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
    if [ "$channel" = "git" ]; then
      local sha
      sha="$(git -C "$HIVEFLOW_ROOT" ls-remote --quiet origin HEAD 2>/dev/null | awk '{print $1}')"
      [ -n "$sha" ] && hf_config_set '.update.remote_sha' "$sha"
    else
      local latest
      latest="$(curl -s -m 8 "$HF_NPM_REGISTRY" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)"
      [ -n "$latest" ] && hf_config_set '.update.latest_version' "$latest"
    fi
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
