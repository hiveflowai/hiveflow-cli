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

# hf_default_model <provider> — model used when none is configured.
# Claude (own key or the Hiveflow proxy): claude-sonnet-4-6, available on
# the direct Anthropic API and on the Bedrock account behind
# /api/cli/llm in dev, staging and prod (it is also the backend's
# CLOUD_COMPUTER_CLI_MODEL default). claude-sonnet-5 is not enabled on
# that Bedrock account. Override with HIVEFLOW_DEFAULT_CLAUDE_MODEL.
hf_default_model() {
  case "$1" in
    claude|hiveflow) printf '%s' "${HIVEFLOW_DEFAULT_CLAUDE_MODEL:-claude-sonnet-4-6}" ;;
    chatgpt)         printf '%s' "gpt-4o" ;;
    gemini)          printf '%s' "gemini-2.5-pro" ;;
    ollama)          printf '%s' "qwen3:8b" ;;
  esac
}

# hf_hiveflow_model [model] — model for the hiveflow provider. Empty, or
# the old /llm default (claude-sonnet-5, which the proxy's Bedrock does not
# serve), falls back to hf_default_model so configs saved before this fix
# keep working.
hf_hiveflow_model() {
  case "${1:-}" in
    ""|claude-sonnet-5) hf_default_model hiveflow ;;
    *) printf '%s' "$1" ;;
  esac
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
