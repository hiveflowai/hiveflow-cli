#!/usr/bin/env bash
# ── Chat directo por API (sin CLIs): /llm y /ask ──────────────
# Reimplementación limpia de la capa API de asis-coder: el usuario
# elige proveedor + guarda su key, y /ask hace la consulta directa.

hf_llm_provider() { hf_config_get '.llm.provider'; }

hf_llm_setup() {
  echo ""
  if [ "$HF_LANG" = "es" ]; then
    echo -e "  ${HF_C_BOLD}Proveedor LLM para /ask y el agente nativo${HF_C_RESET}"
    echo ""
    echo "  1) hiveflow — usa tu cuenta Hiveflow (créditos de tu plan, sin API key)"
    echo "  2) claude   (Anthropic, tu propia API key)"
    echo "  3) chatgpt  (OpenAI, tu propia API key)"
    echo "  4) gemini   (Google, tu propia API key)"
  else
    echo -e "  ${HF_C_BOLD}LLM provider for /ask and the native agent${HF_C_RESET}"
    echo ""
    echo "  1) hiveflow — use your Hiveflow account (plan credits, no API key)"
    echo "  2) claude   (Anthropic, your own API key)"
    echo "  3) chatgpt  (OpenAI, your own API key)"
    echo "  4) gemini   (Google, your own API key)"
  fi
  echo ""
  local choice provider
  read -r -p "  $(hf_t "Provider [1-4]: " "Proveedor [1-4]: ")" choice
  case "$choice" in
    1) provider="hiveflow" ;;
    2) provider="claude"  ;;
    3) provider="chatgpt" ;;
    4) provider="gemini"  ;;
    *) hf_err "$(hf_t "Invalid option." "Opción inválida.")"; return 1 ;;
  esac

  if [ "$provider" = "hiveflow" ]; then
    if ! hf_auth_ok; then
      hf_err "$(hf_t "You need to connect your account first: /login" "Necesitas conectar tu cuenta primero: /login")"
      return 1
    fi
    local model
    read -r -p "  $(hf_t "Model [claude-sonnet-4-5-20250929]: " "Modelo [claude-sonnet-4-5-20250929]: ")" model
    model="${model:-claude-sonnet-4-5-20250929}"
    hf_config_set '.llm.provider' "hiveflow"
    hf_config_del '.llm.key'
    hf_config_set '.llm.model' "$model"
    hf_ok "$(hf_t "LLM via Hiveflow account · $model (tokens are billed to your plan)" "LLM vía cuenta Hiveflow · $model (los tokens corren por tu plan)")"
    return 0
  fi

  local key
  read -r -s -p "  $(hf_t "$provider API key: " "API key de $provider: ")" key; echo ""
  [ -z "$key" ] && { hf_err "$(hf_t "Empty key." "Key vacía.")"; return 1; }

  # Modelo: default sensato por proveedor, editable
  local default_model
  case "$provider" in
    claude)  default_model="claude-sonnet-4-5-20250929" ;;
    chatgpt) default_model="gpt-4o" ;;
    gemini)  default_model="gemini-2.5-pro" ;;
  esac
  local model
  read -r -p "  $(hf_t "Model [$default_model]: " "Modelo [$default_model]: ")" model
  model="${model:-$default_model}"

  hf_config_set '.llm.provider' "$provider"
  hf_config_set '.llm.key' "$key"
  hf_config_set '.llm.model' "$model"
  hf_ok "$(hf_t "Chat API configured: $provider · $model" "Chat API configurado: $provider · $model")"
}

# hf_ask <pregunta> — consulta directa al proveedor configurado
hf_ask() {
  local q="$1"
  local provider key
  provider="$(hf_config_get '.llm.provider')"
  key="$(hf_config_get '.llm.key')"
  if [ -z "$provider" ] || { [ -z "$key" ] && [ "$provider" != "hiveflow" ]; }; then
    hf_warn "$(hf_t "Chat API not configured. Run /llm first." "Chat API sin configurar. Usa /llm primero.")"
    return 1
  fi

  local model
  model="$(hf_config_get '.llm.model')"
  local escaped unexpected
  escaped="$(printf '%s' "$q" | jq -Rs .)"
  unexpected="$(hf_t "unexpected response" "respuesta inesperada")"

  case "$provider" in
    hiveflow)
      # Proxy de Hiveflow (formato Anthropic): billing por tu plan
      key="$(hf_auth_token)"
      [ -z "$key" ] && { hf_err "$(hf_t "No Hiveflow session. Run /login first." "Sin sesión Hiveflow. Usa /login primero.")"; return 1; }
      curl -s -m 120 "$HIVEFLOW_API_URL/api/cli/llm/v1/messages" \
        -H "x-api-key: $key" \
        -H "content-type: application/json" \
        -d "{\"model\":\"${model:-claude-sonnet-4-5-20250929}\",\"max_tokens\":4096,\"messages\":[{\"role\":\"user\",\"content\":$escaped}]}" \
        | jq -r --arg u "$unexpected" '.content[0].text // ("ERROR: " + (.error.message // $u))'
      ;;
    claude)
      curl -s -m 120 https://api.anthropic.com/v1/messages \
        -H "x-api-key: $key" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "{\"model\":\"${model:-claude-sonnet-4-5-20250929}\",\"max_tokens\":4096,\"messages\":[{\"role\":\"user\",\"content\":$escaped}]}" \
        | jq -r --arg u "$unexpected" '.content[0].text // ("ERROR: " + (.error.message // $u))'
      ;;
    chatgpt)
      curl -s -m 120 https://api.openai.com/v1/chat/completions \
        -H "Authorization: Bearer $key" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${model:-gpt-4o}\",\"messages\":[{\"role\":\"user\",\"content\":$escaped}]}" \
        | jq -r --arg u "$unexpected" '.choices[0].message.content // ("ERROR: " + (.error.message // $u))'
      ;;
    gemini)
      curl -s -m 120 "https://generativelanguage.googleapis.com/v1beta/models/${model:-gemini-2.5-pro}:generateContent?key=$key" \
        -H "Content-Type: application/json" \
        -d "{\"contents\":[{\"parts\":[{\"text\":$escaped}]}]}" \
        | jq -r --arg u "$unexpected" '.candidates[0].content.parts[0].text // ("ERROR: " + (.error.message // $u))'
      ;;
    *)
      hf_err "$(hf_t "Unknown provider: $provider (run /llm)" "Proveedor desconocido: $provider (usa /llm)")"
      return 1
      ;;
  esac
}
