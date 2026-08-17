#!/usr/bin/env bash
# ── Persistent configuration: ~/.config/hiveflow/config.json ─

HF_CONFIG_DIR="${HIVEFLOW_CONFIG_DIR:-$HOME/.config/hiveflow}"
HF_CONFIG_FILE="$HF_CONFIG_DIR/config.json"

hf_config_init() {
  mkdir -p "$HF_CONFIG_DIR"
  if [ ! -f "$HF_CONFIG_FILE" ]; then
    echo '{}' > "$HF_CONFIG_FILE"
    chmod 600 "$HF_CONFIG_FILE"
  fi
}

# hf_config_get <jq-key>  (e.g.: .auth.token)
hf_config_get() {
  jq -r "$1 // empty" "$HF_CONFIG_FILE" 2>/dev/null
}

# hf_config_set <jq-key> <string-value>
hf_config_set() {
  local tmp
  tmp="$(mktemp)"
  jq --arg v "$2" "$1 = \$v" "$HF_CONFIG_FILE" > "$tmp" && mv "$tmp" "$HF_CONFIG_FILE"
  chmod 600 "$HF_CONFIG_FILE"
}

hf_config_del() {
  local tmp
  tmp="$(mktemp)"
  jq "del($1)" "$HF_CONFIG_FILE" > "$tmp" && mv "$tmp" "$HF_CONFIG_FILE"
  chmod 600 "$HF_CONFIG_FILE"
}
