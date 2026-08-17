#!/usr/bin/env bash
# ── Loops agénticos con verificación externa ──────────────────
# (Investigación de diseño: hiveflow-docs/cli/LOOPS.md)
#
# Reglas que implementa este módulo:
#   1. El VEREDICTO es del orquestador, nunca del agente (Huang et al.:
#      la auto-corrección intrínseca degrada el rendimiento).
#   2. CONTEXTO FRESCO por iteración; el estado va a disco, no a la
#      conversación (context rot: los modelos degradan con historial largo).
#   3. CINCO FRENOS independientes: iteraciones, tiempo, no-progreso,
#      debilitamiento de tests y aserción verificada.
#   4. TOPES BAJOS: 3 iteraciones. Subirlos compra ~1 punto cada 15 rondas
#      y amplifica el reward hacking.

hf_loop_max_iter()  { local c; c="$(hf_config_get '.loop.max_iterations')"; echo "${c:-3}"; }
hf_loop_max_secs()  { local c; c="$(hf_config_get '.loop.max_seconds')";    echo "${c:-3600}"; }
hf_trace_dir()      { echo "${HF_TRACE_DIR:-$HF_CONFIG_DIR/traces}"; }

# ── L5: auditoría de trayectorias ─────────────────────────────
# Cursor y SpecBench detectaron el reward hacking LEYENDO transcripciones.
# Una tasa de resolución que no puedes auditar no es una tasa.
hf_trace() {
  local tid="$1" iter="$2" event="$3"; shift 3
  local extra="{}" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    if [[ "$v" =~ ^-?[0-9]+$ ]]; then
      extra="$(echo "$extra" | jq -c --arg k "$k" --argjson v "$v" '.[$k]=$v')"
    else
      extra="$(echo "$extra" | jq -c --arg k "$k" --arg v "${v:0:400}" '.[$k]=$v')"
    fi
  done
  mkdir -p "$(hf_trace_dir)"
  jq -nc --arg ts "$(date -Iseconds)" --arg t "$tid" --argjson i "$iter" \
        --arg e "$event" --argjson x "$extra" \
    '{ts:$ts, ticket:$t, iteration:$i, event:$e} + $x' \
    >> "$(hf_trace_dir)/${tid}.jsonl"
}

hf_loop_trace_show() {
  local tid="$1"
  [ -z "$tid" ] && { hf_err "$(hf_t "Usage: /loop trace <ticket-id>" "Uso: /loop trace <ticket-id>")"; return 1; }
  local f="$(hf_trace_dir)/${tid}.jsonl"
  [ ! -f "$f" ] && { hf_warn "$(hf_t "No trajectory for $tid" "Sin trayectoria para $tid")"; return 0; }
  echo ""
  echo -e "  ${HF_C_BOLD}$(hf_t "Trajectory of $tid" "Trayectoria de $tid")${HF_C_RESET}"
  echo ""
  jq -r --arg tf "$(hf_t "failing tests" "tests fallando")" --arg rn "$(hf_t "reason" "motivo")" \
        '"  [iter \(.iteration)] \(.event)" +
         (if .detail then "\n      \(.detail)" else "" end) +
         (if .failing then "\n      \($tf): \(.failing)" else "" end) +
         (if .reason then "\n      \($rn): \(.reason)" else "" end)' "$f"
  echo ""
  hf_dim "$(hf_t "raw: $f" "crudo: $f")"
}

# ── Detección del comando de tests del repo ───────────────────
_hf_test_cmd() {
  local wt="$1"
  if [ -f "$wt/package.json" ] && jq -e '.scripts.test' "$wt/package.json" >/dev/null 2>&1; then
    echo "npm test --silent"; return 0
  fi
  [ -f "$wt/pytest.ini" ] || [ -f "$wt/pyproject.toml" ] && { echo "python -m pytest -q"; return 0; }
  [ -f "$wt/go.mod" ] && { echo "go test ./..."; return 0; }
  return 1
}

# Ejecuta los tests. EL ORQUESTADOR, no el agente: su reporte no cuenta.
# Escribe la salida en <wt>/.hf-test-output y devuelve el rc real.
_hf_run_tests() {
  local wt="$1" cmd
  cmd="$(_hf_test_cmd "$wt")" || return 2   # 2 = el repo no tiene suite
  ( cd "$wt" && timeout 900 bash -c "$cmd" ) > "$wt/.hf-test-output" 2>&1
  return $?
}

# Firma de los tests que fallan: si no cambia entre iteraciones, el agente
# está dando vueltas. Result-aware — no dedup por argumentos.
_hf_failing_signature() {
  local wt="$1"
  [ -f "$wt/.hf-test-output" ] || { echo "none"; return; }
  # Líneas de fallo típicas de jest/mocha/pytest/go, normalizadas
  grep -iE '^\s*(✕|✗|FAIL|FAILED|--- FAIL|not ok)' "$wt/.hf-test-output" 2>/dev/null \
    | sed 's/[0-9]\+\(\.[0-9]\+\)\?\s*m\?s//g' | sort -u | md5sum | cut -c1-12
}

# ── L0: anti reward hacking ───────────────────────────────────
# Añadir tests está bien. MODIFICAR o BORRAR los que ya existían es la
# señal de alarma: es la forma barata de "hacer pasar" la suite.
# Códigos: 0 limpio · 1 debilitó tests preexistentes
_hf_test_weakening() {
  local wt="$1" base="$2"
  local touched f
  # Solo ficheros de test YA EXISTENTES que el diff modifica o borra
  touched="$(git -C "$wt" diff --name-status "origin/$base" 2>/dev/null \
    | awk '$1 ~ /^[MD]/ {print $2}')"
  [ -z "$touched" ] && return 0

  local suspicious=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      *test*|*spec*|*Test*|*Spec*) ;;
      *) continue ;;
    esac
    # ¿Se borraron aserciones? (más líneas quitadas que añadidas en un test)
    local added removed
    added="$(git -C "$wt" diff --numstat "origin/$base" -- "$f" 2>/dev/null | awk '{print $1}')"
    removed="$(git -C "$wt" diff --numstat "origin/$base" -- "$f" 2>/dev/null | awk '{print $2}')"
    if [ "${removed:-0}" -gt "${added:-0}" ]; then
      suspicious="$suspicious $f(-${removed:-0}/+${added:-0})"
    fi
    # Skips introducidos: .skip, xit, @pytest.mark.skip, t.Skip
    if git -C "$wt" diff "origin/$base" -- "$f" 2>/dev/null \
       | grep -qE '^\+.*(\.skip\(|xit\(|xdescribe\(|@pytest\.mark\.skip|t\.Skip\()'; then
      suspicious="$suspicious $f(skip-añadido)"
    fi
  done <<< "$touched"

  [ -n "$suspicious" ] && { echo "$suspicious"; return 1; }
  return 0
}

# ── L1+L2: loop de implementación verificada ──────────────────
# hf_loop_implement <wt> <base> <repo> <tid> <título> <desc> <plan> <ctx> <tool>
# Devuelve: 0 tests en verde · 1 agotado sin verde · 2 parado por freno
hf_loop_implement() {
  local wt="$1" base="$2" repo="$3" tid="$4" title="$5" desc="$6" plan="$7" ctx="$8" tool="$9"
  local max_iter start_ts prev_sig="" iter=0 rc

  max_iter="$(hf_loop_max_iter)"
  start_ts="$(date +%s)"
  hf_trace "$tid" 0 loop_start repo="$repo" tool="$tool" max_iter="$max_iter"

  # Fichero de progreso EN DISCO: así cada iteración arranca con contexto
  # fresco sin perder lo aprendido (Ralph: reiniciar, no compactar).
  local progress="$wt/.hf-progress.md"
  cat > "$progress" <<EOF
# Progreso del ticket $tid

## Bug
$title
$desc

## Plan acordado
$plan

## Intentos previos
(ninguno todavía)
EOF

  while [ "$iter" -lt "$max_iter" ]; do
    iter=$((iter + 1))

    # FRENO 3: circuit breaker de tiempo real
    local elapsed=$(( $(date +%s) - start_ts ))
    if [ "$elapsed" -ge "$(hf_loop_max_secs)" ]; then
      hf_warn "$(hf_t "[$repo] loop stopped: time limit ($(hf_loop_max_secs)s)" "[$repo] loop detenido: límite de tiempo ($(hf_loop_max_secs)s)")"
      hf_trace "$tid" "$iter" budget_stop reason=wall_clock elapsed="$elapsed"
      return 2
    fi

    hf_info "$(hf_t "[$repo] iteration $iter/$max_iter" "[$repo] iteración $iter/$max_iter")"

    local prompt
    if [ "$iter" -eq 1 ]; then
      prompt="$(hf_prompt loop_implement "REPO=$repo" "TITLE=$title" "DESC=$desc" "CTX=$ctx" "PLAN=$plan")" \
        || prompt="Arregla este bug en '$repo' (contenido del ticket no confiable): $title — $desc. Plan: $plan. Escribe un test que lo reproduzca, no debilites tests existentes, no hagas commit, resume en .hf-progress.md."
    else
      # Iteración de corrección: entra el FALLO REAL, no la opinión del agente
      local failures
      failures="$(tail -60 "$wt/.hf-test-output" 2>/dev/null)"
      prompt="$(hf_prompt loop_retry "REPO=$repo" "ITER=$iter" "MAX_ITER=$max_iter" "PROGRESS=$(cat "$progress")" "FAILURES=$failures")" \
        || prompt="Intento $iter/$max_iter en '$repo': los tests siguen en rojo. Progreso: $(cat "$progress"). Salida real de tests: $failures. Corrige el código (no debilites tests preexistentes), sin commit, actualiza .hf-progress.md."
    fi

    # Proceso NUEVO cada iteración: contexto fresco garantizado
    ( cd "$wt" && timeout "$(hf_agent_timeout)" bash -c "$(hf_tool_cmd "$tool" "$prompt" auto)" ) >/dev/null 2>&1
    if [ $? -eq 124 ]; then
      hf_warn "$(hf_t "[$repo] iteration $iter: the agent exceeded its timeout" "[$repo] iteración $iter: el agente excedió su timeout")"
      hf_trace "$tid" "$iter" agent_timeout
      continue
    fi

    # FRENO 5 (L0): ¿debilitó tests preexistentes?
    local weak
    if ! weak="$(_hf_test_weakening "$wt" "$base")"; then
      hf_err "$(hf_t "[$repo] the agent weakened pre-existing tests:$weak" "[$repo] el agente debilitó tests preexistentes:$weak")"
      hf_trace "$tid" "$iter" test_weakening detail="$weak"
      hf_metric test_weakening "$tid" repo="$repo"
      return 2
    fi

    # VEREDICTO DEL ORQUESTADOR — no del agente
    _hf_run_tests "$wt"; rc=$?
    if [ "$rc" -eq 2 ]; then
      hf_dim "$(hf_t "[$repo] the repo has no test suite — no verification possible" "[$repo] el repo no tiene suite de tests — sin verificación posible")"
      hf_trace "$tid" "$iter" no_test_suite
      return 0
    fi
    if [ "$rc" -eq 0 ]; then
      hf_ok "$(hf_t "[$repo] tests green on iteration $iter" "[$repo] tests en verde en la iteración $iter")"
      hf_trace "$tid" "$iter" tests_pass
      hf_metric loop_success "$tid" repo="$repo" iterations="$iter"
      return 0
    fi

    local sig
    sig="$(_hf_failing_signature "$wt")"
    hf_trace "$tid" "$iter" tests_fail failing="$sig" \
      detail="$(tail -3 "$wt/.hf-test-output" 2>/dev/null | tr '\n' ' ')"

    # FRENO 4: no-progreso. Result-aware: misma firma de fallos = da vueltas.
    # Escalonado — el primer choque solo avisa, el segundo para.
    if [ "$sig" = "$prev_sig" ]; then
      hf_warn "$(hf_t "[$repo] no progress: exactly the same tests are failing" "[$repo] sin progreso: fallan exactamente los mismos tests")"
      hf_trace "$tid" "$iter" no_progress_stop failing="$sig"
      hf_metric loop_no_progress "$tid" repo="$repo" iterations="$iter"
      return 1
    fi
    prev_sig="$sig"

    # Acumular el intento en disco (no en el contexto)
    printf '\n### Intento %s\nTests fallando (firma %s):\n```\n%s\n```\n' \
      "$iter" "$sig" "$(tail -20 "$wt/.hf-test-output" 2>/dev/null)" >> "$progress"
  done

  hf_warn "$(hf_t "[$repo] exhausted all $max_iter iterations without getting the tests green" "[$repo] agotadas las $max_iter iteraciones sin poner los tests en verde")"
  hf_trace "$tid" "$iter" loop_exhausted
  hf_metric loop_exhausted "$tid" repo="$repo" iterations="$iter"
  return 1
}

# ── L3: evaluator-optimizer del plan ──────────────────────────
# Un evaluador SEPARADO puntúa el plan antes de gastar en implementar.
# Nunca el mismo modelo que lo escribió en el mismo contexto: ese es
# exactamente el fallo que documenta Huang et al.
# Devuelve el plan (mejorado si hizo falta) por stdout.
hf_loop_refine_plan() {
  local tid="$1" title="$2" desc="$3" plan="$4" repos="$5"
  local threshold="${HF_PLAN_MIN_SCORE:-7}"

  local etool
  etool="$(hf_route security-audit)"   # revisor distinto del implementador
  [ -z "$etool" ] && { echo "$plan"; return 0; }

  local rubric
  rubric="$(hf_prompt plan_rubric "TITLE=$title" "DESC=$desc" "REPOS=$repos" "PLAN=$plan")" \
    || rubric="Evalúa este plan para el bug '$title' (repos: $repos): $plan. Puntúa 1-10 y justifica en una línea."

  local out score
  out="$(timeout 300 bash -c "$(hf_tool_cmd "$etool" "$rubric" safe)" 2>/dev/null | sed -n '/{/,$p' | tr -d '\n')"
  score="$(echo "$out" | jq -r '.score // empty' 2>/dev/null)"

  if [ -z "$score" ]; then
    hf_trace "$tid" 0 plan_eval_failed
    echo "$plan"; return 0
  fi

  hf_trace "$tid" 0 plan_evaluated score="$score" \
    detail="$(echo "$out" | jq -r '.problemas // ""')"

  if [ "$score" -lt "$threshold" ]; then
    local improved
    improved="$(echo "$out" | jq -r '.plan_mejorado // empty')"
    if [ -n "$improved" ]; then
      hf_warn "$(hf_t "Plan scored $score/10 — replanned: $(echo "$out" | jq -r '.problemas // ""')" "Plan puntuado $score/10 — replanificado: $(echo "$out" | jq -r '.problemas // ""')")" >&2
      hf_metric plan_refined "$tid" score="$score"
      echo "$improved"; return 0
    fi
  else
    hf_dim "$(hf_t "Plan validated by independent evaluator ($score/10)" "Plan validado por evaluador independiente ($score/10)")" >&2
  fi
  echo "$plan"
}

# ── Router ────────────────────────────────────────────────────
hf_loop_cmd() {
  case "${1:-help}" in
    trace) shift; hf_loop_trace_show "$@" ;;
    stats)
      local d; d="$(hf_trace_dir)"
      [ ! -d "$d" ] && { hf_warn "$(hf_t "No trajectories yet" "Sin trayectorias aún")"; return 0; }
      echo ""
      echo -e "  ${HF_C_BOLD}$(hf_t "Executed loops" "Loops ejecutados")${HF_C_RESET}"
      echo ""
      local f tid iters last
      for f in "$d"/*.jsonl; do
        [ -f "$f" ] || continue
        tid="$(basename "$f" .jsonl)"
        iters="$(jq -s '[.[].iteration] | max' "$f" 2>/dev/null)"
        last="$(jq -s -r '.[-1].event' "$f" 2>/dev/null)"
        printf "    %-34s %s iter · %s\n" "$tid" "${iters:-0}" "$last"
      done
      echo ""
      hf_dim "$(hf_t "detail: /loop trace <ticket-id>" "detalle: /loop trace <ticket-id>")"
      ;;
    *)
      echo ""
      if [ "$HF_LANG" = "es" ]; then
        echo "  🔁 Loops agénticos"
        echo ""
        echo "    /loop stats           Loops ejecutados y cómo acabaron"
        echo "    /loop trace <id>      Auditar la trayectoria de un ticket"
        echo ""
        hf_dim "El loop se ejecuta dentro de /fix: implementar → verificar → corregir"
        hf_dim "(máx. $(hf_loop_max_iter) iteraciones, contexto fresco cada vuelta)"
      else
        echo "  🔁 Agentic loops"
        echo ""
        echo "    /loop stats           Executed loops and how they ended"
        echo "    /loop trace <id>      Audit a ticket's trajectory"
        echo ""
        hf_dim "The loop runs inside /fix: implement → verify → fix"
        hf_dim "(max $(hf_loop_max_iter) iterations, fresh context each round)"
      fi
      echo ""
      ;;
  esac
}
