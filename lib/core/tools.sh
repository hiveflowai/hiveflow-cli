#!/usr/bin/env bash
# ── Registry de AI coding CLIs ────────────────────────────────
# Templates headless validados contra las versiones actuales:
#   claude  → claude -p '...'            (Claude Code)
#   codex   → codex exec '...'           (OpenAI; --full-auto ya no existe)
#   gemini  → gemini -y -p '...'         (Google)
#   aider   → aider --message '...'
# El prompt SIEMPRE va entre comillas simples; hf_tool_cmd escapa
# para ese contexto (' → '\''). No cambiar a comillas dobles.
#
# Lookups por función `case` (no `declare -A`): el bash 3.2 de macOS
# no soporta arrays asociativos y este archivo debe cargar ahí.

# Fallback i18n: este archivo se sourcea standalone en tests, sin i18n.sh
type hf_t >/dev/null 2>&1 || hf_t() { if [ "${HF_LANG:-en}" = "es" ] && [ -n "${2:-}" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

HF_TOOLS=(claude gemini codex aider)

hf_tool_bin() {
  case "$1" in
    claude) echo "claude" ;;
    gemini) echo "gemini" ;;
    codex)  echo "codex" ;;
    aider)  echo "aider" ;;
    *)      return 1 ;;
  esac
}

hf_tool_desc() {
  case "$1" in
    claude) echo "$(hf_t "Claude Code (Anthropic) — complex refactors, multi-file, security, tests" "Claude Code (Anthropic) — refactors complejos, multi-archivo, seguridad, tests")" ;;
    gemini) echo "$(hf_t "Gemini CLI (Google) — research, 1M context, documentation, analysis" "Gemini CLI (Google) — research, contexto 1M, documentación, análisis")" ;;
    codex)  echo "$(hf_t "Codex CLI (OpenAI) — quick fixes, sandboxed, tests" "Codex CLI (OpenAI) — fixes rápidos, sandboxed, tests")" ;;
    aider)  echo "$(hf_t "Aider — quick fixes, multi-model, git-aware" "Aider — fixes rápidos, multi-modelo, git-aware")" ;;
  esac
}

hf_tool_install_cmd() {
  case "$1" in
    claude) echo "curl -fsSL https://claude.ai/install.sh | sh" ;;
    gemini) echo "npm install -g @google/gemini-cli" ;;
    codex)  echo "npm install -g @openai/codex" ;;
    aider)  echo "python3 -m pip install --user aider-install && aider-install" ;;
  esac
}

# Template de lanzamiento headless por tool
hf_tool_template() {
  case "$1" in
    claude) echo "claude -p '{PROMPT}' {OPTIONS}" ;;
    gemini) echo "gemini {OPTIONS} -p '{PROMPT}'" ;;
    codex)  echo "codex exec {OPTIONS} '{PROMPT}'" ;;
    aider)  echo "aider --yes-always --message '{PROMPT}' {OPTIONS}" ;;
  esac
}

# Flags de autonomía (modo auto) / supervisados (modo safe) por tool
hf_tool_flags() {
  local tool="$1" mode="$2"
  if [ "$mode" = "safe" ]; then
    case "$tool" in
      codex) echo "-s read-only --skip-git-repo-check" ;;
      *)     echo "" ;;
    esac
  else
    case "$tool" in
      claude) echo "--dangerously-skip-permissions" ;;
      gemini) echo "-y" ;;
      codex)  echo "-s workspace-write --skip-git-repo-check" ;;
      *)      echo "" ;;
    esac
  fi
}

hf_tool_installed() {
  local bin
  bin="$(hf_tool_bin "$1")" || return 1
  command -v "$bin" >/dev/null 2>&1
}

hf_tools_list() {
  echo ""
  printf "  %-8s %-11s %s\n" "TOOL" "$(hf_t "STATUS" "ESTADO")" "$(hf_t "DESCRIPTION" "DESCRIPCIÓN")"
  printf "  %-8s %-11s %s\n" "────" "──────" "───────────"
  for t in "${HF_TOOLS[@]}"; do
    if hf_tool_installed "$t"; then
      printf "  %-8s ${HF_C_GREEN}%-11s${HF_C_RESET} %s\n" "$t" "$(hf_t "installed" "instalado")" "$(hf_tool_desc "$t")"
    else
      printf "  %-8s ${HF_C_RED}%-11s${HF_C_RESET} %s\n" "$t" "$(hf_t "missing" "falta")" "$(hf_tool_desc "$t")"
    fi
  done
  echo ""
  hf_dim "$(hf_t "install with: /install <tool>   ·   /install all" "instala con: /install <tool>   ·   /install all")"
}

hf_tool_install() {
  local target="$1"
  local list=()
  if [ "$target" = "all" ]; then
    list=("${HF_TOOLS[@]}")
  elif hf_tool_bin "$target" >/dev/null 2>&1; then
    list=("$target")
  else
    hf_err "$(hf_t "Unknown tool: '$target'. Options: ${HF_TOOLS[*]} | all" "Tool desconocido: '$target'. Opciones: ${HF_TOOLS[*]} | all")"
    return 1
  fi
  for t in "${list[@]}"; do
    if hf_tool_installed "$t"; then
      hf_ok "$(hf_t "$t is already installed." "$t ya está instalado.")"
      continue
    fi
    hf_info "$(hf_t "Installing $t ..." "Instalando $t ...")"
    if bash -c "$(hf_tool_install_cmd "$t")"; then
      hf_ok "$(hf_t "$t installed." "$t instalado.")"
    else
      hf_err "$(hf_t "Failed to install $t. Command: $(hf_tool_install_cmd "$t")" "Falló la instalación de $t. Comando: $(hf_tool_install_cmd "$t")")"
    fi
  done
}

hf_tools_health() {
  for t in "${HF_TOOLS[@]}"; do
    if ! hf_tool_installed "$t"; then
      echo -e "  [$t] ${HF_C_RED}$(hf_t "not installed" "no instalado")${HF_C_RESET}"
      continue
    fi
    local v
    v="$("$(hf_tool_bin "$t")" --version 2>/dev/null | head -1)"
    if [ -n "$v" ]; then
      echo -e "  [$t] ${HF_C_GREEN}OK${HF_C_RESET} ($v)"
    else
      echo -e "  [$t] ${HF_C_YELLOW}$(hf_t "installed but not responding to --version" "instalado pero no responde a --version")${HF_C_RESET}"
    fi
  done
}

# hf_tool_cmd <tool> <prompt> [modo: auto|safe]
# Construye el comando final con el prompt escapado para comillas simples.
hf_tool_cmd() {
  local tool="$1" prompt="$2" mode="${3:-auto}"
  local template
  template="$(hf_tool_template "$tool")"
  [ -z "$template" ] && { hf_err "$(hf_t "No template for '$tool'" "Sin template para '$tool'")"; return 1; }

  local flags
  flags="$(hf_tool_flags "$tool" "$mode")"

  local escaped
  escaped=$(printf '%s' "$prompt" | sed "s/'/'\\\\''/g")

  local cmd="$template"
  cmd="${cmd//\{PROMPT\}/$escaped}"
  cmd="${cmd//\{OPTIONS\}/$flags}"
  echo "$cmd"
}
