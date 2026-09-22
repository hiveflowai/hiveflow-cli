#!/usr/bin/env bash
# ── /agents — el equipo de agentes desde la terminal ─────────────────────────
#   /agents                 lista tus agentes (estado y computadora)
#   /agents <nombre|id>     entra a la conversación del agente: historial con
#                           los adjuntos como URLs numeradas, escribir y ver
#                           la respuesta; dentro: /open N abre el adjunto N,
#                           /refresh relee, /back sale.
# Bash 3.2 (macOS). Solo curl + jq contra ${HIVEFLOW_API_URL}/api.

hf_agents_api() { printf '%s/api' "${HIVEFLOW_API_URL%/}"; }

_hf_agents_get() {
  curl -s -m 20 "$(hf_agents_api)/$1" -H "Authorization: Bearer $(hf_auth_token)" 2>/dev/null
}

_hf_agents_post() {
  curl -s -m 30 -X POST "$(hf_agents_api)/$1" -H "Authorization: Bearer $(hf_auth_token)" \
    -H 'Content-Type: application/json' --data "$2" 2>/dev/null
}

# Lista: nombre · estado · computadora · id corto
hf_agents_list() {
  local resp
  resp="$(_hf_agents_get agents)"
  [ -z "$resp" ] && { hf_err "$(hf_t "Could not reach $(hf_agents_api)" "No se pudo contactar $(hf_agents_api)")"; return 1; }
  echo ""
  printf '%s' "$resp" | jq -r --arg none "$(hf_t "not connected" "sin conectar")" \
    --arg on "$(hf_t "connected" "conectada")" --arg off "$(hf_t "disconnected" "desconectada")" '
    (.data // []) | .[] |
    [ (.name // "?"),
      (.presence.state // "idle"),
      (if (.computer.status // "none") == "connected" then "● " + $on + " · " + (.computer.host // "")
       elif (.computer.status // "none") == "disconnected" then "○ " + $off + " · " + (.computer.host // "")
       else "· " + $none end),
      (._id | .[-6:]) ] | @tsv' | awk -F'\t' '{ printf "  %-26s %-11s %-42s %s\n", $1, $2, $3, $4 }'
  echo ""
  hf_dim "$(hf_t "/agents <name> opens its conversation" "/agents <nombre> abre su conversación")"
}

# Resuelve id y nombre por id o nombre (sin distinguir mayúsculas)
_hf_agents_resolve() {
  local ref="$1" resp
  resp="$(_hf_agents_get agents)"
  printf '%s' "$resp" | jq -r --arg ref "$ref" '
    (.data // []) | map(select((._id == $ref) or (((.name // "") | ascii_downcase) == ($ref | ascii_downcase)))) | .[0] |
    if . == null then empty else "\(._id)\t\(.name)" end'
}

_hf_agents_count() {
  _hf_agents_get "agents/$1/conversation" | jq -r '(.data.messages // []) | length' 2>/dev/null || echo 0
}

# Imprime los mensajes desde el índice $2 (0-based) y acumula adjuntos en HF_AG_URLS.
# Deja el total en HF_AG_TOTAL (no se captura la salida: se imprime tal cual).
_hf_agents_print() {
  local id="$1" from="$2" conv total
  conv="$(_hf_agents_get "agents/$id/conversation")"
  total="$(printf '%s' "$conv" | jq -r '(.data.messages // []) | length')"
  [ -z "$total" ] && total=0
  HF_AG_TOTAL="$total"
  if [ "$from" -lt "$total" ]; then
    printf '%s' "$conv" | jq -r --argjson from "$from" --arg you "$(hf_t "you" "tú")" '
      (.data.messages // [])[$from:] | .[] |
      "\u001e" + (if .role == "user" then "\u001f" + $you else "\u0001" + "agent" end) + "\u001e" +
      ((.content // "") | split("\n")[:8] | join("\n")) +
      ((.files // []) | map("\u0002" + (.name // "archivo") + "\t" + ((.mimeType // .type // "") | tostring) + "\t" + ((.size // 0) | tostring) + "\t" + (.url // "")) | join(""))' \
    | _hf_agents_render "$3"
  fi
}

# Render de lo anterior: cabecera por rol, cuerpo, adjuntos numerados
_hf_agents_render() {
  local name="$1" line
  while IFS= read -r line; do
    case "$line" in
      $'\x1e'$'\x1f'*) line="${line#$'\x1e'$'\x1f'}"; echo ""; echo -e "  ${HF_C_BOLD}👤 ${line%%$'\x1e'*}${HF_C_RESET}"; line="${line#*$'\x1e'}" ;;
      $'\x1e'$'\x01'*) line="${line#$'\x1e'$'\x01'agent$'\x1e'}"; echo ""; echo -e "  ${HF_C_BOLD}🤖 $name${HF_C_RESET}" ;;
    esac
    # adjuntos embebidos con \x02
    local rest="$line" body
    body="${rest%%$'\x02'*}"
    [ -n "$body" ] && printf '%s\n' "$body" | sed 's/^/     /'
    while [ "$rest" != "${rest#*$'\x02'}" ]; do
      rest="${rest#*$'\x02'}"
      local item="${rest%%$'\x02'*}"
      local fname="${item%%$'\t'*}"; local r2="${item#*$'\t'}"; local ftype="${r2%%$'\t'*}"; r2="${r2#*$'\t'}"; local fsize="${r2%%$'\t'*}"; local furl="${r2#*$'\t'}"
      HF_AG_N=$((HF_AG_N + 1)); HF_AG_URLS="$HF_AG_URLS$furl"$'\n'
      echo -e "     📎 [${HF_AG_N}] ${HF_C_BOLD}${fname}${HF_C_RESET} ${HF_C_DIM}${ftype} · ${fsize} B${HF_C_RESET}"
      echo -e "         ${HF_C_DIM}${furl}${HF_C_RESET}"
    done
  done
}

_hf_agents_url() { printf '%s' "$HF_AG_URLS" | sed -n "${1}p"; }

# Sesión interactiva con un agente
hf_agents_session() {
  local ref="$1" hit id name sid seen n line reply_seen
  hit="$(_hf_agents_resolve "$ref")"
  [ -z "$hit" ] && { hf_err "$(hf_t "No agent named '$ref'" "No hay un agente llamado '$ref'")"; return 1; }
  id="${hit%%$'\t'*}"; name="${hit#*$'\t'}"
  sid="$(_hf_agents_get "agents/$id/conversation" | jq -r '.data.sessionId // empty')"
  [ -z "$sid" ] && { hf_err "$(hf_t "Could not open the conversation" "No se pudo abrir la conversación")"; return 1; }
  HF_AG_URLS=""; HF_AG_N=0
  echo ""
  hf_ok "$(hf_t "Conversation with" "Conversación con") ${HF_C_BOLD}🤖 $name${HF_C_RESET}"
  hf_dim "$(hf_t "type to talk · /open N opens attachment N · /refresh · /back to leave" "escribe para hablar · /open N abre el adjunto N · /refresh · /back para salir")"
  local total0; total0="$(_hf_agents_count "$id")"; local start=$(( total0 > 12 ? total0 - 12 : 0 ))
  [ "$start" -gt 0 ] && hf_dim "$(hf_t "… $start earlier messages (/refresh shows new ones)" "… $start mensajes anteriores (/refresh muestra los nuevos)")"
  _hf_agents_print "$id" "$start" "$name"; seen="$HF_AG_TOTAL"
  echo ""
  while true; do
    if [ -t 0 ]; then read -r -e -p "  🤖 $name ❯ " line || break; else read -r line || break; fi
    case "$line" in
      "") continue ;;
      /back|/exit|/q|q) break ;;
      /refresh) _hf_agents_print "$id" "$seen" "$name"; seen="$HF_AG_TOTAL" ;;
      /open*) n="${line#/open}"; n="${n// /}"; local u; u="$(_hf_agents_url "${n:-1}")"
              if [ -n "$u" ]; then (command -v open >/dev/null && open "$u") || (command -v xdg-open >/dev/null && xdg-open "$u") || echo "  $u"; else hf_err "$(hf_t "No attachment $n" "No hay adjunto $n")"; fi ;;
      *)
        local body; body="$(jq -cn --arg m "$line" --arg s "$sid" '{message:$m, sessionId:$s, files:[]}')"
        _hf_agents_post "agents/$id/chat" "$body" >/dev/null
        seen=$((seen + 1))
        printf '  %s' "$(hf_t "thinking…" "pensando…")"
        local waited=0 total
        while [ $waited -lt 240 ]; do
          sleep 3; waited=$((waited + 3))
          total="$(_hf_agents_get "agents/$id/conversation" | jq -r '(.data.messages // []) | length')"
          if [ "${total:-0}" -gt "$seen" ]; then printf '\r%40s\r' ''; _hf_agents_print "$id" "$seen" "$name"; seen="$HF_AG_TOTAL"; break; fi
          printf '.'
        done
        [ $waited -ge 240 ] && { echo ""; hf_dim "$(hf_t "no reply yet — /refresh later" "aún sin respuesta — /refresh más tarde")"; }
        echo "" ;;
    esac
  done
  echo ""
}

hf_agents_cmd() {
  case "${1:-}" in
    ""|list|ls) hf_agents_list ;;
    help|-h|--help)
      echo "  /agents               $(hf_t "list your agents" "lista tus agentes")"
      echo "  /agents <name|id>     $(hf_t "open its conversation (attachments as URLs)" "abre su conversación (adjuntos como URLs)")" ;;
    *) hf_agents_session "$*" ;;
  esac
}
