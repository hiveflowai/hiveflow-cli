#!/bin/bash

# ==========================================
# MÓDULO SWARM ROLE - swarm_role.sh
# ==========================================
# Gestiona el rol de este dispositivo dentro del swarm:
#   - parent: orquestador con Redis broker local
#   - child:  worker que se conecta al parent vía Redis
# Guarda configuración en $SWARM_DIR/role.json

SWARM_ROLE_FILE="$SWARM_DIR/role.json"

type hf_t >/dev/null 2>&1 || hf_t() { if [ "${HF_LANG:-en}" = "es" ] && [ -n "${2:-}" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

swarm_role_help() {
    if [ "${HF_LANG:-en}" = "es" ]; then
    cat <<EOF
${SWARM_C_BOLD}/swarm init${SWARM_C_RESET}  -  inicializar rol del dispositivo

  /swarm init --role parent [--ip <ip>]
       Configura este dispositivo como ORQUESTADOR.
       Redis broker debe estar en este host.

  /swarm init --role child --parent <ip> --token <t> [--name <n>]
       Configura este dispositivo como WORKER.
       Se auto-registra en el parent.

  /swarm role          Muestra el rol actual
  /swarm role reset    Borra la configuración de rol
EOF
    else
    cat <<EOF
${SWARM_C_BOLD}/swarm init${SWARM_C_RESET}  -  initialize the device's role

  /swarm init --role parent [--ip <ip>]
       Configure this device as the ORCHESTRATOR.
       The Redis broker must be on this host.

  /swarm init --role child --parent <ip> --token <t> [--name <n>]
       Configure this device as a WORKER.
       It auto-registers with the parent.

  /swarm role          Show the current role
  /swarm role reset    Delete the role configuration
EOF
    fi
}

swarm_role_get() {
    [ ! -f "$SWARM_ROLE_FILE" ] && { echo ""; return; }
    jq -r '.role // empty' "$SWARM_ROLE_FILE" 2>/dev/null
}

swarm_role_show() {
    if [ ! -f "$SWARM_ROLE_FILE" ] || [ -z "$(swarm_role_get)" ]; then
        swarm_warn "$(hf_t "This device has no role configured." "Este dispositivo no tiene rol configurado.")"
        echo "$(hf_t "Run: /swarm init --role parent | child" "Ejecuta: /swarm init --role parent | child")"
        return 1
    fi
    echo -e "${SWARM_C_BOLD}$(hf_t "This device's role:" "Rol de este dispositivo:")${SWARM_C_RESET}"
    jq . "$SWARM_ROLE_FILE"
}

swarm_role_reset() {
    if [ -f "$SWARM_ROLE_FILE" ]; then
        rm "$SWARM_ROLE_FILE"
        swarm_ok "$(hf_t "Role configuration deleted." "Configuración de rol eliminada.")"
    fi
}

swarm_role_detect_ip() {
    # Intenta detectar la IP principal del host en la red del swarm (192.168.50.x)
    local ip
    ip="$(ip -4 addr show 2>/dev/null | grep -oE '192\.168\.50\.[0-9]+' | head -1)"
    if [ -z "$ip" ]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    echo "$ip"
}

swarm_role_generate_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        head -c 16 /dev/urandom | xxd -p | tr -d '\n'
    fi
}

swarm_role_init_parent() {
    local ip="$1"
    [ -z "$ip" ] && ip="$(swarm_role_detect_ip)"
    local token
    if [ -f "$SWARM_ROLE_FILE" ] && [ "$(swarm_role_get)" = "parent" ]; then
        token="$(jq -r '.token' "$SWARM_ROLE_FILE")"
        swarm_info "$(hf_t "Parent already configured, reusing token." "Parent ya configurado, reusando token.")"
    else
        token="$(swarm_role_generate_token)"
    fi
    local hostname
    hostname="$(hostname)"
    jq -n --arg role parent \
          --arg ip "$ip" \
          --arg token "$token" \
          --arg host "$hostname" \
        '{
            role: $role,
            ip: $ip,
            hostname: $host,
            redis_host: $ip,
            token: $token,
            initialized_at: (now|todate)
        }' > "$SWARM_ROLE_FILE"
    swarm_ok "$(hf_t "Device configured as ${SWARM_C_BOLD}PARENT${SWARM_C_RESET}" "Dispositivo configurado como ${SWARM_C_BOLD}PARENT${SWARM_C_RESET}")"
    echo
    echo -e "${SWARM_C_BOLD}$(hf_t "Enrollment data (share it with the children):" "Datos de enrolamiento (compártelos con los hijos):")${SWARM_C_RESET}"
    echo "  $(hf_t "Parent IP:      $ip" "IP del parent:  $ip")"
    echo "  Token:          $token"
    echo
    echo "$(hf_t "On each child device, run:" "En cada dispositivo hijo, ejecuta:")"
    echo -e "  ${SWARM_C_CYAN}/swarm init --role child --parent $ip --token $token${SWARM_C_RESET}"
    echo
    # Verificar Redis
    if ! command -v redis-server >/dev/null 2>&1; then
        swarm_warn "$(hf_t "Redis is NOT installed on this parent. Install: sudo apt-get install -y redis-server redis-tools" "Redis NO está instalado en este parent. Instala: sudo apt-get install -y redis-server redis-tools")"
    else
        if ! grep -qE "^bind .*${ip}" /etc/redis/redis.conf 2>/dev/null; then
            swarm_warn "$(hf_t "Redis is not configured to accept connections from the swarm network." "Redis no está configurado para aceptar conexiones desde la red del swarm.")"
            echo "$(hf_t "In /etc/redis/redis.conf make sure you have:" "En /etc/redis/redis.conf asegúrate de tener:")"
            echo "  bind 127.0.0.1 $ip"
            echo "  protected-mode no"
            echo "$(hf_t "Then: sudo systemctl restart redis-server" "Luego: sudo systemctl restart redis-server")"
        else
            swarm_ok "$(hf_t "Redis configured for the swarm network." "Redis configurado para la red del swarm.")"
        fi
    fi
}

swarm_role_init_child() {
    local parent_ip="" token="" name=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --parent) parent_ip="$2"; shift 2 ;;
            --token)  token="$2"; shift 2 ;;
            --name)   name="$2"; shift 2 ;;
            *) swarm_error "$(hf_t "Unknown argument: $1" "Argumento desconocido: $1")"; return 1 ;;
        esac
    done
    if [ -z "$parent_ip" ] || [ -z "$token" ]; then
        swarm_error "$(hf_t "Usage: /swarm init --role child --parent <ip> --token <t> [--name <n>]" "Uso: /swarm init --role child --parent <ip> --token <t> [--name <n>]")"
        return 1
    fi
    [ -z "$name" ] && name="$(hostname)"
    local my_ip
    my_ip="$(swarm_role_detect_ip)"

    # Probar conectividad Redis con el parent
    if ! command -v redis-cli >/dev/null 2>&1; then
        swarm_error "$(hf_t "redis-cli is not installed. Install it: sudo apt-get install -y redis-tools" "redis-cli no está instalado. Instala: sudo apt-get install -y redis-tools")"
        return 1
    fi
    if ! redis-cli -h "$parent_ip" -t 3 ping 2>/dev/null | grep -q PONG; then
        swarm_error "$(hf_t "Cannot reach Redis at $parent_ip:6379" "No se puede alcanzar Redis en $parent_ip:6379")"
        echo "$(hf_t "Check that the parent is powered on and Redis accepts connections." "Verifica que el parent esté encendido y Redis acepte conexiones.")"
        return 1
    fi

    # Detectar capacidades
    local has_claude has_tmux has_node
    has_claude="$(command -v claude >/dev/null && echo true || echo false)"
    has_tmux="$(command -v tmux   >/dev/null && echo true || echo false)"
    has_node="$(command -v node   >/dev/null && echo true || echo false)"
    # Lista de CLIs de coding disponibles (no solo claude)
    local detected_tools=()
    for _t in claude gemini codex aider; do
        command -v "$_t" >/dev/null 2>&1 && detected_tools+=("$_t")
    done
    local tools_json="[]"
    if [ ${#detected_tools[@]} -gt 0 ]; then
        tools_json="$(printf '%s\n' "${detected_tools[@]}" | jq -R . | jq -s -c .)"
    fi
    local kernel arch
    kernel="$(uname -s)"
    arch="$(uname -m)"

    # Guardar rol local
    jq -n --arg name "$name" \
          --arg parent "$parent_ip" \
          --arg ip "$my_ip" \
          --arg token "$token" \
          --arg host "$(hostname)" \
          --arg kernel "$kernel" \
          --arg arch "$arch" \
          --argjson has_claude "$has_claude" \
          --argjson has_tmux "$has_tmux" \
          --argjson has_node "$has_node" \
          --argjson tools "$tools_json" \
        '{
            role: "child",
            name: $name,
            ip: $ip,
            hostname: $host,
            parent_ip: $parent,
            redis_host: $parent,
            token: $token,
            capabilities: {
                claude: $has_claude,
                tools:  $tools,
                tmux:   $has_tmux,
                node:   $has_node,
                kernel: $kernel,
                arch:   $arch
            },
            initialized_at: (now|todate),
            enrolled: false
        }' > "$SWARM_ROLE_FILE"
    swarm_ok "$(hf_t "Device configured as ${SWARM_C_BOLD}CHILD${SWARM_C_RESET} '${name}'" "Dispositivo configurado como ${SWARM_C_BOLD}CHILD${SWARM_C_RESET} '${name}'")"
    swarm_info "$(hf_t "Sending enrollment to the parent ($parent_ip)..." "Enviando enrolamiento al parent ($parent_ip)...")"
    swarm_enroll_register
}

swarm_role_init() {
    local role=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --role) role="$2"; shift 2 ;;
            *) break ;;
        esac
    done

    case "$role" in
        parent) swarm_role_init_parent "$@" ;;
        child)  swarm_role_init_child "$@" ;;
        "")     swarm_role_help ;;
        *)      swarm_error "$(hf_t "Unknown role: $role (use parent|child)" "Rol desconocido: $role (usa parent|child)")"; return 1 ;;
    esac
}

swarm_role_cmd() {
    local sub="$1"; shift || true
    case "$sub" in
        ""|show) swarm_role_show ;;
        reset)   swarm_role_reset ;;
        *)       swarm_error "$(hf_t "Unknown subcommand: $sub" "Subcomando desconocido: $sub")"; swarm_role_help; return 1 ;;
    esac
}
