#!/usr/bin/env bash
# ============================================================
# Hiveflow CLI — AI coding CLI orchestrator
#   hiveflow                Interactive REPL (welcome + /commands)
#   hiveflow -p "prompt"    One-off request, no REPL
#   hiveflow --version      Version
# ============================================================

HIVEFLOW_VERSION="1.0.0"

# Resolve the real root (supports symlinks from /usr/local/bin, npm bin, etc.)
_hf_src="${BASH_SOURCE[0]}"
while [ -h "$_hf_src" ]; do
  _hf_dir="$(cd -P "$(dirname "$_hf_src")" && pwd)"
  _hf_src="$(readlink "$_hf_src")"
  [[ "$_hf_src" != /* ]] && _hf_src="$_hf_dir/$_hf_src"
done
HIVEFLOW_ROOT="$(cd -P "$(dirname "$_hf_src")" && pwd)"

for _mod in i18n.sh ui.sh config.sh prompts.sh update.sh auth.sh tools.sh router.sh llm.sh metrics.sh tickets.sh workers.sh intake.sh eval.sh deploy.sh review.sh loop.sh remote.sh engine.sh agent.sh repl.sh; do
  # shellcheck source=/dev/null
  source "$HIVEFLOW_ROOT/lib/core/$_mod"
done

hf_lang_init

# Minimal dependencies
for _dep in jq curl; do
  if ! command -v "$_dep" >/dev/null 2>&1; then
    echo "$(hf_t "hiveflow: missing dependency '$_dep'. Install it and retry." "hiveflow: falta la dependencia '$_dep'. Instálala y reintenta.")" >&2
    exit 1
  fi
done

hf_config_init

case "${1:-}" in
  --version|-v)
    echo "hiveflow $HIVEFLOW_VERSION"
    exit 0
    ;;
  --help|-h)
    hf_banner
    if [ "$HF_LANG" = "es" ]; then
      echo "  hiveflow                REPL interactivo"
      echo "  hiveflow -p \"prompt\"    Petición única (usa el router/tool activo)"
      echo "  hiveflow agent \"prompt\"  Agente nativo one-shot (embebible: stdout = respuesta)"
      echo "  hiveflow agent          Agente nativo interactivo (multi-turn, sesiones)"
      echo "  hiveflow agent --session <id>   Reanudar una sesión del agente"
      echo "  hiveflow agent --plan \"tarea\"   Plan mode: explora y propone sin ejecutar"
      echo "  hiveflow agent --json \"prompt\"  Salida JSON: {ok, exit, response, tokens_*}"
      echo "  hiveflow --version      Versión"
      echo ""
      echo "  Embebible: HIVEFLOW_LLM_PROVIDER/KEY/MODEL configuran el agente por env,"
      echo "  --yes auto-aprueba tools mutantes (scripts/CI)."
      echo ""
      echo "  Dentro del REPL: /help lista todos los comandos."
    else
      echo "  hiveflow                Interactive REPL"
      echo "  hiveflow -p \"prompt\"    One-off request (uses the active router/tool)"
      echo "  hiveflow agent \"prompt\"  Native agent one-shot (embeddable: stdout = response)"
      echo "  hiveflow agent          Native agent interactive (multi-turn, sessions)"
      echo "  hiveflow agent --session <id>   Resume an agent session"
      echo "  hiveflow agent --plan \"task\"    Plan mode: explores and proposes without executing"
      echo "  hiveflow agent --json \"prompt\"  JSON output: {ok, exit, response, tokens_*}"
      echo "  hiveflow --version      Version"
      echo ""
      echo "  Embeddable: HIVEFLOW_LLM_PROVIDER/KEY/MODEL configure the agent via env,"
      echo "  --yes auto-approves mutating tools (scripts/CI)."
      echo ""
      echo "  Inside the REPL: /help lists every command."
    fi
    exit 0
    ;;
  -p|--print)
    shift
    if [ -z "${1:-}" ]; then
      echo "$(hf_t "hiveflow: -p requires a prompt." "hiveflow: -p requiere un prompt.")" >&2
      exit 1
    fi
    hf_auth_ok || { echo "$(hf_t "hiveflow: not authenticated. Run 'hiveflow' and log in." "hiveflow: no autenticado. Ejecuta 'hiveflow' y haz login.")" >&2; exit 1; }
    hf_run_request "$*"
    exit $?
    ;;
  agent|-agent|--agent)
    # Native agent (own agentic engine, no external CLIs).
    #   hiveflow agent "prompt"          one-shot: stdout = model response
    #   hiveflow agent                   interactive multi-turn
    #   hiveflow agent --session <id>    resume a session
    #   hiveflow agent --yes "prompt"    auto-approve tools (scripts/CI)
    #   hiveflow agent --plan "prompt"   plan mode: read-only, proposes without executing
    #   hiveflow agent --json "prompt"   JSON envelope: {ok, exit, response, tokens_*}
    # No hiveflow account required: uses your API key (/llm or HIVEFLOW_LLM_*).
    shift
    _hf_session=""
    _hf_json=0
    _hf_plan=0
    while true; do
      case "${1:-}" in
        --yes|-y)     export CODER_YES=1; shift ;;
        --session|-s) _hf_session="${2:-}"; shift 2 ;;
        --json)       _hf_json=1; shift ;;
        --plan)       _hf_plan=1; shift ;;
        *) break ;;
      esac
    done
    if [ -z "${1:-}" ]; then
      hf_agent_repl "$_hf_session"
      exit $?
    fi
    if [ "$_hf_json" = "1" ]; then
      # JSON mode: stdout = the envelope only; tool progress still goes to stderr.
      _hf_out_file=$(mktemp)
      if [ "$_hf_plan" = "1" ]; then
        hf_agent_plan "$*" > "$_hf_out_file"
      else
        hf_agent_run "$*" > "$_hf_out_file"
      fi
      _hf_rc=$?
      _hf_ok=false; [ "$_hf_rc" -eq 0 ] && _hf_ok=true
      jq -n \
        --rawfile resp "$_hf_out_file" \
        --argjson ok "$_hf_ok" \
        --argjson exit "$_hf_rc" \
        --argjson tokens_in "${CODER_TOKENS_IN:-0}" \
        --argjson tokens_out "${CODER_TOKENS_OUT:-0}" \
        '{ok: $ok, exit: $exit, response: $resp, tokens_in: $tokens_in, tokens_out: $tokens_out}'
      rm -f "$_hf_out_file"
      exit "$_hf_rc"
    fi
    if [ "$_hf_plan" = "1" ]; then
      hf_agent_plan "$*"
    else
      hf_agent_run "$*"
    fi
    exit $?
    ;;
  update)
    shift; hf_update_cmd "$@"; exit $?
    ;;
  swarm)
    # Non-interactive passthrough to the engine (systemd, scripts, cron):
    #   hiveflow swarm daemon start --foreground
    #   hiveflow swarm status
    shift
    hf_engine_dispatch "$@"
    exit $?
    ;;
  remote)
    shift; hf_remote_cmd "$@"; exit $?
    ;;
  loop)
    shift; hf_loop_cmd "$@"; exit $?
    ;;
  deploy)
    shift; hf_deploy_cmd "$@"; exit $?
    ;;
  review)
    shift; hf_review_cmd "$@"; exit $?
    ;;
  eval)
    shift; hf_eval_cmd "$@"; exit $?
    ;;
  intake)
    shift; hf_intake_cmd "$@"; exit $?
    ;;
  worker)
    # Non-interactive (cron/scripts): hiveflow worker run <name> | list | cron …
    shift
    hf_worker_cmd "$@"
    exit $? ;;
  tickets)
    # Non-interactive (cron/scripts): hiveflow tickets watch|list|fix|cron
    shift
    case "${1:-list}" in
      watch) hf_tickets_watch ;;
      list)  hf_tickets_list ;;
      fix)   shift; hf_fix "$@" ;;
      sync)  hf_tickets_sync ;;
      stats) shift; hf_metrics_reconcile; hf_metrics_report "$@" ;;
      cron)  shift; hf_tickets_cron "$@" ;;
      *) echo "hiveflow tickets: watch|list|fix <id>|sync|stats|cron <on|off|status>" >&2; exit 1 ;;
    esac
    exit $?
    ;;
  "")
    hf_welcome
    hf_update_notice
    hf_update_bg_check
    hf_auth_ensure || exit 1
    hf_repl
    ;;
  *)
    echo "$(hf_t "hiveflow: unknown option '$1'. Use --help." "hiveflow: opción desconocida '$1'. Usa --help.")" >&2
    exit 1
    ;;
esac
