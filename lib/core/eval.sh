#!/usr/bin/env bash
# ── Banco de evaluación del agente ────────────────────────────
# Sin esto, cambiar un prompt o un modelo es una apuesta: no sabes si
# mejoró o empeoró hasta que lo sufres en producción.
#
# Un CASO es un bug real ya resuelto, con su commit de fix conocido:
#   {id, repo, base_sha, título, descripción, fix_sha, archivos_esperados[]}
# El runner recrea el estado ANTERIOR al fix, deja trabajar al agente y
# puntúa comparando con lo que hizo el humano.
#
#   /eval add <repo> <sha>   añade el commit como caso al banco
#   /eval list               casos del banco
#   /eval run [n]            ejecuta el banco y puntúa
#   /eval compare            compara las dos últimas ejecuciones

hf_eval_dir()   { echo "${HF_EVAL_DIR:-$HF_CONFIG_DIR/eval}"; }
hf_eval_cases() { echo "$(hf_eval_dir)/cases.jsonl"; }
hf_eval_runs()  { echo "$(hf_eval_dir)/runs"; }

# ── Añadir caso desde un commit de fix real ───────────────────
hf_eval_add() {
  local repo="$1" sha="$2"
  [ -z "$repo" ] || [ -z "$sha" ] && { hf_err "$(hf_t "Usage: /eval add <repo> <fix-sha>" "Uso: /eval add <repo> <sha-del-fix>")"; return 1; }
  local path
  path="$(_hf_repo_path "$repo")"
  [ -z "$path" ] && { hf_err "$(hf_t "Repo '$repo' is not in the catalog" "Repo '$repo' no está en el catálogo")"; return 1; }

  git -C "$path" cat-file -e "${sha}^{commit}" 2>/dev/null || { hf_err "$(hf_t "SHA not found in $repo" "SHA no encontrado en $repo")"; return 1; }

  local subject body base files
  subject="$(git -C "$path" log -1 --format=%s "$sha")"
  body="$(git -C "$path" log -1 --format=%b "$sha" | head -20)"
  base="$(git -C "$path" rev-parse "${sha}^")"
  # Archivos de producción que tocó el humano (los tests se evalúan aparte)
  files="$(git -C "$path" show --name-only --format= "$sha" \
    | grep -vE '(^|/)(tests?|__tests__|spec)/|\.(test|spec)\.[jt]sx?$' \
    | jq -Rc 'select(length>0)' | jq -sc .)"

  mkdir -p "$(hf_eval_dir)"
  local id="EV-$(printf '%s' "$repo$sha" | md5sum | cut -c1-8)"
  if [ -f "$(hf_eval_cases)" ] && jq -e -s --arg i "$id" 'any(.[]; .id == $i)' "$(hf_eval_cases)" >/dev/null 2>&1; then
    hf_warn "$(hf_t "Case $id is already in the bench" "El caso $id ya está en el banco")"
    return 0
  fi
  jq -nc --arg id "$id" --arg repo "$repo" --arg sha "$sha" --arg base "$base" \
        --arg t "$subject" --arg d "$body" --argjson f "$files" \
    '{id:$id, repo:$repo, fix_sha:$sha, base_sha:$base, title:$t, description:$d, expected_files:$f}' \
    >> "$(hf_eval_cases)"
  hf_ok "$(hf_t "Case $id added: $subject" "Caso $id añadido: $subject")"
}

hf_eval_list() {
  local f
  f="$(hf_eval_cases)"
  [ ! -f "$f" ] && { hf_warn "$(hf_t "Bench is empty. Add cases with /eval add <repo> <sha>" "Banco vacío. Añade casos con /eval add <repo> <sha>")"; return 0; }
  echo ""
  printf "  %-12s %-22s %s\n" "$(hf_t "CASE" "CASO")" "REPO" "$(hf_t "TITLE" "TÍTULO")"
  jq -r '[.id, .repo, (.title | .[0:60])] | @tsv' "$f" \
    | while IFS=$'\t' read -r a b c; do printf "  %-12s %-22s %s\n" "$a" "$b" "$c"; done
  echo ""
  hf_dim "$(hf_t "$(wc -l < "$f") cases · run with /eval run" "$(wc -l < "$f") casos · ejecuta con /eval run")"
}

# ── Ejecutar el banco ─────────────────────────────────────────
# Por cada caso: worktree en el estado previo al fix → agente → puntuar.
# Puntuación (0-100), deliberadamente simple y explicable:
#   40  tocó al menos uno de los archivos que tocó el humano
#   20  no tocó archivos de más (precisión: ≤2x los esperados)
#   25  los tests del repo pasan
#   15  añadió test de reproducción
hf_eval_run() {
  local limit="${1:-0}"
  local f
  f="$(hf_eval_cases)"
  [ ! -f "$f" ] && { hf_err "$(hf_t "Bench is empty" "Banco vacío")"; return 1; }

  local runs run_id out
  runs="$(hf_eval_runs)"; mkdir -p "$runs"
  run_id="run-$(date +%Y%m%d-%H%M%S)"
  out="$runs/$run_id.jsonl"

  local tool
  tool="$(hf_active_tool)"; { [ -z "$tool" ] || [ "$tool" = "auto" ]; } && tool="$(hf_route complex-refactor)"
  echo ""
  hf_info "$(hf_t "Running bench with tool='$tool' → $run_id" "Ejecutando banco con tool='$tool' → $run_id")"
  echo ""

  local n=0 total=0 count=0
  while IFS= read -r case_json; do
    [ "$limit" -gt 0 ] && [ "$n" -ge "$limit" ] && break
    n=$((n + 1))

    local id repo base title desc expected path wt score=0 detail=""
    id="$(echo "$case_json"    | jq -r '.id')"
    repo="$(echo "$case_json"  | jq -r '.repo')"
    base="$(echo "$case_json"  | jq -r '.base_sha')"
    title="$(echo "$case_json" | jq -r '.title')"
    desc="$(echo "$case_json"  | jq -r '.description')"
    expected="$(echo "$case_json" | jq -r '.expected_files[]?' | sort -u)"
    path="$(_hf_repo_path "$repo")"
    [ -z "$path" ] && { hf_warn "$(hf_t "$id: repo '$repo' unavailable — skipped" "$id: repo '$repo' no disponible — saltado")"; continue; }

    printf "  %-12s %s\n" "$id" "${title:0:60}"

    # Worktree en el commit ANTERIOR al fix: el agente ve el bug vivo
    wt="$HF_WT_ROOT/eval--$(basename "$path")--$id"
    git -C "$path" worktree remove --force "$wt" >/dev/null 2>&1; rm -rf "$wt"
    mkdir -p "$HF_WT_ROOT"
    git -C "$path" worktree add --force --detach "$wt" "$base" >/dev/null 2>&1 \
      || { hf_warn "$(hf_t "$id: could not prepare the worktree" "$id: no se pudo preparar el worktree")"; continue; }
    _hf_wt_prepare_env "$path" "$wt"

    local prompt
    prompt="$(hf_prompt eval_fix "REPO=$repo" "TITLE=$title" "DESC=$desc")" \
      || prompt="Arregla este bug en '$repo': $title — $desc. Escribe también un test que lo reproduzca. No hagas commit."
    ( cd "$wt" && timeout "$(hf_agent_timeout)" bash -c "$(hf_tool_cmd "$tool" "$prompt" auto)" ) >/dev/null 2>&1

    # ── Puntuación ──
    local touched hits n_touched n_expected
    touched="$( { git -C "$wt" diff --name-only; git -C "$wt" ls-files --others --exclude-standard; } | sort -u)"
    n_touched="$(echo "$touched" | grep -c . || echo 0)"
    n_expected="$(echo "$expected" | grep -c . || echo 0)"

    hits=0
    while IFS= read -r ef; do
      [ -z "$ef" ] && continue
      echo "$touched" | grep -qxF "$ef" && hits=$((hits + 1))
    done <<< "$expected"

    if [ "$hits" -gt 0 ]; then score=$((score + 40)); detail="$(hf_t "hit-files" "acertó-archivos")"
    else detail="$(hf_t "missed-files" "falló-archivos")"; fi
    if [ "$n_expected" -gt 0 ] && [ "$n_touched" -le $((n_expected * 2)) ]; then
      score=$((score + 20)); detail="$detail,$(hf_t "precise" "preciso")"
    fi
    if [ -f "$wt/package.json" ] && jq -e '.scripts.test' "$wt/package.json" >/dev/null 2>&1; then
      ( cd "$wt" && timeout 900 npm test --silent >/dev/null 2>&1 ) \
        && { score=$((score + 25)); detail="$detail,tests-ok"; } || detail="$detail,$(hf_t "tests-fail" "tests-fallan")"
    else
      score=$((score + 25)); detail="$detail,$(hf_t "no-suite" "sin-suite")"
    fi
    _hf_has_test_change "$wt" "" 2>/dev/null
    echo "$touched" | grep -qiE '(^|/)(tests?|__tests__|spec)/|\.(test|spec)\.[jt]sx?$|_test\.(py|go|rb)$|test_.*\.py$' \
      && { score=$((score + 15)); detail="$detail,$(hf_t "with-test" "con-test")"; } || detail="$detail,$(hf_t "no-test" "sin-test")"

    jq -nc --arg id "$id" --arg repo "$repo" --arg tool "$tool" \
          --argjson score "$score" --arg detail "$detail" \
          --argjson hits "$hits" --argjson expected "$n_expected" --argjson touched "$n_touched" \
      '{case:$id, repo:$repo, tool:$tool, score:$score, detail:$detail,
        files_hit:$hits, files_expected:$expected, files_touched:$touched}' >> "$out"

    printf "      → %s/100  (%s)\n" "$score" "$detail"
    total=$((total + score)); count=$((count + 1))
    git -C "$path" worktree remove --force "$wt" >/dev/null 2>&1; rm -rf "$wt"
  done < "$f"

  echo ""
  if [ "$count" -gt 0 ]; then
    hf_ok "$(hf_t "$(printf 'Average: %s/100 over %s cases (tool=%s)' "$((total / count))" "$count" "$tool")" "$(printf 'Media: %s/100 sobre %s casos (tool=%s)' "$((total / count))" "$count" "$tool")")"
    hf_dim "$(hf_t "result: $out" "resultado: $out")"
  else
    hf_warn "$(hf_t "No runnable cases" "Ningún caso ejecutable")"
  fi
}

# ── Comparar las dos últimas ejecuciones ──────────────────────
hf_eval_compare() {
  local runs prev last
  runs="$(hf_eval_runs)"
  [ ! -d "$runs" ] && { hf_warn "$(hf_t "No runs yet" "Sin ejecuciones aún")"; return 0; }
  last="$(ls -1 "$runs"/*.jsonl 2>/dev/null | tail -1)"
  prev="$(ls -1 "$runs"/*.jsonl 2>/dev/null | tail -2 | head -1)"
  [ -z "$last" ] && { hf_warn "$(hf_t "No runs yet" "Sin ejecuciones aún")"; return 0; }
  if [ "$last" = "$prev" ]; then
    hf_warn "$(hf_t "Only one run exists; repeat /eval run after changing something to compare" "Solo hay una ejecución; repite /eval run tras cambiar algo para comparar")"
    return 0
  fi

  local ma mb
  ma="$(jq -s '[.[].score] | add / length | floor' "$prev")"
  mb="$(jq -s '[.[].score] | add / length | floor' "$last")"
  echo ""
  echo -e "  ${HF_C_BOLD}$(hf_t "Comparison" "Comparación")${HF_C_RESET}"
  printf "    $(hf_t "before" "antes ") %s: %s/100 (tool=%s)\n" "$(basename "$prev" .jsonl)" "$ma" "$(jq -sr '.[0].tool' "$prev")"
  printf "    $(hf_t "now   " "ahora ") %s: %s/100 (tool=%s)\n" "$(basename "$last" .jsonl)" "$mb" "$(jq -sr '.[0].tool' "$last")"
  local delta=$((mb - ma))
  if [ "$delta" -gt 0 ]; then
    echo -e "    ${HF_C_GREEN}$(hf_t "▲ +$delta points — the change improves things" "▲ +$delta puntos — el cambio mejora")${HF_C_RESET}"
  elif [ "$delta" -lt 0 ]; then
    echo -e "    ${HF_C_RED}$(hf_t "▼ $delta points — the change makes things worse, review it" "▼ $delta puntos — el cambio empeora, revísalo")${HF_C_RESET}"
  else
    echo "    $(hf_t "= no difference" "= sin diferencia")"
  fi

  # Casos que cambiaron de signo: lo más informativo
  echo ""
  echo "  $(hf_t "Cases that changed:" "Casos que cambiaron:")"
  # Nota: --slurpfile ya entrega un ARRAY de los objetos del JSONL, así que
  # se itera con $p[] — $p[0][] recorrería los valores del primer objeto.
  local changed
  changed="$(jq -s -r --slurpfile p "$prev" '
    ([$p[] | {key:.case, value:.score}] | from_entries) as $before
    | [.[] | select($before[.case] != null and $before[.case] != .score)
        | "    \(.case): \($before[.case]) → \(.score)"] | .[]' "$last" 2>/dev/null)"
  [ -n "$changed" ] && echo "$changed" || echo "    $(hf_t "(none)" "(ninguno)")"
  echo ""
}

hf_eval_cmd() {
  case "${1:-help}" in
    add)     shift; hf_eval_add "$@" ;;
    list|ls) hf_eval_list ;;
    run)     shift; hf_eval_run "${1:-0}" ;;
    compare|cmp) hf_eval_compare ;;
    *)
      echo ""
      if [ "$HF_LANG" = "es" ]; then
        echo "  🧪 Eval — medir si un cambio mejora o empeora el agente"
        echo ""
        echo "    /eval add <repo> <sha>   Añade un commit de fix real como caso"
        echo "    /eval list               Casos del banco"
        echo "    /eval run [n]            Ejecuta el banco y puntúa (0-100)"
        echo "    /eval compare            Compara las dos últimas ejecuciones"
        echo ""
        hf_dim "Flujo: /eval run → cambia prompt o /use <tool> → /eval run → /eval compare"
      else
        echo "  🧪 Eval — measure whether a change improves or degrades the agent"
        echo ""
        echo "    /eval add <repo> <sha>   Add a real fix commit as a case"
        echo "    /eval list               Cases in the bench"
        echo "    /eval run [n]            Run the bench and score (0-100)"
        echo "    /eval compare            Compare the last two runs"
        echo ""
        hf_dim "Flow: /eval run → change prompt or /use <tool> → /eval run → /eval compare"
      fi
      echo ""
      ;;
  esac
}
