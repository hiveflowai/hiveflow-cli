#!/usr/bin/env bash
# ── Prompt-pack dinámico ──────────────────────────────────────
# La orquestación (prompts de triaje, loops, workers, revisor) NO viaja en
# el paquete npm: se sincroniza del backend (GET /api/cli/prompts, auth),
# se cachea 1h y se renderiza localmente. Sin red/auth, cada call site usa
# un fallback mínimo que conserva el CONTRATO de salida (JSON, RESULT:)
# para que el CLI siga funcionando, sin la ingeniería fina.
#
#   hf_prompts_sync [--force]      → cachea $HF_CONFIG_DIR/prompts.json
#   hf_prompt <key> VAR=valor ...  → imprime el prompt renderizado
#                                    (rc≠0 si no hay pack/clave: usa fallback)

hf_prompts_sync() {
  local f="$HF_CONFIG_DIR/prompts.json" api="${HIVEFLOW_API_URL:-https://api.hiveflow.ai}"
  if [ -f "$f" ] && [ -n "$(find "$f" -mmin -60 2>/dev/null)" ] && [ "${1:-}" != "--force" ]; then
    return 0
  fi
  local tok; tok="$(hf_auth_token 2>/dev/null)"
  [ -z "$tok" ] && return 1
  local tmp; tmp="$(mktemp)"
  if curl -s -m 10 "${api%/}/api/cli/prompts" -H "Authorization: Bearer $tok" -o "$tmp" 2>/dev/null \
     && jq -e '.prompts | type == "object"' "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$f"
    chmod 600 "$f"
  else
    rm -f "$tmp"; return 1
  fi
}

hf_prompt() {
  local key="$1"; shift
  local f="$HF_CONFIG_DIR/prompts.json"
  # sincronización perezosa en background para la PRÓXIMA vez
  ( hf_prompts_sync ) >/dev/null 2>&1 &
  [ -f "$f" ] || return 1
  local tpl
  tpl="$(jq -r --arg k "$key" '.prompts[$k] // empty' "$f" 2>/dev/null)"
  [ -z "$tpl" ] && return 1
  local a name val
  for a in "$@"; do
    name="${a%%=*}"; val="${a#*=}"
    tpl="${tpl//\{\{$name\}\}/$val}"
  done
  printf '%s' "$tpl"
}
