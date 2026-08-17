#!/bin/bash

# ==========================================
# MÓDULO SWARM ENROLL - swarm_enroll.sh
# ==========================================
# Auto-registro de hijos contra el parent.
# Protocolo via Redis (broker en el parent):
#   - Child:  LPUSH asis:enroll:queue <json>
#   - Parent: BRPOP asis:enroll:queue (listener) o batch con `enroll process`
#   - Parent responde en asis:enroll:ack:<name>  con ok/err

SWARM_ENROLL_QUEUE="asis:enroll:queue"

type hf_t >/dev/null 2>&1 || hf_t() { if [ "${HF_LANG:-en}" = "es" ] && [ -n "${2:-}" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

swarm_enroll_help() {
    if [ "${HF_LANG:-en}" = "es" ]; then
    cat <<EOF
${SWARM_C_BOLD}/swarm enroll${SWARM_C_RESET}  -  enrolamiento padre/hijo

  register         (child)  Enviar solicitud de registro al parent
  list             (parent) Ver solicitudes pendientes
  process          (parent) Procesar TODAS las pendientes (acepta automáticamente)
  listen           (parent) Listener interactivo (BRPOP, bloquea)
  status           Mostrar estado de enrolamiento de este device
EOF
    else
    cat <<EOF
${SWARM_C_BOLD}/swarm enroll${SWARM_C_RESET}  -  parent/child enrollment

  register         (child)  Send a registration request to the parent
  list             (parent) Show pending requests
  process          (parent) Process ALL pending (accepts automatically)
  listen           (parent) Interactive listener (BRPOP, blocks)
  status           Show this device's enrollment status
EOF
    fi
}

swarm_enroll_register() {
    if [ ! -f "$SWARM_ROLE_FILE" ]; then
        swarm_error "$(hf_t "This device has no role. Run '/swarm init --role child ...' first." "Este device no tiene rol. Ejecuta '/swarm init --role child ...' primero.")"
        return 1
    fi
    local role
    role="$(jq -r '.role' "$SWARM_ROLE_FILE")"
    if [ "$role" != "child" ]; then
        swarm_error "$(hf_t "Only a 'child' device can register. Current role: $role" "Solo un device 'child' puede registrarse. Rol actual: $role")"
        return 1
    fi
    local parent_ip name ip token
    parent_ip="$(jq -r '.parent_ip' "$SWARM_ROLE_FILE")"
    name="$(jq -r '.name'      "$SWARM_ROLE_FILE")"
    ip="$(jq -r '.ip'          "$SWARM_ROLE_FILE")"
    token="$(jq -r '.token'    "$SWARM_ROLE_FILE")"

    local payload
    payload="$(jq -c '{
        name, ip, hostname, token, capabilities,
        enrolled_at: (now|todate)
    }' "$SWARM_ROLE_FILE")"

    swarm_info "$(hf_t "Sending enrollment: $name → $parent_ip" "Enviando enrolamiento: $name → $parent_ip")"
    if ! redis-cli -h "$parent_ip" LPUSH "$SWARM_ENROLL_QUEUE" "$payload" >/dev/null 2>&1; then
        swarm_error "$(hf_t "LPUSH to $parent_ip failed. Check connectivity and Redis." "Falló LPUSH a $parent_ip. Verifica conectividad y Redis.")"
        return 1
    fi

    # Esperar ack (timeout 10s)
    local ack_key="asis:enroll:ack:${name}"
    swarm_info "$(hf_t "Waiting for confirmation from the parent..." "Esperando confirmación del parent...")"
    local ack
    ack="$(redis-cli -h "$parent_ip" BRPOP "$ack_key" 10 2>/dev/null | tail -1)"
    if [ -z "$ack" ]; then
        swarm_warn "$(hf_t "No ack within 10s. The parent may not have a listener running." "No llegó ack en 10s. El parent puede no tener un listener corriendo.")"
        echo "$(hf_t "Run on the parent: /swarm enroll process" "Ejecuta en el parent: /swarm enroll process")"
        return 0
    fi
    local status
    status="$(echo "$ack" | jq -r '.status' 2>/dev/null)"
    if [ "$status" = "ok" ]; then
        swarm_ok "$(hf_t "Parent accepted the enrollment." "Parent aceptó el enrolamiento.")"
        local tmp
        tmp="$(mktemp)"
        jq '.enrolled = true | .enrolled_at = (now|todate)' "$SWARM_ROLE_FILE" > "$tmp" && mv "$tmp" "$SWARM_ROLE_FILE"
    else
        swarm_error "$(hf_t "Parent rejected the enrollment: $(echo "$ack" | jq -r '.reason')" "Parent rechazó el enrolamiento: $(echo "$ack" | jq -r '.reason')")"
        return 1
    fi
}

# Parent: valida token y agrega a devices.json
_swarm_enroll_accept_payload() {
    local payload="$1"
    local parent_token expected_token
    parent_token="$(jq -r '.token' "$SWARM_ROLE_FILE")"
    expected_token="$(echo "$payload" | jq -r '.token')"
    local name ip
    name="$(echo "$payload" | jq -r '.name')"
    ip="$(echo "$payload"   | jq -r '.ip')"

    if [ "$expected_token" != "$parent_token" ]; then
        swarm_warn "$(hf_t "Rejected '$name': invalid token." "Rechazado '$name': token inválido.")"
        redis-cli -h 127.0.0.1 LPUSH "asis:enroll:ack:${name}" \
            "$(jq -nc --arg r "invalid token" '{status:"err", reason:$r}')" >/dev/null
        return 1
    fi

    local type
    if echo "$payload" | jq -r '.capabilities.arch' | grep -qi 'aarch64\|arm'; then
        type="rpi"
    else
        type="other"
    fi

    # Si ya existe, actualizar ip/capabilities; si no, crear
    local tmp
    tmp="$(mktemp)"
    if swarm_device_exists "$name"; then
        jq --arg n "$name" --arg ip "$ip" --arg type "$type" --argjson caps "$(echo "$payload" | jq '.capabilities')" \
            '(.devices[] | select(.name==$n) | .ip) = $ip
           | (.devices[] | select(.name==$n) | .type) = $type
           | (.devices[] | select(.name==$n) | .capabilities) = $caps
           | (.devices[] | select(.name==$n) | .status) = "online"' \
            "$SWARM_DEVICES_FILE" > "$tmp" && mv "$tmp" "$SWARM_DEVICES_FILE"
        swarm_ok "$(hf_t "Updated child '$name' ($ip)" "Actualizado child '$name' ($ip)")"
    else
        jq --arg n "$name" --arg ip "$ip" --arg type "$type" --argjson caps "$(echo "$payload" | jq '.capabilities')" \
            '.devices += [{
                name: $n,
                ip:   $ip,
                type: $type,
                user: "pi",
                port: 22,
                status: "online",
                capabilities: $caps,
                enrolled: true,
                added_at: (now|todate)
            }]' "$SWARM_DEVICES_FILE" > "$tmp" && mv "$tmp" "$SWARM_DEVICES_FILE"
        swarm_ok "$(hf_t "Enrolled new child '$name' ($ip, $type)" "Enrolado nuevo child '$name' ($ip, $type)")"
    fi
    # Ack al hijo
    redis-cli -h 127.0.0.1 LPUSH "asis:enroll:ack:${name}" \
        "$(jq -nc '{status:"ok"}')" >/dev/null
}

swarm_enroll_list() {
    local count
    count="$(redis-cli -h 127.0.0.1 LLEN "$SWARM_ENROLL_QUEUE" 2>/dev/null)"
    if [ -z "$count" ] || [ "$count" = "0" ]; then
        swarm_info "$(hf_t "No pending enrollment requests." "No hay solicitudes de enrolamiento pendientes.")"
        return 0
    fi
    swarm_info "$(hf_t "$count pending requests:" "$count solicitudes pendientes:")"
    redis-cli -h 127.0.0.1 LRANGE "$SWARM_ENROLL_QUEUE" 0 -1 | while read -r p; do
        echo "$p" | jq -r '"  - \(.name) @ \(.ip) (\(.capabilities.arch))"'
    done
}

swarm_enroll_process() {
    if [ "$(swarm_role_get)" != "parent" ]; then
        swarm_error "$(hf_t "This command only runs on the parent." "Este comando solo corre en el parent.")"
        return 1
    fi
    local count
    count="$(redis-cli -h 127.0.0.1 LLEN "$SWARM_ENROLL_QUEUE" 2>/dev/null)"
    [ -z "$count" ] && count=0
    if [ "$count" = "0" ]; then
        swarm_info "$(hf_t "No pending enrollments." "No hay enrolamientos pendientes.")"
        return 0
    fi
    swarm_info "$(hf_t "Processing $count enrollment(s)..." "Procesando $count enrolamiento(s)...")"
    while true; do
        local payload
        payload="$(redis-cli -h 127.0.0.1 RPOP "$SWARM_ENROLL_QUEUE")"
        [ -z "$payload" ] && break
        _swarm_enroll_accept_payload "$payload"
    done
}

swarm_enroll_listen() {
    if [ "$(swarm_role_get)" != "parent" ]; then
        swarm_error "$(hf_t "Only the parent can run 'enroll listen'." "Solo el parent puede correr 'enroll listen'.")"
        return 1
    fi
    swarm_info "$(hf_t "Listening for enrollments on $SWARM_ENROLL_QUEUE (Ctrl+C to exit)..." "Escuchando enrolamientos en $SWARM_ENROLL_QUEUE (Ctrl+C para salir)...")"
    while true; do
        local line
        line="$(redis-cli -h 127.0.0.1 BRPOP "$SWARM_ENROLL_QUEUE" 0 2>/dev/null)"
        local payload
        payload="$(echo "$line" | tail -1)"
        [ -z "$payload" ] && continue
        _swarm_enroll_accept_payload "$payload"
    done
}

swarm_enroll_status() {
    if [ ! -f "$SWARM_ROLE_FILE" ]; then
        swarm_warn "$(hf_t "No role configured." "Sin rol configurado.")"
        return 1
    fi
    jq '{role, name, ip, parent_ip, enrolled, enrolled_at}' "$SWARM_ROLE_FILE"
}

swarm_enroll_cmd() {
    local sub="$1"; shift || true
    case "$sub" in
        register) swarm_enroll_register ;;
        list)     swarm_enroll_list ;;
        process) swarm_enroll_process ;;
        listen)   swarm_enroll_listen ;;
        status)   swarm_enroll_status ;;
        ""|help|-h|--help) swarm_enroll_help ;;
        *) swarm_error "$(hf_t "Unknown subcommand: $sub" "Subcomando desconocido: $sub")"; swarm_enroll_help; return 1 ;;
    esac
}
