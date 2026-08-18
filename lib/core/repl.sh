#!/usr/bin/env bash
# ── Hiveflow REPL ─────────────────────────────────────────────
# Inside the prompt:
#   /command  → hiveflow action (full list in /help)
#   text      → code request, routed to the active tool (or auto)

hf_active_tool()  { hf_config_get '.tool' ; }
hf_active_mode()  { local m; m="$(hf_config_get '.mode')"; echo "${m:-auto}"; }

hf_prompt_label() {
  local tool mode
  tool="$(hf_active_tool)"; [ -z "$tool" ] && tool="auto"
  mode="$(hf_active_mode)"
  echo -e "${HF_C_HONEY}hiveflow${HF_C_RESET} ${HF_C_DIM}(${tool}·${mode})${HF_C_RESET} ❯ "
}
# Detailed help per command: /help fix, /help tickets, ...
hf_help_topic() {
  local t="${1#/}"
  echo ""
  if [ "$HF_LANG" = "es" ]; then
    hf_help_topic_es "$t"
  else
    hf_help_topic_en "$t"
  fi
  echo ""
}

hf_help_topic_en() {
  local t="$1"
  case "$t" in
    tools|install|use|mode|route|health)
      echo -e "  ${HF_C_BOLD}AI CLIs${HF_C_RESET}"
      echo "    /tools              Table of CLIs: installed or not, version, what each is for"
      echo "    /install <tool|all> Install claude, gemini, codex or aider"
      echo "    /use <tool|auto>    Set the active CLI. 'auto' = the router picks by task type"
      echo "    /mode <auto|safe>   auto: CLIs act on their own · safe: they ask for confirmation"
      echo "    /route <text>       Preview which CLI would be picked, without running anything"
      echo "    /health             Check that the CLIs respond"
      echo ""
      hf_dim "The prompt always shows the state: hiveflow (tool·mode) ❯"
      ;;
    fix)
      echo -e "  ${HF_C_BOLD}/fix <ticket-id> [--dry-run]${HF_C_RESET}"
      echo "  Resolves a ticket end to end. Seven steps:"
      echo "    1. Reads the ticket and the user conversation"
      echo "    2. Triage: is it a bug? missing info? duplicate? too big?"
      echo "       and decides which repos it touches"
      echo "    3. Isolated worktree with branch fix/<ticket> (your checkout is untouched)"
      echo "    4. Implements with an agent, including a reproduction test"
      echo "    5. Repo tests"
      echo "    6. Security review + e2e"
      echo "    7. Diff guard → PR → waits for CI → notifies → moves the ticket"
      echo ""
      hf_dim "--dry-run shows what it would do without touching anything. Use it the first time."
      ;;
    tickets|cron|watch|stats|sync)
      echo -e "  ${HF_C_BOLD}Support tickets${HF_C_RESET}"
      echo "    /tickets            List the board's tickets"
      echo "    /tickets setup      Configure backend, org, kanban board and chat"
      echo "    /tickets watch      One agent pass (what the cron runs)"
      echo "    /tickets cron on    Autonomous agent every 5 min"
      echo "    /tickets cron off   Turn it off · cron status: see the latest passes"
      echo "    /tickets sync       Rebase open PRs so they stay mergeable"
      echo "    /tickets stats [d]  Metrics: acceptance, rejections, where it fails"
      echo ""
      hf_dim "Cron flow: takes the N highest-priority tickets from '$(hf_col_trigger 2>/dev/null || echo 'To Do')',"
      hf_dim "works each one in isolation, opens a PR and leaves it for your approval."
      ;;
    intake|alert|debt|audit)
      echo -e "  ${HF_C_BOLD}/intake — feed the queue from other sources${HF_C_RESET}"
      echo "    /intake alert <f.json|->  Sentry/monitoring alert (level → priority)"
      echo "    /intake debt [n]          Searches FIXME/HACK/XXX in your repos"
      echo "    /intake audit [n]         npm audit: critical and high vulnerabilities"
      echo "    /intake scan              debt + audit in one pass"
      echo ""
      hf_dim "Everything enters as a normal ticket: the pipeline doesn't distinguish the origin."
      ;;
    eval|routing)
      echo -e "  ${HF_C_BOLD}Measure and tune the agent${HF_C_RESET}"
      echo "    /eval add <repo> <sha>  Add one of your fix commits as a test case"
      echo "    /eval run [n]           Run the bench and score 0-100"
      echo "    /eval compare           Compare the last two runs"
      echo "    /routing                Which CLI works best in each repo"
      echo ""
      hf_dim "To know if a change helps: /eval run → change something → /eval run → /eval compare"
      ;;
    loop|trace)
      echo -e "  ${HF_C_BOLD}Agentic loops${HF_C_RESET}"
      echo "    /loop stats        Loops executed and how they ended"
      echo "    /loop trace <id>   Full trajectory: each iteration and its verdict"
      echo ""
      echo "  The loop lives inside /fix: implement → THE ORCHESTRATOR runs the"
      echo "  tests → if they fail, another iteration with the real error. Fresh"
      echo "  context each round, at most $(hf_loop_max_iter 2>/dev/null || echo 3) iterations."
      echo ""
      hf_dim "Brakes: iterations · time · no-progress · test weakening."
            ;;
    review)
      echo -e "  ${HF_C_BOLD}/review [n|repo <name>]${HF_C_RESET}"
      echo "  The agent reviews PRs opened by PEOPLE (not its own)."
      echo "  Looks for bugs, security issues and untested logic. Ignores style."
      echo ""
      hf_dim "Always comments, never blocks: approval remains human."
      ;;
    deploy)
      echo -e "  ${HF_C_BOLD}/deploy${HF_C_RESET}"
      echo "    /deploy setup   Configure the health endpoints to watch"
      echo "    /deploy check   Check right now whether they're healthy"
      echo "    /deploy watch   Check and, if something is down, see whether it"
      echo "                    matches a recent merge from the bot"
      ;;
    swarm|agents|ralph|prd|dashboard)
      if [ -n "$HF_ENGINE_LOADED" ]; then
        echo -e "  ${HF_C_BOLD}Swarm and autonomous development${HF_C_RESET}"
        echo "    /swarm              Status (or /swarm help for full detail)"
        echo "    /swarm wizard       Assistant to set up the device swarm"
        echo "    /agents             Which CLI each agent uses: list · choose · set"
        echo "    /dashboard          Live dashboard"
        echo "    /prd                Generate a feature PRD"
        echo "    /ralph              Autonomous loops over a PRD"
      else
        hf_err "$(hf_t "Swarm/Ralph modules are not loaded yet — run /swarm to download them with your Hiveflow account" "Los módulos Swarm/Ralph aún no están cargados — ejecuta /swarm para descargarlos con tu cuenta Hiveflow")"
      fi
      ;;
    llm|ask)
      echo -e "  ${HF_C_BOLD}Direct API chat${HF_C_RESET} ${HF_C_DIM}(without going through the CLIs)${HF_C_RESET}"
      echo "    /llm             Choose provider (claude/chatgpt/gemini), key and model"
      echo "    /ask <question>  One-off query"
      ;;
    agent|native|permissions|sessions|skills|hooks|mcp|new|resume|conversation)
      echo -e "  ${HF_C_BOLD}Conversation${HF_C_RESET} ${HF_C_DIM}(the main prompt IS one continuous thread)${HF_C_RESET}"
      echo "    /new [name]         Start a new conversation (fresh id, optional name)"
      echo "    /resume [id]        Pick a past conversation, see its transcript, keep going"
      echo ""
      echo "  Free text routed to the native agent continues the active thread"
      echo "  (memory across turns, auto-compaction). Exchanges done via external"
      echo "  CLIs (claude/gemini/…) are recorded in the same thread as '[via tool]'."
      echo "  The statusline shows the active thread: 🧵 <id>"
      echo ""
      echo -e "  ${HF_C_BOLD}Native agent${HF_C_RESET} ${HF_C_DIM}(own agentic engine: tool-use loop + permissions)${HF_C_RESET}"
      echo "    /agent <prompt>     One-shot: the agent reads, edits, runs and answers"
      echo "    /agent              Interactive multi-turn (auto-persisted sessions)"
      echo "    /plan <task>        Plan mode: explores and proposes without executing (read-only)"
      echo "    /cost               Input/output tokens accumulated this session"
      echo "    /use native         All free text in the REPL goes to the native agent"
      echo ""
      echo "  Tools: ${CODER_AGENTIC_TOOLS_BANNER:-read_file, write_file, edit_file, bash_exec, web_fetch, grep_search, glob_files, subagent} (+ MCP)"
      echo "  Providers: claude · chatgpt · gemini — configure with /llm"
      echo ""
      echo "    /permissions list|allow|deny|remove   Persistent tool allowlist"
      echo "    /sessions list|show|resume|rm         Multi-turn sessions"
      echo "    /skills list|show                     Custom slash commands (skills/)"
      echo "    /hooks list|add|rm                    Pre/post hooks for each tool"
      echo "    /mcp list|add|connect|tools           Connect MCP servers"
      echo ""
      hf_dim "/mode safe: every mutating tool asks for confirmation. /mode auto: acts on its own."
      hf_dim "Embeddable: hiveflow agent \"prompt\" · env HIVEFLOW_LLM_PROVIDER/KEY/MODEL · --yes"
      ;;
    lang|language|idioma)
      echo -e "  ${HF_C_BOLD}/lang <en|es>${HF_C_RESET}"
      echo "  Change the CLI language (persisted in your config)."
      echo "  Also available via env: HIVEFLOW_LANG=es hiveflow"
      ;;
    worker|workers)
      echo -e "  ${HF_C_BOLD}Workers${HF_C_RESET} ${HF_C_DIM}(local agents watching YOUR boards — /tickets generalized)${HF_C_RESET}"
      echo "    /worker add            Wizard: board, columns, playbook, cadence"
      echo "    /worker list|show|rm   Manage your workers"
      echo "    /worker run <name>     One pass right now"
      echo "    /worker cron on <name> Automatic pass every N min (per worker)"
      echo ""
      echo "  A worker watches ONE kanban column (e.g. 'To Do'), works each card"
      echo "  with the native agent following YOUR playbook, and leaves results"
      echo "  in 'QA' / 'Human in the loop'. Production is moved by a person."
      echo "  /tickets remains the built-in DevOps worker (code → tests → PR)."
      ;;
    remote|rc|control)
      echo -e "  ${HF_C_BOLD}Remote Control${HF_C_RESET} ${HF_C_DIM}(drive this terminal from app.hiveflow.ai → Genius → Remote)${HF_C_RESET}"
      echo "    /remote control        Connect (resumes this terminal's cloud thread)"
      echo "    /remote control new    Connect with a brand-new cloud conversation"
      echo "    /remote control <id>   Connect resuming a specific conversation"
      echo "    /remote stop           Disconnect"
      echo "    /remote                Ticket-runner nodes (status · setup · start)"
      echo ""
      echo "  While connected the terminal stays fully usable: what you type here"
      echo "  and what the web sends both land in the SAME Genius conversation,"
      echo "  and the web sees the agent's steps streamed live."
      ;;
    *)
      hf_err "No help for '$t'. Topics: tools · agent · new · resume · remote · worker · fix · tickets · intake · eval · review · deploy · llm · lang"
      ;;
  esac
}

hf_help_topic_es() {
  local t="$1"
  case "$t" in
    tools|install|use|mode|route|health)
      echo -e "  ${HF_C_BOLD}CLIs de IA${HF_C_RESET}"
      echo "    /tools              Tabla de CLIs: instalado o no, versión, para qué sirve cada uno"
      echo "    /install <tool|all> Instala claude, gemini, codex o aider"
      echo "    /use <tool|auto>    Fija el CLI activo. 'auto' = el router elige por tipo de tarea"
      echo "    /mode <auto|safe>   auto: los CLIs actúan solos · safe: piden confirmación"
      echo "    /route <texto>      Previsualiza qué CLI elegiría, sin ejecutar nada"
      echo "    /health             Comprueba que los CLIs responden"
      echo ""
      hf_dim "El prompt muestra siempre el estado: hiveflow (tool·modo) ❯"
      ;;
    fix)
      echo -e "  ${HF_C_BOLD}/fix <ticket-id> [--dry-run]${HF_C_RESET}"
      echo "  Resuelve un ticket de principio a fin. Siete pasos:"
      echo "    1. Lee el ticket y la conversación del usuario"
      echo "    2. Triaje: ¿es un bug? ¿falta info? ¿duplicado? ¿demasiado grande?"
      echo "       y decide qué repos toca"
      echo "    3. Worktree aislado con rama fix/<ticket> (tu checkout no se toca)"
      echo "    4. Implementa con un agente, incluyendo test de reproducción"
      echo "    5. Tests del repo"
      echo "    6. Revisión de seguridad + e2e"
      echo "    7. Guard del diff → PR → espera el CI → notifica → mueve el ticket"
      echo ""
      hf_dim "--dry-run enseña qué haría sin tocar nada. Úsalo la primera vez."
      ;;
    tickets|cron|watch|stats|sync)
      echo -e "  ${HF_C_BOLD}Tickets de soporte${HF_C_RESET}"
      echo "    /tickets            Lista los tickets del tablero"
      echo "    /tickets setup      Configura backend, org, tablero kanban y chat"
      echo "    /tickets watch      Una pasada del agente (lo que ejecuta el cron)"
      echo "    /tickets cron on    Agente autónomo cada 5 min"
      echo "    /tickets cron off   Apagarlo · cron status: ver últimas pasadas"
      echo "    /tickets sync       Rebasa los PRs abiertos para que sigan mergeables"
      echo "    /tickets stats [d]  Métricas: aceptación, rechazos, dónde falla"
      echo ""
      hf_dim "Flujo del cron: coge los N más prioritarios de '$(hf_col_trigger 2>/dev/null || echo 'Por Hacer')',"
      hf_dim "trabaja cada uno aislado, abre PR y lo deja para tu aprobación."
      ;;
    intake|alert|debt|audit)
      echo -e "  ${HF_C_BOLD}/intake — alimentar la cola desde otras fuentes${HF_C_RESET}"
      echo "    /intake alert <f.json|->  Alerta de Sentry/monitoring (nivel → prioridad)"
      echo "    /intake debt [n]          Busca FIXME/HACK/XXX en tus repos"
      echo "    /intake audit [n]         npm audit: vulnerabilidades críticas y altas"
      echo "    /intake scan              debt + audit de una pasada"
      echo ""
      hf_dim "Todo entra como ticket normal: el pipeline no distingue el origen."
      ;;
    eval|routing)
      echo -e "  ${HF_C_BOLD}Medir y ajustar el agente${HF_C_RESET}"
      echo "    /eval add <repo> <sha>  Añade un commit de fix tuyo como caso de prueba"
      echo "    /eval run [n]           Ejecuta el banco y puntúa 0-100"
      echo "    /eval compare           Compara las dos últimas ejecuciones"
      echo "    /routing                Qué CLI funciona mejor en cada repo"
      echo ""
      hf_dim "Para saber si un cambio mejora: /eval run → cambias algo → /eval run → /eval compare"
      ;;
    loop|trace)
      echo -e "  ${HF_C_BOLD}Loops agénticos${HF_C_RESET}"
      echo "    /loop stats        Loops ejecutados y cómo acabaron"
      echo "    /loop trace <id>   Trayectoria completa: cada iteración y su veredicto"
      echo ""
      echo "  El loop vive dentro de /fix: implementa → EL ORQUESTADOR corre los"
      echo "  tests → si fallan, otra iteración con el error real. Contexto fresco"
      echo "  cada vuelta, máximo $(hf_loop_max_iter 2>/dev/null || echo 3) iteraciones."
      echo ""
      hf_dim "Frenos: iteraciones · tiempo · no-progreso · debilitamiento de tests."
      hf_dim ""
      ;;
    review)
      echo -e "  ${HF_C_BOLD}/review [n|repo <nombre>]${HF_C_RESET}"
      echo "  El agente revisa los PRs abiertos por PERSONAS (no los suyos)."
      echo "  Busca bugs, problemas de seguridad y lógica sin tests. Ignora el estilo."
      echo ""
      hf_dim "Siempre comenta, nunca bloquea: la aprobación sigue siendo humana."
      ;;
    deploy)
      echo -e "  ${HF_C_BOLD}/deploy${HF_C_RESET}"
      echo "    /deploy setup   Configura los endpoints de salud a vigilar"
      echo "    /deploy check   Comprueba ahora si están sanos"
      echo "    /deploy watch   Comprueba y, si algo está caído, mira si coincide"
      echo "                    con algún merge reciente del bot"
      ;;
    swarm|agents|ralph|prd|dashboard)
      if [ -n "$HF_ENGINE_LOADED" ]; then
        echo -e "  ${HF_C_BOLD}Swarm y desarrollo autónomo${HF_C_RESET}"
        echo "    /swarm              Estado (o /swarm help para todo el detalle)"
        echo "    /swarm wizard       Asistente para montar el swarm de devices"
        echo "    /agents             Qué CLI usa cada agente: list · choose · set"
        echo "    /dashboard          Dashboard en vivo"
        echo "    /prd                Generar un PRD de feature"
        echo "    /ralph              Loops autónomos sobre un PRD"
      else
        hf_err "$(hf_t "Swarm/Ralph modules are not loaded yet — run /swarm to download them with your Hiveflow account" "Los módulos Swarm/Ralph aún no están cargados — ejecuta /swarm para descargarlos con tu cuenta Hiveflow")"
      fi
      ;;
    llm|ask)
      echo -e "  ${HF_C_BOLD}Chat directo por API${HF_C_RESET} ${HF_C_DIM}(sin pasar por los CLIs)${HF_C_RESET}"
      echo "    /llm             Elige proveedor (claude/chatgpt/gemini), key y modelo"
      echo "    /ask <pregunta>  Consulta puntual"
      ;;
    agent|native|permissions|sessions|skills|hooks|mcp|new|resume|conversation|conversacion)
      echo -e "  ${HF_C_BOLD}Conversación${HF_C_RESET} ${HF_C_DIM}(el prompt principal ES un hilo continuo)${HF_C_RESET}"
      echo "    /new [nombre]       Nueva conversación (id nuevo, nombre opcional)"
      echo "    /resume [id]        Elegir una conversación pasada, ver su transcript y seguir"
      echo ""
      echo "  El texto libre ruteado al agente nativo continúa el hilo activo"
      echo "  (memoria entre turnos, auto-compactación). Lo que se resuelve con"
      echo "  CLIs externos (claude/gemini/…) queda en el mismo hilo como '[via tool]'."
      echo "  La statusline muestra el hilo activo: 🧵 <id>"
      echo ""
      echo -e "  ${HF_C_BOLD}Agente nativo${HF_C_RESET} ${HF_C_DIM}(motor agentic propio: tool-use loop + permisos)${HF_C_RESET}"
      echo "    /agent <prompt>     One-shot: el agente lee, edita, ejecuta y responde"
      echo "    /agent              Interactivo multi-turn (sesiones auto-persistidas)"
      echo "    /plan <tarea>       Plan mode: explora y propone sin ejecutar (solo lectura)"
      echo "    /cost               Tokens de entrada/salida acumulados en la sesión"
      echo "    /use native         El texto libre del REPL va siempre al agente nativo"
      echo ""
      echo "  Tools: ${CODER_AGENTIC_TOOLS_BANNER:-read_file, write_file, edit_file, bash_exec, web_fetch, grep_search, glob_files, subagent} (+ MCP)"
      echo "  Providers: claude · chatgpt · gemini — configura con /llm"
      echo ""
      echo "    /permissions list|allow|deny|remove   Allowlist persistente de tools"
      echo "    /sessions list|show|resume|rm         Sesiones multi-turn"
      echo "    /skills list|show                     Slash commands custom (skills/)"
      echo "    /hooks list|add|rm                    Hooks pre/post de cada tool"
      echo "    /mcp list|add|connect|tools           Conectar servers MCP"
      echo ""
      hf_dim "Modo /mode safe: cada tool mutante pide confirmación. /mode auto: actúa solo."
      hf_dim "Embebible: hiveflow agent \"prompt\" · env HIVEFLOW_LLM_PROVIDER/KEY/MODEL · --yes"
      ;;
    lang|language|idioma)
      echo -e "  ${HF_C_BOLD}/lang <en|es>${HF_C_RESET}"
      echo "  Cambia el idioma del CLI (se guarda en tu config)."
      echo "  También por env: HIVEFLOW_LANG=es hiveflow"
      ;;
    worker|workers)
      echo -e "  ${HF_C_BOLD}Workers${HF_C_RESET} ${HF_C_DIM}(agentes locales vigilando TUS tableros — /tickets generalizado)${HF_C_RESET}"
      echo "    /worker add            Wizard: tablero, columnas, playbook, cadencia"
      echo "    /worker list|show|rm   Gestionar tus workers"
      echo "    /worker run <nombre>   Una pasada ahora mismo"
      echo "    /worker cron on <nom>  Pasada automática cada N min (por worker)"
      echo ""
      echo "  Un worker vigila UNA columna de un kanban (p.ej. 'Por Hacer'),"
      echo "  trabaja cada card con el agente nativo siguiendo TU playbook, y"
      echo "  deja el resultado en 'QA' / 'Human in the loop'. A producción lo"
      echo "  mueve una persona. /tickets sigue siendo el worker DevOps"
      echo "  integrado (código → tests → PR)."
      ;;
    remote|rc|control)
      echo -e "  ${HF_C_BOLD}Remote Control${HF_C_RESET} ${HF_C_DIM}(controla esta terminal desde app.hiveflow.ai → Genius → Remote)${HF_C_RESET}"
      echo "    /remote control        Conectar (retoma el hilo en la nube de esta terminal)"
      echo "    /remote control new    Conectar con una conversación nueva en la nube"
      echo "    /remote control <id>   Conectar retomando una conversación concreta"
      echo "    /remote stop           Desconectar"
      echo "    /remote                Nodos ejecutores de tickets (status · setup · start)"
      echo ""
      echo "  Conectado, la terminal sigue 100% usable: lo que tecleas aquí y lo"
      echo "  que manda la web caen en la MISMA conversación de Genius, y la web"
      echo "  ve en vivo el streaming de pasos del agente."
      ;;
    *)
      hf_err "No hay ayuda para '$t'. Temas: tools · agent · new · resume · remote · worker · fix · tickets · intake · eval · review · deploy · llm · lang"
      ;;
  esac
}

hf_help() {
  # With an argument: detailed help for that topic
  [ -n "${1:-}" ] && { hf_help_topic "$1"; return; }
  if [ "$HF_LANG" = "es" ]; then
    hf_help_es
  else
    hf_help_en
  fi
}

hf_help_en() {
  echo ""
  echo -e "  ${HF_C_BOLD}First time?${HF_C_RESET}  /tools → /install all → /tickets setup"
  echo -e "  ${HF_C_DIM}Detail for any command: /help <command>   ·   full guide: GUIA.md   ·   español: /lang es${HF_C_RESET}"
  echo ""
  echo -e "  ${HF_C_BOLD}🔧 AI CLIs${HF_C_RESET}"
  echo "  /tools              See the CLIs (claude, gemini, codex, aider)"
  echo "  /install <tool|all> Install the missing ones"
  echo "  /use <tool|auto>    Set the active CLI, or 'auto' (routing by task)"
  echo "  /mode <auto|safe>   auto: they act on their own · safe: they ask for confirmation"
  echo "  /route <text>       Preview which CLI the router would pick"
  echo "  /health             Check that they respond"
  echo ""
  if [ -n "$HF_ENGINE_LOADED" ]; then
    echo -e "  ${HF_C_BOLD}🐝 Distributed swarm${HF_C_RESET} ${HF_C_DIM}(agents across devices)${HF_C_RESET}"
    echo "  /swarm              Swarm status (or /swarm help: full detail)"
    echo "  /swarm wizard       Guided assistant to set up the swarm"
    echo "  /agents             Tools per agent: list · choose <proj> <agent> · set"
    echo "  /dashboard          Live swarm dashboard"
    echo ""
    echo -e "  ${HF_C_BOLD}🤖 Autonomous development${HF_C_RESET}"
    echo "  /prd                Generate a feature PRD (guided)"
    echo "  /ralph              Autonomous loops: start · status · logs · stop"
    echo ""
  fi
  echo -e "  ${HF_C_BOLD}🎫 Support tickets → PR${HF_C_RESET}"
  echo "  /tickets            List the support board's tickets"
  echo "  /tickets setup      Configure API, kanban board and chat"
  echo "  /fix <id>           Pipeline: understand → plan → branch → code →"
  echo "                      tests → security/e2e → PR → notify → kanban"
  echo "  /tickets watch      One agent pass (what the cron runs)"
  echo "  /tickets cron on    🤖 Autonomous agent: works the tickets every 5 min"
  echo "  /worker             🐝 YOUR boards: an agent per kanban with your playbook"
  echo "  /tickets stats [d]  📊 PR acceptance rate, cost and where it fails"
  echo "  /intake             📥 Other sources: prod alerts, tech debt, npm audit"
  echo "  /eval               🧪 Test bench: does a change help or hurt?"
  echo "  /review             👀 The agent reviews PRs opened by humans"
  echo "  /deploy check       🚀 Did what got merged break production?"
  echo "  /routing            🧭 Which CLI works best in each repo (learned)"
  echo "  /loop trace <id>    🔁 Audit the loop: what it tried and verified"
  echo "  /remote             🖥️  Run the tickets on nodes (this PC or another machine)"
  echo ""
  echo -e "  ${HF_C_BOLD}🧵 Conversation${HF_C_RESET} ${HF_C_DIM}(this prompt is one continuous thread)${HF_C_RESET}"
  echo "  /new [name]         New conversation (fresh id) · /resume [id]: pick one and continue"
  echo "  /remote control     Drive this terminal from the web (Genius → Remote), same thread"
  echo ""
  echo -e "  ${HF_C_BOLD}🤖 Native agent${HF_C_RESET} ${HF_C_DIM}(own agentic engine, no external CLIs)${HF_C_RESET}"
  echo "  /agent [prompt]     With prompt: one-shot · without: interactive multi-turn"
  echo "  /plan <task>        Plan mode: explores and proposes WITHOUT executing (read-only)"
  echo "  /cost               Tokens the agent consumed this session"
  echo "  /use native         Send ALL free text to the native agent"
  echo "  /permissions        Tool allowlist (list · allow · deny · remove)"
  echo "  /sessions           Agent sessions: list · show · resume · rm"
  echo "  /skills             Skills (custom slash commands): list · show"
  echo "  /hooks              Pre/post tool hooks: list · add · rm"
  echo "  /mcp                MCP servers: list · add · connect · tools"
  echo ""
  echo -e "  ${HF_C_BOLD}💬 Direct API chat${HF_C_RESET} ${HF_C_DIM}(no CLIs)${HF_C_RESET}"
  echo "  /llm                Choose provider (claude/chatgpt/gemini) + API key"
  echo "  /ask <question>     One-off query to the configured provider"
  echo ""
  echo -e "  ${HF_C_BOLD}👤 Account and session${HF_C_RESET}"
  echo "  /status             Account, active tool, mode"
  echo "  /login · /logout    Hiveflow account"
  echo "  /update [check]     Update the CLI (git pull or npm, per install)"
  echo "  /lang <en|es>       CLI language"
  echo "  /help               This help"
  echo "  /exit               Quit"
  echo ""
  echo -e "  ${HF_C_BOLD}Everything else is a code request.${HF_C_RESET} Examples:"
  hf_dim 'fix the login bug              → quick-fix   → codex/aider'
  hf_dim 'document the API               → docs        → gemini'
  hf_dim 'refactor the payments module   → refactor    → claude'
  echo ""
}

hf_help_es() {
  echo ""
  echo -e "  ${HF_C_BOLD}¿Primera vez?${HF_C_RESET}  /tools → /install all → /tickets setup"
  echo -e "  ${HF_C_DIM}Detalle de cualquier comando: /help <comando>   ·   guía completa: GUIA.md   ·   English: /lang en${HF_C_RESET}"
  echo ""
  echo -e "  ${HF_C_BOLD}🔧 CLIs de IA${HF_C_RESET}"
  echo "  /tools              Ver los CLIs (claude, gemini, codex, aider)"
  echo "  /install <tool|all> Instalar los que falten"
  echo "  /use <tool|auto>    Fijar el CLI activo, o 'auto' (routing por tarea)"
  echo "  /mode <auto|safe>   auto: actúan solos · safe: piden confirmación"
  echo "  /route <texto>      Previsualizar qué CLI elegiría el router"
  echo "  /health             Verificar que responden"
  echo ""
  if [ -n "$HF_ENGINE_LOADED" ]; then
    echo -e "  ${HF_C_BOLD}🐝 Swarm distribuido${HF_C_RESET} ${HF_C_DIM}(agentes en varios devices)${HF_C_RESET}"
    echo "  /swarm              Estado del swarm (o /swarm help: todo el detalle)"
    echo "  /swarm wizard       Asistente guiado para montar el swarm"
    echo "  /agents             Tools por agente: list · choose <proy> <agente> · set"
    echo "  /dashboard          Dashboard del swarm en vivo"
    echo ""
    echo -e "  ${HF_C_BOLD}🤖 Desarrollo autónomo${HF_C_RESET}"
    echo "  /prd                Generar un PRD de feature (guiado)"
    echo "  /ralph              Loops autónomos: start · status · logs · stop"
    echo ""
  fi
  echo -e "  ${HF_C_BOLD}🎫 Tickets de soporte → PR${HF_C_RESET}"
  echo "  /tickets            Listar tickets del tablero de soporte"
  echo "  /tickets setup      Configurar API, tablero kanban y chat"
  echo "  /fix <id>           Pipeline: entender → plan → rama → código →"
  echo "                      tests → seguridad/e2e → PR → notificar → kanban"
  echo "  /tickets watch      Una pasada del agente (lo que ejecuta el cron)"
  echo "  /tickets cron on    🤖 Agente autónomo: cada 5 min trabaja los tickets"
  echo "  /worker             🐝 TUS tableros: un agente por kanban con tu playbook"
  echo "  /tickets stats [d]  📊 Tasa de aceptación de PRs, coste y dónde falla"
  echo "  /intake             📥 Otras fuentes: alertas de prod, deuda técnica, npm audit"
  echo "  /eval               🧪 Banco de pruebas: ¿mejora o empeora un cambio?"
  echo "  /review             👀 El agente revisa los PRs abiertos por humanos"
  echo "  /deploy check       🚀 ¿Lo mergeado rompió producción?"
  echo "  /routing            🧭 Qué CLI funciona mejor en cada repo (aprendido)"
  echo "  /loop trace <id>    🔁 Auditar el loop: qué intentó y qué verificó"
  echo "  /remote             🖥️  Correr los tickets en nodos (esta PC u otra máquina)"
  echo ""
  echo -e "  ${HF_C_BOLD}🧵 Conversación${HF_C_RESET} ${HF_C_DIM}(este prompt es un hilo continuo)${HF_C_RESET}"
  echo "  /new [nombre]       Nueva conversación (id nuevo) · /resume [id]: elegir una y seguir"
  echo "  /remote control     Controlar esta terminal desde la web (Genius → Remote), mismo hilo"
  echo ""
  echo -e "  ${HF_C_BOLD}🤖 Agente nativo${HF_C_RESET} ${HF_C_DIM}(motor agentic propio, sin CLIs externos)${HF_C_RESET}"
  echo "  /agent [prompt]     Con prompt: one-shot · sin prompt: modo interactivo multi-turn"
  echo "  /plan <tarea>       Plan mode: explora y propone SIN ejecutar (solo lectura)"
  echo "  /cost               Tokens consumidos por el agente en esta sesión"
  echo "  /use native         Que TODO el texto libre vaya al agente nativo"
  echo "  /permissions        Allowlist de tools (list · allow · deny · remove)"
  echo "  /sessions           Sesiones del agente: list · show · resume · rm"
  echo "  /skills             Skills (slash commands custom): list · show"
  echo "  /hooks              Hooks pre/post tool: list · add · rm"
  echo "  /mcp                Servers MCP: list · add · connect · tools"
  echo ""
  echo -e "  ${HF_C_BOLD}💬 Chat directo por API${HF_C_RESET} ${HF_C_DIM}(sin CLIs)${HF_C_RESET}"
  echo "  /llm                Elegir proveedor (claude/chatgpt/gemini) + API key"
  echo "  /ask <pregunta>     Consulta puntual al proveedor configurado"
  echo ""
  echo -e "  ${HF_C_BOLD}👤 Cuenta y sesión${HF_C_RESET}"
  echo "  /status             Cuenta, tool activo, modo"
  echo "  /login · /logout    Cuenta Hiveflow"
  echo "  /update [check]     Actualizar el CLI (git pull o npm, según instalación)"
  echo "  /lang <en|es>       Idioma del CLI"
  echo "  /help               Esta ayuda"
  echo "  /exit               Salir"
  echo ""
  echo -e "  ${HF_C_BOLD}Todo lo demás es una petición de código.${HF_C_RESET} Ejemplos:"
  hf_dim 'arregla el bug del login        → quick-fix   → codex/aider'
  hf_dim 'documenta la API               → docs        → gemini'
  hf_dim 'refactoriza el módulo de pagos → refactor    → claude'
  echo ""
}

hf_status() {
  echo ""
  local method tool mode
  method="$(hf_auth_method)"
  tool="$(hf_active_tool)"; [ -z "$tool" ] && tool="auto"
  mode="$(hf_active_mode)"
  local email; email="$(hf_auth_email 2>/dev/null)"
  echo -e "  $(hf_t "Account:" "Cuenta: ") ${HF_C_GREEN}$(hf_t "authenticated" "autenticado")${HF_C_RESET} (${method:-api})${email:+ · ${HF_C_BOLD}$email${HF_C_RESET}}"
  echo -e "  Tool:    ${HF_C_BOLD}$tool${HF_C_RESET}$( [ "$tool" = "auto" ] && hf_t ' — the router picks per task' ' — el router elige por tarea')"
  echo -e "  $(hf_t "Mode:   " "Modo:   ") ${HF_C_BOLD}$mode${HF_C_RESET}$( [ "$mode" = "auto" ] && hf_t ' — CLIs act without asking for confirmation' ' — los CLIs actúan sin pedir confirmación' || hf_t ' — CLIs ask for confirmation' ' — los CLIs piden confirmación')"
  echo -e "  $(hf_t "Lang:   " "Idioma: ") ${HF_C_BOLD}$HF_LANG${HF_C_RESET}"
  hf_tools_health
  echo ""
}

# ── Custom line editor (raw mode) ─────────────────────────────
# Modern macOS blocks TIOCSTI, so keys can't be "pushed back" into
# readline: we read every key ourselves. Upsides: "/" opens the palette
# instantly, the colored prompt never misaligns, and we control history,
# arrows and editing. HF_HISTORY is maintained by hf_repl.

# Redraws the full line (prompt + buffer) and positions the cursor.
# Uses the caller's variables (bash dynamic scope): prompt, buffer, pos.
# WRAP-aware redraw: if prompt+buffer span several visual rows, we must
# move up to the first one, clear downward and reposition the cursor by
# row/column — a plain \r\033[K only repaints the last row and STACKS
# copies of the line once it exceeds the terminal width.
_hf_ed_redraw() {
  local cols=${HF_ED_COLS:-120} vplen=${HF_ED_PLEN:-0}
  local total=$(( vplen + ${#buffer} )) cpos=$(( vplen + pos ))
  local endrow=$(( total / cols ))
  [ $(( total % cols )) -eq 0 ] && [ "$total" -gt 0 ] && endrow=$(( endrow - 1 ))
  local crow=$(( cpos / cols )) ccol=$(( cpos % cols ))
  if [ "$ccol" -eq 0 ] && [ "$cpos" -gt 0 ]; then crow=$(( crow - 1 )); ccol=$cols; fi
  # Move up to the first row of the previous drawing and repaint
  [ "${HF_ED_CURROW:-0}" -gt 0 ] && printf '\033[%dA' "$HF_ED_CURROW"
  if [ "$endrow" -gt 0 ] || [ "${HF_ED_LASTROWS:-0}" -gt 0 ]; then
    printf '\r\033[J%s%s' "$prompt" "$buffer"
  else
    # single row: \033[K preserves the statusline below
    printf '\r\033[K%s%s' "$prompt" "$buffer"
  fi
  # From the end of the text to the cursor's logical position
  [ "$endrow" -gt "$crow" ] && printf '\033[%dA' $(( endrow - crow ))
  printf '\r'
  [ "$ccol" -gt 0 ] && printf '\033[%dC' "$ccol"
  HF_ED_CURROW=$crow
  HF_ED_LASTROWS=$endrow
}

# Fully erases the editor's current drawing (multi-row included)
_hf_ed_clear() {
  [ "${HF_ED_CURROW:-0}" -gt 0 ] && printf '\033[%dA' "$HF_ED_CURROW"
  printf '\r\033[J'
  HF_ED_CURROW=0
  HF_ED_LASTROWS=0
}

# Statusline below the input line: path · git branch · LLM model
# Environment the CLI points at, inferred from the active API — first
# thing on the statusline: with several environments (local/prod) you
# need to know WHERE you are before typing anything.
hf_env_tag() {
  local api="${HIVEFLOW_API_URL:-https://api.hiveflow.ai}" host env
  host="${api#*://}"; host="${host%%/*}"
  case "$host" in
    localhost*|127.0.0.1*|0.0.0.0*) env="local" ;;
    api.hiveflow.ai)                env="prod" ;;
    *staging*|*dev*)                env="staging" ;;
    *)                              env="custom" ;;
  esac
  printf '%s · %s' "$env" "$host"
}

hf_status_line() {
  local path branch provider model line cols
  path="${PWD/#$HOME/~}"
  branch="$(git branch --show-current 2>/dev/null)"
  provider="$(hf_config_get '.llm.provider')"
  model="$(hf_config_get '.llm.model')"
  if [ -n "$provider" ] && [ -z "$model" ]; then
    case "$provider" in
      claude|hiveflow) model="claude-sonnet-4-5-20250929" ;;
      chatgpt)         model="gpt-4o" ;;
      gemini)          model="gemini-2.5-pro" ;;
    esac
  fi
  line="  [$(hf_env_tag)] $path"
  [ -n "$branch" ] && line="$line ⎇ $branch"
  [ -n "$model" ] && line="$line · $model${provider:+ ($provider)}"
  [ -n "${HF_REPL_SESSION:-}" ] && line="$line · 🧵 ${HF_REPL_SESSION##*-}"
  cols="$(tput cols 2>/dev/null || echo 120)"
  printf '%s' "${line:0:$cols}"
}

# Paints the statusline on the line below and returns the cursor to the
# input line (where typing happens)
hf_status_line_draw() {
  [ -t 1 ] || return 0
  printf '\n\033[K\033[2m%s\033[0m\r\033[A' "$(hf_status_line)"
}

# When reading ends (Enter), the cursor lands on the statusline:
# clear it so the command's output doesn't mix with it
hf_status_line_clear() {
  [ -t 1 ] || return 0
  printf '\r\033[K'
}

# hf_read_line: leaves the line in HF_LINE (and HF_LINE_RC=1 on EOF).
# "/" with an empty buffer → immediate palette.
hf_read_line() {
  HF_LINE=""
  HF_LINE_RC=0
  local prompt
  prompt="$(hf_prompt_label)"

  if ! [ -t 0 ]; then
    # No TTY (pipes, scripts): simple read
    IFS= read -r HF_LINE || HF_LINE_RC=1
    return
  fi

  hf_status_line_draw
  printf '%s' "$prompt"

  # Geometry for the multi-row redraw (VISIBLE prompt length)
  HF_ED_COLS="$(tput cols 2>/dev/null || echo 120)"; [ "${HF_ED_COLS:-0}" -gt 0 ] || HF_ED_COLS=120
  local _pv; _pv="$(printf '%s' "$prompt" | sed $'s/\x1b\\[[0-9;]*m//g')"
  HF_ED_PLEN=${#_pv}
  HF_ED_CURROW=0; HF_ED_LASTROWS=0

  local buffer="" pos=0 key seq rest head tail
  local hist_len=${#HF_HISTORY[@]} hist_idx=${#HF_HISTORY[@]} hist_stash=""
  local saved
  saved=$(stty -g 2>/dev/null)
  stty -icanon -echo 2>/dev/null

  while :; do
    IFS= read -r -n1 key || { HF_LINE_RC=1; break; }
    case "$key" in
      "")  # Enter
        break ;;
      $'\x7f'|$'\x08')  # Backspace: delete the char before the cursor
        if [ "$pos" -gt 0 ]; then
          buffer="${buffer:0:pos-1}${buffer:pos}"
          pos=$((pos - 1))
          _hf_ed_redraw
        fi ;;
      $'\x1b')  # Escape sequences (arrows, home/end, delete)
        seq=""
        IFS= read -r -n1 -t 1 seq 2>/dev/null || seq=""
        if [ "$seq" = "[" ]; then
          IFS= read -r -n1 -t 1 seq 2>/dev/null || seq=""
          case "$seq" in
            A)  # ↑ history
              if [ "$hist_idx" -gt 0 ]; then
                [ "$hist_idx" -eq "$hist_len" ] && hist_stash="$buffer"
                hist_idx=$((hist_idx - 1))
                buffer="${HF_HISTORY[$hist_idx]}"
                pos=${#buffer}
                _hf_ed_redraw
              fi ;;
            B)  # ↓ history
              if [ "$hist_idx" -lt "$hist_len" ]; then
                hist_idx=$((hist_idx + 1))
                if [ "$hist_idx" -eq "$hist_len" ]; then
                  buffer="$hist_stash"
                else
                  buffer="${HF_HISTORY[$hist_idx]}"
                fi
                pos=${#buffer}
                _hf_ed_redraw
              fi ;;
            C) if [ "$pos" -lt "${#buffer}" ]; then pos=$((pos + 1)); _hf_ed_redraw; fi ;;
            D) if [ "$pos" -gt 0 ]; then pos=$((pos - 1)); _hf_ed_redraw; fi ;;
            H) pos=0; _hf_ed_redraw ;;
            F) pos=${#buffer}; _hf_ed_redraw ;;
            3)  # Delete key: [3~
              IFS= read -r -n1 -t 1 seq 2>/dev/null || true
              if [ "$pos" -lt "${#buffer}" ]; then
                buffer="${buffer:0:pos}${buffer:pos+1}"
                _hf_ed_redraw
              fi ;;
            Z)  # Shift+Tab → toggle auto ⇄ safe mode (keeps what's typed)
              stty "$saved" 2>/dev/null
              _hf_ed_clear
              if [ "$(hf_active_mode)" = "auto" ]; then
                hf_config_set '.mode' "safe"
              else
                hf_config_set '.mode' "auto"
              fi
              hf_mode_banner
              prompt="$(hf_prompt_label)"
              _pv="$(printf '%s' "$prompt" | sed $'s/\x1b\\[[0-9;]*m//g')"
              HF_ED_PLEN=${#_pv}
              hf_status_line_draw
              _hf_ed_redraw
              stty -icanon -echo 2>/dev/null ;;
          esac
        fi ;;  # bare ESC: ignore
      $'\x04')  # Ctrl+D: EOF only with an empty buffer
        if [ -z "$buffer" ]; then HF_LINE_RC=1; break; fi ;;
      $'\x01') pos=0; _hf_ed_redraw ;;                      # Ctrl+A
      $'\x05') pos=${#buffer}; _hf_ed_redraw ;;             # Ctrl+E
      $'\x15') buffer=""; pos=0; _hf_ed_redraw ;;           # Ctrl+U
      $'\x0b') buffer="${buffer:0:pos}"; _hf_ed_redraw ;;   # Ctrl+K
      $'\x17')  # Ctrl+W: delete previous word
        head="${buffer:0:pos}"
        tail="${buffer:pos}"
        head="${head%"${head##*[![:space:]]}"}"
        while [ -n "$head" ] && [ "${head: -1}" != " " ]; do head="${head%?}"; done
        buffer="$head$tail"
        pos=${#head}
        _hf_ed_redraw ;;
      "/")
        if [ -z "$buffer" ]; then
          # Instant palette
          stty "$saved" 2>/dev/null
          _hf_ed_clear
          hf_palette
          if [ -n "$HF_PALETTE_CHOICE" ]; then
            HF_LINE="$HF_PALETTE_CHOICE"
            printf '%s%s\n' "$prompt" "$HF_LINE"
            return 0
          fi
          if [ -n "$HF_PALETTE_SEED" ]; then
            # Tab/space in the palette: keep editing with the command filled in
            buffer="$HF_PALETTE_SEED"
            pos=${#buffer}
            HF_PALETTE_SEED=""
          fi
          hf_status_line_draw
          _hf_ed_redraw
          stty -icanon -echo 2>/dev/null
        else
          buffer="${buffer:0:pos}/${buffer:pos}"
          pos=$((pos + 1))
          _hf_ed_redraw
        fi ;;
      *)
        # Printable character (the bytes of a multibyte char arrive back to
        # back and are inserted in order; the redraw paints the full char)
        buffer="${buffer:0:pos}${key}${buffer:pos}"
        pos=$((pos + ${#key}))
        _hf_ed_redraw ;;
    esac
  done

  stty "$saved" 2>/dev/null
  # Move down to the end of the drawn text before the newline
  if [ "${HF_ED_LASTROWS:-0}" -gt "${HF_ED_CURROW:-0}" ]; then
    printf '\033[%dB' $(( HF_ED_LASTROWS - HF_ED_CURROW ))
  fi
  printf '\n'
  hf_status_line_clear
  HF_LINE="$buffer"
}

# Command palette: opens when "/" is pressed. Arrows to move,
# typing filters live, Enter runs, Esc cancels.
# Leaves the choice in HF_PALETTE_CHOICE ("" if cancelled).
HF_PALETTE_CHOICE=""
HF_PALETTE_SEED=""
hf_palette() {
  HF_PALETTE_CHOICE=""
  HF_PALETTE_SEED=""
  local entries=(
    "/help|$(hf_t "All commands and what they do" "Todos los comandos y qué hacen")"
    "/agent|$(hf_t "Native agent: reads, edits and runs code" "Agente nativo: lee, edita y ejecuta código")"
    "/new|$(hf_t "New conversation in this prompt (optional name)" "Nueva conversación en este prompt (nombre opcional)")"
    "/resume|$(hf_t "Pick a past conversation and continue it" "Elegir una conversación pasada y continuarla")"
    "/plan|$(hf_t "Explore and propose WITHOUT executing" "Explorar y proponer SIN ejecutar")"
    "/llm|$(hf_t "Choose the agent's provider/model" "Elegir proveedor/modelo del agente")"
    "/mode|$(hf_t "auto (acts alone) · safe (asks first)" "auto (actúa solo) · safe (pide confirmación)")"
    "/use|$(hf_t "Set active tool: claude·gemini·codex·aider·native·auto" "Fijar tool activo: claude·gemini·codex·aider·native·auto")"
    "/tools|$(hf_t "See installed AI CLIs" "Ver los AI CLIs instalados")"
    "/install|$(hf_t "Install missing AI CLIs" "Instalar los AI CLIs que falten")"
    "/route|$(hf_t "Preview which CLI the router would pick" "Previsualizar qué CLI elegiría el router")"
    "/status|$(hf_t "Account, tool, mode and language" "Cuenta, tool, modo e idioma")"
    "/sessions|$(hf_t "List/resume agent conversations" "Listar/reanudar conversaciones del agente")"
    "/cost|$(hf_t "Tokens used this session" "Tokens usados en esta sesión")"
    "/permissions|$(hf_t "Persistent tool allowlist" "Allowlist persistente de tools")"
    "/skills|$(hf_t "Custom slash commands" "Slash commands custom")"
    "/hooks|$(hf_t "Pre/post hooks per tool" "Hooks pre/post por tool")"
    "/mcp|$(hf_t "Connect MCP servers" "Conectar servers MCP")"
    "/worker|$(hf_t "Agents watching YOUR boards (playbook + cadence)" "Agentes vigilando TUS tableros (playbook + cadencia)")"
    "/docs|$(hf_t "Sync the live Hiveflow API reference (for the agent)" "Sincronizar la referencia viva de la API (para el agente)")"
    "/tickets|$(hf_t "Support tickets → PR pipeline" "Tickets de soporte → pipeline a PR")"
    "/fix|$(hf_t "Resolve a ticket end to end" "Resolver un ticket de principio a fin")"
    "/remote|$(hf_t "Remote Control: mirror this CLI in the web/app" "Remote Control: reflejar este CLI en la web/app")"
    "/review|$(hf_t "Agent reviews human-opened PRs" "El agente revisa PRs abiertos por humanos")"
    "/deploy|$(hf_t "Health checks of your endpoints" "Salud de tus endpoints")"
    "/intake|$(hf_t "Feed tickets from alerts/debt/audit" "Alimentar tickets desde alertas/deuda/audit")"
    "/eval|$(hf_t "Bench: does a change help or hurt?" "Banco de pruebas: ¿mejora o empeora?")"
    "/routing|$(hf_t "Which CLI works best per repo" "Qué CLI funciona mejor por repo")"
    "/loop|$(hf_t "Agentic loop stats and traces" "Stats y trazas de loops agénticos")"
    "/health|$(hf_t "Check the AI CLIs respond" "Comprobar que los AI CLIs responden")"
    "/swarm|$(hf_t "Distributed agents across devices" "Agentes distribuidos en devices")"
    "/agents|$(hf_t "Tool per swarm agent" "Tool por agente del swarm")"
    "/dashboard|$(hf_t "Live swarm dashboard" "Dashboard del swarm en vivo")"
    "/prd|$(hf_t "Generate a feature PRD" "Generar un PRD de feature")"
    "/ralph|$(hf_t "Autonomous loops over a PRD" "Loops autónomos sobre un PRD")"
    "/ask|$(hf_t "One-off question to the configured LLM" "Pregunta puntual al LLM configurado")"
    "/update|$(hf_t "Update the CLI" "Actualizar el CLI")"
    "/lang|$(hf_t "Language: en · es" "Idioma: en · es")"
    "/login|$(hf_t "Connect your Hiveflow account" "Conectar tu cuenta Hiveflow")"
    "/logout|$(hf_t "Sign out" "Cerrar sesión")"
    "/exit|$(hf_t "Quit" "Salir")"
  )
  local filter="" sel=0 max_show=10
  local key rest e name desc i total
  # Inline dropdown: reserve the menu height once (scrolling happens
  # only here) and afterwards always repaint INSIDE that block, so it
  # never misaligns even at the bottom of the window.
  local term_lines rows
  term_lines="$(tput lines 2>/dev/null || echo 24)"
  [ "$max_show" -gt $((term_lines - 5)) ] && max_show=$((term_lines - 5))
  [ "$max_show" -lt 3 ] && max_show=3
  rows=$((max_show + 2))
  printf '\033[?25l'
  trap 'printf "\033[?25h"' RETURN
  for ((i = 0; i < rows; i++)); do printf '\n'; done
  printf '\033[%dA' "$rows"
  while true; do
    # Prefix first (/st → /status before /install), substring afterwards
    local matches=() subs=()
    for e in "${entries[@]}"; do
      name="${e%%|*}"
      if [ -z "$filter" ] || [[ "${name#/}" == "$filter"* ]]; then
        matches+=("$e")
      elif [[ "$name" == *"$filter"* ]]; then
        subs+=("$e")
      fi
    done
    matches+=("${subs[@]+"${subs[@]}"}")
    total=${#matches[@]}
    [ "$sel" -ge "$total" ] && sel=$(( total > 0 ? total - 1 : 0 ))
    [ "$sel" -ge "$max_show" ] && sel=$((max_show - 1))

    printf '\r\033[K  \033[1m❯ /\033[0m\033[1m%s\033[0m\n' "$filter"
    for ((i = 0; i < max_show; i++)); do
      printf '\033[K'
      if [ "$i" -lt "$total" ]; then
        e="${matches[$i]}"
        name="${e%%|*}"; desc="${e#*|}"
        if [ "$i" -eq "$sel" ]; then
          printf '  \033[38;5;99m❯ %-13s\033[0m \033[2m%s\033[0m\n' "$name" "$desc"
        else
          printf '    %-13s \033[2m%s\033[0m\n' "$name" "$desc"
        fi
      else
        printf '\n'
      fi
    done
    # Footer WITHOUT a trailing \n: the cursor stays inside the reserved block
    printf '\033[K  \033[2m%s\033[0m' "$(hf_t "↑↓ move · enter run · tab/space add args · esc cancel · type to filter" "↑↓ mover · enter ejecutar · tab/espacio con args · esc cancelar · escribe para filtrar")"

    IFS= read -r -s -n1 key || break
    case "$key" in
      "")
        if [ "$total" -gt 0 ]; then
          HF_PALETTE_CHOICE="${matches[$sel]%%|*}"
        fi
        break ;;
      " ")
        # Space: switch to typing the line with arguments
        HF_PALETTE_SEED="/${filter} "
        break ;;
      $'\x09')
        # Tab: autocomplete the selected command and keep typing
        if [ "$total" -gt 0 ]; then
          HF_PALETTE_SEED="${matches[$sel]%%|*} "
        else
          HF_PALETTE_SEED="/${filter}"
        fi
        break ;;
      $'\x1b')
        rest=""
        IFS= read -r -s -n2 -t 1 rest 2>/dev/null
        case "$rest" in
          '[A') [ "$sel" -gt 0 ] && sel=$((sel - 1)) ;;
          '[B') sel=$((sel + 1)) ;;
          "")   break ;;
        esac ;;
      $'\x7f'|$'\x08') filter="${filter%?}" ;;
      $'\x03') break ;;
      *)
        if [[ "$key" == [[:print:]] ]] && [ "$key" != "/" ]; then
          filter="$filter$key"
          sel=0
        fi ;;
    esac
    # Return to the top of the block for the next frame
    printf '\r\033[%dA' $((rows - 1))
  done
  # Erase only the menu block and return the cursor to the prompt line
  printf '\r\033[%dA\033[J\033[?25h' $((rows - 1))
}

# One-line tips to teach the CLI (Claude Code style).
# The first one of the session is always /help; afterwards they rotate randomly.
HF_TIP_SHOWN=0
hf_tip() {
  local tips_en=(
    "/help — see everything Hiveflow can do (or /help <command> for detail)"
    "/llm — choose the agent's model: your Hiveflow account or your own claude/chatgpt/gemini key"
    "shift+tab (or /mode safe) — make tools ask for confirmation before touching anything"
    "/use native — send everything to Hiveflow's own agent, no external CLIs needed"
    "/agent <task> — the native agent reads, edits and runs code by itself"
    "/plan <task> — explore and propose a plan WITHOUT executing anything"
    "/tools — see which AI CLIs you have · /install all installs the missing ones"
    "/sessions — list and resume the agent's previous conversations"
    "/cost — tokens the agent has consumed in this session"
    "/status — account, active tool, mode and language"
    "/update check — see if there's a new Hiveflow CLI version"
    "/lang es — cambia el CLI a español"
    "/permissions — persistent allowlist of what the agent can run"
    "/route <text> — preview which CLI the router would pick, without running it"
  )
  local tips_es=(
    "/help — ver todo lo que Hiveflow puede hacer (o /help <comando> para detalle)"
    "/llm — elige el modelo del agente: tu cuenta Hiveflow o tu propia key de claude/chatgpt/gemini"
    "shift+tab (o /mode safe) — que los tools pidan confirmación antes de tocar nada"
    "/use native — que todo vaya al agente propio de Hiveflow, sin CLIs externos"
    "/agent <tarea> — el agente nativo lee, edita y ejecuta código él solo"
    "/plan <tarea> — explorar y proponer un plan SIN ejecutar nada"
    "/tools — ver qué AI CLIs tienes · /install all instala los que falten"
    "/sessions — listar y reanudar conversaciones previas del agente"
    "/cost — tokens que el agente ha consumido en esta sesión"
    "/status — cuenta, tool activo, modo e idioma"
    "/update check — ver si hay versión nueva del Hiveflow CLI"
    "/lang en — switch the CLI to English"
    "/permissions — allowlist persistente de lo que el agente puede ejecutar"
    "/route <texto> — previsualiza qué CLI elegiría el router, sin ejecutar"
  )
  local n=${#tips_en[@]} idx
  if [ "$HF_TIP_SHOWN" = "0" ]; then
    idx=0
    HF_TIP_SHOWN=1
  else
    idx=$(( (RANDOM % (n - 1)) + 1 ))
  fi
  local tip
  if [ "$HF_LANG" = "es" ]; then tip="${tips_es[$idx]}"; else tip="${tips_en[$idx]}"; fi
  echo ""
  hf_dim "💡 $tip"
}

# ── /new and /resume: Claude Code-style agent conversations ──

# Prints the full transcript of an agent session (text + tools)
hf_session_transcript() {
  local id="$1" f
  f="$(sessions_dir 2>/dev/null)/$id/messages.json"
  [ -f "$f" ] || return 1
  echo ""
  jq -r '.[]
    | if .role == "user" then
        (if (.content | type) == "string" then "U" + .content
         elif (.content | type) == "array" and ([.content[] | select(.type? == "tool_result")] | length) > 0 then empty
         else "U" + (.content | tostring) end)
      elif .role == "assistant" then
        ( [.content[]? | select(.type? == "text") | "A" + .text],
          [.content[]? | select(.type? == "tool_use") | "T" + .name] )
        | .[]
      else empty end' "$f" 2>/dev/null | while IFS= read -r line; do
    case "${line:0:1}" in
      U) printf '\033[38;5;51myou \xe2\x9d\xaf\033[0m %s\n' "${line:1}" ;;
      A) [ -n "${line:1}" ] && printf '%s\n' "${line:1}" ;;
      T) printf '  \033[38;5;99m\xe2\x8f\xba\033[0m \033[2m%s\033[0m\n' "${line:1}" ;;
      *) [ -n "$line" ] && printf '%s\n' "$line" ;;
    esac
  done
  echo ""
}

# Resumes a conversation IN the orchestrator: prints the whole thread and
# leaves it active — free text on the main prompt continues it.
hf_agent_resume() {
  local id="$1"
  if ! sessions_exists "$id" >/dev/null 2>&1; then
    hf_err "$(hf_t "Session not found: $id (see /resume)" "Sesión no encontrada: $id (mira /resume)")"
    return 1
  fi
  hf_session_transcript "$id"
  HF_REPL_SESSION="$id"
  hf_ok "$(hf_t "Conversation resumed: ${HF_C_BOLD}$id${HF_C_RESET} — keep typing to continue it" "Conversación reanudada: ${HF_C_BOLD}$id${HF_C_RESET} — sigue escribiendo para continuarla")"
}

# Interactive conversation picker (same pattern as the palette)
hf_resume_picker() {
  local base ids=() labels=() id meta label turns updated first f
  base="$(sessions_dir 2>/dev/null)"
  [ -d "$base" ] || { hf_dim "$(hf_t "No conversations yet — /new starts one" "Aún no hay conversaciones — /new abre una")"; return 0; }
  for id in $(ls -t "$base" 2>/dev/null | head -15); do
    meta="$base/$id/meta.json"
    [ -f "$meta" ] || continue
    label=$(jq -r '.label // empty' "$meta" 2>/dev/null)
    turns=$(jq -r '.turn_count // 0' "$meta" 2>/dev/null)
    updated=$(jq -r '.updated_at // "" | .[0:16]' "$meta" 2>/dev/null)
    if [ -z "$label" ]; then
      f="$base/$id/messages.json"
      label=$(jq -r '[.[] | select(.role == "user") | .content | if type == "string" then . else empty end] | first // "" | .[0:46]' "$f" 2>/dev/null)
    fi
    ids+=("$id")
    labels+=("${label:-\(empty\)} · ${turns}t · ${updated}")
  done
  [ ${#ids[@]} -eq 0 ] && { hf_dim "$(hf_t "No conversations yet — /new starts one" "Aún no hay conversaciones — /new abre una")"; return 0; }

  local sel=0 total=${#ids[@]} i key rest rows
  rows=$((total + 2))
  printf '\033[?25l'
  trap 'printf "\033[?25h"' RETURN
  for ((i = 0; i < rows; i++)); do printf '\n'; done
  printf '\033[%dA' "$rows"
  while :; do
    printf '\r\033[K  \033[1m%s\033[0m\n' "$(hf_t "Resume a conversation" "Reanudar una conversación")"
    for ((i = 0; i < total; i++)); do
      printf '\033[K'
      if [ "$i" -eq "$sel" ]; then
        printf '  \033[38;5;99m❯ %s\033[0m \033[2m%s\033[0m\n' "${ids[$i]}" "${labels[$i]}"
      else
        printf '    %s \033[2m%s\033[0m\n' "${ids[$i]}" "${labels[$i]}"
      fi
    done
    printf '\033[K  \033[2m%s\033[0m' "$(hf_t "↑↓ move · enter open · esc cancel" "↑↓ mover · enter abrir · esc cancelar")"
    IFS= read -r -s -n1 key || break
    case "$key" in
      "") break ;;
      $'\x1b')
        rest=""
        IFS= read -r -s -n2 -t 1 rest 2>/dev/null
        case "$rest" in
          '[A') [ "$sel" -gt 0 ] && sel=$((sel - 1)) ;;
          '[B') [ "$sel" -lt $((total - 1)) ] && sel=$((sel + 1)) ;;
          "")   sel=-1; break ;;
        esac ;;
    esac
    printf '\r\033[%dA' $((rows - 1))
  done
  printf '\r\033[%dA\033[J\033[?25h' $((rows - 1))
  [ "$sel" -ge 0 ] && hf_agent_resume "${ids[$sel]}"
}

# Banner for the active mode (Claude Code style on shift+tab)
hf_mode_banner() {
  local m
  m="$(hf_active_mode)"
  if [ "$m" = "auto" ]; then
    echo -e "  ${HF_C_HONEY}⏵⏵${HF_C_RESET} $(hf_t "auto mode — tools act without asking" "modo auto — los tools actúan sin preguntar") ${HF_C_DIM}$(hf_t "(shift+tab to switch)" "(shift+tab para cambiar)")${HF_C_RESET}"
  else
    echo -e "  ${HF_C_CYAN}⏸${HF_C_RESET}  $(hf_t "safe mode — asks before mutating actions" "modo safe — pide confirmación antes de acciones mutantes") ${HF_C_DIM}$(hf_t "(shift+tab to switch)" "(shift+tab para cambiar)")${HF_C_RESET}"
  fi
}

hf_lang_cmd() {
  local arg="${1:-}"
  case "$arg" in
    en|es)
      hf_config_set '.lang' "$arg"
      HF_LANG="$arg"
      if [ "$arg" = "es" ]; then
        hf_ok "Idioma: español. Vuelve a inglés con /lang en"
      else
        hf_ok "Language: English. Switch back with /lang es"
      fi ;;
    "")
      echo -e "  $(hf_t "Current language:" "Idioma actual:") ${HF_C_BOLD}$HF_LANG${HF_C_RESET} · $(hf_t "change it with /lang <en|es>" "cámbialo con /lang <en|es>")" ;;
    *)
      hf_err "$(hf_t "Usage: /lang <en|es>" "Uso: /lang <en|es>")" ;;
  esac
}

# Thread context for external CLIs: they are stateless (every -p starts
# from scratch), so without this they know nothing of the prior conversation.
# Last 6 exchanges, capped at ~4000 chars.
hf_session_context() {
  declare -f sessions_load >/dev/null 2>&1 || return 0
  [ -n "${HF_REPL_SESSION:-}" ] || return 0
  sessions_load "$HF_REPL_SESSION" 2>/dev/null | jq -r '
    [.[] | select(.role=="user" or .role=="assistant")
     | .content = (if (.content|type)=="string" then .content
         else ([.content[]? | select(.type=="text") | .text] | join("\n")) end)
     | select(.content != null and .content != "")]
    | .[-6:] | .[] | "\(.role): \(.content)"' 2>/dev/null | tail -c 4000
}

# Last assistant reply in a session (for the remote mirror)
hf_session_last_assistant() {
  declare -f sessions_load >/dev/null 2>&1 || return 0
  sessions_load "$1" 2>/dev/null | jq -r '
    [.[] | select(.role=="assistant")] | last
    | if . == null then empty
      elif (.content|type)=="string" then .content
      else ([.content[]? | select(.type=="text") | .text] | join("\n")) end' 2>/dev/null
}

# Native agent turn on the REPL thread + mirroring of the reply
_hf_native_turn() {
  hf_rc_mirror_active 2>/dev/null && ( _hf_rc_activity 1 ) >/dev/null 2>&1 &
  hf_agent_turn "$HF_REPL_SESSION" "$1"
  local rc=$?
  if hf_rc_mirror_active 2>/dev/null; then
    local a; a="$(hf_session_last_assistant "$HF_REPL_SESSION")"
    [ -n "$a" ] && ( _hf_rc_append assistant "$a" ) >/dev/null 2>&1 &
    ( _hf_rc_activity 0 ) >/dev/null 2>&1 &
  fi
  return $rc
}

# Runs a code request with the active tool or the router
hf_run_request() {
  local prompt="$1"
  local tool mode
  tool="$(hf_active_tool)"
  mode="$(hf_active_mode)"

  # Native agent explicitly set → turn on the REPL's CONVERSATION
  if [ "$tool" = "native" ]; then
    if hf_repl_session_ensure; then
      _hf_native_turn "$prompt"
    else
      hf_agent_run "$prompt"
    fi
    return $?
  fi

  if [ -z "$tool" ] || [ "$tool" = "auto" ]; then
    local task_type
    task_type="$(hf_infer_task_type "$prompt")"
    tool="$(hf_route "$task_type")"
    if [ -z "$tool" ]; then
      hf_err "$(hf_t "No CLI installed and no API key for the native agent. Use /install all or /llm" "No hay ningún CLI instalado ni API key para el agente nativo. Usa /install all o /llm")"
      return 1
    fi
    hf_info "$(hf_t "Router: task '${task_type}'" "Router: tarea '${task_type}'") → ${HF_C_BOLD}${tool}${HF_C_RESET}"
    if [ "$tool" = "native" ]; then
      if hf_repl_session_ensure; then
        _hf_native_turn "$prompt"
      else
        hf_agent_run "$prompt"
      fi
      return $?
    fi
  elif ! hf_tool_installed "$tool"; then
    hf_err "$(hf_t "The active tool '$tool' is not installed. /install $tool  or  /use auto" "El tool activo '$tool' no está instalado. /install $tool  o  /use auto")"
    return 1
  fi

  # The REPL conversation travels with the prompt: the external CLI gets
  # the recent thread and replies in context (the short command is shown).
  local cmd ctx run_prompt
  run_prompt="$prompt"
  hf_repl_session_ensure >/dev/null 2>&1 || true
  ctx="$(hf_session_context)"
  if [ -n "$ctx" ]; then
    run_prompt="[Previous conversation in this session — continue it naturally and reply ONLY to the last user message]
$ctx

user: $prompt"
  fi
  hf_dim "$ $(hf_tool_cmd "$tool" "$prompt" "$mode")"
  [ -n "$ctx" ] && hf_dim "  $(hf_t "(+ thread context: $(printf '%s' "$ctx" | grep -c .) lines)" "(+ contexto del hilo: $(printf '%s' "$ctx" | grep -c .) líneas)")"
  cmd="$(hf_tool_cmd "$tool" "$run_prompt" "$mode")"
  echo ""
  # Clean environment for external CLIs:
  # - whatever the native agent exported this session (keys/proxy) must
  #   not be inherited — with the hiveflow provider, ANTHROPIC_API_KEY is
  #   an hf_ token that would break claude.
  # - claude also uses its own login (claude.ai subscription); an
  #   ANTHROPIC_API_KEY from the shell would force it to bill via API and
  #   turns off connectors. Opt-out: HIVEFLOW_CLAUDE_ENV_KEY=1.
  local scrub=""
  [ -n "${HF_AGENT_ENV_EXPORTED:-}" ] && scrub="unset $HF_AGENT_ENV_EXPORTED;"
  if [ "$tool" = "claude" ] && [ "${HIVEFLOW_CLAUDE_ENV_KEY:-0}" != "1" ]; then
    scrub="$scrub unset ANTHROPIC_API_KEY ANTHROPIC_MESSAGES_URL;"
  fi
  # Spinner while the CLI works (templates are one-shot: they emit
  # nothing until the end). TTY only; HIVEFLOW_NO_SPINNER=1 disables it.
  local rc
  if [ -t 1 ] && [ -z "${HIVEFLOW_NO_SPINNER:-}" ]; then
    local out_file pid frames i t0 label
    out_file="$(mktemp)"
    label="$(hf_t "$tool is working… (esc/ctrl+c to cancel)" "$tool está trabajando… (esc/ctrl+c para cancelar)")"
    hf_rc_mirror_active 2>/dev/null && ( _hf_rc_activity 1 ) >/dev/null 2>&1 &
    eval "( $scrub $cmd )" > "$out_file" 2>&1 &
    pid=$!
    trap 'kill "$pid" 2>/dev/null' INT
    frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; i=0; t0=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  \033[38;5;99m%s\033[0m \033[2m%s %ss\033[0m ' "${frames:$((i % 10)):1}" "$label" "$((SECONDS - t0))"
      i=$((i + 1))
      sleep 0.12
    done
    wait "$pid"; rc=$?
    # Re-arm the REPL trap (restores the terminal on Ctrl+C at the prompt)
    if [ -n "${HF_STTY_ORIG:-}" ]; then
      trap 'stty "$HF_STTY_ORIG" 2>/dev/null; echo ""; exit 130' INT
    else
      trap - INT
    fi
    printf '\r\033[K'
    cat "$out_file"
    # The REPL conversation also records what the external CLIs do
    local clean_out
    clean_out="$(sed -e $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' -e $'s/\r//g' "$out_file")"
    if hf_repl_session_ensure; then
      hf_session_append_exchange "$HF_REPL_SESSION" "$prompt" "$clean_out" "$tool"
    fi
    # Remote Control mirror: the reply also goes to the Genius thread.
    # (captured BEFORE the rm: in a background job the expansion happens
    # in the child and the file might no longer exist → 'cat: No such file')
    if hf_rc_mirror_active 2>/dev/null; then
      ( _hf_rc_append assistant "$clean_out" ) >/dev/null 2>&1 &
      ( _hf_rc_activity 0 ) >/dev/null 2>&1 &
    fi
    rm -f "$out_file"
  else
    # No TTY (pipes/scripts): also record the exchange on the thread
    local out_file2 clean_out2
    out_file2="$(mktemp)"
    eval "( $scrub $cmd )" 2>&1 | tee "$out_file2"
    rc=${PIPESTATUS[0]}
    clean_out2="$(sed -e $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' -e $'s/\r//g' "$out_file2")"
    if hf_repl_session_ensure; then
      hf_session_append_exchange "$HF_REPL_SESSION" "$prompt" "$clean_out2" "$tool"
    fi
    if hf_rc_mirror_active 2>/dev/null; then
      ( _hf_rc_append assistant "$clean_out2" ) >/dev/null 2>&1 &
      ( _hf_rc_activity 0 ) >/dev/null 2>&1 &
    fi
    rm -f "$out_file2"
  fi
  echo ""
  [ $rc -eq 0 ] && hf_ok "$(hf_t "$tool finished (exit 0)" "$tool terminó (exit 0)")" || hf_warn "$(hf_t "$tool exited with code $rc" "$tool salió con código $rc")"
  return $rc
}

hf_handle_slash() {
  local line="$1"
  local cmd args
  cmd="${line%% *}"
  args="${line#"$cmd"}"; args="${args# }"

  case "$cmd" in
    /help|/h|/\?)   hf_help $args ;;
    /lang)          hf_lang_cmd $args ;;
    /tools)         hf_tools_list ;;
    /install)       hf_tool_install "${args:-all}" ;;
    /use)
      case "$args" in
        auto) hf_config_set '.tool' "auto"; hf_ok "$(hf_t "Tool: auto (routing by task)" "Tool: auto (routing por tarea)")" ;;
        native)
          if hf_agent_available; then
            hf_config_set '.tool' "native"; hf_ok "$(hf_t "Active tool: native agent (tools: ${CODER_AGENTIC_TOOLS_BANNER:-read/write/edit/bash/...})" "Tool activo: agente nativo (tools: ${CODER_AGENTIC_TOOLS_BANNER:-read/write/edit/bash/...})")"
          else
            hf_err "$(hf_t "The native agent needs a provider + API key. Configure it with /llm" "El agente nativo necesita proveedor + API key. Configúralo con /llm")"
          fi ;;
        claude|gemini|codex|aider)
          if hf_tool_installed "$args"; then
            hf_config_set '.tool' "$args"; hf_ok "$(hf_t "Active tool: $args" "Tool activo: $args")"
          else
            hf_err "$(hf_t "'$args' is not installed. /install $args" "'$args' no está instalado. /install $args")"
          fi ;;
        *) hf_err "$(hf_t "Usage: /use <claude|gemini|codex|aider|native|auto>" "Uso: /use <claude|gemini|codex|aider|native|auto>")" ;;
      esac ;;
    /mode)
      case "$args" in
        auto|safe) hf_config_set '.mode' "$args"; hf_mode_banner ;;
        toggle)
          if [ "$(hf_active_mode)" = "auto" ]; then
            hf_config_set '.mode' "safe"
          else
            hf_config_set '.mode' "auto"
          fi
          hf_mode_banner ;;
        *) hf_err "$(hf_t "Usage: /mode <auto|safe|toggle>" "Uso: /mode <auto|safe|toggle>")" ;;
      esac ;;
    /route)
      if [ -z "$args" ]; then
        hf_err "$(hf_t "Usage: /route <task description>" "Uso: /route <descripción de la tarea>")"
      else
        local tt sel
        tt="$(hf_infer_task_type "$args")"
        sel="$(hf_route "$tt")"
        echo -e "  '${args}' → $(hf_t "task" "tarea") ${HF_C_BOLD}$tt${HF_C_RESET} → tool ${HF_C_BOLD}${sel:-$(hf_t "none installed" "ninguno instalado")}${HF_C_RESET}"
      fi ;;
    /health)        hf_tools_health ;;
    /status)        hf_status ;;
    # ── Swarm engine (vendored from asis-coder) ──
    /swarm)         hf_engine_dispatch ${args:-status} ;;
    /agents)        hf_engine_dispatch tool ${args:-list} ;;
    /dashboard)     hf_engine_dispatch dashboard $args ;;
    /prd)           hf_engine_dispatch prd $args ;;
    /ralph)         hf_engine_dispatch ralph ${args:-help} ;;
    # ── Support tickets → PR ──
    /worker|/workers) hf_worker_cmd $args ;;
    /docs)
      if hf_docs_sync ${args:+--force}; then
        hf_ok "$(hf_t "API reference synced from the backend (live-generated)" "Referencia de la API sincronizada del backend (generada en vivo)")"
      else
        hf_warn "$(hf_t "Could not sync now — using cached copy if any" "No se pudo sincronizar ahora — se usa la copia cacheada si existe")"
      fi
      if [ -f "$HF_CONFIG_DIR/api-reference.md" ]; then
        hf_dim "  $HF_CONFIG_DIR/api-reference.md · $(wc -l < "$HF_CONFIG_DIR/api-reference.md" | tr -d ' ') lines · $(date -r "$HF_CONFIG_DIR/api-reference.md" '+%H:%M' 2>/dev/null)"
        hf_dim "$(hf_t "The native agent reads it automatically when operating the Hiveflow API" "El agente nativo la lee automáticamente al operar la API de Hiveflow")"
      fi ;;
    /tickets)
      case "$args" in
        setup|config) hf_tickets_setup ;;
        watch)        hf_tickets_watch ;;
        sync)         hf_tickets_sync ;;
        stats*)       hf_metrics_reconcile; hf_metrics_report ${args#stats} ;;
        cron*)        hf_tickets_cron ${args#cron} ;;
        *)            hf_tickets_list ;;
      esac ;;
    /fix)           hf_fix $args ;;
    /intake)        hf_intake_cmd $args ;;
    /eval)          hf_eval_cmd $args ;;
    /deploy)        hf_deploy_cmd $args ;;
    /review)        hf_review_cmd $args ;;
    /routing)       hf_adaptive_report ;;
    /loop)          hf_loop_cmd $args ;;
    /remote)        hf_remote_cmd $args ;;
    # ── Native agent (own agentic engine) ──
    /agent)
      if [ -n "$args" ]; then
        hf_agent_run "$args"
      else
        hf_agent_repl
      fi ;;
    /new)
      # New ORCHESTRATOR conversation: free text follows this thread
      HF_REPL_SESSION=""
      if hf_repl_session_ensure "$args"; then
        hf_ok "$(hf_t "New conversation: ${HF_C_BOLD}$HF_REPL_SESSION${HF_C_RESET}${args:+ ($args)}" "Nueva conversación: ${HF_C_BOLD}$HF_REPL_SESSION${HF_C_RESET}${args:+ ($args)}")"
        hf_dim "$(hf_t "free text continues it (native agent keeps the whole thread)" "el texto libre la continúa (el agente nativo mantiene todo el hilo)")"
        # Remote mirror active → the cloud follows the new thread (1:1)
        hf_rc_attach_thread 2>/dev/null
      else
        hf_err "$(hf_t "Could not create the conversation." "No se pudo crear la conversación.")"
      fi ;;
    /resume)
      if [ -n "$args" ]; then
        hf_agent_resume "$args"
      else
        hf_resume_picker
      fi
      # Remote mirror active → the cloud follows the resumed thread (1:1)
      hf_rc_attach_thread 2>/dev/null ;;
    /plan)          hf_agent_plan "$args" ;;
    /cost)          hf_agent_cost ;;
    /permissions)   permissions_cli $args ;;
    /hooks)         hooks_cli $args ;;
    /mcp)           mcp_cli $args ;;
    /skills)        skills_cli $args ;;
    /sessions)
      # `resume` needs the provider environment (llm_choice, API key):
      # go through hf_agent_repl instead of calling the engine bare.
      case "$args" in
        resume\ *) hf_agent_repl "${args#resume }" ;;
        *)         sessions_cli $args ;;
      esac ;;
    # ── Direct API chat ──
    /llm)           hf_llm_setup ;;
    /ask)
      if [ -z "$args" ]; then
        hf_err "$(hf_t "Usage: /ask <question>" "Uso: /ask <pregunta>")"
      else
        hf_ask "$args"
      fi ;;
    /login)         hf_login ;;
    /logout)        hf_logout ;;
    /update)        hf_update_cmd $args ;;
    /exit|/quit|/q) return 42 ;;
    *)              hf_err "$(hf_t "Unknown command: $cmd — see /help" "Comando desconocido: $cmd — mira /help")" ;;
  esac
  return 0
}

hf_repl() {
  hf_dim "$(hf_t "Type /help to see the commands, or just describe the code you need." "Escribe /help para ver los comandos, o directamente qué código necesitas.")"
  hf_dim "$(hf_t "shift+tab: switch auto ⇄ safe mode · \"/\" + enter: command menu" "shift+tab: cambiar modo auto ⇄ safe · \"/\" + enter: menú de comandos")"
  echo ""
  # Ctrl+C at the prompt: restore the terminal before exiting (the raw
  # editor leaves it without echo if the process dies mid-edit)
  if [ -t 0 ]; then
    HF_STTY_ORIG=$(stty -g 2>/dev/null)
    trap 'stty "$HF_STTY_ORIG" 2>/dev/null; echo ""; exit 130' INT
  fi
  HF_HISTORY=()
  local line
  while true; do
    hf_read_line
    [ "$HF_LINE_RC" = "1" ] && break
    line="$HF_LINE"
    [ -z "$line" ] && continue
    HF_HISTORY+=("$line")
    # Remote Control mirror active: what you type here also goes to the
    # thread (slash commands are local CLI plumbing, not conversation)
    if hf_rc_mirror_active 2>/dev/null && [[ "$line" != /* ]]; then
      _hf_rc_append user "$line" &
    fi

    if [ "$line" = "/" ]; then
      # fallback without python3: "/" + Enter opens the palette
      hf_palette
      if [ -n "$HF_PALETTE_CHOICE" ]; then
        history -s "$HF_PALETTE_CHOICE" 2>/dev/null
        echo -e "$(hf_prompt_label)$HF_PALETTE_CHOICE"
        hf_handle_slash "$HF_PALETTE_CHOICE"
        [ $? -eq 42 ] && break
      fi
    elif [[ "$line" == /* ]]; then
      hf_handle_slash "$line"
      [ $? -eq 42 ] && break
    else
      hf_run_request "$line"
      hf_tip
    fi
  done
  # On CLI exit, stop the mirror so the web sees it disconnected
  if hf_rc_mirror_active 2>/dev/null; then
    hf_rc_stop >/dev/null 2>&1
  fi
  echo ""
  hf_dim "$(hf_t "See you soon 🐝" "Hasta pronto 🐝")"
}
