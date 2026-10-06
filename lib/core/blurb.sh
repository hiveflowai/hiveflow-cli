#!/usr/bin/env bash
# ── Blurb: HiveFlow's physical mascot (RP2350 Touch AMOLED board) ──────────
#   hiveflow blurb status              bridge + board status
#   hiveflow blurb emotion <name> [ms] show an emotion (36 available: hiveflow blurb list)
#   hiveflow blurb state <name>        idle|running|thinking|listening|speaking|success|error|…
#   hiveflow blurb send '<json>'       raw line, e.g. '{"t":"blink"}'
#   hiveflow blurb list                emotions and states the board understands
#
# Talks to the local blurb-bridge (npx @hiveflow/blurb-bridge, or the desktop app's
# Hardware section) on http://127.0.0.1:4243. Without a bridge it falls back to writing
# straight to the board's USB serial port (macOS/Linux), one JSON line per message.

HF_BLURB_URL="${HIVEFLOW_BLURB_URL:-http://127.0.0.1:${BLURB_BRIDGE_PORT:-4243}}"

hf_blurb_port() {
  local p
  for p in /dev/cu.usbmodem* /dev/ttyACM*; do [ -e "$p" ] && { echo "$p"; return 0; }; done
  return 1
}

# hf_blurb_send <json>  → bridge first, serial port as fallback
hf_blurb_send() {
  local json="$1" out
  if out=$(curl -s -m 2 -X POST -H 'Content-Type: application/json' -d "$json" "$HF_BLURB_URL/send" 2>/dev/null) && [ -n "$out" ]; then
    echo "$out"; return 0
  fi
  local dev; dev=$(hf_blurb_port) || { echo "$(hf_t "blurb: no bridge on $HF_BLURB_URL and no board on USB" "blurb: no hay bridge en $HF_BLURB_URL ni placa por USB")" >&2; return 1; }
  if command -v stty >/dev/null 2>&1; then stty -f "$dev" 115200 raw -echo 2>/dev/null || stty -F "$dev" 115200 raw -echo 2>/dev/null; fi
  printf '%s\n' "$json" > "$dev" && echo "{\"ok\":true,\"via\":\"$dev\"}"
}

hf_blurb() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    status)
      curl -s -m 2 "$HF_BLURB_URL/status" 2>/dev/null | jq . 2>/dev/null \
        || { local dev; dev=$(hf_blurb_port) && echo "{\"bridge\":false,\"board\":\"$dev\"}" || echo '{"bridge":false,"board":null}'; } ;;
    emotion)
      [ -z "${1:-}" ] && { echo "$(hf_t "usage: hiveflow blurb emotion <name> [ms]" "uso: hiveflow blurb emotion <nombre> [ms]")" >&2; return 1; }
      hf_blurb_send "{\"t\":\"emotion\",\"v\":\"$1\",\"ms\":${2:-3000}}" ;;
    state)
      [ -z "${1:-}" ] && { echo "$(hf_t "usage: hiveflow blurb state <name>" "uso: hiveflow blurb state <nombre>")" >&2; return 1; }
      hf_blurb_send "{\"t\":\"state\",\"v\":\"$1\"}" ;;
    send)
      [ -z "${1:-}" ] && { echo "usage: hiveflow blurb send '<json>'" >&2; return 1; }
      hf_blurb_send "$1" ;;
    list)
      echo "emotions: normal happy glee excited proud love shy sad crying worried scared frustrated annoyed angry furious disgusted unimpressed bored tired sleepy sleeping closed focused determined suspicious skeptic squint curious confused thinking surprised awe mischievous embarrassed dizzy dead"
      echo "states:   idle running thinking listening speaking success error offline low-credits paused loading saving waiting not-found crashed" ;;
    *)
      cat <<USAGE
$(hf_t "Blurb — HiveFlow's physical mascot" "Blurb — la mascota física de HiveFlow")
  hiveflow blurb status
  hiveflow blurb emotion <name> [ms]
  hiveflow blurb state <name>
  hiveflow blurb send '<json>'
  hiveflow blurb list
$(hf_t "Bridge: npx @hiveflow/blurb-bridge (or the desktop app → Settings → Hardware)." "Bridge: npx @hiveflow/blurb-bridge (o la app de escritorio → Ajustes → Hardware).")
USAGE
      ;;
  esac
}
