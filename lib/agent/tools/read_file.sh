#!/bin/bash

# ==========================================
# AGENTIC TOOL: read_file
# ==========================================
# Safe read confined to the cwd. Returns content in `cat -n` format
# (numbered lines with a "%6d\t" prefix).
#
# Sourced by lib/tool_calling.sh::register_tool. Do NOT set global strict
# mode here: this file is sourced in the parent shell and `set -euo pipefail`
# would leak flags into coder.sh / legacy modules.

# tool_read_file_definition
# Emits the JSON schema (internal canonical Anthropic format).
tool_read_file_definition() {
    cat <<'EOF'
{
  "name": "read_file",
  "description": "Read a text file from disk and return its content prefixed with line numbers (cat -n format: %6d\\t<line>). Paths must resolve inside the current working directory; absolute paths outside cwd and symlinks are rejected. Reads up to 2000 lines per call by default; use offset+limit to page through larger files.",
  "input_schema": {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "File path, absolute or relative to cwd. Must resolve inside the current working directory."
      },
      "offset": {
        "type": "integer",
        "description": "1-indexed start line. Defaults to 1.",
        "minimum": 1
      },
      "limit": {
        "type": "integer",
        "description": "Maximum number of lines to read. Defaults to 2000.",
        "minimum": 1
      }
    },
    "required": ["path"]
  }
}
EOF
}

# tool_read_file_handler <input_json>
# Reads a file confined to the cwd. Emits content on stdout.
# Errors and diagnostic messages go to stderr. Return codes:
#   0  OK
#   1  file not found / outside cwd / not readable / is a directory / is a symlink
#   2  invalid input JSON or missing fields
tool_read_file_handler() {
    local input_json="$1"
    local path offset limit
    local parent real_path real_pwd

    if [ -z "$input_json" ]; then
        echo "read_file: missing input JSON" >&2
        return 2
    fi

    # Validate required path. jq -e returns != 0 if null/missing.
    if ! path=$(echo "$input_json" | jq -re '.path' 2>/dev/null); then
        echo "read_file: missing required field 'path'" >&2
        return 2
    fi
    if [ -z "$path" ]; then
        echo "read_file: field 'path' must be a non-empty string" >&2
        return 2
    fi

    # offset / limit with defaults.
    offset=$(echo "$input_json" | jq -r '.offset // 1' 2>/dev/null)
    limit=$(echo "$input_json" | jq -r '.limit // 2000' 2>/dev/null)

    if ! [[ "$offset" =~ ^[1-9][0-9]*$ ]]; then
        echo "read_file: 'offset' must be a positive integer (got: $offset)" >&2
        return 2
    fi
    if ! [[ "$limit" =~ ^[1-9][0-9]*$ ]]; then
        echo "read_file: 'limit' must be a positive integer (got: $limit)" >&2
        return 2
    fi

    # Existence + type. Reject symlinks by default (safety: prevents
    # reading targets outside the cwd via a symlink residing in the cwd).
    if [ -L "$path" ]; then
        echo "read_file: refusing to follow symlink: $path" >&2
        return 1
    fi
    if [ ! -e "$path" ]; then
        echo "read_file: file not found: $path" >&2
        return 1
    fi
    if [ -d "$path" ]; then
        echo "read_file: path is a directory, not a file: $path" >&2
        return 1
    fi
    if [ ! -f "$path" ]; then
        echo "read_file: not a regular file: $path" >&2
        return 1
    fi
    if [ ! -r "$path" ]; then
        echo "read_file: file not readable: $path" >&2
        return 1
    fi

    # Canonicalize for cwd enforcement. `cd ... && pwd -P` is portable
    # (macOS BSD + GNU). Avoid `realpath` for old-BSD compatibility.
    if ! parent=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P); then
        echo "read_file: cannot resolve parent directory of: $path" >&2
        return 1
    fi
    real_path="$parent/$(basename "$path")"
    real_pwd=$(cd "$PWD" && pwd -P)

    case "$real_path" in
        "$real_pwd"|"$real_pwd"/*) : ;;
        *)
            echo "read_file: path outside cwd is not allowed: $real_path (cwd=$real_pwd)" >&2
            return 1
            ;;
    esac

    # Emit lines [offset, offset+limit) in `cat -n` format ("%6d\t%s").
    # awk with `exit` stops reading once past the range (does not scan huge files).
    awk -v off="$offset" -v lim="$limit" '
        NR >= off && NR < off + lim { printf "%6d\t%s\n", NR, $0 }
        NR >= off + lim { exit }
    ' "$real_path"
}
