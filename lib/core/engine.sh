#!/usr/bin/env bash
# ── Swarm engine loader ───────────────────────────────────────
# The proprietary engine modules (distributed swarm + ralph) do NOT ship in
# the public npm package. They are served by the Hiveflow backend to
# authenticated accounts (GET /api/cli/engine), cached under
# $HF_CONFIG_DIR/engine/ and sourced from there. Resolution order:
#   1. $HIVEFLOW_ROOT/lib/engine/   (internal/dev checkout)
#   2. $HF_CONFIG_DIR/engine/engine (synced cache from the backend)
#
# IMPORTANT: modules are sourced at SCRIPT LEVEL (not inside a function).
# They use `declare -A`, which inside a function would create local
# variables that vanish on return (real bug caught in testing).
#
# For compatibility, the engine uses the SAME state as asis-coder
# (~/.config/coder-cli): your existing devices, projects and agents
# work without migration. Overridable with HIVEFLOW_ENGINE_DIR.

# Environment the engine modules expect
CONFIG_DIR="${HIVEFLOW_ENGINE_DIR:-$HOME/.config/coder-cli}"
CONFIG_FILE="$CONFIG_DIR/config"
DEBUG="${DEBUG:-false}"
mkdir -p "$CONFIG_DIR"

HF_ENGINE_CACHE="$HF_CONFIG_DIR/engine"

# Download the engine pack from the backend into the local cache.
# Requires an authenticated account; quiet failure (rc≠0) otherwise.
hf_engine_sync() {
  local api="${HIVEFLOW_API_URL:-https://api.hiveflow.ai}"
  local tok; tok="$(hf_auth_token 2>/dev/null)"
  [ -z "$tok" ] && return 1
  command -v jq >/dev/null || return 1
  local tmp; tmp="$(mktemp)"
  if ! curl -s -m 20 "${api%/}/api/cli/engine" -H "Authorization: Bearer $tok" -o "$tmp" 2>/dev/null \
     || ! jq -e '.files | type == "object" and (length > 0)' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; return 1
  fi
  mkdir -p "$HF_ENGINE_CACHE/engine" "$HF_ENGINE_CACHE/assets"
  local rel
  while IFS= read -r rel; do
    case "$rel" in engine/*.sh|assets/*.sh) ;; *) continue ;; esac
    jq -r --arg k "$rel" '.files[$k]' "$tmp" | base64 -d > "$HF_ENGINE_CACHE/$rel" 2>/dev/null || {
      rm -f "$tmp"; return 1
    }
    chmod +x "$HF_ENGINE_CACHE/$rel"
  done < <(jq -r '.files | keys[]' "$tmp")
  jq -r '.version' "$tmp" > "$HF_ENGINE_CACHE/.version" 2>/dev/null
  chmod -R go-rwx "$HF_ENGINE_CACHE" 2>/dev/null
  rm -f "$tmp"
  return 0
}

# Resolve where the modules live (repo checkout wins over cache)
HF_ENGINE_SRC=""
if [ -d "$HIVEFLOW_ROOT/lib/engine" ]; then
  HF_ENGINE_SRC="$HIVEFLOW_ROOT/lib/engine"
  HF_RALPH_SRC="$HIVEFLOW_ROOT/assets/ralph.sh"
elif [ -f "$HF_ENGINE_CACHE/engine/swarm_router.sh" ]; then
  HF_ENGINE_SRC="$HF_ENGINE_CACHE/engine"
  HF_RALPH_SRC="$HF_ENGINE_CACHE/assets/ralph.sh"
fi
export HF_RALPH_SRC

# The engine modules use `declare -A` (bash 4+). macOS's bash 3.2
# does not support it: in that case they are NOT loaded (the rest of the
# CLI — router, external CLIs, native agent — works the same) and /swarm warns.
HF_ENGINE_LOADED=1
if [ "${BASH_VERSINFO[0]:-3}" -lt 4 ] || [ -z "$HF_ENGINE_SRC" ]; then
  HF_ENGINE_LOADED=""
else
  for _hf_mod in swarm_common swarm_role swarm_enroll swarm_daemon swarm_bootstrap \
                 swarm_wizard device_manager worktree_manager project_swarm \
                 swarm_manager agent_comm swarm_ralph prd_generator \
                 swarm_project_wizard swarm_dashboard cli_orchestrator swarm_router; do
    # shellcheck source=/dev/null
    if ! source "$HF_ENGINE_SRC/$_hf_mod.sh" 2>/dev/null; then
      HF_ENGINE_LOADED=""
      break
    fi
  done
  unset _hf_mod
fi

# Bridge: /swarm, /ralph, /prd, /agents, /dashboard delegate here
hf_engine_dispatch() {
  if [ -z "$HF_ENGINE_LOADED" ]; then
    if [ "${BASH_VERSINFO[0]:-3}" -lt 4 ]; then
      hf_err "$(hf_t "The swarm engine needs bash 4+ (you have ${BASH_VERSION:-3.x}). On macOS: brew install bash" "El motor swarm necesita bash 4+ (tienes ${BASH_VERSION:-3.x}). En macOS: brew install bash")"
    elif [ -z "$HF_ENGINE_SRC" ]; then
      # First use: try to fetch the engine pack from the backend
      hf_info "$(hf_t "Swarm/Ralph modules are not bundled — downloading from your Hiveflow account..." "Los módulos Swarm/Ralph no vienen en el paquete — descargándolos de tu cuenta Hiveflow...")"
      if hf_engine_sync; then
        hf_ok "$(hf_t "Engine downloaded. Restart hiveflow to enable /swarm, /ralph, /prd and /dashboard." "Motor descargado. Reinicia hiveflow para habilitar /swarm, /ralph, /prd y /dashboard.")"
      else
        hf_err "$(hf_t "Could not download the engine (are you logged in? /login). Swarm/Ralph require a Hiveflow account." "No se pudo descargar el motor (¿sesión iniciada? /login). Swarm/Ralph requieren cuenta de Hiveflow.")"
      fi
    else
      hf_err "$(hf_t "The swarm engine did not load correctly at startup." "El motor swarm no cargó correctamente al arrancar.")"
    fi
    return 1
  fi
  swarm_router "$@"
}
