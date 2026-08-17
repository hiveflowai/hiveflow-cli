#!/usr/bin/env bash
# ── Hiveflow UI: colores, banner, helpers ────────────────────

HF_C_RESET='\033[0m'
HF_C_BOLD='\033[1m'
HF_C_DIM='\033[2m'
HF_C_YELLOW='\033[33m'
HF_C_GREEN='\033[32m'
HF_C_RED='\033[31m'
HF_C_CYAN='\033[36m'
HF_C_HONEY='\033[38;5;214m'   # ámbar hiveflow

hf_banner() {
  # HIVEFLOW CLI en "ANSI Shadow", colores de marca (logo: #7951EE→#5F68F1).
  # Degradado por filas: HIVEFLOW violeta→índigo, CLI cian eléctrico.
  # Truecolor si el terminal lo soporta; fallback a 256 colores.
  local p1 p2 p3 p4 p5 p6 c1 c2 c3 c4 c5 c6
  case "${COLORTERM:-}" in
    truecolor|24bit)
      p1='\033[38;2;167;139;250m' p2='\033[38;2;147;122;240m' p3='\033[38;2;127;106;231m'
      p4='\033[38;2;107;89;221m'  p5='\033[38;2;87;72;212m'   p6='\033[38;2;67;56;202m'
      c1='\033[38;2;34;211;238m'  c2='\033[38;2;28;195;230m'  c3='\033[38;2;21;179;222m'
      c4='\033[38;2;15;164;215m'  c5='\033[38;2;8;148;207m'   c6='\033[38;2;2;132;199m' ;;
    *)
      p1='\033[38;5;183m' p2='\033[38;5;141m' p3='\033[38;5;135m'
      p4='\033[38;5;99m'  p5='\033[38;5;63m'  p6='\033[38;5;57m'
      c1='\033[38;5;51m' c2='\033[38;5;45m' c3='\033[38;5;39m'
      c4='\033[38;5;38m' c5='\033[38;5;33m' c6='\033[38;5;32m' ;;
  esac
  local B="$HF_C_BOLD" R="$HF_C_RESET"
  echo ""
  echo -e "${B}${p1}  ██╗  ██╗██╗██╗   ██╗███████╗███████╗██╗      ██████╗ ██╗    ██╗   ${c1} ██████╗██╗     ██╗${R}"
  echo -e "${B}${p2}  ██║  ██║██║██║   ██║██╔════╝██╔════╝██║     ██╔═══██╗██║    ██║   ${c2}██╔════╝██║     ██║${R}"
  echo -e "${B}${p3}  ███████║██║██║   ██║█████╗  █████╗  ██║     ██║   ██║██║ █╗ ██║   ${c3}██║     ██║     ██║${R}"
  echo -e "${B}${p4}  ██╔══██║██║╚██╗ ██╔╝██╔══╝  ██╔══╝  ██║     ██║   ██║██║███╗██║   ${c4}██║     ██║     ██║${R}"
  echo -e "${B}${p5}  ██║  ██║██║ ╚████╔╝ ███████╗██║     ███████╗╚██████╔╝╚███╔███╔╝   ${c5}╚██████╗███████╗██║${R}"
  echo -e "${B}${p6}  ╚═╝  ╚═╝╚═╝  ╚═══╝  ╚══════╝╚═╝     ╚══════╝ ╚═════╝  ╚══╝╚══╝    ${c6} ╚═════╝╚══════╝╚═╝${R}"
  echo ""
  echo -e "  ${HF_C_BOLD}🐝 Hiveflow CLI${HF_C_RESET} ${HF_C_DIM}v${HIVEFLOW_VERSION}${HF_C_RESET} — $(hf_t "AI coding CLI orchestrator" "orquestador de AI coding CLIs")"
  echo -e "  ${HF_C_DIM}$(hf_t "claude · gemini · codex · aider — one entry point" "claude · gemini · codex · aider — un solo punto de entrada")${HF_C_RESET}"
  echo ""
}

hf_ok()    { echo -e "  ${HF_C_GREEN}✓${HF_C_RESET} $*"; }
hf_err()   { echo -e "  ${HF_C_RED}✗${HF_C_RESET} $*" >&2; }
hf_info()  { echo -e "  ${HF_C_CYAN}›${HF_C_RESET} $*"; }
hf_warn()  { echo -e "  ${HF_C_YELLOW}!${HF_C_RESET} $*"; }
hf_dim()   { echo -e "  ${HF_C_DIM}$*${HF_C_RESET}"; }

hf_welcome() {
  hf_banner
  local user_label="${HIVEFLOW_USER:-}"
  if [ -z "$user_label" ] && command -v hf_config_get >/dev/null 2>&1; then
    user_label="$(hf_config_get '.auth.name' 2>/dev/null)"
    [ -z "$user_label" ] && user_label="$(hf_config_get '.auth.email' 2>/dev/null)"
  fi
  if [ -n "$user_label" ]; then
    echo -e "  $(hf_t "Welcome back," "Bienvenido de nuevo,") ${HF_C_BOLD}${user_label}${HF_C_RESET} 👋"
  else
    echo -e "  ${HF_C_BOLD}$(hf_t "Welcome to Hiveflow" "Bienvenido a Hiveflow")${HF_C_RESET} 👋"
  fi
  echo ""
}


# ── hf_pick: selector con flechas, reutilizable ────────────────
# Entrada por globals (bash 3.2, sin stdin — las teclas van por el tty):
#   HF_PICK_VALUES=(v1 v2 …)  HF_PICK_LABELS=("etiqueta 1" …)
#   hf_pick "Título"  →  HF_PICK_CHOICE=valor elegido ("" si canceló)
# Sin TTY (pipes/tests) elige el primero: los scripts no se bloquean.
HF_PICK_CHOICE=""
hf_pick() {
  local title="$1" sel=0 total=${#HF_PICK_VALUES[@]} i key rest rows
  HF_PICK_CHOICE=""
  [ "$total" -eq 0 ] && return 1
  if ! [ -t 0 ]; then HF_PICK_CHOICE="${HF_PICK_VALUES[0]}"; return 0; fi
  rows=$((total + 2))
  printf '\033[?25l'
  for ((i = 0; i < rows; i++)); do printf '\n'; done
  printf '\033[%dA' "$rows"
  while :; do
    printf '\r\033[K  \033[1m%s\033[0m\n' "$title"
    for ((i = 0; i < total; i++)); do
      printf '\033[K'
      if [ "$i" -eq "$sel" ]; then
        printf '  \033[38;5;99m❯ %s\033[0m\n' "${HF_PICK_LABELS[$i]}"
      else
        printf '    %s\n' "${HF_PICK_LABELS[$i]}"
      fi
    done
    printf '\033[K  \033[2m%s\033[0m' "$(hf_t "↑↓ move · enter select · esc cancel" "↑↓ mover · enter elegir · esc cancelar")"
    IFS= read -r -s -n1 key || break
    case "$key" in
      "") HF_PICK_CHOICE="${HF_PICK_VALUES[$sel]}"; break ;;
      $'\x1b')
        rest=""
        IFS= read -r -s -n2 -t 1 rest 2>/dev/null
        case "$rest" in
          "[A") [ "$sel" -gt 0 ] && sel=$((sel - 1)) ;;
          "[B") [ "$sel" -lt $((total - 1)) ] && sel=$((sel + 1)) ;;
          "")   break ;;
        esac ;;
    esac
    printf '\r\033[%dA' $((rows - 1))
  done
  printf '\r\033[%dA\033[J\033[?25h' $((rows - 1))
  [ -n "$HF_PICK_CHOICE" ]
}
