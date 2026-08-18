#!/bin/bash

# ==========================================
# AGENTIC TOOL: grep_search
# ==========================================
# Search files under a path (confined to cwd) for a regex pattern. Wraps ripgrep
# when available and falls back to BSD/GNU grep. Read-only: no permission check
# (the tool is already listed in _PERMISSIONS_READ_ONLY_TOOLS in lib/permissions.sh).
#
# Sourced by lib/tool_calling.sh::register_tool. Do NOT set global strict mode
# here: this file is sourced in the parent shell and `set -euo pipefail` would
# leak flags into coder.sh / legacy modules.
#
# Inputs:
#   pattern          (string,  required) - regex pattern (rg = Rust regex, grep -E = ERE).
#                                          With fixed_strings=true it is treated as literal.
#   path             (string,  optional) - file or directory inside the cwd. Default ".".
#                                          Symlinks rejected. Path canonicalized and
#                                          forced to be inside $PWD.
#   glob             (string,  optional) - file glob (e.g. "*.sh"). rg --glob
#                                          (.gitignore-style syntax, supports **).
#                                          grep --include (basename match, no **).
#   case_insensitive (bool,    optional) - default false.
#   fixed_strings    (bool,    optional) - default false. true → literal pattern (-F).
#   max_results      (integer, optional) - cap on total returned lines. Default 100,
#                                          range [1, 1000].
#
# Env vars:
#   CODER_GREP_FORCE_TOOL  - "rg" or "grep" to force detection (used in tests).
#                            If you ask for "rg" but rg is not in PATH, falls back to "grep".
#
# Output (stdout, structured format for the LLM):
#   grep_search: tool=<rg|grep> pattern=<...> path=<...> matches=<N> truncated=<true|false>
#   --- matches ---
#   <file>:<line>:<content>
#   ...
#   (or "(no matches)" if N=0)
#
# Exit codes:
#   0  search executed (any number of matches, including zero)
#   1  path outside cwd / symlink rejected / path does not exist / infra fail / tool error
#   2  invalid JSON or missing fields / out-of-range values

# tool_grep_search_definition
# Emits the JSON schema (internal canonical Anthropic format).
tool_grep_search_definition() {
    cat <<'EOF'
{
  "name": "grep_search",
  "description": "Recursively search files under a path (confined to cwd) for a regex pattern. Wraps ripgrep when available and falls back to grep. Read-only — no permission prompt. Default path is '.'. Symlinks are rejected, .git/ is excluded. Use 'glob' to scope by filename (e.g. '*.sh'). Output is file:line:content, capped at max_results (default 100, max 1000).",
  "input_schema": {
    "type": "object",
    "properties": {
      "pattern": {
        "type": "string",
        "description": "Regex pattern. Treated as ERE-ish (rg uses Rust regex, grep -E). Set fixed_strings=true for literal matching."
      },
      "path": {
        "type": "string",
        "description": "File or directory inside the current working directory. Defaults to '.'."
      },
      "glob": {
        "type": "string",
        "description": "Optional file glob to scope the search (e.g. '*.sh', '*.md'). rg uses .gitignore-style globs (supports **), grep uses --include basename matching."
      },
      "case_insensitive": {
        "type": "boolean",
        "description": "Match case-insensitively. Default false."
      },
      "fixed_strings": {
        "type": "boolean",
        "description": "Treat 'pattern' as a literal string instead of a regex. Default false."
      },
      "max_results": {
        "type": "integer",
        "description": "Maximum total matches to return. Default 100, range [1, 1000].",
        "minimum": 1,
        "maximum": 1000
      }
    },
    "required": ["pattern"]
  }
}
EOF
}

# _grep_search_pick_tool
# Stdout = "rg" or "grep". Honors CODER_GREP_FORCE_TOOL if set.
# If "rg" is forced but rg is not in PATH, falls back to "grep".
_grep_search_pick_tool() {
    local forced="${CODER_GREP_FORCE_TOOL:-}"
    case "$forced" in
        rg)
            if command -v rg >/dev/null 2>&1; then echo rg; else echo grep; fi
            ;;
        grep)
            echo grep
            ;;
        "")
            if command -v rg >/dev/null 2>&1; then echo rg; else echo grep; fi
            ;;
        *)
            return 1
            ;;
    esac
}

# tool_grep_search_handler <input_json>
# Reads inputs via jq, validates, runs rg or grep, emits structured output.
tool_grep_search_handler() {
    local input_json="$1"
    local pattern path glob case_insensitive fixed_strings max_results
    local tool real_path real_pwd parent
    local search_target

    if [ -z "$input_json" ]; then
        echo "grep_search: missing input JSON" >&2
        return 2
    fi

    if ! pattern=$(echo "$input_json" | jq -re '.pattern' 2>/dev/null); then
        echo "grep_search: missing required field 'pattern'" >&2
        return 2
    fi
    if [ -z "$pattern" ]; then
        echo "grep_search: field 'pattern' must be a non-empty string" >&2
        return 2
    fi

    path=$(echo "$input_json" | jq -r '.path // "."' 2>/dev/null)
    if [ -z "$path" ]; then
        path="."
    fi

    glob=$(echo "$input_json" | jq -r '.glob // ""' 2>/dev/null)
    case_insensitive=$(echo "$input_json" | jq -r '.case_insensitive // false' 2>/dev/null)
    fixed_strings=$(echo "$input_json" | jq -r '.fixed_strings // false' 2>/dev/null)
    max_results=$(echo "$input_json" | jq -r '.max_results // 100' 2>/dev/null)

    case "$case_insensitive" in
        true|false) : ;;
        *) echo "grep_search: 'case_insensitive' must be boolean (got: $case_insensitive)" >&2; return 2 ;;
    esac
    case "$fixed_strings" in
        true|false) : ;;
        *) echo "grep_search: 'fixed_strings' must be boolean (got: $fixed_strings)" >&2; return 2 ;;
    esac
    if ! [[ "$max_results" =~ ^[1-9][0-9]*$ ]]; then
        echo "grep_search: 'max_results' must be a positive integer (got: $max_results)" >&2
        return 2
    fi
    if [ "$max_results" -lt 1 ] || [ "$max_results" -gt 1000 ]; then
        echo "grep_search: 'max_results' out of range [1, 1000] (got: $max_results)" >&2
        return 2
    fi

    # Path validation: existence, no symlinks, cwd containment.
    if [ -L "$path" ]; then
        echo "grep_search: refusing to follow symlink: $path" >&2
        return 1
    fi
    if [ ! -e "$path" ]; then
        echo "grep_search: path not found: $path" >&2
        return 1
    fi

    if [ -d "$path" ]; then
        if ! real_path=$(cd "$path" 2>/dev/null && pwd -P); then
            echo "grep_search: cannot resolve directory: $path" >&2
            return 1
        fi
    else
        if ! parent=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P); then
            echo "grep_search: cannot resolve parent directory of: $path" >&2
            return 1
        fi
        real_path="$parent/$(basename "$path")"
    fi
    real_pwd=$(cd "$PWD" && pwd -P)

    case "$real_path" in
        "$real_pwd"|"$real_pwd"/*) : ;;
        *)
            echo "grep_search: path outside cwd is not allowed: $real_path (cwd=$real_pwd)" >&2
            return 1
            ;;
    esac

    # We use the original path (relative when applicable) so matches in the
    # output show readable paths for the LLM. Containment has already been
    # verified against $real_pwd.
    search_target="$path"

    if ! tool=$(_grep_search_pick_tool); then
        echo "grep_search: invalid CODER_GREP_FORCE_TOOL (got: ${CODER_GREP_FORCE_TOOL:-})" >&2
        return 2
    fi

    local all_matches=""
    local search_rc=0

    if [ "$tool" = "rg" ]; then
        local rg_args=( --no-heading --line-number --color=never --hidden --no-messages )
        [ "$case_insensitive" = true ] && rg_args+=( -i )
        [ "$fixed_strings" = true ] && rg_args+=( -F )
        [ -n "$glob" ] && rg_args+=( -g "$glob" )
        rg_args+=( -g '!.git/' )
        rg_args+=( -e "$pattern" -- "$search_target" )

        set +e
        all_matches=$(rg "${rg_args[@]}" 2>/dev/null)
        search_rc=$?
        set -e
        # rg: 0 found, 1 no matches, 2+ error.
        case "$search_rc" in
            0|1) : ;;
            *)
                echo "grep_search: rg failed with exit $search_rc" >&2
                return 1
                ;;
        esac
    else
        # BSD/GNU grep compatibility: -r recursive, -n line number, -I skip binary,
        # -E ERE (mutually exclusive with -F), --exclude-dir=.git.
        local grep_args=( -r -n -I --exclude-dir=.git )
        [ "$case_insensitive" = true ] && grep_args+=( -i )
        if [ "$fixed_strings" = true ]; then
            grep_args+=( -F )
        else
            grep_args+=( -E )
        fi
        [ -n "$glob" ] && grep_args+=( --include="$glob" )
        grep_args+=( -e "$pattern" -- "$search_target" )

        set +e
        all_matches=$(grep "${grep_args[@]}" 2>/dev/null)
        search_rc=$?
        set -e
        # grep: 0 found, 1 no matches, 2+ error.
        case "$search_rc" in
            0|1) : ;;
            *)
                echo "grep_search: grep failed with exit $search_rc" >&2
                return 1
                ;;
        esac
    fi

    # Total matches and truncation.
    local total truncated capped
    if [ -z "$all_matches" ]; then
        total=0
    else
        total=$(printf '%s\n' "$all_matches" | wc -l | tr -d ' ')
    fi

    if [ "$total" -gt "$max_results" ]; then
        truncated=true
        capped=$(printf '%s\n' "$all_matches" | head -n "$max_results")
    else
        truncated=false
        capped="$all_matches"
    fi

    echo "grep_search: tool=${tool} pattern=${pattern} path=${search_target} matches=${total} truncated=${truncated}"
    echo "--- matches ---"
    if [ "$total" -eq 0 ]; then
        echo "(no matches)"
    else
        printf '%s\n' "$capped"
    fi
    return 0
}
