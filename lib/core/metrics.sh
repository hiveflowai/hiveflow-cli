#!/usr/bin/env bash
# ── Telemetría del harness ────────────────────────────────────
# Un evento JSON por línea (JSONL) en ~/.config/hiveflow/metrics.jsonl.
# Sin esto el agente es fire-and-forget: no sabrías si ayuda o estorba.

hf_metrics_file() { echo "${HF_METRICS_FILE:-$HF_CONFIG_DIR/metrics.jsonl}"; }

# hf_metric <evento> <ticket> [k=v ...]
# Ej: hf_metric pr_created HF-123 repo=backend duration_s=412 tool=claude
hf_metric() {
  local event="$1" ticket="${2:-}"; shift 2 2>/dev/null || shift $#
  local extra="{}" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    # números sin comillas, resto como string
    if [[ "$v" =~ ^-?[0-9]+$ ]]; then
      extra="$(echo "$extra" | jq -c --arg k "$k" --argjson v "$v" '.[$k]=$v')"
    else
      extra="$(echo "$extra" | jq -c --arg k "$k" --arg v "$v" '.[$k]=$v')"
    fi
  done
  jq -nc --arg e "$event" --arg t "$ticket" --arg ts "$(date -Iseconds)" --argjson x "$extra" \
    '{ts:$ts, event:$e, ticket:$t} + $x' >> "$(hf_metrics_file)"
}

# Cronómetro simple (segundos)
hf_timer_start() { date +%s; }
hf_timer_end()   { echo $(( $(date +%s) - ${1:-$(date +%s)} )); }

# ── Informe ───────────────────────────────────────────────────
hf_metrics_report() {
  local f days since
  f="$(hf_metrics_file)"
  days="${1:-7}"
  [ ! -f "$f" ] && { hf_warn "$(hf_t "No metrics yet ($f)" "Aún no hay métricas ($f)")"; return 0; }
  since="$(date -d "-$days days" -Iseconds 2>/dev/null || date -v-"${days}"d -Iseconds)"

  local events
  events="$(jq -c --arg s "$since" 'select(.ts >= $s)' "$f")"
  [ -z "$events" ] && { hf_warn "$(hf_t "No events in the last $days days" "Sin eventos en los últimos $days días")"; return 0; }

  echo ""
  echo -e "  ${HF_C_BOLD}📊 $(hf_t "Harness — last $days days" "Harness — últimos $days días")${HF_C_RESET}"
  echo ""

  local started prs merged rejected blocked triaged_out failed
  started="$(echo "$events"   | jq -s '[.[] | select(.event=="fix_started")] | length')"
  prs="$(echo "$events"       | jq -s '[.[] | select(.event=="pr_created")] | length')"
  merged="$(echo "$events"    | jq -s '[.[] | select(.event=="pr_merged")] | length')"
  rejected="$(echo "$events"  | jq -s '[.[] | select(.event=="pr_rejected")] | length')"
  blocked="$(echo "$events"   | jq -s '[.[] | select(.event=="blocked")] | length')"
  triaged_out="$(echo "$events" | jq -s '[.[] | select(.event=="triaged_out")] | length')"
  failed="$(echo "$events"    | jq -s '[.[] | select(.event=="fix_failed")] | length')"

  printf "  %-26s %s\n" "$(hf_t "Tickets worked:" "Tickets abordados:")" "$started"
  printf "  %-26s %s\n" "$(hf_t "  → filtered in triage:" "  → filtrados en triaje:")" "$triaged_out"
  printf "  %-26s %s\n" "$(hf_t "  → blocked by guard:" "  → bloqueados por guard:")" "$blocked"
  printf "  %-26s %s\n" "$(hf_t "  → failed:" "  → fallidos:")" "$failed"
  printf "  %-26s %s\n" "$(hf_t "PRs created:" "PRs creados:")" "$prs"
  printf "  %-26s ${HF_C_GREEN}%s${HF_C_RESET}\n" "$(hf_t "  → merged:" "  → mergeados:")" "$merged"
  printf "  %-26s ${HF_C_RED}%s${HF_C_RESET}\n" "$(hf_t "  → rejected:" "  → rechazados:")" "$rejected"

  # La métrica que decide si el agente sirve
  local decided
  decided=$(( merged + rejected ))
  if [ "$decided" -gt 0 ]; then
    echo ""
    printf "  ${HF_C_BOLD}%-26s %s%%${HF_C_RESET}  $(hf_t "(of %s PRs already decided)" "(de %s PRs ya decididos)")\n" \
      "$(hf_t "Acceptance rate:" "Tasa de aceptación:")" "$(( merged * 100 / decided ))" "$decided"
  fi

  # Cobertura de reproducción: fixes que demuestran que el bug está resuelto
  local no_test with_test
  no_test="$(echo "$events" | jq -s '[.[] | select(.event=="no_repro_test")] | length')"
  if [ "$prs" -gt 0 ]; then
    with_test=$(( prs - no_test ))
    printf "  %-26s %s%%  $(hf_t "(%s of %s PRs)" "(%s de %s PRs)")\n" "$(hf_t "With repro test:" "Con test de reproducción:")" \
      "$(( with_test * 100 / prs ))" "$with_test" "$prs"
  fi

  # Duración media hasta PR
  local avg
  avg="$(echo "$events" | jq -s '[.[] | select(.event=="pr_created") | .duration_s // empty] | if length>0 then (add/length|floor) else empty end')"
  [ -n "$avg" ] && printf "  %-26s %s min\n" "$(hf_t "Avg time to PR:" "Tiempo medio a PR:")" "$((avg / 60))"

  # Dónde falla
  local by_repo
  by_repo="$(echo "$events" | jq -sr '[.[] | select(.event=="fix_failed" or .event=="blocked") | .repo // empty]
    | group_by(.) | map({repo: .[0], n: length}) | sort_by(-.n) | .[] | "    \(.repo): \(.n)"' 2>/dev/null)"
  [ -n "$by_repo" ] && { echo ""; echo "  $(hf_t "Failures/blocks by repo:" "Fallos/bloqueos por repo:")"; echo "$by_repo"; }

  # Motivos de bloqueo (dice qué endurecer o relajar)
  local reasons
  reasons="$(echo "$events" | jq -sr '[.[] | select(.event=="blocked" or .event=="triaged_out") | .reason // empty]
    | group_by(.) | map({r: .[0], n: length}) | sort_by(-.n) | .[] | "    \(.r): \(.n)"' 2>/dev/null)"
  [ -n "$reasons" ] && { echo ""; echo "  $(hf_t "Filtering reasons:" "Motivos de filtrado:")"; echo "$reasons"; }

  # Por qué rechazas los PRs: la señal más accionable del harness
  local rejections
  rejections="$(echo "$events" | jq -sr --arg nc "$(hf_t "no comment" "sin comentario")" '[.[] | select(.event=="pr_rejected")]
    | .[] | "    [\(.repo // "?")] \(.reason // $nc | .[0:90])"' 2>/dev/null)"
  if [ -n "$rejections" ]; then
    echo ""
    echo -e "  ${HF_C_BOLD}$(hf_t "Why they were rejected" "Por qué se rechazaron")${HF_C_RESET} ${HF_C_DIM}$(hf_t "(what to fix in prompts/routing)" "(qué corregir en prompts/routing)")${HF_C_RESET}:"
    echo "$rejections"
  fi

  # Qué CLI produce PRs que aceptas
  local by_tool
  by_tool="$(echo "$events" | jq -sr --arg acc "$(hf_t "accepted" "aceptados")" '
    [.[] | select(.event=="pr_created") | {ticket, tool: (.tool // "?")}] as $created
    | [.[] | select(.event=="pr_merged") | .ticket] as $merged
    | $created | group_by(.tool) | map({
        tool: .[0].tool, n: length,
        ok: [.[] | select(.ticket as $t | $merged | index($t))] | length
      }) | .[] | "    \(.tool): \(.ok)/\(.n) \($acc)"' 2>/dev/null)"
  [ -n "$by_tool" ] && { echo ""; echo "  $(hf_t "Acceptance by CLI:" "Aceptación por CLI:")"; echo "$by_tool"; }

  echo ""
  hf_dim "$(hf_t "raw detail: $f" "detalle crudo: $f")"
}

# ¿Ya se registró el desenlace de este ticket?
# Nota: slurp + any, NO 'jq -e select' en streaming — con JSONL, -e mira solo
# la última entrada procesada y devuelve 4 si esa no produjo salida, aunque
# hubiera coincidencias antes. Ese fallo re-notificaría al usuario cada pasada.
_hf_outcome_seen() {
  local tid="$1" f
  f="$(hf_metrics_file)"
  [ -f "$f" ] || return 1
  jq -e -s --arg t "$tid" \
    'any(.[]; .ticket == $t and (.event == "pr_merged" or .event == "pr_rejected"))' \
    "$f" >/dev/null 2>&1
}

# Reconcilia el destino de los PRs del bot y CIERRA EL LAZO:
#   merged → avisa al reportador y mueve el ticket a la columna final
#   cerrado sin mergear → registra el motivo (la señal más valiosa que hay)
hf_metrics_reconcile() {
  command -v gh >/dev/null || return 0
  local f name path tid branch st url body
  f="$(hf_metrics_file)"
  while IFS='|' read -r name path; do
    while IFS=$'\t' read -r branch st url; do
      [ -z "$branch" ] && continue
      tid="${branch#fix/}"
      _hf_outcome_seen "$tid" && continue

      case "$st" in
        MERGED)
          hf_metric pr_merged "$tid" repo="$name"
          # El usuario que reportó el bug merece enterarse de que se arregló
          _hf_notify_ticket "$tid" "$(hf_t "✅ The fix for ticket $tid was merged into $name. Thanks for reporting it!" "✅ El fix del ticket $tid se integró en $name. ¡Gracias por reportarlo!")" 2>/dev/null
          hf_ticket_move "$tid" "$(hf_col_shipped)" 2>/dev/null
          echo "$(hf_t "[reconcile] $tid merged → '$(hf_col_shipped)' + user notified" "[reconcile] $tid mergeado → '$(hf_col_shipped)' + usuario notificado")"
          ;;
        CLOSED)
          # Motivo del rechazo: último comentario del PR (lo que escribió quien
          # lo cerró). Es lo que permite mejorar prompts y routing.
          body="$(cd "$path" 2>/dev/null && gh pr view "$branch" --json comments \
            --jq '[.comments[].body] | last // ""' 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
          hf_metric pr_rejected "$tid" repo="$name" reason="${body:-sin_comentario}"
          echo "$(hf_t "[reconcile] $tid rejected — reason: ${body:-(no comment)}" "[reconcile] $tid rechazado — motivo: ${body:-（sin comentario）}")"
          ;;
      esac
    done < <(cd "$path" 2>/dev/null && gh pr list --state closed --limit 50 \
      --json headRefName,state,url \
      --jq '.[] | select(.headRefName | startswith("fix/HF-")) | "\(.headRefName)\t\(.state)\t\(.url)"' 2>/dev/null)
  done < <(hf_repos_catalog)
}

# ── Routing adaptativo ────────────────────────────────────────
# El routing estático (tabla por tipo de tarea) es una hipótesis. Con
# historial suficiente, los datos mandan: si en ESTE repo un CLI produce
# PRs que aceptas y otro no, conviene usar el que funciona.
#
# Devuelve el mejor CLI para un repo, o vacío si no hay evidencia.
# Exige un mínimo de muestras para no sobreajustar a dos casualidades.
hf_best_tool_for_repo() {
  local repo="$1" f min
  f="$(hf_metrics_file)"
  [ -f "$f" ] || return 1
  min="${HF_ADAPTIVE_MIN_SAMPLES:-4}"

  jq -s -r --arg repo "$repo" --argjson min "$min" '
    [.[] | select(.event=="pr_created" and .repo==$repo)] as $created
    | [.[] | select(.event=="pr_merged")   | .ticket] as $merged
    | [.[] | select(.event=="pr_rejected") | .ticket] as $rejected
    | $created
    | map(. + {decided: ((.ticket as $t | $merged | index($t)) != null
                      or (.ticket as $t | $rejected | index($t)) != null),
               ok: ((.ticket as $t | $merged | index($t)) != null)})
    | map(select(.decided))
    | group_by(.tool)
    | map({tool: .[0].tool, n: length, ok: (map(select(.ok)) | length)})
    | map(select(.n >= $min))
    | map(. + {rate: (.ok * 100 / .n)})
    | sort_by(-.rate)
    | if length > 0 and .[0].rate >= 60 then .[0].tool else empty end
  ' "$f" 2>/dev/null
}

# Informe legible de lo aprendido por repo
hf_adaptive_report() {
  local f
  f="$(hf_metrics_file)"
  [ ! -f "$f" ] && { hf_warn "$(hf_t "No metrics yet" "Sin métricas aún")"; return 0; }
  echo ""
  echo -e "  ${HF_C_BOLD}🧭 $(hf_t "Learned routing" "Routing aprendido")${HF_C_RESET} ${HF_C_DIM}$(hf_t "(min. ${HF_ADAPTIVE_MIN_SAMPLES:-4} decided PRs)" "(mín. ${HF_ADAPTIVE_MIN_SAMPLES:-4} PRs decididos)")${HF_C_RESET}"
  echo ""
  local out
  out="$(jq -s -r --argjson min "${HF_ADAPTIVE_MIN_SAMPLES:-4}" \
    --arg acc "$(hf_t "accepted" "aceptados")" \
    --arg insuf "$(hf_t "  (not enough samples)" "  (muestras insuficientes)")" '
    [.[] | select(.event=="pr_created")] as $created
    | [.[] | select(.event=="pr_merged")   | .ticket] as $merged
    | [.[] | select(.event=="pr_rejected") | .ticket] as $rejected
    | $created
    | map(. + {decided: ((.ticket as $t | $merged | index($t)) != null
                      or (.ticket as $t | $rejected | index($t)) != null),
               ok: ((.ticket as $t | $merged | index($t)) != null)})
    | map(select(.decided))
    | group_by(.repo)
    | map({repo: .[0].repo,
           tools: (group_by(.tool) | map({tool: .[0].tool, n: length,
                                          ok: (map(select(.ok)) | length)}))})
    | .[] | .repo as $r | .tools[]
    | "    \($r): \(.tool) → \(.ok)/\(.n) \($acc)\(if .n >= $min then "" else $insuf end)"
  ' "$f" 2>/dev/null)"
  [ -n "$out" ] && echo "$out" || echo "    $(hf_t "(no decided PRs yet)" "(aún sin PRs decididos)")"
  echo ""
}

# ── Autonomía graduada ────────────────────────────────────────
# Auto-merge SOLO para clases de cambio de bajo riesgo y con historial
# probado. Apagado por defecto: la autonomía se gana con datos, no se
# presupone. Config: .tickets.automerge.<clase> = true
#
# Clases (de menor a mayor riesgo):
#   docs   — solo .md, comentarios, textos
#   deps   — bumps de versión de parche en lockfiles
# Nada más es elegible: la lógica de negocio siempre pasa por humano.

# _hf_change_class <worktree> <base> → docs | deps | code
# Clasificación en BASH PURO a propósito: de esto depende si un PR puede
# mergearse sin humano. `grep` puede estar envuelto en la máquina (shims a
# ugrep, alias con -G, GREP_OPTIONS…) y una inversión -v que se comporte
# distinto clasificaría código como documentación. Sin dependencias externas
# el veredicto es el mismo en cualquier entorno.
_hf_change_class() {
  local wt="$1" base="$2" files f
  files="$( { git -C "$wt" diff --name-only "origin/$base"; git -C "$wt" ls-files --others --exclude-standard; } | sort -u)"
  [ -z "$files" ] && { echo "code"; return; }

  local all_docs=1 all_deps=1
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      *.md|*.mdx|*.txt|*.rst|docs/*) ;;
      *) all_docs=0 ;;
    esac
    case "$f" in
      package.json|package-lock.json|yarn.lock|pnpm-lock.yaml|\
      */package.json|*/package-lock.json|*/yarn.lock|*/pnpm-lock.yaml) ;;
      *) all_deps=0 ;;
    esac
  done <<< "$files"

  [ "$all_docs" -eq 1 ] && { echo "docs"; return; }
  [ "$all_deps" -eq 1 ] && { echo "deps"; return; }
  echo "code"
}

# Tasa de aceptación histórica de una clase (0-100); -1 si hay pocos datos
_hf_class_acceptance() {
  local class="$1" f merged rejected total
  f="$(hf_metrics_file)"
  [ -f "$f" ] || { echo "-1"; return; }
  merged="$(jq -s --arg c "$class" '[.[] | select(.event=="pr_merged" and .change_class==$c)] | length' "$f")"
  rejected="$(jq -s --arg c "$class" '[.[] | select(.event=="pr_rejected" and .change_class==$c)] | length' "$f")"
  total=$((merged + rejected))
  # Menos de 5 decididos: no hay evidencia suficiente para confiar
  [ "$total" -lt 5 ] && { echo "-1"; return; }
  echo $(( merged * 100 / total ))
}

# ¿Se puede auto-mergear este PR? Todas las condiciones deben cumplirse.
# 0 = sí · 1 = no (con motivo por stdout)
hf_automerge_eligible() {
  local wt="$1" base="$2" class acc
  class="$(_hf_change_class "$wt" "$base")"

  [ "$class" = "code" ] && { echo "$(hf_t "code change (never automatic)" "cambio de código (nunca automático)")"; return 1; }
  [ "$(hf_config_get ".tickets.automerge.$class")" = "true" ] || { echo "$(hf_t "automerge disabled for class '$class'" "automerge desactivado para clase '$class'")"; return 1; }

  acc="$(_hf_class_acceptance "$class")"
  [ "$acc" -lt 0 ] && { echo "$(hf_t "class '$class' lacks history (<5 decided PRs)" "clase '$class' sin historial suficiente (<5 PRs decididos)")"; return 1; }
  [ "$acc" -lt "${HF_AUTOMERGE_MIN_ACCEPTANCE:-90}" ] && { echo "$(hf_t "'$class' acceptance is ${acc}% (<${HF_AUTOMERGE_MIN_ACCEPTANCE:-90}%)" "aceptación de '$class' es ${acc}% (<${HF_AUTOMERGE_MIN_ACCEPTANCE:-90}%)")"; return 1; }

  echo "$(hf_t "$class (historical acceptance ${acc}%)" "$class (aceptación histórica ${acc}%)")"
  return 0
}

# ── Gate de CI ────────────────────────────────────────────────
# Espera a los checks del PR. El CI sabe lo que el `npm test` local no
# (matrices de versiones, servicios, lint, build de producción).
# Códigos: 0 verde · 1 rojo · 2 timeout/pendiente · 3 sin checks
hf_ci_gate() {
  local wt="$1" branch="$2" timeout_s="${3:-900}"
  command -v gh >/dev/null || return 3
  local interval="${HF_CI_POLL_INTERVAL:-30}"
  local waited=0 out
  while :; do
    out="$(cd "$wt" && gh pr checks "$branch" --json bucket --jq '.[].bucket' 2>/dev/null)"

    if [ -z "$out" ]; then
      # Sin checks registrados: puede que el CI tarde en aparecer.
      # Pasado el margen, asumimos que este repo no tiene CI.
      [ "$waited" -ge "${HF_CI_NO_CHECKS_GRACE:-120}" ] && return 3
    elif echo "$out" | grep -q '^fail$'; then
      return 1                       # algún check en rojo → veredicto inmediato
    elif ! echo "$out" | grep -q '^pending$'; then
      return 0                       # nada pendiente y nada roto → verde
    fi

    waited=$((waited + interval))
    [ "$waited" -ge "$timeout_s" ] && return 2   # sigue pendiente → reevaluar luego
    sleep "$interval"
  done
}
