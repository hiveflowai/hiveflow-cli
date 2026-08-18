#!/bin/bash

# ==========================================
# PERMISSIONS MODULE - permissions.sh
# ==========================================
# Permission system for agentic mutating tools (M2).
# Sourced by tool_calling.sh / coder.sh. Do NOT enable strict mode globally
# here: this file is sourced into the parent shell and `set -euo pipefail`
# would leak flags into coder.sh / legacy modules.
#
# Public contract:
#   check_permission <tool> <resource>     -> 0=allow, 1=deny, 2=needs-confirm
#                                              (sets PERMISSION_REASON)
#   confirm_permission <tool> <resource> [yes_flag]
#                                          -> 0=approved, 1=denied (interactive)
#   permissions_init                       -> creates config if missing
#   permissions_allow <tool> <pattern>     -> add entry to allowlist
#   permissions_deny  <tool> <pattern>     -> add entry to denylist
#   permissions_remove <allow|deny> <tool> <pattern>
#   permissions_list                       -> human-readable dump

# Double-source guard (coder.sh + tests both source us).
if [ -n "${_PERMISSIONS_LOADED:-}" ]; then
    return 0
fi
_PERMISSIONS_LOADED=1

# i18n fallback: hf_t existe aunque i18n.sh no esté cargado (tests sourcean directo).
type hf_t >/dev/null 2>&1 || hf_t() { if [ "${HF_LANG:-en}" = "es" ] && [ -n "${2:-}" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# Config path. Override via env for tests.
: "${PERMISSIONS_CONFIG:=${CONFIG_DIR:-$HOME/.config/coder-cli}/permissions.json}"

# Tools that NEVER require a permission check (read-only by contract).
# Documented in CLAUDE.md -> "Canonical pattern" -> read-only safe-by-default.
_PERMISSIONS_READ_ONLY_TOOLS=(read_file grep_search glob_files)

# Hardcoded denylist - command patterns for bash_exec / shell_exec.
# Editing here is security-relevant: adding a pattern prevents a class of
# destructive commands; removing exposes users. Audit every change.
# Glob matching via bash `[[ x == $pattern ]]` (no extglob, no globstar:
# inside `[[ ]]` `*` already matches any sequence including `/`).
_PERMISSIONS_HARD_DENY_PATTERNS=(
    "*rm -rf /*"
    "*sudo rm -rf*"
    "*dd *of=/dev/sd*"
    "*dd *of=/dev/nvme*"
    "*dd *of=/dev/disk*"
    "*mkfs.*"
    "*:(){:|:&};:*"
    "*> /dev/sd*"
    "*>/dev/sd*"
    "*> /dev/nvme*"
    "*>/dev/nvme*"
    "*> /dev/disk*"
    "*>/dev/disk*"
    "*chmod -R 777 /*"
)

# ---- Internal helpers ----

# _permissions_match_pattern <input> <pattern>
# Bash glob match. `*` matches any sequence (including `/`) inside [[ ]].
_permissions_match_pattern() {
    local input="$1"
    local pattern="$2"
    # shellcheck disable=SC2053  # pattern is intentional, no quote
    [[ "$input" == $pattern ]]
}

# _permissions_is_read_only_tool <tool>
_permissions_is_read_only_tool() {
    local tool="$1"
    local t
    for t in "${_PERMISSIONS_READ_ONLY_TOOLS[@]}"; do
        [ "$t" = "$tool" ] && return 0
    done
    return 1
}

# _permissions_check_hard_deny <tool> <resource>
# Applies only to bash_exec / shell_exec. Returns 0 if match (=deny).
_permissions_check_hard_deny() {
    local tool="$1"
    local resource="$2"
    local pattern

    if [ "$tool" != "bash_exec" ] && [ "$tool" != "shell_exec" ]; then
        return 1
    fi

    for pattern in "${_PERMISSIONS_HARD_DENY_PATTERNS[@]}"; do
        if _permissions_match_pattern "$resource" "$pattern"; then
            PERMISSION_REASON="hard denylist match: $pattern"
            return 0
        fi
    done
    return 1
}

# _permissions_check_user_list <list> <tool> <resource>
# list = "allowlist" or "denylist". Returns 0 if any entry matches.
_permissions_check_user_list() {
    local list="$1"
    local tool="$2"
    local resource="$3"
    local cfg="$PERMISSIONS_CONFIG"
    local entries pattern

    [ -f "$cfg" ] || return 1

    entries=$(jq -r --arg list "$list" --arg tool "$tool" \
        '.[$list][]? | select(.tool == $tool) | .pattern' "$cfg" 2>/dev/null) || return 1
    [ -z "$entries" ] && return 1

    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        if _permissions_match_pattern "$resource" "$pattern"; then
            PERMISSION_REASON="user ${list}: $tool $pattern"
            return 0
        fi
    done <<< "$entries"
    return 1
}

# ---- Public API ----

# permissions_init: create config with safe defaults if missing. Validate structure.
permissions_init() {
    local cfg="$PERMISSIONS_CONFIG"
    local dir
    dir=$(dirname "$cfg")

    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || { echo "permissions_init: cannot create $dir" >&2; return 1; }
    fi

    if [ ! -f "$cfg" ]; then
        cat > "$cfg" <<'JSON'
{
  "version": 1,
  "allowlist": [],
  "denylist": []
}
JSON
    fi

    if ! jq -e '.version == 1 and (.allowlist | type == "array") and (.denylist | type == "array")' \
            "$cfg" >/dev/null 2>&1; then
        echo "permissions_init: invalid config at $cfg" >&2
        return 1
    fi
    return 0
}

# check_permission <tool> <resource>
# 0 = allow, 1 = deny, 2 = needs-confirm. Sets PERMISSION_REASON.
check_permission() {
    local tool="${1:-}"
    local resource="${2:-}"

    PERMISSION_REASON=""

    if [ -z "$tool" ]; then
        PERMISSION_REASON="missing tool name"
        return 1
    fi

    if _permissions_check_hard_deny "$tool" "$resource"; then
        return 1
    fi

    if _permissions_check_user_list "denylist" "$tool" "$resource"; then
        return 1
    fi

    if _permissions_is_read_only_tool "$tool"; then
        PERMISSION_REASON="read-only tool (auto-allow)"
        return 0
    fi

    if _permissions_check_user_list "allowlist" "$tool" "$resource"; then
        return 0
    fi

    PERMISSION_REASON="not in allowlist"
    return 2
}

# _permissions_atomic_jq_update <jq_expr> [<jq_arg_name> <jq_arg_value> ...]
# Apply a jq expression to the config and atomically replace it.
# Pass name+value pairs that become jq --arg flags.
_permissions_atomic_jq_update() {
    local expr="$1"; shift
    local cfg="$PERMISSIONS_CONFIG"
    local tmp
    local -a jq_args=()

    while [ "$#" -ge 2 ]; do
        jq_args+=(--arg "$1" "$2")
        shift 2
    done

    tmp=$(mktemp "${cfg}.XXXXXX") || return 1
    if ! jq "${jq_args[@]}" "$expr" "$cfg" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$cfg"
    return 0
}

# _permissions_dedup_key: separator used to dedup (tool + sep + pattern).
# Use a control char unlikely to appear in tool names or path globs.
_PERMISSIONS_DEDUP_SEP="|"

# permissions_allow <tool> <pattern>
permissions_allow() {
    local tool="${1:-}"
    local pattern="${2:-}"

    [ -n "$tool" ]    || { echo "permissions_allow: tool required" >&2; return 1; }
    [ -n "$pattern" ] || { echo "permissions_allow: pattern required" >&2; return 1; }

    permissions_init || return 1
    # shellcheck disable=SC2016  # $tool, $pattern, $sep are jq vars via --arg
    _permissions_atomic_jq_update \
        '.allowlist = ((.allowlist + [{tool: $tool, pattern: $pattern}]) | unique_by(.tool + $sep + .pattern))' \
        tool "$tool" pattern "$pattern" sep "$_PERMISSIONS_DEDUP_SEP"
}

# permissions_deny <tool> <pattern>
permissions_deny() {
    local tool="${1:-}"
    local pattern="${2:-}"

    [ -n "$tool" ]    || { echo "permissions_deny: tool required" >&2; return 1; }
    [ -n "$pattern" ] || { echo "permissions_deny: pattern required" >&2; return 1; }

    permissions_init || return 1
    # shellcheck disable=SC2016  # $tool, $pattern, $sep are jq vars via --arg
    _permissions_atomic_jq_update \
        '.denylist = ((.denylist + [{tool: $tool, pattern: $pattern}]) | unique_by(.tool + $sep + .pattern))' \
        tool "$tool" pattern "$pattern" sep "$_PERMISSIONS_DEDUP_SEP"
}

# permissions_remove <allow|deny> <tool> <pattern>
permissions_remove() {
    local list="${1:-}"
    local tool="${2:-}"
    local pattern="${3:-}"
    local key

    case "$list" in
        allow) key="allowlist" ;;
        deny)  key="denylist" ;;
        *) echo "permissions_remove: list must be 'allow' or 'deny'" >&2; return 1 ;;
    esac
    [ -n "$tool" ]    || { echo "permissions_remove: tool required" >&2; return 1; }
    [ -n "$pattern" ] || { echo "permissions_remove: pattern required" >&2; return 1; }

    permissions_init || return 1
    # shellcheck disable=SC2016  # $key, $tool, $pattern are jq vars via --arg
    _permissions_atomic_jq_update \
        '.[$key] = (.[$key] | map(select(.tool != $tool or .pattern != $pattern)))' \
        key "$key" tool "$tool" pattern "$pattern"
}

# permissions_list: print full config in human-readable form.
permissions_list() {
    permissions_init || return 1
    local cfg="$PERMISSIONS_CONFIG"
    local entry count

    echo "Config: $cfg"
    echo
    echo "Hardcoded denylist (always enforced for bash_exec/shell_exec):"
    for entry in "${_PERMISSIONS_HARD_DENY_PATTERNS[@]}"; do
        echo "  - $entry"
    done
    echo
    echo "Read-only tools (auto-allow, no confirm):"
    for entry in "${_PERMISSIONS_READ_ONLY_TOOLS[@]}"; do
        echo "  - $entry"
    done
    echo
    echo "User allowlist:"
    count=$(jq -r '.allowlist | length' "$cfg")
    if [ "$count" = "0" ]; then
        echo "  (empty)"
    else
        jq -r '.allowlist[] | "  - \(.tool): \(.pattern)"' "$cfg"
    fi
    echo
    echo "User denylist:"
    count=$(jq -r '.denylist | length' "$cfg")
    if [ "$count" = "0" ]; then
        echo "  (empty)"
    else
        jq -r '.denylist[] | "  - \(.tool): \(.pattern)"' "$cfg"
    fi
}

# confirm_permission <tool> <resource> [<yes_flag>]
# yes_flag=1 auto-approves (but NEVER bypasses hard deny / user deny).
# No TTY + needs-confirm => deny (cannot prompt).
# Answers: y/yes once, a/always (persists to allowlist), n/no, d/deny-always.
confirm_permission() {
    local tool="${1:-}"
    local resource="${2:-}"
    local yes_flag="${3:-0}"
    local rc

    check_permission "$tool" "$resource"
    rc=$?

    case "$rc" in
        0) return 0 ;;
        1) echo "DENIED: $PERMISSION_REASON" >&2; return 1 ;;
        2)
            if [ "$yes_flag" = "1" ]; then
                return 0
            fi
            if [ ! -t 0 ]; then
                echo "DENIED: non-interactive shell, cannot confirm '$tool' on '$resource'" >&2
                return 1
            fi
            ;;
    esac

    echo "" >&2
    echo "Tool requires permission:" >&2
    echo "  Tool:     $tool" >&2
    echo "  Resource: $resource" >&2
    echo "" >&2
    echo "Choose: [y]es once / [a]lways (persist allow) / [n]o / [d]eny-always" >&2

    local answer
    read -r -p "> " answer

    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        a|A|always|ALWAYS)
            permissions_allow "$tool" "$resource" || return 1
            return 0
            ;;
        d|D|deny|DENY)
            permissions_deny "$tool" "$resource" || return 1
            return 1
            ;;
        *) return 1 ;;
    esac
}

# ---- CLI dispatcher ----

# _permissions_cli_usage: stdout, multilínea, sin trailing newline extra.
_permissions_cli_usage() {
    printf '%s\n' "$(hf_t "Usage: coder permissions <subcommand> [args]" "Uso: coder permissions <subcommand> [args]")"
    cat <<'EOF'

Subcommands:
  list                                  List allowlist/denylist + hardcoded defaults.
  allow <tool> <pattern>                Add an allowlist entry.
  deny  <tool> <pattern>                Add a denylist entry.
  remove <allow|deny> <tool> <pattern>  Remove an entry.

Examples:
  coder permissions list
  coder permissions allow write_file '/tmp/*'
  coder permissions deny  bash_exec   '*curl evil.com*'
  coder permissions remove allow write_file '/tmp/*'
EOF
}

# permissions_cli <subcommand> [<args>...]
# Exit codes: 0 ok, 1 internal error (delegated), 2 usage error.
permissions_cli() {
    local sub="${1:-}"

    case "$sub" in
        list)
            permissions_list
            ;;
        allow)
            shift
            if [ "$#" -ne 2 ]; then
                echo "permissions allow: expected <tool> <pattern>" >&2
                _permissions_cli_usage >&2
                return 2
            fi
            permissions_allow "$1" "$2"
            ;;
        deny)
            shift
            if [ "$#" -ne 2 ]; then
                echo "permissions deny: expected <tool> <pattern>" >&2
                _permissions_cli_usage >&2
                return 2
            fi
            permissions_deny "$1" "$2"
            ;;
        remove)
            shift
            if [ "$#" -ne 3 ]; then
                echo "permissions remove: expected <allow|deny> <tool> <pattern>" >&2
                _permissions_cli_usage >&2
                return 2
            fi
            permissions_remove "$1" "$2" "$3"
            ;;
        -h|--help|help)
            _permissions_cli_usage
            return 0
            ;;
        "")
            _permissions_cli_usage >&2
            return 2
            ;;
        *)
            echo "permissions: unknown subcommand '$sub'" >&2
            _permissions_cli_usage >&2
            return 2
            ;;
    esac
}
