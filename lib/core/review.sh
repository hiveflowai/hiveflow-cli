#!/usr/bin/env bash
# ── Auto-review de PRs humanos ────────────────────────────────
# El agente no solo escribe código: también revisa el de otros. Un
# revisor incansable que mira TODOS los PRs en minutos, deja comentarios
# concretos y no bloquea a nadie (sus veredictos son COMMENT, nunca
# REQUEST_CHANGES: la autoridad sigue siendo humana).
#
#   /review              revisa los PRs abiertos sin revisar
#   /review <n>          revisa un PR concreto
#   /review repo <name>  solo un repo

# PRs abiertos por HUMANOS (las ramas fix/HF-* son del bot)
_hf_human_prs() {
  local path="$1"
  (cd "$path" 2>/dev/null && gh pr list --state open --json number,title,headRefName,author \
    --jq '.[] | select(.headRefName | startswith("fix/HF-") | not) | "\(.number)\t\(.title)\t\(.author.login)"' 2>/dev/null)
}

# ¿Ya dejamos review en este PR? Evita comentar lo mismo cada pasada.
_hf_already_reviewed() {
  local path="$1" num="$2"
  (cd "$path" && gh pr view "$num" --json comments \
    --jq '[.comments[].body] | map(select(startswith("🤖 **Automated review**") or startswith("🤖 **Revisión automática**"))) | length' 2>/dev/null) \
    | grep -qv '^0$'
}

# hf_review_pr <repo-path> <repo-name> <numero>
hf_review_pr() {
  local path="$1" name="$2" num="$3"
  local base diff title
  base="$(_hf_repo_base "$path")"
  title="$(cd "$path" && gh pr view "$num" --json title --jq .title 2>/dev/null)"

  # Diff acotado: un prompt con 10k líneas ni cabe ni sirve
  diff="$(cd "$path" && gh pr diff "$num" 2>/dev/null | head -1200)"
  [ -z "$diff" ] && { hf_warn "$(hf_t "[$name#$num] no readable diff" "[$name#$num] sin diff legible")"; return 1; }

  local tool
  tool="$(hf_route security-audit)"
  [ -z "$tool" ] && { hf_err "$(hf_t "No CLI available" "Ningún CLI disponible")"; return 1; }

  local prompt
  prompt="$(hf_prompt pr_review "NUM=$num" "NAME=$name" "TITLE=$title" "DIFF=$diff")" \
    || prompt="Revisa el PR #$num de $name ('$title'). Diff: $diff. Reporta máx 5 hallazgos reales (bugs, seguridad, tests faltantes); si no hay nada: 'Sin hallazgos.'"

  local out
  out="$(cd "$path" && timeout 600 bash -c "$(hf_tool_cmd "$tool" "$prompt" safe)" 2>/dev/null)"
  [ -z "$out" ] && { hf_warn "$(hf_t "[$name#$num] the reviewer returned nothing" "[$name#$num] el revisor no devolvió nada")"; return 1; }

  local body="$(hf_t "🤖 **Automated review** (Hiveflow CLI · $tool)

$out

---
*Informational comment: approval remains human.*" "🤖 **Revisión automática** (Hiveflow CLI · $tool)

$out

---
*Comentario informativo: la aprobación sigue siendo humana.*")"

  if (cd "$path" && gh pr comment "$num" --body "$body" >/dev/null 2>&1); then
    hf_ok "$(hf_t "[$name#$num] reviewed" "[$name#$num] revisado")"
    hf_metric pr_reviewed "" repo="$name" pr="$num" tool="$tool"
  else
    hf_err "$(hf_t "[$name#$num] could not post the comment" "[$name#$num] no se pudo publicar el comentario")"
    return 1
  fi
}

hf_review_cmd() {
  command -v gh >/dev/null || { hf_err "$(hf_t "gh not installed" "gh no instalado")"; return 1; }
  # Publica comentarios en PRs reales: confirmar SIEMPRE en interactivo.
  if [ -t 0 ]; then
    local _confirm
    read -r -p "  $(hf_t "This will review open PRs in your repos and POST comments on GitHub. Continue? [y/N]: " "Esto revisará PRs abiertos de tus repos y PUBLICARÁ comentarios en GitHub. ¿Continuar? [y/N]: ")" _confirm
    case "$_confirm" in y|Y|s|S) : ;; *) hf_dim "$(hf_t "Cancelled." "Cancelado.")"; return 0 ;; esac
  fi
  local filter_repo="" only_pr=""
  case "${1:-}" in
    repo) filter_repo="$2" ;;
    ''|all) ;;
    *) only_pr="$1" ;;
  esac

  local name path num title author found=0
  while IFS='|' read -r name path; do
    [ -n "$filter_repo" ] && [ "$name" != "$filter_repo" ] && continue
    while IFS=$'\t' read -r num title author; do
      [ -z "$num" ] && continue
      [ -n "$only_pr" ] && [ "$num" != "$only_pr" ] && continue
      if _hf_already_reviewed "$path" "$num"; then
        hf_dim "$(hf_t "[$name#$num] already reviewed — skipped" "[$name#$num] ya revisado — omitido")"
        continue
      fi
      hf_info "$(hf_t "[$name#$num] $title (by $author)" "[$name#$num] $title (por $author)")"
      hf_review_pr "$path" "$name" "$num"
      found=$((found + 1))
    done < <(_hf_human_prs "$path")
  done < <(_hf_repos_unique)

  [ "$found" -eq 0 ] && hf_dim "$(hf_t "No human PRs pending review" "No hay PRs humanos pendientes de revisar")"
  return 0
}
