#!/usr/bin/env bash
# ── Native agent (agentic engine vendored from asis-coder) ────
# IMPORTANT: like engine.sh, this file is sourced at SCRIPT LEVEL:
# the modules use double-source guards and global state that would
# be lost inside a function.
#
# The engine shares CONFIG_DIR with the swarm (~/.config/coder-cli):
# permissions.json, hooks.json, mcp.json, skills/ and sessions/ live there.
#
# Engine entry points (lib/agent/tool_calling.sh):
#   consultar_llm_agentic <prompt>   one-shot with tools
#   modo_agentico_interactivo        multi-turn with sessions
# Tools: read_file, write_file, edit_file, bash_exec, web_fetch,
#        grep_search, glob_files, subagent (+ connected MCP tools).

HF_AGENT_DIR="$HIVEFLOW_ROOT/lib/agent"
HF_AGENT_LOADED=1
for _hf_amod in permissions hooks sessions skills mcp_client llm_dynamic_models tool_calling; do
  # shellcheck source=/dev/null
  if ! source "$HF_AGENT_DIR/$_hf_amod.sh"; then
    echo "$(hf_t "hiveflow: could not load agentic module: $_hf_amod" "hiveflow: no se pudo cargar el módulo agentic: $_hf_amod")" >&2
    HF_AGENT_LOADED=""
  fi
done
unset _hf_amod

# The `subagent` tool spawns children `$CODER_SUBAGENT_BIN -agent <prompt>`.
# Point it at hiveflow: subagents use this same engine.
export CODER_SUBAGENT_BIN="${CODER_SUBAGENT_BIN:-$HIVEFLOW_ROOT/hiveflow.sh}"

# Hiveflow policy on top of the engine (the engine stays neutral):
# more loop iterations than asis-coder's conservative default.
export TOOL_LOOP_MAX_ITERATIONS="${TOOL_LOOP_MAX_ITERATIONS:-40}"

# 4096 truncates write_file of large files mid-response (tool_use without
# content → broken history). 16K is the sane maximum without streaming.
export CODER_CLAUDE_MAX_TOKENS="${CODER_CLAUDE_MAX_TOKENS:-16384}"

# Builds CODER_SYSTEM_PROMPT with the project context in cwd:
# AGENTS.md/CLAUDE.md (first one that exists) + shallow structure.
# Opt-out: HIVEFLOW_NO_PROJECT_CONTEXT=1. If the caller already provides
# CODER_SYSTEM_PROMPT, it is respected.
# ── Dynamic Hiveflow API reference ────────────────────────────
# The backend serves /llms.txt GENERATED LIVE from its spec: every deploy
# updates the reference with no manual steps. The CLI caches it for 1h and
# points the agent at it — so the agent always knows how to drive the current API.
hf_docs_sync() {
  local f="$HF_CONFIG_DIR/api-reference.md" api="${HIVEFLOW_API_URL:-https://api.hiveflow.ai}"
  # fresh if less than 60 min old
  if [ -f "$f" ] && [ -n "$(find "$f" -mmin -60 2>/dev/null)" ] && [ "${1:-}" != "--force" ]; then
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  if curl -s -m 10 "${api%/}/llms.txt" -o "$tmp" 2>/dev/null && grep -q "Hiveflow API" "$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"; return 1
  fi
}

hf_agent_project_context() {
  [ "${HIVEFLOW_NO_PROJECT_CONTEXT:-}" = "1" ] && return 0
  [ -n "${CODER_SYSTEM_PROMPT:-}" ] && return 0

  local ctx memfile=""
  ctx="You are the Hiveflow CLI native agent working in: $PWD"

  # Hiveflow API reference (cached; refreshes itself every hour)
  ( hf_docs_sync ) >/dev/null 2>&1 &
  if [ -f "$HF_CONFIG_DIR/api-reference.md" ]; then
    ctx="$ctx

## Hiveflow API
ALWAYS UP-TO-DATE reference of the platform API (endpoints, auth,
multi-tenant scoping, workers, remote control, kanban/tools) at:
$HF_CONFIG_DIR/api-reference.md
Read it with read_file whenever the task involves driving Hiveflow via its API.
To call it from bash_exec: curl -H \"Authorization: Bearer \$HIVEFLOW_API_TOKEN\" \$HIVEFLOW_API_BASE/api/<path> (both variables are already in your environment)."
  fi

  for f in AGENTS.md CLAUDE.md .agents.md; do
    if [ -f "$f" ]; then memfile="$f"; break; fi
  done
  if [ -n "$memfile" ]; then
    # 16KB cap: the memory file must not eat the context.
    ctx="$ctx

## Project instructions ($memfile)
$(head -c 16384 "$memfile")"
  fi

  local listing
  listing=$(find . -maxdepth 2 \( -name .git -o -name node_modules -o -name .venv \) -prune -o -type f -print 2>/dev/null | head -80)
  if [ -n "$listing" ]; then
    ctx="$ctx

## Structure (partial, max 80 files, depth 2)
$listing"
  fi

  export CODER_SYSTEM_PROMPT="$ctx"
}

# Maps hiveflow config (.llm.*) or the HIVEFLOW_LLM_* env vars to the
# environment the engine expects: llm_choice + API key + model per provider.
# Env wins over config (embeddable: scripts/CI without config.json).
# With no model configured, hiveflow sets serious defaults (the vendored
# engine keeps its legacy ones so its tests don't break).
hf_agent_env() {
  # PLATFORM credential for the agent's bash: with the live reference
  # (/llms.txt) + these vars, the agent can drive the Hiveflow API
  # (curl -H "Authorization: Bearer $HIVEFLOW_API_TOKEN" $HIVEFLOW_API_BASE/api/…).
  # They are scrubbed for external CLIs along with the rest (HF_AGENT_ENV_EXPORTED).
  local _tok; _tok="$(hf_auth_token 2>/dev/null)"
  if [ -n "$_tok" ]; then
    export HIVEFLOW_API_TOKEN="$_tok"
    export HIVEFLOW_API_BASE="${HIVEFLOW_API_URL:-https://api.hiveflow.ai}"
  fi

  local provider key model
  provider="${HIVEFLOW_LLM_PROVIDER:-$(hf_config_get '.llm.provider')}"
  key="${HIVEFLOW_LLM_KEY:-$(hf_config_get '.llm.key')}"
  model="${HIVEFLOW_LLM_MODEL:-$(hf_config_get '.llm.model')}"

  # "hiveflow" provider: the backend proxy speaks the Anthropic format, so
  # we reuse the claude adapter pointing it at the proxy with the account
  # credential (hf_...). Billing goes to the user's Hiveflow plan.
  if [ "$provider" = "hiveflow" ]; then
    key="${HIVEFLOW_LLM_KEY:-$(hf_auth_token)}"
    if [ -z "$key" ]; then
      hf_err "$(hf_t "The hiveflow provider needs your account connected. Run /login first." "El proveedor hiveflow necesita tu cuenta conectada. Usa /login primero.")"
      return 1
    fi
    llm_choice="claude"
    export ANTHROPIC_API_KEY="$key"
    export ANTHROPIC_MESSAGES_URL="${HIVEFLOW_API_URL%/}/api/cli/llm/v1/messages"
    HF_AGENT_ENV_EXPORTED="ANTHROPIC_API_KEY ANTHROPIC_MESSAGES_URL HIVEFLOW_API_TOKEN"
    export CODER_CLAUDE_MODEL="${model:-${CODER_CLAUDE_MODEL:-claude-sonnet-4-5-20250929}}"
    hf_agent_project_context
    return 0
  fi

  if [ -z "$provider" ] || [ -z "$key" ]; then
    hf_err "$(hf_t "The native agent needs a provider + API key. Run /llm (or export HIVEFLOW_LLM_PROVIDER and HIVEFLOW_LLM_KEY)." "El agente nativo necesita proveedor + API key. Usa /llm (o exporta HIVEFLOW_LLM_PROVIDER y HIVEFLOW_LLM_KEY).")"
    return 1
  fi

  llm_choice="$provider"
  case "$provider" in
    claude)
      export ANTHROPIC_API_KEY="$key"
      HF_AGENT_ENV_EXPORTED="ANTHROPIC_API_KEY HIVEFLOW_API_TOKEN"
      export CODER_CLAUDE_MODEL="${model:-${CODER_CLAUDE_MODEL:-claude-sonnet-4-5-20250929}}"
      ;;
    chatgpt)
      export OPENAI_API_KEY="$key"
      HF_AGENT_ENV_EXPORTED="OPENAI_API_KEY HIVEFLOW_API_TOKEN"
      export CODER_OPENAI_MODEL="${model:-${CODER_OPENAI_MODEL:-gpt-4o}}"
      ;;
    gemini)
      export GEMINI_API_KEY="$key"
      HF_AGENT_ENV_EXPORTED="GEMINI_API_KEY"
      export CODER_GEMINI_MODEL="${model:-${CODER_GEMINI_MODEL:-gemini-2.5-pro}}"
      ;;
    *)
      hf_err "$(hf_t "Provider not supported by the agent: $provider (claude|chatgpt|gemini)" "Proveedor no soportado por el agente: $provider (claude|chatgpt|gemini)")"
      return 1
      ;;
  esac

  hf_agent_project_context
  return 0
}

# Mirrors the hiveflow mode into the engine's permission gating:
#   auto → CODER_YES=1 (mutating tools auto-approved)
#   safe → interactive confirmation / permissions.json allowlist
hf_agent_apply_mode() {
  # An explicit --yes (or CODER_YES=1 from the caller/subagent) always wins.
  [ "${CODER_YES:-}" = "1" ] && return 0
  local mode
  mode="$(hf_active_mode 2>/dev/null)"
  if [ "${mode:-auto}" = "auto" ]; then
    export CODER_YES=1
  else
    export CODER_YES=0
  fi
}

# ── ORCHESTRATOR conversation (unified REPL) ──────────────────
# The main prompt keeps ONE live conversation (HF_REPL_SESSION):
# native agent turns continue it with history+compaction, and exchanges
# routed to external CLIs are recorded in it too.

HF_REPL_SESSION=""

# Guarantees an active session for the REPL (lazy). $1 = optional label.
hf_repl_session_ensure() {
  [ -n "$HF_REPL_SESSION" ] && return 0
  declare -f sessions_new >/dev/null 2>&1 || return 1
  local provider
  provider="${HIVEFLOW_LLM_PROVIDER:-$(hf_config_get '.llm.provider')}"
  HF_REPL_SESSION=$(sessions_new "${provider:-}" "" "${1:-}" 2>/dev/null) || HF_REPL_SESSION=""
  [ -n "$HF_REPL_SESSION" ]
}

# hf_agent_turn <session_id> <prompt> — ONE native agent turn inside the
# conversation: loads history, appends the prompt, runs the loop (with
# compaction and repair included) and persists.
hf_agent_turn() {
  local sid="$1" prompt="$2" provider messages rc
  [ -z "$HF_AGENT_LOADED" ] && { hf_err "$(hf_t "The agentic engine did not load correctly at startup." "El motor agentic no cargó correctamente al arrancar.")"; return 1; }
  hf_agent_env || return 1
  hf_agent_apply_mode
  provider="${llm_choice:-claude}"
  if [ "${#REGISTERED_TOOLS[@]}" -eq 0 ] 2>/dev/null; then
    _register_agentic_tools "hf_agent_turn" || return 1
  fi

  messages=$(sessions_load "$sid" 2>/dev/null)
  { [ -z "$messages" ] || ! printf '%s' "$messages" | jq empty >/dev/null 2>&1; } && messages='[]'

  case "$provider" in
    gemini)
      messages=$(jq -nc --argjson m "$messages" --arg p "$prompt" \
        '$m + [{role: "user", parts: [{text: $p}]}]') ;;
    *)
      messages=$(jq -nc --argjson m "$messages" --arg p "$prompt" \
        '$m + [{role: "user", content: $p}]') ;;
  esac

  CODER_AGENT_INTERACTIVE=1
  case "$provider" in
    claude)  agentic_loop_anthropic_continue "$messages" ;;
    chatgpt) agentic_loop_openai_continue    "$messages" ;;
    gemini)  agentic_loop_gemini_continue    "$messages" ;;
    *)       hf_err "$(hf_t "Provider not supported: $provider" "Proveedor no soportado: $provider")"; return 1 ;;
  esac
  rc=$?
  CODER_AGENT_INTERACTIVE=0

  messages="${CODER_AGENTIC_MESSAGES:-$messages}"
  if declare -f sessions_save >/dev/null 2>&1; then
    sessions_save "$sid" "$messages" "$provider" "${CODER_CLAUDE_MODEL:-}" >/dev/null 2>&1 || true
  fi
  return $rc
}

# Records in the conversation an exchange executed by an EXTERNAL CLI
# (the orchestrator thread logs EVERYTHING, no matter who did it).
hf_session_append_exchange() {
  local sid="$1" user="$2" output="$3" tool="$4" messages
  declare -f sessions_load >/dev/null 2>&1 || return 0
  messages=$(sessions_load "$sid" 2>/dev/null)
  { [ -z "$messages" ] || ! printf '%s' "$messages" | jq empty >/dev/null 2>&1; } && messages='[]'
  messages=$(jq -nc --argjson m "$messages" --arg u "$user" --arg a "$output" --arg t "$tool" \
    '$m + [{role: "user", content: $u}, {role: "assistant", content: ("[via " + $t + "]\n" + $a)}]')
  sessions_save "$sid" "$messages" >/dev/null 2>&1 || true
}

# hf_agent_run <prompt> — one-shot agentic (REPL, -p, subagents, scripts)
hf_agent_run() {
  local prompt="$1"
  if [ -z "$HF_AGENT_LOADED" ]; then
    hf_err "$(hf_t "The agentic engine did not load correctly at startup." "El motor agentic no cargó correctamente al arrancar.")"
    return 1
  fi
  [ -z "$prompt" ] && { hf_err "$(hf_t "hf_agent_run: prompt missing." "hf_agent_run: falta el prompt.")"; return 2; }
  hf_agent_env || return 1
  hf_agent_apply_mode
  consultar_llm_agentic "$prompt"
}

# hf_agent_plan <prompt> — plan mode: explore and propose WITHOUT executing.
# Same loop with read-only tools. Resets the registry in case an earlier
# run in this session registered the full set.
hf_agent_plan() {
  local prompt="$1"
  if [ -z "$HF_AGENT_LOADED" ]; then
    hf_err "$(hf_t "The agentic engine did not load correctly at startup." "El motor agentic no cargó correctamente al arrancar.")"
    return 1
  fi
  [ -z "$prompt" ] && { hf_err "$(hf_t "Usage: /plan <what you want to plan>" "Uso: /plan <qué quieres planear>")"; return 2; }
  hf_agent_env || return 1
  REGISTERED_TOOLS=()
  CODER_AGENT_TOOLS="read_file grep_search glob_files web_fetch" \
    consultar_llm_agentic "Plan mode (read-only): explore what you need and produce a step-by-step implementation plan. You may NOT edit or execute anything. Task: $prompt"
  local rc=$?
  REGISTERED_TOOLS=()
  return $rc
}

# hf_agent_cost — tokens accumulated in this REPL session
hf_agent_cost() {
  local tin="${CODER_TOKENS_IN:-0}" tout="${CODER_TOKENS_OUT:-0}"
  echo ""
  if [ "$HF_LANG" = "es" ]; then
    echo -e "  ${HF_C_BOLD}Uso del agente nativo en esta sesión${HF_C_RESET}"
    echo "  Tokens de entrada:  $tin"
    echo "  Tokens de salida:   $tout"
    echo "  Total:              $((tin + tout))"
    hf_dim "El coste depende del modelo/proveedor; consulta su pricing."
  else
    echo -e "  ${HF_C_BOLD}Native agent usage in this session${HF_C_RESET}"
    echo "  Input tokens:   $tin"
    echo "  Output tokens:  $tout"
    echo "  Total:          $((tin + tout))"
    hf_dim "Cost depends on the model/provider; check its pricing."
  fi
  echo ""
}

# hf_agent_repl [session_id] — interactive multi-turn (resumable)
hf_agent_repl() {
  if [ -z "$HF_AGENT_LOADED" ]; then
    hf_err "$(hf_t "The agentic engine did not load correctly at startup." "El motor agentic no cargó correctamente al arrancar.")"
    return 1
  fi
  hf_agent_env || return 1
  hf_agent_apply_mode
  [ -n "${1:-}" ] && export CODER_RESUME_SESSION_ID="$1"
  modo_agentico_interactivo
  local rc=$?
  unset CODER_RESUME_SESSION_ID
  return $rc
}

# Is a provider configured for the native agent?
# hiveflow: the account session is enough. Others: need their API key.
hf_agent_available() {
  [ -n "$HF_AGENT_LOADED" ] || return 1
  local provider key
  provider="${HIVEFLOW_LLM_PROVIDER:-$(hf_config_get '.llm.provider')}"
  [ -z "$provider" ] && return 1
  if [ "$provider" = "hiveflow" ]; then
    key="${HIVEFLOW_LLM_KEY:-$(hf_auth_token)}"
  else
    key="${HIVEFLOW_LLM_KEY:-$(hf_config_get '.llm.key')}"
  fi
  [ -n "$key" ]
}
