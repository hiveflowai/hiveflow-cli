#!/usr/bin/env bash
# ── Ralph loop endurecido (Hiveflow CLI) ──────────────────────
# Loop autónomo sobre un PRD para trabajo GREENFIELD.
#
# La idea original (Geoff Huntley): un proceso nuevo por iteración con
# contexto fresco, y todo el estado en disco. Aquí se le añaden los frenos
# que la evidencia recomienda (ver LOOPS.md):
#   · verificación externa entre iteraciones (el loop no cree al agente)
#   · detección de no-progreso escalonada (aviso → parada)
#   · presupuesto de iteraciones y de reloj
#   · trayectoria auditable en ralph-trace.jsonl
#
# Uso: ./ralph.sh [--tool claude|codex|gemini|aider] [--max-seconds N] <iteraciones>
#
# ADVERTENCIA: técnica greenfield. Huntley es explícito en que no la
# usaría sobre un codebase existente; para bugs en código vivo usa /fix.

set -uo pipefail

TOOL="claude"
MAX_SECONDS=$((6 * 3600))
MAX_ITER=20

while [ $# -gt 0 ]; do
  case "$1" in
    --tool)        TOOL="$2"; shift 2 ;;
    --max-seconds) MAX_SECONDS="$2"; shift 2 ;;
    *) [[ "$1" =~ ^[0-9]+$ ]] && MAX_ITER="$1"; shift ;;
  esac
done

PRD="${PRD_FILE:-prd.json}"
PROGRESS="ralph-progress.md"
TRACE="ralph-trace.jsonl"
START_TS=$(date +%s)

[ -f "$PRD" ] || { echo "ralph: no encuentro $PRD"; exit 1; }

trace() {
  local iter="$1" event="$2" detail="${3:-}"
  printf '{"ts":"%s","iteration":%s,"event":"%s","detail":"%s"}\n' \
    "$(date -Iseconds)" "$iter" "$event" "${detail//\"/\'}" >> "$TRACE"
}

# Comando del agente. Prompt por stdin: proceso nuevo = contexto fresco.
agent_cmd() {
  case "$TOOL" in
    claude) echo "claude -p --dangerously-skip-permissions" ;;
    codex)  echo "codex exec -s workspace-write --skip-git-repo-check -" ;;
    gemini) echo "gemini -y -p" ;;
    aider)  echo "aider --yes-always --message-file -" ;;
    *)      echo "claude -p --dangerously-skip-permissions" ;;
  esac
}

# Verificación EXTERNA: lo que decide si hubo progreso, no el agente.
verify() {
  if [ -f package.json ] && grep -q '"test"' package.json 2>/dev/null; then
    timeout 900 npm test --silent > .ralph-verify 2>&1; return $?
  elif [ -f go.mod ]; then
    timeout 900 go test ./... > .ralph-verify 2>&1; return $?
  elif [ -f pyproject.toml ] || [ -f pytest.ini ]; then
    timeout 900 python -m pytest -q > .ralph-verify 2>&1; return $?
  fi
  return 2   # sin suite: no hay verificación posible
}

# Firma del estado: tareas pendientes del PRD + fallos de tests.
# Si no cambia entre iteraciones, el loop está girando en vacío.
signature() {
  {
    jq -r '[.tasks[]? | select(.status != "done") | .id] | join(",")' "$PRD" 2>/dev/null
    [ -f .ralph-verify ] && grep -ciE '(FAIL|✗|not ok)' .ralph-verify 2>/dev/null
  } | md5sum | cut -c1-12
}

[ -f "$PROGRESS" ] || cat > "$PROGRESS" <<EOF
# Progreso de Ralph

Este fichero es la memoria del loop: cada iteración arranca con contexto
fresco y lee esto. Mantenlo conciso y actualizado.

## Hecho
(nada aún)

## Siguiente
Leer $PRD y empezar por la primera tarea pendiente.
EOF

echo "ralph: tool=$TOOL · máx $MAX_ITER iteraciones · $MAX_SECONDS s"
trace 0 loop_start "tool=$TOOL max_iter=$MAX_ITER"

prev_sig=""
stall=0
iter=0

while [ "$iter" -lt "$MAX_ITER" ]; do
  iter=$((iter + 1))

  # FRENO: reloj
  elapsed=$(( $(date +%s) - START_TS ))
  if [ "$elapsed" -ge "$MAX_SECONDS" ]; then
    echo "ralph: límite de tiempo alcanzado (${elapsed}s)"
    trace "$iter" budget_stop "wall_clock=${elapsed}"
    break
  fi

  # ¿Queda trabajo?
  pending="$(jq -r '[.tasks[]? | select(.status != "done")] | length' "$PRD" 2>/dev/null || echo 1)"
  if [ "${pending:-1}" -eq 0 ]; then
    echo "ralph: PRD completo"
    trace "$iter" prd_complete
    break
  fi

  echo "── iteración $iter/$MAX_ITER (pendientes: $pending)"

  # Contexto FRESCO: proceso nuevo, prompt reconstruido desde disco.
  # No se compacta ni se arrastra historial (context rot).
  prompt="$(cat <<EOF
Trabajas en un proyecto guiado por un PRD. Esta es la iteración $iter de $MAX_ITER.

## PRD
$(cat "$PRD")

## Progreso hasta ahora
$(cat "$PROGRESS")

$( [ -f .ralph-verify ] && printf '## Salida real de la última verificación\n```\n%s\n```\n' "$(tail -40 .ralph-verify)" )

## Cómo trabajar
- Coge UNA sola tarea pendiente del PRD, la más prioritaria.
- Impleméntala completa, con sus tests. Nada de placeholders ni TODOs.
- PROHIBIDO debilitar o saltar tests existentes para que pase la suite.
- Marca la tarea como done en $PRD cuando esté terminada y verificada.
- Actualiza $PROGRESS: qué hiciste y qué sigue. Sé breve.
- No hagas commit; el orquestador se encarga.
EOF
)"

  printf '%s' "$prompt" | timeout 3600 $(agent_cmd) >/dev/null 2>&1

  # VERIFICACIÓN EXTERNA
  verify; vrc=$?
  case $vrc in
    0) trace "$iter" verify_pass ;;
    2) trace "$iter" verify_skipped "sin suite de tests" ;;
    *) trace "$iter" verify_fail "$(tail -3 .ralph-verify 2>/dev/null | tr '\n' ' ')" ;;
  esac

  # FRENO: no-progreso, escalonado (primero avisa, luego para)
  sig="$(signature)"
  if [ "$sig" = "$prev_sig" ]; then
    stall=$((stall + 1))
    if [ "$stall" -ge 2 ]; then
      echo "ralph: sin progreso en 2 iteraciones seguidas — parando"
      trace "$iter" no_progress_stop "sig=$sig"
      break
    fi
    echo "ralph: aviso — esta iteración no cambió nada"
    trace "$iter" no_progress_warn "sig=$sig"
    printf '\n> AVISO: la iteración %s no produjo cambios. Cambia de enfoque o marca la tarea como bloqueada.\n' "$iter" >> "$PROGRESS"
  else
    stall=0
  fi
  prev_sig="$sig"
done

echo "ralph: fin tras $iter iteraciones ($(( $(date +%s) - START_TS ))s)"
trace "$iter" loop_end "elapsed=$(( $(date +%s) - START_TS ))"
