#!/usr/bin/env bash
# ── Hiveflow CLI installer ────────────────────────────────────
# 1. Links `hiveflow` into the PATH
# 2. Offers to install any missing AI CLIs
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Language: English by default, Spanish if HIVEFLOW_LANG=es or config .lang=es
HF_CONFIG_FILE="${HIVEFLOW_CONFIG_DIR:-$HOME/.config/hiveflow}/config.json"
source "$ROOT/lib/core/i18n.sh"
hf_lang_init

echo ""
echo "  $(hf_t "🐝 Installing Hiveflow CLI..." "🐝 Instalando Hiveflow CLI...")"
echo ""

chmod +x "$ROOT/hiveflow.sh"

# Binary destination: ~/.local/bin if it exists/is in PATH, otherwise /usr/local/bin
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
ln -sf "$ROOT/hiveflow.sh" "$BIN_DIR/hiveflow"
# Shortcuts: 'hf' (two letters, matches the code's hf_ prefix),
# 'hive' and 'flow'. Note: 'hf' is also the HuggingFace CLI; if you
# install that, use 'hive' or 'flow'.
for short in hf hive flow; do
  if command -v "$short" >/dev/null 2>&1 && [ "$(readlink -f "$(command -v "$short")")" != "$ROOT/hiveflow.sh" ]; then
    echo "  $(hf_t "! '$short' already exists on your system — not overwriting" "! '$short' ya existe en tu sistema — no se sobrescribe")"
  else
    ln -sf "$ROOT/hiveflow.sh" "$BIN_DIR/$short"
  fi
done
echo "  $(hf_t "✓ hiveflow (and shortcuts: hf, hive, flow) → $BIN_DIR/" "✓ hiveflow (y atajos: hf, hive, flow) → $BIN_DIR/")"

case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *) echo "  $(hf_t "! $BIN_DIR is not in your PATH. Add to your ~/.bashrc:" "! $BIN_DIR no está en tu PATH. Añade a tu ~/.bashrc:")"
     echo "      export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# Dependencies
for dep in jq curl; do
  command -v "$dep" >/dev/null 2>&1 || echo "  $(hf_t "! Missing '$dep' — install it (apt install $dep)" "! Falta '$dep' — instálalo (apt install $dep)")"
done

# AI CLIs
echo ""
echo "  $(hf_t "Detected AI CLIs:" "AI CLIs detectados:")"
for t in claude gemini codex aider; do
  if command -v "$t" >/dev/null 2>&1; then
    echo "    ✓ $t"
  else
    echo "    $(hf_t "✗ $t (install it later with: hiveflow → /install $t)" "✗ $t (instálalo luego con: hiveflow → /install $t)")"
  fi
done

echo ""
echo "  $(hf_t "Done. Run:  hiveflow" "Listo. Ejecuta:  hiveflow")"
echo ""
