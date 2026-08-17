#!/bin/bash

# ==========================================
# MÓDULO SWARM ROUTER - swarm_router.sh
# ==========================================
# Punto de entrada para el subcomando `/swarm ...`.
# Enruta a los módulos: device, project, agent, worktree, msg y control.

type hf_t >/dev/null 2>&1 || hf_t() { if [ "${HF_LANG:-en}" = "es" ] && [ -n "${2:-}" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

swarm_help() {
    if [ "${HF_LANG:-en}" = "es" ]; then
    cat <<EOF
${SWARM_C_BOLD}/swarm${SWARM_C_RESET}  -  orquestación distribuida de agentes Claude
        (arquitectura padre/hijo con enrolamiento automático)

${SWARM_C_BOLD}INICIALIZACIÓN${SWARM_C_RESET}
  /swarm wizard              ⭐ Configuración interactiva (recomendado)
  /swarm init --role parent [--ip <ip>]
  /swarm init --role child  --parent <ip> --token <t> [--name <n>]
  /swarm role                Ver rol de este device
  /swarm doctor              Diagnóstico

${SWARM_C_BOLD}ENROLAMIENTO${SWARM_C_RESET}  (automático al init child)
  /swarm enroll list         (parent) Solicitudes pendientes
  /swarm enroll process      (parent) Acepta todas las pendientes
  /swarm enroll listen       (parent) Listener en vivo
  /swarm enroll register     (child)  Reenviar registro

${SWARM_C_BOLD}DAEMON${SWARM_C_RESET}  (en cada child)
  /swarm daemon start [--foreground]
  /swarm daemon stop
  /swarm daemon status
  /swarm daemon logs [--follow]

${SWARM_C_BOLD}CREACIÓN DE PROYECTOS${SWARM_C_RESET}
  /swarm create          ⭐ Asistente interactivo (recomendado)
                              Pregunta contexto, genera PRDs, crea estructura

${SWARM_C_BOLD}GESTIÓN${SWARM_C_RESET}  (en el parent)
  /swarm device  ...     Inventario de dispositivos
  /swarm project ...     Proyectos y repos
  /swarm agent   ...     Asignar agentes a devices
  /swarm worktree ...    git worktrees

${SWARM_C_BOLD}EJECUCIÓN${SWARM_C_RESET}  (en el parent)
  /swarm start <project> [agent]
  /swarm stop  <project> [agent]
  /swarm status [project]
  /swarm logs <project> <agent> [--follow]
  /swarm attach <project> <agent>
  /swarm run <project> <agent> "<cmd>"

${SWARM_C_BOLD}AI CLI TOOLS${SWARM_C_RESET}
  /agents list                   CLIs disponibles y estado
  /agents install <name>         Instalar un CLI (claude,gemini,codex,aider)
  /agents test [name|all]        Health check
  /agents select <task-type>     Ver routing para un tipo de tarea
  /agents set <proj> <agent> <t> Asignar tool a un agente

${SWARM_C_BOLD}COMUNICACIÓN${SWARM_C_RESET}
  /swarm msg ...         Mensajes entre agentes

${SWARM_C_BOLD}DASHBOARD${SWARM_C_RESET}  (monitor en tiempo real tipo htop)
  /dashboard [--mode all|devices|agents|redis|logs] [--refresh N]
  Controles: q=quit, d=devices, a=agents, r=redis, l=logs, v=all, +/-=speed

${SWARM_C_BOLD}RALPH (EJECUCIÓN AUTÓNOMA)${SWARM_C_RESET}
  /ralph start <project> <agent> --prd <prd.json> [--iterations N]
  /ralph stop <project> <agent>
  /ralph status <project> <agent>
  /ralph logs <project> <agent> [--follow]
  /ralph progress <project> <agent>
  /ralph validate <project> <agent>

  Ejecuta Claude Code repetidamente hasta completar todos los items del PRD.
  Usa skills: /prd → genera PRD | /ralph → convierte a JSON

${SWARM_C_BOLD}PRD GENERATOR${SWARM_C_RESET}  (generar PRDs desde templates)
  /prd bootstrap <project> --type <nodejs|python|go|rust>
  /prd feature <project> <name> --description "<desc>"
  /prd merger <project> [--branches feat/a,feat/b,...]

${SWARM_C_BOLD}BOOTSTRAP AUTOMATIZADO${SWARM_C_RESET}  (recomendado)

En el PARENT (una sola línea):
  curl -fsSL https://raw.githubusercontent.com/johnolven/asis-coder/main/bootstrap-parent.sh | bash

Luego, desde el PARENT, desplegar en todas las Raspberries (una línea):
  /swarm bootstrap children 192.168.50.10 192.168.50.11 192.168.50.12 192.168.50.13 --user pi

Verificar:
  /swarm device list
  /swarm project create mi-app --repo https://github.com/me/mi-app.git
  /swarm agent add mi-app auth --device rb001 --branch feat/auth --task "..."
  /swarm start mi-app

${SWARM_C_BOLD}BOOTSTRAP MANUAL${SWARM_C_RESET}  (por si no tienes SSH configurado)

En cada CHILD (desde la propia Raspberry):
  curl -fsSL https://raw.githubusercontent.com/johnolven/asis-coder/main/bootstrap-child.sh \\
      | bash -s -- --parent <parent-ip> --token <token>
EOF
    else
    cat <<EOF
${SWARM_C_BOLD}/swarm${SWARM_C_RESET}  -  distributed orchestration of Claude agents
        (parent/child architecture with automatic enrollment)

${SWARM_C_BOLD}INITIALIZATION${SWARM_C_RESET}
  /swarm wizard              ⭐ Interactive setup (recommended)
  /swarm init --role parent [--ip <ip>]
  /swarm init --role child  --parent <ip> --token <t> [--name <n>]
  /swarm role                Show this device's role
  /swarm doctor              Diagnostics

${SWARM_C_BOLD}ENROLLMENT${SWARM_C_RESET}  (automatic on child init)
  /swarm enroll list         (parent) Pending requests
  /swarm enroll process      (parent) Accept all pending
  /swarm enroll listen       (parent) Live listener
  /swarm enroll register     (child)  Resend registration

${SWARM_C_BOLD}DAEMON${SWARM_C_RESET}  (on each child)
  /swarm daemon start [--foreground]
  /swarm daemon stop
  /swarm daemon status
  /swarm daemon logs [--follow]

${SWARM_C_BOLD}PROJECT CREATION${SWARM_C_RESET}
  /swarm create          ⭐ Interactive assistant (recommended)
                              Asks for context, generates PRDs, creates structure

${SWARM_C_BOLD}MANAGEMENT${SWARM_C_RESET}  (on the parent)
  /swarm device  ...     Device inventory
  /swarm project ...     Projects and repos
  /swarm agent   ...     Assign agents to devices
  /swarm worktree ...    git worktrees

${SWARM_C_BOLD}EXECUTION${SWARM_C_RESET}  (on the parent)
  /swarm start <project> [agent]
  /swarm stop  <project> [agent]
  /swarm status [project]
  /swarm logs <project> <agent> [--follow]
  /swarm attach <project> <agent>
  /swarm run <project> <agent> "<cmd>"

${SWARM_C_BOLD}AI CLI TOOLS${SWARM_C_RESET}
  /agents list                   Available CLIs and status
  /agents install <name>         Install a CLI (claude,gemini,codex,aider)
  /agents test [name|all]        Health check
  /agents select <task-type>     Show routing for a task type
  /agents set <proj> <agent> <t> Assign a tool to an agent

${SWARM_C_BOLD}COMMUNICATION${SWARM_C_RESET}
  /swarm msg ...         Messages between agents

${SWARM_C_BOLD}DASHBOARD${SWARM_C_RESET}  (htop-style real-time monitor)
  /dashboard [--mode all|devices|agents|redis|logs] [--refresh N]
  Controls: q=quit, d=devices, a=agents, r=redis, l=logs, v=all, +/-=speed

${SWARM_C_BOLD}RALPH (AUTONOMOUS EXECUTION)${SWARM_C_RESET}
  /ralph start <project> <agent> --prd <prd.json> [--iterations N]
  /ralph stop <project> <agent>
  /ralph status <project> <agent>
  /ralph logs <project> <agent> [--follow]
  /ralph progress <project> <agent>
  /ralph validate <project> <agent>

  Runs Claude Code repeatedly until every PRD item is complete.
  Uses skills: /prd → generates PRD | /ralph → converts to JSON

${SWARM_C_BOLD}PRD GENERATOR${SWARM_C_RESET}  (generate PRDs from templates)
  /prd bootstrap <project> --type <nodejs|python|go|rust>
  /prd feature <project> <name> --description "<desc>"
  /prd merger <project> [--branches feat/a,feat/b,...]

${SWARM_C_BOLD}AUTOMATED BOOTSTRAP${SWARM_C_RESET}  (recommended)

On the PARENT (single line):
  curl -fsSL https://raw.githubusercontent.com/johnolven/asis-coder/main/bootstrap-parent.sh | bash

Then, from the PARENT, deploy to all the Raspberries (one line):
  /swarm bootstrap children 192.168.50.10 192.168.50.11 192.168.50.12 192.168.50.13 --user pi

Verify:
  /swarm device list
  /swarm project create my-app --repo https://github.com/me/my-app.git
  /swarm agent add my-app auth --device rb001 --branch feat/auth --task "..."
  /swarm start my-app

${SWARM_C_BOLD}MANUAL BOOTSTRAP${SWARM_C_RESET}  (in case SSH is not set up)

On each CHILD (from the Raspberry itself):
  curl -fsSL https://raw.githubusercontent.com/johnolven/asis-coder/main/bootstrap-child.sh \\
      | bash -s -- --parent <parent-ip> --token <token>
EOF
    fi
}

swarm_doctor() {
    echo -e "${SWARM_C_BOLD}▸ $(hf_t "Swarm diagnostics" "Diagnóstico del swarm")${SWARM_C_RESET}"
    local ok=1
    for tool in jq ssh tmux git; do
        if command -v "$tool" >/dev/null 2>&1; then
            swarm_ok "$tool: $(command -v $tool)"
        else
            swarm_error "$tool: $(hf_t "MISSING" "FALTA")"
            ok=0
        fi
    done
    if command -v redis-cli >/dev/null 2>&1; then
        swarm_ok "redis-cli: $(command -v redis-cli)"
    else
        swarm_warn "$(hf_t "redis-cli: missing (optional, needed for '/swarm msg')" "redis-cli: falta (opcional, necesario para '/swarm msg')")"
    fi
    echo
    echo -e "${SWARM_C_BOLD}$(hf_t "Directories" "Directorios")${SWARM_C_RESET}"
    echo "  SWARM_DIR:          $SWARM_DIR"
    echo "  SWARM_DEVICES_FILE: $SWARM_DEVICES_FILE"
    echo "  SWARM_PROJECTS_DIR: $SWARM_PROJECTS_DIR"
    echo "  SWARM_LOG_DIR:      $SWARM_LOG_DIR"
    [ -f "$SWARM_DEVICES_FILE" ] && swarm_ok "$(hf_t "devices.json exists" "devices.json existe")" || swarm_warn "$(hf_t "devices.json does not exist (run: /swarm init)" "devices.json no existe (ejecuta: /swarm init)")"
    [ $ok -eq 0 ] && return 1 || return 0
}

swarm_router() {
    swarm_init_dirs
    swarm_require_jq || return 1
    local cmd="$1"; shift || true
    case "$cmd" in
        init)    swarm_role_init "$@" ;;
        role)    swarm_role_cmd "$@" ;;
        wizard)  swarm_wizard_run "$@" ;;
        doctor)  swarm_doctor ;;
        create)  swarm_project_wizard "$@" ;;

        enroll)  swarm_enroll_cmd "$@" ;;
        daemon)  swarm_daemon_cmd "$@" ;;
        bootstrap) swarm_bootstrap_cmd "$@" ;;

        device)   swarm_device_cmd "$@" ;;
        project)  swarm_project_cmd "$@" ;;
        agent)    swarm_agent_cmd "$@" ;;
        worktree|wt) swarm_worktree_cmd "$@" ;;

        start)    swarm_start "$@" ;;
        stop)     swarm_stop "$@" ;;
        status)   swarm_status "$@" ;;
        logs)     swarm_logs "$@" ;;
        attach)   swarm_attach "$@" ;;
        run)      swarm_run "$@" ;;

        msg)      swarm_comm_cmd "$@" ;;
        ralph)    swarm_ralph_cmd "$@" ;;
        prd)      prd_generate_cmd "$@" ;;
        tool)     swarm_tool_handler "$@" ;;
        dashboard) swarm_dashboard_cmd "$@" ;;

        ""|help|-h|--help) swarm_help ;;
        *) swarm_error "$(hf_t "Unknown subcommand 'swarm $cmd'." "Subcomando 'swarm $cmd' desconocido.")"; swarm_help; return 1 ;;
    esac
}
