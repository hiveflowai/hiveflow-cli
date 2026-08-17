#!/usr/bin/env bash
# ── Post-deploy verification ──────────────────────────────────
# The loop does not end at the merge: a merged fix can break production.
# This module checks health after the deploy and, if something degrades
# after merging a bot PR, warns and leaves a trail in the metrics.
#
#   /deploy check          health check of the configured endpoints
#   /deploy watch          check + correlation with recent merges
#   /deploy setup          configure endpoints to watch

hf_deploy_targets() { jq -c '.deploy.targets // []' "$HF_CONFIG_FILE" 2>/dev/null; }

hf_deploy_setup() {
  echo ""
  echo -e "  ${HF_C_BOLD}$(hf_t "Endpoints to watch after each deploy" "Endpoints a vigilar tras cada deploy")${HF_C_RESET}"
  hf_dim "$(hf_t "One per line, format: name=url  ·  empty line to finish" "Uno por línea, formato: nombre=url  ·  línea vacía para terminar")"
  echo ""
  local targets="[]" line name url
  while true; do
    read -r -p "  > " line
    [ -z "$line" ] && break
    name="${line%%=*}"; url="${line#*=}"
    [ "$name" = "$url" ] && { hf_err "$(hf_t "Format: name=url" "Formato: nombre=url")"; continue; }
    targets="$(echo "$targets" | jq -c --arg n "$name" --arg u "$url" '. + [{name:$n, url:$u}]')"
    hf_ok "$name → $url"
  done
  local tmp; tmp="$(mktemp)"
  jq --argjson t "$targets" '.deploy.targets = $t' "$HF_CONFIG_FILE" > "$tmp" && mv "$tmp" "$HF_CONFIG_FILE"
  chmod 600 "$HF_CONFIG_FILE"
  hf_ok "$(hf_t "$(echo "$targets" | jq length) endpoints configured" "$(echo "$targets" | jq length) endpoints configurados")"
}

# One check: HTTP code + latency. Returns 0 healthy, 1 degraded.
_hf_health_probe() {
  local url="$1" timeout="${2:-10}"
  local out code ms
  out="$(curl -s -o /dev/null -m "$timeout" -w '%{http_code} %{time_total}' "$url" 2>/dev/null)"
  code="${out%% *}"; ms="${out##* }"
  # curl returns 000 when there was no response
  echo "$code ${ms}s"
  case "$code" in
    2*|3*) return 0 ;;
    *)     return 1 ;;
  esac
}

hf_deploy_check() {
  local targets
  targets="$(hf_deploy_targets)"
  [ "$targets" = "[]" ] || [ -z "$targets" ] && { hf_warn "$(hf_t "No endpoints configured (/deploy setup)" "Sin endpoints configurados (/deploy setup)")"; return 0; }

  local unhealthy=0 name url result
  echo ""
  printf "  %-20s %-12s %s\n" "$(hf_t "SERVICE" "SERVICIO")" "$(hf_t "STATUS" "ESTADO")" "$(hf_t "DETAIL" "DETALLE")"
  while IFS=$'\t' read -r name url; do
    [ -z "$url" ] && continue
    if result="$(_hf_health_probe "$url")"; then
      printf "  %-20s ${HF_C_GREEN}%-12s${HF_C_RESET} %s\n" "$name" "$(hf_t "healthy" "sano")" "$result"
      hf_metric health_ok "" service="$name"
    else
      printf "  %-20s ${HF_C_RED}%-12s${HF_C_RESET} %s\n" "$name" "$(hf_t "DEGRADED" "DEGRADADO")" "$result"
      hf_metric health_fail "" service="$name" detail="$result"
      unhealthy=$((unhealthy + 1))
    fi
  done < <(echo "$targets" | jq -r '.[] | "\(.name)\t\(.url)"')
  echo ""
  return "$unhealthy"
}

# Correlation: if something is degraded and the bot merged something
# recently, that merge is the prime suspect. It does not assert it — it flags it.
hf_deploy_watch() {
  local unhealthy=0
  hf_deploy_check || unhealthy=$?
  [ "$unhealthy" -eq 0 ] && return 0

  local since recent
  since="$(date -d '-2 hours' -Iseconds 2>/dev/null || date -v-2H -Iseconds)"
  recent="$(jq -s -r --arg s "$since" \
    '[.[] | select(.event=="pr_merged" and .ts >= $s)] | .[] | "\(.ticket) (\(.repo // "?"))"' \
    "$(hf_metrics_file)" 2>/dev/null)"

  if [ -n "$recent" ]; then
    hf_err "$(hf_t "$unhealthy degraded service(s) after recent bot merges:" "$unhealthy servicio(s) degradado(s) tras merges recientes del bot:")"
    echo "$recent" | sed 's/^/      /'
    hf_warn "$(hf_t "Prime suspect: revert those PRs if the degradation persists" "Primer sospechoso: revertir esos PRs si la degradación persiste")"
    local first
    first="$(echo "$recent" | head -1 | awk '{print $1}')"
    _hf_notify_ticket "$first" "$(hf_t "🚨 Production degraded after merging $first. Review and consider a revert." "🚨 Producción degradada tras el merge de $first. Revisar y considerar revert.")"
    hf_metric deploy_regression_suspected "$first"
  else
    hf_warn "$(hf_t "$unhealthy degraded service(s), no bot merges in the last 2h — external cause" "$unhealthy servicio(s) degradado(s), sin merges del bot en las últimas 2h — causa externa")"
  fi
  return 1
}

hf_deploy_cmd() {
  case "${1:-check}" in
    setup) hf_deploy_setup ;;
    check) hf_deploy_check ;;
    watch) hf_deploy_watch ;;
    *)
      echo ""
      if [ "$HF_LANG" = "es" ]; then
        echo "  🚀 Deploy — verificar que lo mergeado no rompió producción"
        echo ""
        echo "    /deploy setup   Configurar endpoints de salud"
        echo "    /deploy check   Comprobar ahora"
        echo "    /deploy watch   Comprobar y correlacionar con merges recientes"
      else
        echo "  🚀 Deploy — verify that merged code did not break production"
        echo ""
        echo "    /deploy setup   Configure health endpoints"
        echo "    /deploy check   Check now"
        echo "    /deploy watch   Check and correlate with recent merges"
      fi
      echo ""
      ;;
  esac
}
