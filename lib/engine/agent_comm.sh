#!/bin/bash

# ==========================================
# MÓDULO AGENT COMM - agent_comm.sh
# ==========================================
# Comunicación entre agentes vía Redis (corriendo en la AGX como broker).
# Protocolo simple:
#   - Canal por proyecto:     asis:<project>:events
#   - Inbox por agente:       asis:<project>:inbox:<agent>
#   - Mensajes JSON: {from, to, type, payload, ts}

type hf_t >/dev/null 2>&1 || hf_t() { if [ "${HF_LANG:-en}" = "es" ] && [ -n "${2:-}" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

swarm_comm_help() {
    if [ "${HF_LANG:-en}" = "es" ]; then
    cat <<EOF
${SWARM_C_BOLD}/swarm msg${SWARM_C_RESET}  -  comunicación entre agentes

  setup                                   Verificar/instalar Redis en AGX
  send <project> <from> <to> "<texto>"    Enviar mensaje (to='*' = broadcast)
  read <project> <agent>                  Leer inbox del agente
  listen <project> <agent>                Seguir inbox en vivo (bloquea)
  bus <project>                           Ver el canal de eventos del proyecto
EOF
    else
    cat <<EOF
${SWARM_C_BOLD}/swarm msg${SWARM_C_RESET}  -  inter-agent communication

  setup                                   Verify/install Redis on the AGX
  send <project> <from> <to> "<text>"     Send a message (to='*' = broadcast)
  read <project> <agent>                  Read the agent's inbox
  listen <project> <agent>                Follow inbox live (blocks)
  bus <project>                           Watch the project's event channel
EOF
    fi
}

swarm_comm_broker_host() {
    # IP de la AGX en la red del switch (gateway del swarm)
    echo "192.168.50.1"
}

swarm_comm_require_redis_cli() {
    if ! command -v redis-cli >/dev/null 2>&1; then
        swarm_error "$(hf_t "redis-cli is not installed. Install it: sudo apt-get install -y redis-tools" "redis-cli no está instalado. Instala: sudo apt-get install -y redis-tools")"
        return 1
    fi
    return 0
}

swarm_comm_setup() {
    swarm_info "$(hf_t "Setting up Redis broker on the AGX..." "Configurando Redis broker en la AGX...")"
    if ! command -v redis-server >/dev/null 2>&1; then
        swarm_warn "$(hf_t "redis-server is not installed." "redis-server no está instalado.")"
        echo "$(hf_t "Run on the AGX: sudo apt-get install -y redis-server redis-tools" "Ejecuta en la AGX: sudo apt-get install -y redis-server redis-tools")"
        return 1
    fi
    # Verificar que Redis escuche en 192.168.50.1 para que las Raspberries lo alcancen
    local bind_ok
    bind_ok="$(grep -E '^bind .*192\.168\.50\.1' /etc/redis/redis.conf 2>/dev/null)"
    if [ -z "$bind_ok" ]; then
        swarm_warn "$(hf_t "Redis is NOT configured to listen on 192.168.50.1" "Redis NO está configurado para escuchar en 192.168.50.1")"
        echo "$(hf_t "Edit /etc/redis/redis.conf:" "Edita /etc/redis/redis.conf:")"
        echo "  bind 127.0.0.1 192.168.50.1"
        echo "  protected-mode no"
        echo "$(hf_t "Then: sudo systemctl restart redis-server" "Luego: sudo systemctl restart redis-server")"
    else
        swarm_ok "$(hf_t "Redis configured for the swarm network." "Redis configurado para la red del swarm.")"
    fi
    redis-cli -h "$(swarm_comm_broker_host)" ping 2>/dev/null \
        && swarm_ok "$(hf_t "Redis broker responding at $(swarm_comm_broker_host)" "Broker Redis responde en $(swarm_comm_broker_host)")" \
        || swarm_warn "$(hf_t "Broker not responding yet." "Broker no responde aún.")"
}

swarm_comm_send() {
    local project="$1" from="$2" to="$3"; shift 3
    local text="$*"
    swarm_comm_require_redis_cli || return 1
    if [ -z "$project" ] || [ -z "$from" ] || [ -z "$to" ] || [ -z "$text" ]; then
        swarm_error "$(hf_t "Usage: /swarm msg send <project> <from> <to> \"<text>\"" "Uso: /swarm msg send <project> <from> <to> \"<texto>\"")"
        return 1
    fi
    local host
    host="$(swarm_comm_broker_host)"
    local msg
    msg="$(jq -nc --arg p "$project" --arg f "$from" --arg t "$to" --arg x "$text" \
        '{project:$p, from:$f, to:$t, type:"text", payload:$x, ts:(now|todate)}')"
    # Evento en canal del proyecto
    redis-cli -h "$host" PUBLISH "asis:${project}:events" "$msg" >/dev/null
    # Inbox (si es broadcast, saltamos inbox individual)
    if [ "$to" != "*" ]; then
        redis-cli -h "$host" LPUSH "asis:${project}:inbox:${to}" "$msg" >/dev/null
        redis-cli -h "$host" LTRIM "asis:${project}:inbox:${to}" 0 999 >/dev/null
    fi
    swarm_ok "$(hf_t "Message sent from '$from' to '$to' (project $project)." "Mensaje enviado de '$from' a '$to' (proyecto $project).")"
}

swarm_comm_read() {
    local project="$1" agent="$2"
    swarm_comm_require_redis_cli || return 1
    local host
    host="$(swarm_comm_broker_host)"
    local key="asis:${project}:inbox:${agent}"
    local count
    count="$(redis-cli -h "$host" LLEN "$key")"
    if [ "$count" = "0" ]; then
        swarm_info "$(hf_t "Inbox for '$agent' is empty." "Inbox de '$agent' vacío.")"
        return 0
    fi
    swarm_info "$(hf_t "Inbox for '$agent' ($count messages):" "Inbox de '$agent' ($count mensajes):")"
    redis-cli -h "$host" LRANGE "$key" 0 -1 | while read -r line; do
        echo "  $line" | jq -r '"  [\(.ts)] \(.from) → \(.to): \(.payload)"' 2>/dev/null || echo "  $line"
    done
}

swarm_comm_listen() {
    local project="$1" agent="$2"
    swarm_comm_require_redis_cli || return 1
    local host
    host="$(swarm_comm_broker_host)"
    swarm_info "$(hf_t "Listening to inbox for '$agent' (Ctrl+C to exit)..." "Escuchando inbox de '$agent' (Ctrl+C para salir)...")"
    while true; do
        local msg
        msg="$(redis-cli -h "$host" BRPOP "asis:${project}:inbox:${agent}" 0 2>/dev/null | tail -1)"
        [ -n "$msg" ] && echo "$msg" | jq -r '"[\(.ts)] \(.from) → \(.to): \(.payload)"' 2>/dev/null
    done
}

swarm_comm_bus() {
    local project="$1"
    swarm_comm_require_redis_cli || return 1
    local host
    host="$(swarm_comm_broker_host)"
    swarm_info "$(hf_t "Channel 'asis:${project}:events' (Ctrl+C to exit)..." "Canal 'asis:${project}:events' (Ctrl+C para salir)...")"
    redis-cli -h "$host" SUBSCRIBE "asis:${project}:events"
}

swarm_comm_cmd() {
    local sub="$1"; shift
    case "$sub" in
        setup)  swarm_comm_setup ;;
        send)   swarm_comm_send "$@" ;;
        read)   swarm_comm_read "$@" ;;
        listen) swarm_comm_listen "$@" ;;
        bus)    swarm_comm_bus "$@" ;;
        ""|help|-h|--help) swarm_comm_help ;;
        *) swarm_error "$(hf_t "Unknown subcommand: $sub" "Subcomando desconocido: $sub")"; swarm_comm_help; return 1 ;;
    esac
}
