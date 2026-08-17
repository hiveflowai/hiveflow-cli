#!/usr/bin/env bash
# ── Router automático: tipo de tarea → mejor tool disponible ──
# Cadenas de routing por función `case` (no `declare -A`): compatible
# con el bash 3.2 de macOS.

# `native` = el agente propio (cuenta como candidato de pleno derecho).
# Gemini va al final de sus cadenas: cerró el acceso individual en jun-2026
# y para muchos usuarios el binario está instalado pero ya no autentica.
hf_routing_chain() {
  case "$1" in
    complex-refactor) echo "claude:native:aider:codex" ;;
    large-analysis)   echo "claude:native:gemini" ;;
    quick-fix)        echo "aider:codex:claude:native" ;;
    documentation)    echo "claude:native:gemini" ;;
    security-audit)   echo "claude:native" ;;
    test-generation)  echo "claude:aider:native" ;;
    research)         echo "claude:native:gemini" ;;
    new-feature)      echo "claude:aider:native" ;;
    *)                echo "claude:native:codex:aider:gemini" ;;
  esac
}

# Infiere el tipo de tarea del texto (keywords es/en)
hf_infer_task_type() {
  local t
  t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$t" in
    *securit*|*segurid*|*audit*|*vulnerab*)        echo "security-audit" ;;
    *test*|*prueba*|*spec*)                        echo "test-generation" ;;
    *document*|*readme*|*docs*)                    echo "documentation" ;;
    *refactor*|*reestructur*|*migra*)              echo "complex-refactor" ;;
    *investig*|*research*|*explora*)               echo "research" ;;
    *analiz*|*analy*|*revisa*|*review*)            echo "large-analysis" ;;
    *arregla*|*fix*|*bug*|*corrige*|*hotfix*)      echo "quick-fix" ;;
    *implementa*|*feature*|*crea*|*nueva*|*new*)   echo "new-feature" ;;
    *)                                             echo "default" ;;
  esac
}

# Devuelve el primer candidato disponible de la cadena de routing.
# `native` está disponible si hay API key configurada (hf_agent_available).
hf_route() {
  local task_type="${1:-default}"
  local routing
  routing="$(hf_routing_chain "$task_type")"
  local candidates
  IFS=':' read -ra candidates <<< "$routing"
  for c in "${candidates[@]}"; do
    if [ "$c" = "native" ]; then
      hf_agent_available && { echo "native"; return 0; }
    elif hf_tool_installed "$c"; then
      echo "$c"
      return 0
    fi
  done
  for t in "${HF_TOOLS[@]}"; do
    hf_tool_installed "$t" && { echo "$t"; return 0; }
  done
  hf_agent_available && { echo "native"; return 0; }
  return 1
}
