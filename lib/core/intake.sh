#!/usr/bin/env bash
# ── Intake plural ─────────────────────────────────────────────
# El trabajo no solo llega de tickets de soporte. Este módulo normaliza
# otras fuentes a la MISMA cola (cards del kanban), de modo que el
# pipeline /fix no sabe ni le importa de dónde vino el trabajo.
#
# Fuentes:
#   alert   — alertas de producción (Sentry/webhook/JSON)
#   debt    — deuda técnica: TODO/FIXME del código
#   audit   — vulnerabilidades de dependencias (npm audit)

# Repos únicos POR PATH. El catálogo trae alias (backend →
# hiveflow-backend) que resuelven al mismo directorio: escanearlos todos
# crearía dos tickets para el mismo hallazgo.
_hf_repos_unique() {
  hf_repos_catalog | awk -F'|' '!seen[$2]++'
}

# hf_intake_push <origen> <título> <descripción> [prioridad] [repo]
# Crea una card en la columna trigger. Es el ÚNICO punto de entrada:
# cualquier fuente nueva solo tiene que llamar aquí.
hf_intake_push() {
  local source="$1" title="$2" desc="$3" priority="${4:-medium}" repo="${5:-}"
  local kid
  kid="$(hf_config_get '.tickets.kanban_id')"
  [ -z "$kid" ] && { hf_err "$(hf_t "Tickets not configured (/tickets setup)" "Tickets sin configurar (/tickets setup)")"; return 1; }

  # ID estable por contenido: reejecutar el escaneo no duplica cards
  local hash tid
  hash="$(printf '%s|%s|%s' "$source" "$repo" "$title" | md5sum | cut -c1-8)"
  tid="HF-${source}-${hash}"

  local fresh
  fresh="$(hf_api GET "/app-instances/$kid")"
  [ -z "$fresh" ] && { hf_err "$(hf_t "Could not read the board" "No se pudo leer el tablero")"; return 1; }

  # ¿Ya existe? (abierta o ya resuelta: no reabrir lo cerrado)
  if echo "$fresh" | _hf_cards_flat | jq -e --arg id "$tid" 'any(.[]; (.ticketId // "") == $id)' >/dev/null 2>&1; then
    echo "$(hf_t "[intake] $tid already exists — skipped" "[intake] $tid ya existe — omitido")"
    return 0
  fi

  local colmap cards cols trigger
  trigger="$(hf_col_trigger)"
  colmap="$(echo "$fresh" | _hf_colmap)"
  cards="$(echo "$fresh" | _hf_cards_flat | jq -c \
    --arg id "$tid" --arg t "$title" --arg d "$desc" --arg p "$priority" \
    --arg c "$trigger" --arg s "$source" --arg r "$repo" --argjson m "$colmap" \
    '[.[] | .column = ($m[.column] // .column)]
     + [{id: $id, ticketId: $id, title: $t, description: $d,
         priority: $p, column: $c, source: $s} + (if $r != "" then {repoHint: $r} else {} end)]')"
  cols="$(echo "$fresh" | jq -c --arg col "$trigger" '
    [(.data.columns // [])[] | if type == "object" then .title else . end] as $t
    | if ($t | index($col)) then $t else $t + [$col] end')"

  hf_api PATCH "/app-instances/$kid/data" \
    "$(jq -nc --argjson cards "$cards" --argjson cols "$cols" \
      '{op:"set", payload:{fields:{cards:$cards, columns:$cols}}}')" >/dev/null \
    && { echo "$(hf_t "[intake] $tid created ($source, $priority): $title" "[intake] $tid creado ($source, $priority): $title")"; hf_metric intake_created "$tid" source="$source" priority="$priority"; }
}

# ── Alertas de producción ─────────────────────────────────────
# Acepta JSON por stdin o fichero. Formato Sentry-like o genérico:
#   {"title":"...", "message":"...", "level":"error", "culprit":"...", "project":"..."}
hf_intake_alert() {
  local input="${1:--}"
  local json
  json="$(cat "$input" 2>/dev/null)" || { hf_err "$(hf_t "Could not read the alert" "No se pudo leer la alerta")"; return 1; }
  echo "$json" | jq -e . >/dev/null 2>&1 || { hf_err "$(hf_t "The alert is not valid JSON" "La alerta no es JSON válido")"; return 1; }

  local title msg level culprit project priority
  title="$(echo "$json"   | jq -r --arg d "$(hf_t "Untitled alert" "Alerta sin título")" '.title // .error // .message // $d')"
  msg="$(echo "$json"     | jq -r '.message // .culprit // ""')"
  level="$(echo "$json"   | jq -r '.level // "error"')"
  culprit="$(echo "$json" | jq -r '.culprit // .transaction // ""')"
  project="$(echo "$json" | jq -r '.project // .repo // ""')"

  case "$level" in
    fatal|critical) priority="critical" ;;
    error)          priority="high" ;;
    warning)        priority="medium" ;;
    *)              priority="low" ;;
  esac

  hf_intake_push alert "$title" \
"$(hf_t "Production alert (level: $level).
$msg
${culprit:+Location: $culprit}
${project:+Project: $project}

Investigate the root cause from the stack/location and fix it." "Alerta de producción (nivel: $level).
$msg
${culprit:+Ubicación: $culprit}
${project:+Proyecto: $project}

Investiga la causa raíz a partir del stack/ubicación y arréglala.")" \
    "$priority" "$project"
}

# ── Deuda técnica: TODO/FIXME ─────────────────────────────────
# Solo marcas explícitas de deuda accionable, no cualquier comentario.
hf_intake_debt() {
  local limit="${1:-5}"
  local name path found=0
  while IFS='|' read -r name path; do
    [ "$found" -ge "$limit" ] && break
    # FIXME/HACK/XXX: deuda real. TODO suele ser ruido, se excluye.
    local hits
    hits="$(git -C "$path" grep -nIE '(FIXME|HACK|XXX)[:( ]' -- \
      ':!*node_modules*' ':!*dist*' ':!*.min.*' 2>/dev/null | head -3)"
    [ -z "$hits" ] && continue
    local line
    while IFS= read -r line; do
      [ "$found" -ge "$limit" ] && break
      local file text
      file="${line%%:*}"
      text="$(echo "$line" | cut -d: -f3- | sed 's/^[[:space:]]*//' | cut -c1-160)"
      hf_intake_push debt "$(hf_t "Tech debt in $name: $(basename "$file")" "Deuda técnica en $name: $(basename "$file")")" \
"$(hf_t "Debt marker found in $name.
File: $file
Content: $text

Check whether it is still valid; if so, resolve it and remove the marker. If it no longer applies, remove only the marker." "Marca de deuda encontrada en $name.
Archivo: $file
Contenido: $text

Evalúa si sigue siendo válida; si lo es, resuélvela y elimina la marca. Si ya no aplica, elimina solo la marca.")" \
        "low" "$name" && found=$((found + 1))
    done <<< "$hits"
  done < <(_hf_repos_unique)
  [ "$found" -eq 0 ] && echo "$(hf_t "[intake] no new tech debt" "[intake] sin deuda técnica nueva")"
  return 0
}

# ── Vulnerabilidades de dependencias ──────────────────────────
hf_intake_audit() {
  local limit="${1:-3}"
  local name path found=0
  while IFS='|' read -r name path; do
    [ "$found" -ge "$limit" ] && break
    [ -f "$path/package.json" ] || continue
    local report crit high
    report="$(cd "$path" && timeout 120 npm audit --json 2>/dev/null)"
    [ -z "$report" ] && continue
    crit="$(echo "$report" | jq -r '.metadata.vulnerabilities.critical // 0' 2>/dev/null)"
    high="$(echo "$report" | jq -r '.metadata.vulnerabilities.high // 0' 2>/dev/null)"
    [ "${crit:-0}" -eq 0 ] && [ "${high:-0}" -eq 0 ] && continue
    local top
    top="$(echo "$report" | jq -r '[.vulnerabilities // {} | to_entries[]
      | select(.value.severity == "critical" or .value.severity == "high")
      | "\(.key) (\(.value.severity))"] | join(", ") | .[0:200]' 2>/dev/null)"
    hf_intake_push audit "$(hf_t "Vulnerabilities in $name: $crit critical, $high high" "Vulnerabilidades en $name: $crit críticas, $high altas")" \
"$(hf_t "npm audit found vulnerabilities in $name.
Packages: $top

Update the affected dependencies to safe versions without breaking the build. Run the tests after updating." "npm audit detectó vulnerabilidades en $name.
Paquetes: $top

Actualiza las dependencias afectadas a versiones seguras sin romper la build. Ejecuta los tests tras actualizar.")" \
      "$([ "${crit:-0}" -gt 0 ] && echo critical || echo high)" "$name" \
      && found=$((found + 1))
  done < <(_hf_repos_unique)
  [ "$found" -eq 0 ] && echo "$(hf_t "[intake] no new critical/high vulnerabilities" "[intake] sin vulnerabilidades críticas/altas nuevas")"
  return 0
}

# ── Router ────────────────────────────────────────────────────
hf_intake_cmd() {
  case "${1:-help}" in
    alert) shift; hf_intake_alert "$@" ;;
    debt)  shift; hf_intake_debt "$@" ;;
    audit) shift; hf_intake_audit "$@" ;;
    scan)  hf_intake_debt "${2:-5}"; hf_intake_audit "${3:-3}" ;;
    *)
      echo ""
      if [ "$HF_LANG" = "es" ]; then
        echo "  📥 Intake — alimentar la cola desde otras fuentes"
        echo ""
        echo "    /intake alert <fichero.json|->  Alerta de producción (Sentry/webhook)"
        echo "    /intake debt [n]                Escanea FIXME/HACK/XXX en los repos"
        echo "    /intake audit [n]               npm audit: vulns críticas y altas"
        echo "    /intake scan                    debt + audit de una pasada"
        echo ""
        hf_dim "Todo entra como card en '$(hf_col_trigger)' y lo trabaja el mismo pipeline."
      else
        echo "  📥 Intake — feed the queue from other sources"
        echo ""
        echo "    /intake alert <file.json|->     Production alert (Sentry/webhook)"
        echo "    /intake debt [n]                Scan repos for FIXME/HACK/XXX"
        echo "    /intake audit [n]               npm audit: critical and high vulns"
        echo "    /intake scan                    debt + audit in one pass"
        echo ""
        hf_dim "Everything lands as a card in '$(hf_col_trigger)' and goes through the same pipeline."
      fi
      echo ""
      ;;
  esac
}
