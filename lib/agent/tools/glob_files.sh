#!/bin/bash

# ==========================================
# AGENTIC TOOL: glob_files
# ==========================================
# List files (or directories) under a path confined to the cwd that match a
# glob pattern. Backed by `find` (portable BSD/GNU). Read-only: no permission
# check (the tool is already listed in _PERMISSIONS_READ_ONLY_TOOLS in
# lib/permissions.sh).
#
# Sourced by lib/tool_calling.sh::register_tool. Do NOT set global strict
# mode here: this file is sourced in the parent shell and `set -euo pipefail`
# would leak flags into coder.sh / legacy modules.
#
# Inputs:
#   pattern          (string,  required) - glob pattern. Without '/' → matches
#                                          basename (find -name). With '/' →
#                                          matches the full path
#                                          (find -path "*<pattern>"). '**' is
#                                          flattened to '*' (find does not
#                                          support globstar; recursion is the default).
#   path             (string,  optional) - directory inside the cwd to scope
#                                          the search. Default ".".
#                                          Symlinks rejected; files (not
#                                          dirs) rejected.
#   case_insensitive (bool,    optional) - default false. true → -iname / -ipath.
#   type             (string,  optional) - "file" (default), "dir" or "any".
#   max_results      (integer, optional) - cap on returned lines. Default 100,
#                                          range [1, 1000].
#
# Output (stdout, structured format for the LLM):
#   glob_files: pattern=<...> path=<...> type=<...> matches=<N> truncated=<true|false>
#   --- files ---
#   <relative path>
#   ...
#   (or "(no matches)" if N=0)
#
# Sort: lexical LC_ALL=C (deterministic).
# `.git/` excluded by default via -prune (not descended into or reported).
# The "./" prefix is stripped from the output when path="." to avoid polluting
# the LLM's view with find's internal convention.
#
# Exit codes:
#   0  find executed (any number of matches, including zero)
#   1  path outside cwd / symlink rejected / does not exist / not a dir / find error
#   2  invalid JSON or missing fields / out-of-range values / invalid type

# tool_glob_files_definition
# Emits the JSON schema (internal canonical Anthropic format).
tool_glob_files_definition() {
    cat <<'EOF'
{
  "name": "glob_files",
  "description": "Recursively list files (or directories) under a path (confined to cwd) matching a glob pattern. Backed by find. Read-only — no permission prompt. Default path is '.', default type is 'file'. Symlinks at the root path are rejected. The .git/ directory is excluded. Patterns without '/' match basename (e.g. '*.sh'); patterns with '/' match against the full path (e.g. 'lib/*.sh', 'tests/test_*.sh'). '**' is treated as '*' (find recurses by default). Output is sorted lexically and capped at max_results (default 100, max 1000).",
  "input_schema": {
    "type": "object",
    "properties": {
      "pattern": {
        "type": "string",
        "description": "Glob pattern. Without '/' it matches basename. With '/' it matches the full path. '**' is flattened to '*'."
      },
      "path": {
        "type": "string",
        "description": "Directory inside the current working directory to search under. Defaults to '.'."
      },
      "case_insensitive": {
        "type": "boolean",
        "description": "Case-insensitive match. Default false."
      },
      "type": {
        "type": "string",
        "description": "Entry type to match: 'file' (default), 'dir', or 'any'.",
        "enum": ["file", "dir", "any"]
      },
      "max_results": {
        "type": "integer",
        "description": "Maximum number of matches to return. Default 100, range [1, 1000].",
        "minimum": 1,
        "maximum": 1000
      }
    },
    "required": ["pattern"]
  }
}
EOF
}

# tool_glob_files_handler <input_json>
# Reads inputs via jq, validates, runs find, emits structured output.
tool_glob_files_handler() {
    local input_json="$1"
    local pattern path case_insensitive type_filter max_results
    local real_path real_pwd
    local pattern_for_find
    local -a name_or_path_flag find_type_args
    local all_matches search_rc total truncated capped

    if [ -z "$input_json" ]; then
        echo "glob_files: missing input JSON" >&2
        return 2
    fi

    if ! pattern=$(echo "$input_json" | jq -re '.pattern' 2>/dev/null); then
        echo "glob_files: missing required field 'pattern'" >&2
        return 2
    fi
    if [ -z "$pattern" ]; then
        echo "glob_files: field 'pattern' must be a non-empty string" >&2
        return 2
    fi

    path=$(echo "$input_json" | jq -r '.path // "."' 2>/dev/null)
    if [ -z "$path" ]; then
        path="."
    fi

    case_insensitive=$(echo "$input_json" | jq -r '.case_insensitive // false' 2>/dev/null)
    type_filter=$(echo "$input_json" | jq -r '.type // "file"' 2>/dev/null)
    max_results=$(echo "$input_json" | jq -r '.max_results // 100' 2>/dev/null)

    case "$case_insensitive" in
        true|false) : ;;
        *) echo "glob_files: 'case_insensitive' must be boolean (got: $case_insensitive)" >&2; return 2 ;;
    esac
    case "$type_filter" in
        file|dir|any) : ;;
        *) echo "glob_files: 'type' must be one of file|dir|any (got: $type_filter)" >&2; return 2 ;;
    esac
    if ! [[ "$max_results" =~ ^[1-9][0-9]*$ ]]; then
        echo "glob_files: 'max_results' must be a positive integer (got: $max_results)" >&2
        return 2
    fi
    if [ "$max_results" -lt 1 ] || [ "$max_results" -gt 1000 ]; then
        echo "glob_files: 'max_results' out of range [1, 1000] (got: $max_results)" >&2
        return 2
    fi

    # Path validation: existence, no symlinks, must be a dir, cwd containment.
    if [ -L "$path" ]; then
        echo "glob_files: refusing to follow symlink: $path" >&2
        return 1
    fi
    if [ ! -e "$path" ]; then
        echo "glob_files: path not found: $path" >&2
        return 1
    fi
    if [ ! -d "$path" ]; then
        echo "glob_files: path is not a directory: $path" >&2
        return 1
    fi
    if ! real_path=$(cd "$path" 2>/dev/null && pwd -P); then
        echo "glob_files: cannot resolve directory: $path" >&2
        return 1
    fi
    real_pwd=$(cd "$PWD" && pwd -P)
    case "$real_path" in
        "$real_pwd"|"$real_pwd"/*) : ;;
        *)
            echo "glob_files: path outside cwd is not allowed: $real_path (cwd=$real_pwd)" >&2
            return 1
            ;;
    esac

    # '**' → '*' (find does not understand globstar; traversal is recursive by default).
    # Note: in `${var//pat/repl}` the pattern needs the glob escaped (`\*\*`)
    # to match `**` literally, but the replacement is plain text (`*`).
    pattern_for_find="${pattern//\*\*/*}"

    # Routing: '/' in pattern → -path; without '/' → -name.
    if [[ "$pattern_for_find" == */* ]]; then
        if [ "$case_insensitive" = true ]; then
            name_or_path_flag=( -ipath "*${pattern_for_find}" )
        else
            name_or_path_flag=( -path "*${pattern_for_find}" )
        fi
    else
        if [ "$case_insensitive" = true ]; then
            name_or_path_flag=( -iname "${pattern_for_find}" )
        else
            name_or_path_flag=( -name "${pattern_for_find}" )
        fi
    fi

    # Type filter.
    case "$type_filter" in
        file) find_type_args=( -type f ) ;;
        dir)  find_type_args=( -type d ) ;;
        any)  find_type_args=( ) ;;
    esac

    # find: prune .git/, then match. We use the original $path (not $real_path)
    # so the output uses readable relative paths when applicable.
    # `find -name .git -prune -o (<pat>) <type> -print`: if .git matches it is
    # pruned (not descended into or reported); on the other branch, implicit AND
    # between match + type + print.
    set +e
    if [ "${#find_type_args[@]}" -gt 0 ]; then
        all_matches=$(find "$path" \
            -name .git -prune -o \
            \( "${name_or_path_flag[@]}" \) "${find_type_args[@]}" -print \
            2>/dev/null | LC_ALL=C sort)
    else
        all_matches=$(find "$path" \
            -name .git -prune -o \
            \( "${name_or_path_flag[@]}" \) -print \
            2>/dev/null | LC_ALL=C sort)
    fi
    search_rc=$?
    set -e

    if [ "$search_rc" -ne 0 ]; then
        echo "glob_files: find failed with exit $search_rc" >&2
        return 1
    fi

    # Strip leading "./" when path="." to avoid polluting the LLM's view
    # with find's internal convention.
    if [ "$path" = "." ] && [ -n "$all_matches" ]; then
        all_matches=$(printf '%s\n' "$all_matches" | sed 's|^\./||')
    fi

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

    echo "glob_files: pattern=${pattern} path=${path} type=${type_filter} matches=${total} truncated=${truncated}"
    echo "--- files ---"
    if [ "$total" -eq 0 ]; then
        echo "(no matches)"
    else
        printf '%s\n' "$capped"
    fi
    return 0
}
