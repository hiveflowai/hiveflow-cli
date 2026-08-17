#!/usr/bin/env bash
# ── i18n: inglés por defecto, español opt-in ──────────────────
# Resolución del idioma: HIVEFLOW_LANG (env) > config .lang > "en"
#
# Uso:
#   hf_t "English text" "Texto en español"   → imprime según HF_LANG
#   Bloques grandes (ayudas): funciones _en/_es y despachar por $HF_LANG.
#
# Cambiar idioma: /lang es · /lang en  (o export HIVEFLOW_LANG=es)

HF_LANG="en"

hf_lang_init() {
  local lang="${HIVEFLOW_LANG:-}"
  if [ -z "$lang" ] && [ -f "${HF_CONFIG_FILE:-}" ]; then
    lang="$(jq -r '.lang // empty' "$HF_CONFIG_FILE" 2>/dev/null)"
  fi
  case "$lang" in
    es|es_*|es-*|ES) HF_LANG="es" ;;
    *)               HF_LANG="en" ;;
  esac
}

# hf_t <english> [<español>] — imprime la variante del idioma activo.
# Sin variante en español, cae al inglés.
hf_t() {
  if [ "$HF_LANG" = "es" ] && [ $# -ge 2 ] && [ -n "$2" ]; then
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}
