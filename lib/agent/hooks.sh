#!/bin/bash

# ==========================================
# HOOKS MODULE - hooks.sh
# ==========================================
# Pre/post hooks for agentic tool dispatch (P1.hooks-1).
#
# Storage: $CODER_HOOKS_CONFIG (default $CONFIG_DIR/hooks.json).
#
# Config schema (JSON):
#   {
#     "tool_pre":  { "<tool>": ["cmd", ...], "*": ["cmd", ...] },
#     "tool_post": { "<tool>": ["cmd", ...], "*": ["cmd", ...] }
#   }
#
# Each hook is a shell command string executed via `bash -c`. Tool-specific
# entries fire before the wildcard "*" entries for the same event. Failures
# are non-fatal: the caller is never blocked by a hook (a future P1.hooks-N
# may add opt-in blocking semantics; v1 is observe-only).
#
# Env vars exported to each hook:
#   CODER_HOOK_EVENT    tool_pre | tool_post
#   CODER_HOOK_TOOL     tool name
#   CODER_HOOK_INPUT    JSON input passed to the tool (truncated)
#   CODER_HOOK_EXIT     tool exit code (tool_post only, empty for tool_pre)
#   CODER_HOOK_OUTPUT   tool stdout (tool_post only, truncated, empty for pre)
#
# Tunables (env, read at call time):
#   CODER_HOOK_INPUT_MAX     bytes (default 4096)
#   CODER_HOOK_OUTPUT_MAX    bytes (default 4096)
#   CODER_HOOK_TIMEOUT       seconds for each hook (default 10; enforced only
#                            if `timeout` or `gtimeout` is on PATH — macOS
#                            default lacks both)
#
# This file is sourced into the parent shell; do NOT enable `set -euo pipefail`
# globally here (would leak flags into coder.sh and legacy modules).
#
# Public contract:
#   hooks_init                              -> 0 ok, 1 fail
#   hooks_config_path                       -> echoes config path
#   hooks_list_for <event> [tool]           -> emits cmds (one per line);
#                                              0 ok (possibly empty),
#                                              2 invalid event
#   hooks_run <event> <tool> [input_json] [exit_code] [output]
#                                           -> runs each hook in order;
#                                              always 0 (non-fatal); 2 only
#                                              for invalid event / empty tool

# Double-source guard (coder.sh + tests both source us).
if [ -n "${_HOOKS_LOADED:-}" ]; then
    return 0
fi
_HOOKS_LOADED=1

# i18n fallback: hf_t existe aunque i18n.sh no esté cargado (tests sourcean directo).
type hf_t >/dev/null 2>&1 || hf_t() { if [ "${HF_LANG:-en}" = "es" ] && [ -n "${2:-}" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# Tunables: only set if caller did not.
: "${CODER_HOOK_INPUT_MAX:=4096}"
: "${CODER_HOOK_OUTPUT_MAX:=4096}"
: "${CODER_HOOK_TIMEOUT:=10}"

hooks_config_path() {
    echo "${CODER_HOOKS_CONFIG:-${CONFIG_DIR:-$HOME/.config/coder-cli}/hooks.json}"
}

hooks_init() {
    local path dir
    path=$(hooks_config_path)
    dir=$(dirname "$path")
    mkdir -p "$dir" 2>/dev/null || return 1
    if [ ! -f "$path" ]; then
        printf '%s\n' '{"tool_pre":{},"tool_post":{}}' > "$path" 2>/dev/null || return 1
    fi
    return 0
}

# Internal: validate event name. 0 = ok, 2 = invalid.
_hooks_valid_event() {
    case "${1:-}" in
        tool_pre|tool_post) return 0 ;;
        *) return 2 ;;
    esac
}

# hooks_list_for <event> [tool]
# Emits hook commands registered for <event>, one per line.
# If <tool> is given: tool-specific hooks first, then wildcard ("*") hooks.
# If <tool> is omitted: emits only the wildcard hooks for the event.
# Order within each list follows the JSON config (jq preserves order).
# Returns 0 ok (possibly empty), 2 invalid event.
# Malformed JSON or missing config file emit nothing with rc=0.
hooks_list_for() {
    local event="${1:-}" tool="${2:-}"
    if ! _hooks_valid_event "$event"; then
        echo "hooks_list_for: invalid event: $event" >&2
        return 2
    fi
    local path
    path=$(hooks_config_path)
    [ -f "$path" ] || return 0
    [ -s "$path" ] || return 0

    if [ -z "$tool" ]; then
        jq -r --arg ev "$event" '
          (.[$ev]["*"] // []) | .[]
        ' "$path" 2>/dev/null
    else
        jq -r --arg ev "$event" --arg tool "$tool" '
          ((.[$ev][$tool] // []) + (.[$ev]["*"] // [])) | .[]
        ' "$path" 2>/dev/null
    fi
    return 0
}

# hooks_run <event> <tool> [input_json] [exit_code] [output]
# Runs every hook registered for <event>/<tool> in order. Each hook is
# fire-and-wait: failures are surfaced to stderr with the captured
# stdout+stderr, but never propagate as a non-zero return — the agentic
# tool dispatch must never be blocked by an observability hook (v1).
# Returns 0 on success, 2 only for invalid inputs (invalid event / empty
# tool name).
hooks_run() {
    local event="${1:-}" tool="${2:-}" input_json="${3:-}" exit_code="${4:-}" output="${5:-}"
    if ! _hooks_valid_event "$event"; then
        echo "hooks_run: invalid event: $event" >&2
        return 2
    fi
    if [ -z "$tool" ]; then
        echo "hooks_run: tool name empty" >&2
        return 2
    fi

    local hooks
    hooks=$(hooks_list_for "$event" "$tool")
    [ -z "$hooks" ] && return 0

    # Truncate input/output to bounded sizes before exporting as env vars
    # (avoids E2BIG on platforms with small argv+env limits).
    if [ "${#input_json}" -gt "$CODER_HOOK_INPUT_MAX" ]; then
        input_json="${input_json:0:$CODER_HOOK_INPUT_MAX}"
    fi
    if [ "${#output}" -gt "$CODER_HOOK_OUTPUT_MAX" ]; then
        output="${output:0:$CODER_HOOK_OUTPUT_MAX}"
    fi

    local cmd
    while IFS= read -r cmd; do
        [ -z "$cmd" ] && continue
        _hooks_exec_one "$event" "$tool" "$input_json" "$exit_code" "$output" "$cmd"
    done <<< "$hooks"
    return 0
}

# Internal: execute one hook. Captures stdout+stderr to a tmp file; only
# surfaces them on non-zero exit so successful hooks remain silent (avoids
# polluting agentic streaming output to the user terminal). Always returns 0.
_hooks_exec_one() {
    local event="$1" tool="$2" input_json="$3" exit_code="$4" output="$5" cmd="$6"
    local tmp rc=0
    tmp=$(mktemp 2>/dev/null) || return 0

    if command -v timeout >/dev/null 2>&1; then
        CODER_HOOK_EVENT="$event" CODER_HOOK_TOOL="$tool" \
        CODER_HOOK_INPUT="$input_json" CODER_HOOK_EXIT="$exit_code" \
        CODER_HOOK_OUTPUT="$output" \
            timeout "${CODER_HOOK_TIMEOUT}s" bash -c "$cmd" >"$tmp" 2>&1
        rc=$?
    elif command -v gtimeout >/dev/null 2>&1; then
        CODER_HOOK_EVENT="$event" CODER_HOOK_TOOL="$tool" \
        CODER_HOOK_INPUT="$input_json" CODER_HOOK_EXIT="$exit_code" \
        CODER_HOOK_OUTPUT="$output" \
            gtimeout "${CODER_HOOK_TIMEOUT}s" bash -c "$cmd" >"$tmp" 2>&1
        rc=$?
    else
        CODER_HOOK_EVENT="$event" CODER_HOOK_TOOL="$tool" \
        CODER_HOOK_INPUT="$input_json" CODER_HOOK_EXIT="$exit_code" \
        CODER_HOOK_OUTPUT="$output" \
            bash -c "$cmd" >"$tmp" 2>&1
        rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
        {
            echo "hooks: $event hook for '$tool' failed (rc=$rc): $cmd"
            if [ -s "$tmp" ]; then
                sed 's/^/  /' "$tmp"
            fi
        } >&2
    fi

    rm -f "$tmp"
    return 0
}

# ==========================================
# CLI dispatcher (`coder hooks ...`)
# ==========================================

_hooks_cli_usage() {
    printf '%s\n' "$(hf_t "Usage: coder hooks <subcommand> [args]" "Uso: coder hooks <subcommand> [args]")"
    cat <<'EOF'

Subcommands:
  list                                    List registered hooks (event, tool, index, command).
  add <event> <tool> <cmd>                Append a hook command. Event = tool_pre | tool_post.
                                          Tool = registered name or "*" for wildcard.
  remove <event> <tool> <index|--all>     Remove the hook at <index> (1-based) for that
                                          event/tool, or remove every hook for that tool.

Examples:
  coder hooks list
  coder hooks add tool_pre  read_file  'echo "READ $CODER_HOOK_INPUT" >> /tmp/audit.log'
  coder hooks add tool_post '*'        'logger -t coder "rc=$CODER_HOOK_EXIT tool=$CODER_HOOK_TOOL"'
  coder hooks remove tool_pre read_file 1
  coder hooks remove tool_post '*' --all
EOF
}

# Internal: atomic write of new JSON content to config path.
# Args: <new_json>. Echoes nothing; returns 0 ok, 1 on write fail.
_hooks_cli_write() {
    local new_json="$1"
    local path tmp
    path=$(hooks_config_path)
    tmp=$(mktemp 2>/dev/null) || return 1
    printf '%s\n' "$new_json" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

# Internal: load current config as JSON string. If file missing/empty, returns
# the empty schema. If JSON is malformed, returns 1.
_hooks_cli_load() {
    local path
    path=$(hooks_config_path)
    if [ ! -f "$path" ] || [ ! -s "$path" ]; then
        printf '%s\n' '{"tool_pre":{},"tool_post":{}}'
        return 0
    fi
    local content
    if ! content=$(jq -c '.' "$path" 2>/dev/null); then
        return 1
    fi
    printf '%s\n' "$content"
    return 0
}

# hooks_cli <subcommand> [<args>...]
# Exit codes: 0 ok, 1 internal error (jq fail, write fail, invalid index,
# malformed config, missing entry), 2 usage error.
hooks_cli() {
    local sub="${1:-}"

    case "$sub" in
        list)
            shift
            if [ "$#" -ne 0 ]; then
                echo "hooks list: unexpected arguments" >&2
                _hooks_cli_usage >&2
                return 2
            fi
            local json
            if ! json=$(_hooks_cli_load); then
                echo "hooks list: malformed JSON in $(hooks_config_path)" >&2
                return 1
            fi
            local rows
            rows=$(printf '%s\n' "$json" | jq -r '
              ( (.tool_pre  // {}) | to_entries | map(. as $t |
                  ($t.value // []) | to_entries | map(
                    [ "tool_pre", $t.key, ((.key|tonumber)+1|tostring), .value ] | @tsv
                  )) | flatten )
              + ( (.tool_post // {}) | to_entries | map(. as $t |
                  ($t.value // []) | to_entries | map(
                    [ "tool_post", $t.key, ((.key|tonumber)+1|tostring), .value ] | @tsv
                  )) | flatten )
              | .[]
            ' 2>/dev/null)
            if [ -z "$rows" ]; then
                echo "(no hooks registered)"
                return 0
            fi
            printf '%-10s %-20s %-4s %s\n' "EVENT" "TOOL" "#" "COMMAND"
            local event tool idx cmd
            while IFS=$'\t' read -r event tool idx cmd; do
                [ -n "$event" ] || continue
                printf '%-10s %-20s %-4s %s\n' "$event" "$tool" "$idx" "$cmd"
            done <<<"$rows"
            ;;
        add)
            shift
            if [ "$#" -ne 3 ]; then
                echo "hooks add: expected <event> <tool> <cmd>" >&2
                _hooks_cli_usage >&2
                return 2
            fi
            local event="$1" tool="$2" cmd="$3"
            if ! _hooks_valid_event "$event"; then
                echo "hooks add: invalid event '$event' (expected tool_pre or tool_post)" >&2
                return 2
            fi
            if [ -z "$tool" ]; then
                echo "hooks add: tool name cannot be empty" >&2
                return 2
            fi
            if [ -z "$cmd" ]; then
                echo "hooks add: command cannot be empty" >&2
                return 2
            fi
            if ! hooks_init >/dev/null; then
                echo "hooks add: cannot initialize config at $(hooks_config_path)" >&2
                return 1
            fi
            local json new_json
            if ! json=$(_hooks_cli_load); then
                echo "hooks add: malformed JSON in $(hooks_config_path)" >&2
                return 1
            fi
            if ! new_json=$(printf '%s\n' "$json" | jq -c \
                --arg ev "$event" --arg tool "$tool" --arg cmd "$cmd" '
                  .[$ev] = (.[$ev] // {})
                  | .[$ev][$tool] = ((.[$ev][$tool] // []) + [$cmd])
                ' 2>/dev/null); then
                echo "hooks add: jq transform failed" >&2
                return 1
            fi
            if ! _hooks_cli_write "$new_json"; then
                echo "hooks add: failed to write $(hooks_config_path)" >&2
                return 1
            fi
            echo "added: $event $tool $cmd"
            ;;
        remove)
            shift
            if [ "$#" -ne 3 ]; then
                echo "hooks remove: expected <event> <tool> <index|--all>" >&2
                _hooks_cli_usage >&2
                return 2
            fi
            local event="$1" tool="$2" selector="$3"
            if ! _hooks_valid_event "$event"; then
                echo "hooks remove: invalid event '$event' (expected tool_pre or tool_post)" >&2
                return 2
            fi
            if [ -z "$tool" ]; then
                echo "hooks remove: tool name cannot be empty" >&2
                return 2
            fi
            local json
            if ! json=$(_hooks_cli_load); then
                echo "hooks remove: malformed JSON in $(hooks_config_path)" >&2
                return 1
            fi
            local count
            count=$(printf '%s\n' "$json" | jq -r \
                --arg ev "$event" --arg tool "$tool" \
                '(.[$ev][$tool] // []) | length' 2>/dev/null)
            if [ -z "$count" ] || [ "$count" = "0" ]; then
                echo "hooks remove: no hooks registered for $event $tool" >&2
                return 1
            fi
            local new_json
            if [ "$selector" = "--all" ]; then
                if ! new_json=$(printf '%s\n' "$json" | jq -c \
                    --arg ev "$event" --arg tool "$tool" \
                    'del(.[$ev][$tool])' 2>/dev/null); then
                    echo "hooks remove: jq transform failed" >&2
                    return 1
                fi
            else
                case "$selector" in
                    ''|*[!0-9]*)
                        echo "hooks remove: index must be a positive integer or --all (got '$selector')" >&2
                        return 2
                        ;;
                esac
                if [ "$selector" -lt 1 ] || [ "$selector" -gt "$count" ]; then
                    echo "hooks remove: index $selector out of range (have $count hook(s) for $event $tool)" >&2
                    return 1
                fi
                local jq_idx=$((selector - 1))
                if ! new_json=$(printf '%s\n' "$json" | jq -c \
                    --arg ev "$event" --arg tool "$tool" --argjson i "$jq_idx" '
                      .[$ev][$tool] = (.[$ev][$tool] | del(.[$i]))
                      | if (.[$ev][$tool] | length) == 0 then del(.[$ev][$tool]) else . end
                    ' 2>/dev/null); then
                    echo "hooks remove: jq transform failed" >&2
                    return 1
                fi
            fi
            if ! _hooks_cli_write "$new_json"; then
                echo "hooks remove: failed to write $(hooks_config_path)" >&2
                return 1
            fi
            if [ "$selector" = "--all" ]; then
                echo "removed: $event $tool ($count hook(s))"
            else
                echo "removed: $event $tool #$selector"
            fi
            ;;
        -h|--help|help)
            _hooks_cli_usage
            return 0
            ;;
        "")
            _hooks_cli_usage >&2
            return 2
            ;;
        *)
            echo "hooks: unknown subcommand '$sub'" >&2
            _hooks_cli_usage >&2
            return 2
            ;;
    esac
}
