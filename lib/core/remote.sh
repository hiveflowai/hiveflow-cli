#!/usr/bin/env bash
# ── /remote — despacho de runs a nodos ────────────────────────
# Nuestra versión del patrón de ejecución remota de Anthropic. Ver la
# investigación en hiveflow-docs/cli/REMOTE.md. Los 5 componentes del patrón:
#
#   CLIENTE → BRIDGE → RUNNER → STORE → NOTIFICADOR
#   (disparo) (este)   (worktree) (runs) (PR + chat)
#
# Un NODO es una máquina que puede correr el pipeline de tickets:
#   · local  → esta máquina (el run corre en segundo plano, aislado)
#   · ssh    → otra PC/servidor con hiveflow instalado, vía SSH saliente
#
# Igual que Anthropic: conexión SÓLO saliente (SSH), el trabajo corre en
# un entorno efímero (worktree), nunca se toca la rama base, el input del
# ticket entra como dato no-confiable, y cada run lleva un id trazable que
# acaba en el commit y el PR.

hf_remote_nodes()  { jq -c '.remote.nodes // []' "$HF_CONFIG_FILE" 2>/dev/null; }
hf_runs_dir()      { echo "${HF_RUNS_DIR:-$HF_CONFIG_DIR/runs}"; }

# ── Registro de nodos ─────────────────────────────────────────
hf_remote_add() {
  local name="$1" target="${2:-local}" repo_root="${3:-}"
  [ -z "$name" ] && { hf_err "$(hf_t "Usage: /remote add <name> [local|user@host] [repo-root]" "Uso: /remote add <nombre> [local|user@host] [repo-root]")"; return 1; }

  local type="local"
  case "$target" in
    local) type="local"; repo_root="${repo_root:-$(hf_config_get '.tickets.repo_root')}" ;;
    *@*)   type="ssh"
           # Verificar alcance del nodo SSH (outbound-only, como Anthropic)
           hf_info "$(hf_t "Testing SSH to $target ..." "Probando SSH a $target ...")"
           if ! ssh -o ConnectTimeout=8 -o BatchMode=yes "$target" 'command -v hiveflow >/dev/null' 2>/dev/null; then
             hf_warn "$(hf_t "Could not confirm 'hiveflow' on $target (installed? SSH key?). Registering anyway." "No se pudo confirmar 'hiveflow' en $target (¿instalado? ¿clave SSH?). Se registra igual.")"
           else
             hf_ok "$(hf_t "$target responds and has hiveflow" "$target responde y tiene hiveflow")"
           fi ;;
    *) hf_err "$(hf_t "Invalid target: use 'local' or 'user@host'" "Target inválido: usa 'local' o 'usuario@host'")"; return 1 ;;
  esac

  local tmp; tmp="$(mktemp)"
  jq --arg n "$name" --arg t "$target" --arg ty "$type" --arg r "$repo_root" \
    '.remote.nodes = ((.remote.nodes // []) | map(select(.name != $n)) + [{name:$n, target:$t, type:$ty, repo_root:$r}])' \
    "$HF_CONFIG_FILE" > "$tmp" && mv "$tmp" "$HF_CONFIG_FILE"
  chmod 600 "$HF_CONFIG_FILE"
  hf_ok "$(hf_t "Node '$name' registered ($type${repo_root:+, repos: $repo_root})" "Nodo '$name' registrado ($type${repo_root:+, repos: $repo_root})")"
}

hf_remote_remove() {
  local name="$1"
  [ -z "$name" ] && { hf_err "$(hf_t "Usage: /remote remove <name>" "Uso: /remote remove <nombre>")"; return 1; }
  local tmp; tmp="$(mktemp)"
  jq --arg n "$name" '.remote.nodes = ((.remote.nodes // []) | map(select(.name != $n)))' \
    "$HF_CONFIG_FILE" > "$tmp" && mv "$tmp" "$HF_CONFIG_FILE"
  hf_ok "$(hf_t "Node '$name' removed" "Nodo '$name' eliminado")"
}

hf_remote_list() {
  local nodes
  nodes="$(hf_remote_nodes)"
  if [ "$nodes" = "[]" ] || [ -z "$nodes" ]; then
    hf_warn "$(hf_t "No nodes. Register one: /remote add <name> [local|user@host]" "Sin nodos. Registra uno: /remote add <nombre> [local|user@host]")"
    hf_dim "$(hf_t "The 'local' node runs tickets on this very machine." "El nodo 'local' corre los tickets en esta misma máquina.")"
    return 0
  fi
  echo ""
  printf "  %-14s %-8s %-24s %s\n" "$(hf_t "NODE" "NODO")" "$(hf_t "TYPE" "TIPO")" "$(hf_t "TARGET" "DESTINO")" "$(hf_t "STATUS" "ESTADO")"
  local name type target
  while IFS=$'\t' read -r name type target; do
    [ -z "$name" ] && continue
    local st="—"
    if [ "$type" = "local" ]; then
      st="$(hf_t "ready" "listo")"
    elif ssh -o ConnectTimeout=5 -o BatchMode=yes "$target" true 2>/dev/null; then
      st="$(hf_t "reachable" "alcanzable")"
    else
      st="$(hf_t "unreachable" "sin conexión")"
    fi
    printf "  %-14s %-8s %-24s %s\n" "$name" "$type" "$target" "$st"
  done < <(echo "$nodes" | jq -r '.[] | "\(.name)\t\(.type)\t\(.target)"')
  echo ""
}

_hf_node_field() {
  hf_remote_nodes | jq -r --arg n "$1" --arg f "$2" '.[] | select(.name==$n) | .[$f] // empty'
}

# ── Store de runs ─────────────────────────────────────────────
# Cada run lleva un id que se inyecta al entorno (como CLAUDE_CODE_REMOTE_
# SESSION_ID) y acaba en el trailer del commit y el body del PR.
_hf_run_id() {
  # Determinista sin depender de Date/random (bloqueados en algunos entornos)
  local seed="$1$2"
  echo "run-$(printf '%s' "$seed" | md5sum | cut -c1-10)"
}

hf_remote_run() {
  local ticket="$1" node="${2:-}"
  [ -z "$ticket" ] && { hf_err "$(hf_t "Usage: /remote run <ticket-id> [node]" "Uso: /remote run <ticket-id> [nodo]")"; return 1; }

  local nodes; nodes="$(hf_remote_nodes)"
  # Sin nodo especificado: el primero, o 'local' implícito
  if [ -z "$node" ]; then
    node="$(echo "$nodes" | jq -r '.[0].name // empty')"
    [ -z "$node" ] && { hf_remote_add local local >/dev/null; node="local"; }
  fi
  local type target repo_root
  type="$(_hf_node_field "$node" type)"
  target="$(_hf_node_field "$node" target)"
  repo_root="$(_hf_node_field "$node" repo_root)"
  [ -z "$type" ] && { hf_err "$(hf_t "Node '$node' does not exist (/remote list)" "Nodo '$node' no existe (/remote list)")"; return 1; }

  local run_id; run_id="$(_hf_run_id "$ticket" "$node")"
  mkdir -p "$(hf_runs_dir)"
  local log="$(hf_runs_dir)/${run_id}.log"
  local meta="$(hf_runs_dir)/${run_id}.json"

  jq -nc --arg id "$run_id" --arg t "$ticket" --arg n "$node" --arg ty "$type" \
    '{run_id:$id, ticket:$t, node:$n, type:$ty, status:"running"}' > "$meta"
  hf_metric remote_run_started "$ticket" run_id="$run_id" node="$node"

  hf_ok "$(hf_t "Run $run_id → ticket $ticket on node '$node' ($type)" "Run $run_id → ticket $ticket en nodo '$node' ($type)")"

  if [ "$type" = "local" ]; then
    # RUNNER local en segundo plano: el pipeline ya aísla en worktree.
    # HF_RUN_ID viaja al entorno → trazabilidad ticket↔run↔PR.
    ( HF_RUN_ID="$run_id" HIVEFLOW_ROOT="$HIVEFLOW_ROOT" \
        "$HIVEFLOW_ROOT/hiveflow.sh" tickets fix "$ticket" > "$log" 2>&1
      _hf_run_finish "$meta" $? ) &
    hf_dim "$(hf_t "running in the background · /remote logs $run_id · /remote status" "corriendo en segundo plano · /remote logs $run_id · /remote status")"
  else
    # BRIDGE saliente: SSH al nodo, que corre su propio hiveflow.
    # Nunca abrimos puertos entrantes (patrón outbound-only de Anthropic).
    ( ssh -o ConnectTimeout=10 "$target" \
        "HF_RUN_ID='$run_id' hiveflow tickets fix '$ticket'" > "$log" 2>&1
      _hf_run_finish "$meta" $? ) &
    hf_dim "$(hf_t "dispatched via SSH to $target · /remote logs $run_id" "despachado por SSH a $target · /remote logs $run_id")"
  fi
}

_hf_run_finish() {
  local meta="$1" rc="$2"
  local status="done"; [ "$rc" -ne 0 ] && status="failed"
  local tmp; tmp="$(mktemp)"
  jq --arg s "$status" --argjson rc "$rc" '.status=$s | .exit=$rc' "$meta" > "$tmp" && mv "$tmp" "$meta"
  local tid; tid="$(jq -r '.ticket' "$meta")"
  hf_metric remote_run_finished "$tid" run_id="$(jq -r '.run_id' "$meta")" status="$status"
}

hf_remote_status() {
  local d; d="$(hf_runs_dir)"
  [ ! -d "$d" ] && { hf_warn "$(hf_t "No runs yet" "Sin runs todavía")"; return 0; }
  echo ""
  printf "  %-18s %-24s %-10s %s\n" "RUN" "TICKET" "$(hf_t "NODE" "NODO")" "$(hf_t "STATUS" "ESTADO")"
  local f
  for f in "$d"/*.json; do
    [ -f "$f" ] || continue
    jq -r '"  \(.run_id)\t\(.ticket)\t\(.node)\t\(.status)\(if .exit and .exit!=0 then " (exit \(.exit))" else "" end)"' "$f"
  done | sort | while IFS=$'\t' read -r r t n s; do
    printf "  %-18s %-24s %-10s %s\n" "$r" "$t" "$n" "$s"
  done
  echo ""
  hf_dim "$(hf_t "logs for a run: /remote logs <run-id>" "logs de un run: /remote logs <run-id>")"
}

hf_remote_logs() {
  local run="$1"
  [ -z "$run" ] && { hf_err "$(hf_t "Usage: /remote logs <run-id>" "Uso: /remote logs <run-id>")"; return 1; }
  local log="$(hf_runs_dir)/${run}.log"
  [ ! -f "$log" ] && { hf_err "$(hf_t "No log for $run" "No hay log para $run")"; return 1; }
  tail -40 "$log"
}

# ══ Remote Control ════════════════════════════════════════════
# Refleja ESTA sesión del CLI en tu web/app. Patrón de Anthropic:
#   · el CLI registra y hace LONG-POLL saliente a un relay (sin puertos entrantes)
#   · la web/app, autenticada como TÚ, empuja prompts al relay
#   · el CLI los ejecuta LOCAL y devuelve la respuesta
#   · solo cruzan mensajes y resultados; tu código/FS/env nunca salen
#
# El relay es pluggable (.remote.relay):
#   local:<dir>   cola de ficheros — para el desktop (también local) y para probar
#   http:<url>    endpoint HTTP — el que implementará el backend para la web
#
# Contrato del relay (para que backend/frontend implementen su lado):
#   REGISTER  → anuncia la sesión: {session_id, operator, cwd, started}
#   POLL      → devuelve el siguiente prompt pendiente, o vacío (long-poll)
#              {msg_id, text}
#   RESPOND   → publica la respuesta: {msg_id, output, status}

# Relay configurado, o — con cuenta conectada — el backend de Hiveflow por
# defecto: /remote control funciona sin configurar nada.
hf_remote_relay() {
  local r
  r="$(hf_config_get '.remote.relay')"
  if [ -z "$r" ] && hf_auth_ok 2>/dev/null; then
    r="http:${HIVEFLOW_API_URL%/}/api/rc"
  fi
  printf '%s' "$r"
}
# Cada arranque de hiveflow = una sesión NUEVA (estándar Claude Code):
# varias terminales — incluso en la misma carpeta — son sesiones
# independientes y la web puede escribirle a cada una por separado.
# Retomar un hilo pasado es siempre explícito: /remote control <id>.
# La semilla se fija UNA vez por proceso al cargar este archivo (la función
# corre dentro de $(...) — un subshell — así que cachear ahí no persiste:
# cada llamada generaría un id distinto y /remote control duplicaría sesiones).
HF_RC_SESSION_SEED="${HF_RC_SESSION_SEED:-$$-$(date +%s 2>/dev/null || echo 0)}"
export HF_RC_SESSION_SEED
hf_remote_session() {
  echo "sess-$(printf '%s' "$1$USER$HOSTNAME$HF_RC_SESSION_SEED" | md5sum | cut -c1-10)"
}

# ── Adaptador de relay LOCAL (cola de ficheros) ───────────────
# <dir>/inbox/  prompts entrantes (los deja la web/app)
# <dir>/outbox/ respuestas salientes (las deja el CLI)
_hf_relay_local_dir() { local r; r="$(hf_remote_relay)"; echo "${r#local:}"; }

# Varias CLIs pueden estar conectadas → una sesión por fichero (el contador de
# la web = nº de sesiones online del operador). El estado connected/disconnected
# lo decide el heartbeat: si last_seen es viejo, el CLI se cayó.
_hf_relay_register() {
  local sid="$1" dir
  case "$(hf_remote_relay)" in
    local:*) dir="$(_hf_relay_local_dir)"; mkdir -p "$dir/sessions" "$dir/inbox" "$dir/outbox"
             jq -nc --arg s "$sid" --arg o "$USER" --arg c "$PWD" --arg h "$HOSTNAME" --argjson t "$(date +%s)" \
               '{session_id:$s, operator:$o, cwd:$c, host:$h, status:"connected", last_seen:$t}' \
               > "$dir/sessions/$sid.json" ;;
    http:*)  local url resp; url="$(hf_remote_relay)"; url="${url#http:}"
             # $2 = conversation_id a reanudar · $3 = "new" fuerza hilo nuevo.
             # La respuesta trae la conversación de Genius que respalda el hilo.
             resp="$(curl -s -m 10 -X POST "${url}/register" \
               -H "Authorization: Bearer $(hf_auth_token)" -H "Content-Type: application/json" \
               -d "$(jq -nc --arg s "$sid" --arg o "$USER" --arg c "$PWD" --arg h "$HOSTNAME" \
                     --arg conv "${2:-}" --arg th "${HF_REPL_SESSION:-}" \
                     --argjson new "$([ "${3:-}" = "new" ] && echo true || echo false)" \
                     '{session_id:$s, operator:$o, cwd:$c, host:$h}
                      + (if $conv != "" then {conversation_id:$conv} else {} end)
                      + (if $th != "" then {thread_id:$th} else {} end)
                      + (if $new then {new_conversation:true} else {} end)')" 2>/dev/null)"
             HF_RC_CONVERSATION_ID="$(printf '%s' "$resp" | jq -r '.conversation_id // empty' 2>/dev/null)"
             HF_RC_CONVERSATION_TITLE="$(printf '%s' "$resp" | jq -r '.conversation_title // empty' 2>/dev/null)"
             HF_RC_CONVERSATION_MSGS="$(printf '%s' "$resp" | jq -r '.conversation_messages // 0' 2>/dev/null)"
             # ¿El relay ACEPTÓ el registro? (auth inválida → success:false /
             # sin session_id). Sin esto la conexión fallaba en silencio.
             HF_RC_REGISTERED="$(printf '%s' "$resp" | jq -r 'if (.session_id // empty) != "" then "1" else "" end' 2>/dev/null)"
             HF_RC_REGISTER_ERR="$(printf '%s' "$resp" | jq -r '.message // .error // empty' 2>/dev/null)"
             [ -z "$resp" ] && HF_RC_REGISTER_ERR="$(hf_t "no response from the relay" "el relay no respondió")" ;;
  esac
}

# Latido: renueva last_seen. La web marca "desconectada" si no hay latido reciente.
_hf_relay_heartbeat() {
  local sid="$1"
  case "$(hf_remote_relay)" in
    local:*) local dir f tmp; dir="$(_hf_relay_local_dir)"; f="$dir/sessions/$sid.json"
             [ -f "$f" ] || return 0; tmp="$(mktemp)"
             jq --argjson t "$(date +%s)" '.last_seen=$t | .status="connected"' "$f" > "$tmp" && mv "$tmp" "$f" ;;
    http:*)  local url r ok; url="$(hf_remote_relay)"; url="${url#http:}"
             r="$(curl -s -m 8 -X POST "${url}/heartbeat" -H "Authorization: Bearer $(hf_auth_token)" -H "Content-Type: application/json" \
               -d "$(jq -nc --arg s "$sid" '{session_id:$s}')" 2>/dev/null)"
             # OJO jq: 'false // empty' da vacío ('//' trata false como
             # ausente) — hay que leer .ok tal cual
             ok="$(printf '%s' "$r" | jq -r '.ok' 2>/dev/null)"
             # ok:false = el relay ya no conoce esta sesión (redeploy/reinicio
             # del backend purga la memoria): re-registrarse con el MISMO hilo
             # para que la web vuelva a vernos sin duplicar conversación.
             if [ "$ok" = "false" ]; then
               _hf_relay_register "$sid"
               { printf '  \033[2m%s\033[0m\n' "$(hf_t "relay restarted — session re-registered" "el relay se reinició — sesión re-registrada")"; } > /dev/tty 2>/dev/null || true
             fi ;;
  esac
}

# Desconexión limpia (Ctrl+C / cierre del CLI) → marca la sesión desconectada.
_hf_relay_disconnect() {
  local sid="$1"
  case "$(hf_remote_relay)" in
    local:*) local dir f tmp; dir="$(_hf_relay_local_dir)"; f="$dir/sessions/$sid.json"
             [ -f "$f" ] || return 0; tmp="$(mktemp)"
             jq '.status="disconnected"' "$f" > "$tmp" && mv "$tmp" "$f" ;;
    http:*)  local url; url="$(hf_remote_relay)"; url="${url#http:}"
             curl -s -m 8 -X POST "${url}/disconnect" -H "Authorization: Bearer $(hf_auth_token)" -H "Content-Type: application/json" \
               -d "$(jq -nc --arg s "$sid" '{session_id:$s}')" >/dev/null 2>&1 ;;
  esac
}

# Imprime el siguiente prompt pendiente como  msg_id<TAB>texto  (o nada)
_hf_relay_poll() {
  local sid="$1"
  case "$(hf_remote_relay)" in
    local:*)
      local dir f; dir="$(_hf_relay_local_dir)"
      f="$(ls -1 "$dir/inbox/" 2>/dev/null | head -1)"
      [ -z "$f" ] && return 0
      local mid="${f%.json}"
      printf '%s\t%s' "$mid" "$(jq -r '.text // empty' "$dir/inbox/$f")"
      rm -f "$dir/inbox/$f" ;;
    http:*)
      local url; url="$(hf_remote_relay)"; url="${url#http:}"
      local r; r="$(curl -s -m 35 "${url}/poll?session=$sid" -H "Authorization: Bearer $(hf_auth_token)" 2>/dev/null)"
      [ -z "$r" ] || [ "$r" = "{}" ] && return 0
      # Cualquier respuesta que NO sea un mensaje (error de auth, proxy,
      # sesión purgada tras un redeploy…) carece de msg_id/text: sin este
      # guard, jq imprimía el string "null" y el daemon lo EJECUTABA en
      # bucle ("🌐 web ❯ null" infinito quemando llamadas al agente).
      local _mid _text
      _mid="$(printf '%s' "$r" | jq -r '.msg_id // empty' 2>/dev/null)"
      _text="$(printf '%s' "$r" | jq -r '.text // empty' 2>/dev/null)"
      { [ -z "$_mid" ] || [ -z "$_text" ]; } && return 0
      printf '%s\t%s' "$_mid" "$_text" ;;
  esac
}

_hf_relay_respond() {
  local sid="$1" mid="$2" output="$3"
  case "$(hf_remote_relay)" in
    local:*)
      local dir; dir="$(_hf_relay_local_dir)"
      jq -nc --arg m "$mid" --arg o "$output" '{msg_id:$m, output:$o, status:"done"}' > "$dir/outbox/$mid.json" ;;
    http:*)
      local url; url="$(hf_remote_relay)"; url="${url#http:}"
      curl -s -m 15 -X POST "${url}/respond" -H "Authorization: Bearer $(hf_auth_token)" -H "Content-Type: application/json" \
        -d "$(jq -nc --arg s "$sid" --arg m "$mid" --arg o "$output" '{session_id:$s, msg_id:$m, output:$o}')" >/dev/null 2>&1 ;;
  esac
}

# El bucle: registra, hace polling y ejecuta cada prompt en ESTA sesión.
hf_remote_control() {
  local relay; relay="$(hf_remote_relay)"
  if [ -z "$relay" ]; then
    hf_err "$(hf_t "No relay available. Log in first (/login) or set one manually:" "Sin relay disponible. Haz login primero (/login) o configura uno a mano:")"
    hf_dim "$(hf_t "Local (desktop/testing):  /remote relay local:~/.config/hiveflow/relay" "Local (desktop/pruebas):  /remote relay local:~/.config/hiveflow/relay")"
    hf_dim "$(hf_t "Web:  /remote relay http:https://api.hiveflow.ai/api/rc" "Web:  /remote relay http:https://api.hiveflow.ai/api/rc")"
    return 1
  fi
  local sid; sid="$(hf_remote_session "$PWD")"
  HF_RC_SID="$sid"; export HF_RC_SID
  local sdir pidfile
  sdir="$(_hf_rc_state_dir)"; pidfile="$sdir/daemon.pid"
  # ¿Ya conectada ESTA terminal? No registrar de nuevo: solo avisar.
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    local conv; conv="$(cat "$sdir/conversation" 2>/dev/null)"
    hf_ok "$(hf_t "This terminal is already connected — thread ${HF_C_BOLD}🧵 ${HF_REPL_SESSION##*-}${HF_C_RESET}" "Esta terminal ya está conectada — hilo ${HF_C_BOLD}🧵 ${HF_REPL_SESSION##*-}${HF_C_RESET}")"
    [ -n "$conv" ] && hf_dim "$(hf_t "conversation: $conv — follow it in Genius" "conversación: $conv — síguela en Genius")"
    hf_dim "$(hf_t "/new starts a new conversation (also in the web) · /remote stop disconnects" "/new abre otra conversación (también en la web) · /remote stop desconecta")"
    return 0
  fi
  mkdir -p "$sdir"
  # Conectar = subir la conversación ACTUAL del REPL: asegúrala primero
  # para que la nube se ate a este hilo (1:1) y no a la terminal.
  declare -f hf_repl_session_ensure >/dev/null 2>&1 && hf_repl_session_ensure >/dev/null 2>&1
  # $1 opcional: id de conversación de Genius a reanudar, o "new" para hilo nuevo
  HF_RC_CONVERSATION_ID=""; HF_RC_CONVERSATION_TITLE=""; HF_RC_REGISTERED=""
  if [ "${1:-}" = "new" ]; then
    _hf_relay_register "$sid" "" "new"
  else
    _hf_relay_register "$sid" "${1:-}"
  fi
  # Registro rechazado (token inválido para ESTE ambiente, backend caído…):
  # avisar fuerte y no fingir que estamos conectados.
  case "$relay" in http:*)
    if [ -z "${HF_RC_REGISTERED:-}" ]; then
      hf_err "$(hf_t "Could not connect to the relay ($(hf_env_tag 2>/dev/null || echo api)): ${HF_RC_REGISTER_ERR:-unknown error}" "No se pudo conectar al relay ($(hf_env_tag 2>/dev/null || echo api)): ${HF_RC_REGISTER_ERR:-error desconocido}")"
      hf_dim "$(hf_t "Your token may belong to ANOTHER environment. Check the statusline tag and run /login against this one." "Tu token puede ser de OTRO ambiente. Mira la etiqueta de la statusline y haz /login contra este.")"
      return 1
    fi ;;
  esac
  # Espejo EN SEGUNDO PLANO: el prompt local sigue vivo; web y CLI conviven.
  printf '%s' "$sid" > "$sdir/session"
  printf '%s' "${HF_RC_CONVERSATION_ID:-}" > "$sdir/conversation"

  echo ""
  hf_ok "$(hf_t "Remote Control active — thread ${HF_C_BOLD}🧵 ${HF_REPL_SESSION##*-}${HF_C_RESET}" "Remote Control activo — hilo ${HF_C_BOLD}🧵 ${HF_REPL_SESSION##*-}${HF_C_RESET}")"
  case "$relay" in
    local:*) hf_dim "$(hf_t "local relay: $(_hf_relay_local_dir) — the desktop and the (local) web can now send it requests" "relay local: $(_hf_relay_local_dir) — el desktop y la web (local) ya pueden pedirle cosas")" ;;
    http:*)
      if [ -n "${HF_RC_CONVERSATION_ID:-}" ]; then
        hf_dim "$(hf_t "conversation: ${HF_RC_CONVERSATION_TITLE:-CLI} (${HF_RC_CONVERSATION_ID})" "conversación: ${HF_RC_CONVERSATION_TITLE:-CLI} (${HF_RC_CONVERSATION_ID})")"
        # Nube vacía + hilo local con historia → subirla para que la web la vea
        if [ "${HF_RC_CONVERSATION_MSGS:-0}" = "0" ] && [ -n "${HF_REPL_SESSION:-}" ]; then
          hf_dim "$(hf_t "syncing this terminal's conversation history to the web…" "sincronizando el historial de esta terminal a la web…")"
          ( _hf_rc_backfill "$sid" ) >/dev/null 2>&1 &
        fi
        hf_dim "$(hf_t "follow it in Genius, or resume later: /remote control ${HF_RC_CONVERSATION_ID} · new thread: /remote control new" "síguela en Genius, o retómala luego: /remote control ${HF_RC_CONVERSATION_ID} · hilo nuevo: /remote control new")"
      else
        hf_dim "$(hf_t "open it in the web/app; you'll see this session mirrored and can ask it anything" "ábrela en la web/app; verás esta sesión reflejada y podrás pedirle cualquier cosa")"
      fi ;;
  esac
  hf_dim "$(hf_t "keep using the CLI normally — web prompts will show up here · /remote stop to stop mirroring" "sigue usando el CLI normal — lo que pidan desde la web aparecerá aquí · /remote stop para detener")"
  echo ""

  hf_metric rc_session_start "" session="$sid"
  ( _hf_rc_daemon "$sid" ) </dev/null >> "$sdir/daemon.log" 2>&1 &
  printf '%s' "$!" > "$pidfile"
  disown 2>/dev/null || true
  return 0
}

# ── Espejo en segundo plano ───────────────────────────────────
# Estado POR SESIÓN (HF_RC_SID la fija el proceso que arranca el espejo):
# cada terminal tiene su propio daemon/pid/log y no pisa a las demás.
_hf_rc_state_dir() { echo "$HF_CONFIG_DIR/rc/${HF_RC_SID:-default}"; }

hf_rc_mirror_active() {
  local p="$(_hf_rc_state_dir)/daemon.pid"
  [ -f "$p" ] && kill -0 "$(cat "$p" 2>/dev/null)" 2>/dev/null
}

# Progreso intermedio de un prompt web en curso (streaming de pasos)
_hf_relay_progress() {
  local mid="$1" chunk="$2" url
  case "$(hf_remote_relay)" in
    http:*)
      url="$(hf_remote_relay)"; url="${url#http:}"
      chunk="$(printf '%s' "$chunk" | sed -e $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' -e $'s/\r//g')"
      [ -z "$chunk" ] && return 0
      curl -s -m 8 -X POST "${url}/progress" \
        -H "Authorization: Bearer $(hf_auth_token)" -H "Content-Type: application/json" \
        -d "$(jq -nc --arg m "$mid" --arg c "$chunk" '{msg_id:$m, lines: ($c | split("\n"))}')" >/dev/null 2>&1 ;;
  esac
}

# La terminal está trabajando un turno local (busy=1) o terminó (busy=0):
# los visores de la conversación en web/iOS pintan "pensando" con esto.
_hf_rc_activity() {
  local b="$1" sid url
  hf_rc_mirror_active || return 0
  sid="$(cat "$(_hf_rc_state_dir)/session" 2>/dev/null)"
  [ -z "$sid" ] && return 0
  case "$(hf_remote_relay)" in
    http:*)
      url="$(hf_remote_relay)"; url="${url#http:}"
      curl -s -m 6 -X POST "${url}/activity" \
        -H "Authorization: Bearer $(hf_auth_token)" -H "Content-Type: application/json" \
        -d "$(jq -nc --arg s "$sid" --argjson b "$b" '{session_id:$s, busy:($b==1)}')" >/dev/null 2>&1 ;;
  esac
}

# Añade un mensaje a la conversación de Genius del espejo (best-effort).
# Si la web la borró, el backend la recrea vacía y responde recreated=true:
# resubimos TODO el historial local — la terminal es la fuente de verdad.
_hf_rc_append() {
  local role="$1" content="$2" sid url resp
  hf_rc_mirror_active || return 0
  sid="$(cat "$(_hf_rc_state_dir)/session" 2>/dev/null)"
  [ -z "$sid" ] && return 0
  case "$(hf_remote_relay)" in
    http:*)
      url="$(hf_remote_relay)"; url="${url#http:}"
      content="$(printf '%s' "$content" | sed -e $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' -e $'s/\r//g')"
      resp="$(curl -s -m 10 -X POST "${url}/append" \
        -H "Authorization: Bearer $(hf_auth_token)" -H "Content-Type: application/json" \
        -d "$(jq -nc --arg s "$sid" --arg r "$role" --arg c "$content" \
              '{session_id:$s, role:$r, content:$c}')" 2>/dev/null)"
      if [ "$(printf '%s' "$resp" | jq -r '.recreated // false' 2>/dev/null)" = "true" ]; then
        # Primero la historia completa, luego el mensaje que disparó el
        # renacer (el backend no lo añadió para preservar el orden).
        _hf_rc_backfill "$sid"
        curl -s -m 10 -X POST "${url}/append" \
          -H "Authorization: Bearer $(hf_auth_token)" -H "Content-Type: application/json" \
          -d "$(jq -nc --arg s "$sid" --arg r "$role" --arg c "$content" \
                '{session_id:$s, role:$r, content:$c}')" >/dev/null 2>&1
      fi ;;
  esac
}

# Al conectar el espejo, vuelca el historial LOCAL del hilo del REPL a la
# conversación de Genius, para que la web muestre toda la conversación y no
# solo lo posterior a la conexión. Solo se llama con la conversación vacía.
_hf_rc_backfill() {
  local sid="$1" url msgs
  [ -n "${HF_REPL_SESSION:-}" ] || return 0
  declare -f sessions_load >/dev/null 2>&1 || return 0
  msgs="$(sessions_load "$HF_REPL_SESSION" 2>/dev/null)"
  [ -z "$msgs" ] || [ "$msgs" = "[]" ] && return 0
  url="$(hf_remote_relay)"; case "$url" in http:*) url="${url#http:}" ;; *) return 0 ;; esac
  printf '%s' "$msgs" | jq -c '
    .[] | select(.role=="user" or .role=="assistant")
    | .content = (if (.content|type)=="string" then .content
        else ([.content[]? | select(.type=="text") | .text] | join("\n")) end)
    | select(.content != null and .content != "")
    | {role, content}' 2>/dev/null | while IFS= read -r m; do
      curl -s -m 10 -X POST "${url}/append" \
        -H "Authorization: Bearer $(hf_auth_token)" -H "Content-Type: application/json" \
        -d "$(printf '%s' "$m" | jq -c --arg s "$sid" '{session_id:$s} + .')" >/dev/null 2>&1
    done
}

# /new o /resume con el espejo activo: re-adjunta la nube al hilo local
# ACTUAL (HF_REPL_SESSION). El backend busca la conversación 1:1 de ese
# hilo — la crea si no existe — y appends/responds posteriores caen ahí.
# Si la conversación está vacía y el hilo tiene historia, se sube.
hf_rc_attach_thread() {
  local sdir sid
  hf_rc_mirror_active 2>/dev/null || return 0
  sdir="$(_hf_rc_state_dir)"
  sid="$(cat "$sdir/session" 2>/dev/null)"
  [ -z "$sid" ] && return 0
  HF_RC_CONVERSATION_ID=""; HF_RC_CONVERSATION_TITLE=""; HF_RC_CONVERSATION_MSGS=""
  _hf_relay_register "$sid"
  if [ -n "${HF_RC_CONVERSATION_ID:-}" ]; then
    printf '%s' "$HF_RC_CONVERSATION_ID" > "$sdir/conversation"
    hf_dim "$(hf_t "cloud: Genius conversation ${HF_RC_CONVERSATION_TITLE:-CLI} (${HF_RC_CONVERSATION_ID})" "nube: conversación de Genius ${HF_RC_CONVERSATION_TITLE:-CLI} (${HF_RC_CONVERSATION_ID})")"
    if [ "${HF_RC_CONVERSATION_MSGS:-0}" = "0" ] && [ -n "${HF_REPL_SESSION:-}" ]; then
      ( _hf_rc_backfill "$sid" ) >/dev/null 2>&1 &
    fi
  fi
}

hf_rc_stop() {
  local sdir p sid
  sdir="$(_hf_rc_state_dir)"; p="$sdir/daemon.pid"
  if [ -f "$p" ]; then
    kill "$(cat "$p" 2>/dev/null)" 2>/dev/null
    sid="$(cat "$sdir/session" 2>/dev/null)"
    [ -n "$sid" ] && { _hf_relay_disconnect "$sid"; hf_metric rc_session_end "" session="$sid"; }
    rm -f "$p"
    unset HF_RC_SID
    hf_ok "$(hf_t "Mirroring stopped — the web now sees this terminal as disconnected." "Espejo detenido — la web ya ve esta terminal como desconectada.")"
  else
    hf_dim "$(hf_t "Remote Control is not mirroring." "Remote Control no está reflejando.")"
  fi
}

# El bucle del daemon: latido + poll + ejecutar + responder. Lo que pide la
# web se muestra también en la terminal del usuario (via /dev/tty).
_hf_rc_daemon() {
  local sid="$1" mid text beats=0
  trap '_hf_relay_disconnect "$sid"; exit 0' INT TERM
  while true; do
    beats=$((beats + 1))
    [ $((beats % 5)) -eq 1 ] && _hf_relay_heartbeat "$sid"
    local pending; pending="$(_hf_relay_poll "$sid")"
    if [ -n "$pending" ]; then
      mid="${pending%%$'\t'*}"; text="${pending#*$'\t'}"
      { printf '\n  \033[38;5;51m🌐 web ❯\033[0m %s\n' "$text"; } > /dev/tty 2>/dev/null || true
      # MISMA ejecución que el REPL, pero con salida PROGRESIVA: cada línea
      # nueva se manda a la web (/progress) y se pinta en la terminal en vivo.
      local outf runpid sent total new out
      outf=$(mktemp)
      if [[ "$text" == /* ]]; then
        ( hf_handle_slash "$text" ) > "$outf" 2>&1 &
      else
        ( HIVEFLOW_NO_SPINNER=1 hf_run_request "$text" ) > "$outf" 2>&1 &
      fi
      runpid=$!
      sent=0
      while kill -0 "$runpid" 2>/dev/null; do
        total=$(wc -l < "$outf" 2>/dev/null | tr -d ' ')
        if [ "${total:-0}" -gt "$sent" ]; then
          new="$(sed -n "$((sent + 1)),${total}p" "$outf")"
          printf '%s\n' "$new" > /dev/tty 2>/dev/null || true
          _hf_relay_progress "$mid" "$new"
          sent=$total
        fi
        sleep 1
      done
      wait "$runpid" 2>/dev/null
      total=$(wc -l < "$outf" 2>/dev/null | tr -d ' ')
      if [ "${total:-0}" -gt "$sent" ]; then
        new="$(sed -n "$((sent + 1)),${total}p" "$outf")"
        printf '%s\n' "$new" > /dev/tty 2>/dev/null || true
        _hf_relay_progress "$mid" "$new"
      fi
      # La web guarda texto plano: fuera códigos ANSI y retornos de carro
      out="$(sed -e $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' -e $'s/\r//g' "$outf")"
      rm -f "$outf"
      _hf_relay_respond "$sid" "$mid" "$out"
      # Confirmar y devolver el prompt para que el usuario sepa que puede escribir
      { printf '  \033[32m✓\033[0m %s\n\n%s' "$(hf_t "answered to the web" "respondido a la web")" "$(hf_prompt_label)"; } > /dev/tty 2>/dev/null || true
      hf_metric rc_message "" session="$sid"
    else
      sleep "${HF_RC_POLL:-2}"
    fi
  done
}

# Lista de sesiones del operador con su estado (lo que la web pinta en el modal
# y cuenta en el badge). "desconectada" si el último latido pasa de STALE_SECS.
hf_remote_sessions() {
  local stale="${HF_RC_STALE_SECS:-30}"
  case "$(hf_remote_relay)" in
    local:*)
      local dir; dir="$(_hf_relay_local_dir)"
      [ -d "$dir/sessions" ] || { echo "[]"; return; }
      local now; now="$(date +%s)"
      # Recalcula el estado por antigüedad del latido
      for f in "$dir/sessions"/*.json; do
        [ -f "$f" ] || continue
        jq -c --argjson now "$now" --argjson stale "$stale" '
          (.last_seen // 0) as $ls
          | if .status == "disconnected" then .status = "disconnected"
            elif ($now - $ls) > $stale then .status = "disconnected"
            else .status = "connected" end' "$f"
      done | jq -s '.' ;;
    http:*)
      local url; url="$(hf_remote_relay)"; url="${url#http:}"
      curl -s -m 10 "${url}/sessions" -H "Authorization: Bearer $(hf_auth_token)" 2>/dev/null || echo "[]" ;;
    *) echo "[]" ;;
  esac
}

hf_remote_cmd() {
  case "${1:-help}" in
    add)    shift; hf_remote_add "$@" ;;
    sessions) hf_remote_sessions | jq -r --arg c "$(hf_t "connected" "conectada")" --arg d "$(hf_t "disconnected" "desconectada")" \
                '.[] | "  " + (if .status=="connected" then "\u25cf" else "\u25cb" end) + " " + .session_id + "  " + (.host // "?") + ":" + (.cwd // "?") + "  " + (if .status=="connected" then $c else $d end)' ;;
    remove|rm) shift; hf_remote_remove "$@" ;;
    list|ls) hf_remote_list ;;
    relay)  shift
            if [ -z "$1" ]; then hf_dim "$(hf_t "current relay: $(hf_remote_relay || hf_t 'none' 'ninguno')" "relay actual: $(hf_remote_relay || echo 'ninguno')")"
            else
              local tmp; tmp="$(mktemp)"
              jq --arg r "$1" '.remote.relay=$r' "$HF_CONFIG_FILE" > "$tmp" && mv "$tmp" "$HF_CONFIG_FILE"
              hf_ok "Relay: $1"
            fi ;;
    control|serve) shift; hf_remote_control "${1:-}" ;;
    stop)   hf_rc_stop ;;
    run)    shift; hf_remote_run "$@" ;;
    status) hf_remote_status ;;
    logs)   shift; hf_remote_logs "$@" ;;
    *)
      echo ""
      if [ "$HF_LANG" = "es" ]; then
        echo "  🖥️  /remote — reflejar el CLI en web/app y correr tickets en nodos"
        echo ""
        echo -e "  ${HF_C_BOLD}Remote Control${HF_C_RESET} (pedirle cualquier cosa al CLI desde web/app):"
        echo "    /remote relay <local:dir|http:url>  Dónde se refleja la sesión"
        echo "    /remote control                     Reflejar ESTA sesión y escuchar"
        echo ""
        echo -e "  ${HF_C_BOLD}Nodos${HF_C_RESET} (correr tickets en otra máquina):"
        echo "    /remote add <nombre> [local|user@host]  Registrar un nodo"
        echo "    /remote list                     Nodos y su estado"
        echo "    /remote run <ticket> [nodo]      Despachar un ticket a un nodo"
        echo "    /remote status · logs <run-id>   Runs en curso y sus logs"
        echo ""
        hf_dim "Remote Control refleja tu sesión (solo saliente, autenticado como tú)."
        
      else
        echo "  🖥️  /remote — mirror the CLI in web/app and run tickets on nodes"
        echo ""
        echo -e "  ${HF_C_BOLD}Remote Control${HF_C_RESET} (ask the CLI anything from web/app):"
        echo "    /remote relay <local:dir|http:url>  Where the session is mirrored"
        echo "    /remote control                     Mirror THIS session and listen"
        echo ""
        echo -e "  ${HF_C_BOLD}Nodes${HF_C_RESET} (run tickets on another machine):"
        echo "    /remote add <name> [local|user@host]  Register a node"
        echo "    /remote list                     Nodes and their status"
        echo "    /remote run <ticket> [node]      Dispatch a ticket to a node"
        echo "    /remote status · logs <run-id>   Running runs and their logs"
        echo ""
        hf_dim "Remote Control mirrors your session (outbound-only, authenticated as you)."
        hf_dim "See REMOTE.md for the relay contract the web implements."
      fi
      echo ""
      ;;
  esac
}
