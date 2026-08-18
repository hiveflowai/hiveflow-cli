#!/usr/bin/env bash
# ── Swarm engine adapter (vendored from asis-coder) ───────────
# IMPORTANT: this file is sourced at SCRIPT LEVEL (not inside a
# function). The engine modules use `declare -A` which, if sourced
# inside a function, would create local variables that are lost on
# return (real bug caught in testing).
#
# For compatibility, the engine uses the SAME state as asis-coder
# (~/.config/coder-cli): your existing devices, projects and agents
# work without migration. Overridable with HIVEFLOW_ENGINE_DIR.

# Environment the engine modules expect
CONFIG_DIR="${HIVEFLOW_ENGINE_DIR:-$HOME/.config/coder-cli}"
CONFIG_FILE="$CONFIG_DIR/config"
DEBUG="${DEBUG:-false}"
mkdir -p "$CONFIG_DIR"

# The swarm engine modules use `declare -A` (bash 4+). macOS's bash 3.2
# does not support it: in that case they are NOT loaded (the rest of the
# CLI — router, external CLIs, native agent — works the same) and /swarm warns.
# NOTE: lib/engine/ is not included in the public npm package (proprietary).
HF_ENGINE_LOADED=1
if [ "${BASH_VERSINFO[0]:-3}" -lt 4 ]; then
  HF_ENGINE_LOADED=""
elif [ ! -d "$HIVEFLOW_ROOT/lib/engine" ]; then
  # Engine modules not present (public package) — silently skip
  HF_ENGINE_LOADED=""
else
  for _hf_mod in swarm_common swarm_role swarm_enroll swarm_daemon swarm_bootstrap \
                 swarm_wizard device_manager worktree_manager project_swarm \
                 swarm_manager agent_comm swarm_ralph prd_generator \
                 swarm_project_wizard swarm_dashboard cli_orchestrator swarm_router; do
    # shellcheck source=/dev/null
    if ! source "$HIVEFLOW_ROOT/lib/engine/$_hf_mod.sh" 2>/dev/null; then
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
    elif [ ! -d "$HIVEFLOW_ROOT/lib/engine" ]; then
      hf_err "$(hf_t "Swarm/Ralph features are not included in the public package. Available in Hiveflow Pro." "Las features Swarm/Ralph no están incluidas en el paquete público. Disponibles en Hiveflow Pro.")"
    else
      hf_err "$(hf_t "The swarm engine did not load correctly at startup." "El motor swarm no cargó correctamente al arrancar.")"
    fi
    return 1
  fi
  swarm_router "$@"
}
