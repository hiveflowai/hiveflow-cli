#!/bin/bash

# ==========================================
# AGENTIC TOOL: edit_file
# ==========================================
# Byte-exact replacement of a substring in a file confined to the cwd.
# Sourced by lib/tool_calling.sh::register_tool. Do NOT set global strict
# mode here (this file is sourced in the parent shell).
#
# Contract:
#   - Match is byte-exact, NOT regex and NOT glob. Uses `jq --rawfile` +
#     `split($old) | join($new)` to preserve all bytes (including internal
#     and trailing newlines).
#   - If replace_all != true (default false), old_string MUST appear exactly
#     once; zero matches and more than one are errors.
#   - dry_run = true => prints the planned diff -u and does NOT touch the file
#     (no write permission required, but the path is still subject to containment).
#   - Symlinks and paths outside the cwd are rejected (mirrors read_file/write_file).
#   - Mandatory permission check via confirm_permission before writing.
#   - Automatic backup at ${CODER_BACKUP_DIR:-$CONFIG_DIR/backups}/<timestamp-XXXXXX>/<basename>
#     before overwriting. If the copy fails, the write is aborted.
#   - Atomic write via mktemp in the same directory + mv.
#
# Env vars:
#   CODER_BACKUP_DIR  - root for backups (default: $CONFIG_DIR/backups)
#   CODER_YES         - "1" => auto-approve needs-confirm without prompting

# tool_edit_file_definition
# Emits the JSON schema (internal canonical Anthropic format).
tool_edit_file_definition() {
    cat <<'EOF'
{
  "name": "edit_file",
  "description": "Replace an exact substring in a file. Match is byte-exact (no regex, no glob). By default fails when old_string is absent or appears more than once; pass replace_all=true to replace every occurrence. Pass dry_run=true to print a unified diff without modifying the file. Paths must resolve inside the current working directory; symlinks and non-regular files are rejected. When writing, the original is copied to a timestamped backup directory before the atomic overwrite.",
  "input_schema": {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Target file path, absolute or relative to cwd. Must resolve inside the current working directory."
      },
      "old_string": {
        "type": "string",
        "description": "Exact substring to replace. Non-empty. Matched byte-by-byte without regex interpretation."
      },
      "new_string": {
        "type": "string",
        "description": "Replacement text. Empty string is allowed (used for deletion)."
      },
      "replace_all": {
        "type": "boolean",
        "description": "Replace every occurrence. Default false (requires exactly one match)."
      },
      "dry_run": {
        "type": "boolean",
        "description": "Print a unified diff of the planned change without writing. Default false."
      }
    },
    "required": ["path", "old_string", "new_string"]
  }
}
EOF
}

# tool_edit_file_handler <input_json>
# Stdout = success/dry-run message + optional diff.
# Stderr = diagnostic messages on error.
# Exit codes:
#   0  OK
#   1  symlink / outside cwd / not found / not a regular file /
#      old_string not found / not unique / permission denied /
#      backup failed / write failed / permissions.sh module not loaded
#   2  invalid input JSON or missing fields
tool_edit_file_handler() {
    local input_json="$1"
    local path old_string new_string replace_all dry_run
    local parent real_path real_pwd target_dir
    local backup_root backup_subdir backup_path
    local occurrences tmp diff_out bytes

    if [ -z "$input_json" ]; then
        echo "edit_file: missing input JSON" >&2
        return 2
    fi

    if ! path=$(echo "$input_json" | jq -re '.path' 2>/dev/null); then
        echo "edit_file: missing required field 'path'" >&2
        return 2
    fi
    if [ -z "$path" ]; then
        echo "edit_file: field 'path' must be a non-empty string" >&2
        return 2
    fi

    if ! old_string=$(echo "$input_json" | jq -re '.old_string' 2>/dev/null); then
        echo "edit_file: missing required field 'old_string'" >&2
        return 2
    fi
    if [ -z "$old_string" ]; then
        echo "edit_file: field 'old_string' must be a non-empty string" >&2
        return 2
    fi

    # jq -re fails if .new_string == null. "" passes (returns an empty string).
    if ! new_string=$(echo "$input_json" | jq -re '.new_string' 2>/dev/null); then
        echo "edit_file: missing required field 'new_string'" >&2
        return 2
    fi

    replace_all=$(echo "$input_json" | jq -r '.replace_all // false' 2>/dev/null)
    dry_run=$(echo "$input_json" | jq -r '.dry_run // false' 2>/dev/null)

    # Symlinks rejected (same as read_file/write_file).
    if [ -L "$path" ]; then
        echo "edit_file: refusing to follow symlink: $path" >&2
        return 1
    fi
    if [ ! -e "$path" ]; then
        echo "edit_file: file not found: $path" >&2
        return 1
    fi
    if [ ! -f "$path" ]; then
        echo "edit_file: not a regular file: $path" >&2
        return 1
    fi
    if [ ! -r "$path" ]; then
        echo "edit_file: file not readable: $path" >&2
        return 1
    fi

    if ! parent=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P); then
        echo "edit_file: cannot resolve parent directory of: $path" >&2
        return 1
    fi
    real_path="$parent/$(basename "$path")"
    real_pwd=$(cd "$PWD" && pwd -P)

    case "$real_path" in
        "$real_pwd"|"$real_pwd"/*) : ;;
        *)
            echo "edit_file: path outside cwd is not allowed: $real_path (cwd=$real_pwd)" >&2
            return 1
            ;;
    esac

    # Count matches with a literal split in jq (NOT regex). length(split) = matches + 1.
    if ! occurrences=$(jq -rn \
            --rawfile c "$real_path" \
            --arg o "$old_string" \
            '($c | split($o) | length) - 1' 2>/dev/null); then
        echo "edit_file: failed to analyze file: $real_path" >&2
        return 1
    fi

    if ! [[ "$occurrences" =~ ^[0-9]+$ ]]; then
        echo "edit_file: invalid occurrence count from jq ('$occurrences') for $real_path" >&2
        return 1
    fi

    if [ "$occurrences" -eq 0 ]; then
        echo "edit_file: old_string not found in $real_path" >&2
        return 1
    fi

    if [ "$replace_all" != "true" ] && [ "$occurrences" -gt 1 ]; then
        echo "edit_file: old_string is not unique in $real_path ($occurrences matches); pass replace_all=true to replace every occurrence" >&2
        return 1
    fi

    target_dir="$parent"

    # Materialize the new content into a tmpfile (preserves bytes via jq -j).
    if ! tmp=$(mktemp "${real_path}.XXXXXX" 2>/dev/null); then
        echo "edit_file: cannot create temp file next to $real_path" >&2
        return 1
    fi

    if ! jq -jn \
            --rawfile c "$real_path" \
            --arg o "$old_string" \
            --arg n "$new_string" \
            '$c | split($o) | join($n)' > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo "edit_file: jq replacement failed for $real_path" >&2
        return 1
    fi

    # Dry-run: emit diff and discard tmpfile.
    if [ "$dry_run" = "true" ]; then
        diff_out=$(diff -u "$real_path" "$tmp" 2>/dev/null || true)
        rm -f "$tmp"
        echo "edit_file: dry_run, ${occurrences} occurrence(s) would be replaced in $real_path"
        if [ -n "$diff_out" ]; then
            echo "$diff_out"
        fi
        return 0
    fi

    # Permission check before mutating.
    if ! declare -f confirm_permission >/dev/null 2>&1; then
        rm -f "$tmp"
        echo "edit_file: lib/permissions.sh not loaded (confirm_permission undefined); refusing to write" >&2
        return 1
    fi

    if ! confirm_permission "edit_file" "$real_path" "${CODER_YES:-0}"; then
        rm -f "$tmp"
        echo "edit_file: permission denied for $real_path" >&2
        return 1
    fi

    if [ ! -w "$target_dir" ]; then
        rm -f "$tmp"
        echo "edit_file: target directory not writable: $target_dir" >&2
        return 1
    fi

    # Mandatory backup (the file always exists in edit_file).
    backup_root="${CODER_BACKUP_DIR:-${CONFIG_DIR:-$HOME/.config/coder-cli}/backups}"
    if ! mkdir -p "$backup_root"; then
        rm -f "$tmp"
        echo "edit_file: cannot create backup root: $backup_root" >&2
        return 1
    fi
    if ! backup_subdir=$(mktemp -d "$backup_root/$(date +%Y%m%d-%H%M%S)-XXXXXX" 2>/dev/null); then
        rm -f "$tmp"
        echo "edit_file: cannot create backup subdir under $backup_root" >&2
        return 1
    fi
    backup_path="$backup_subdir/$(basename "$real_path")"
    if ! cp -p "$real_path" "$backup_path"; then
        rm -f "$tmp"
        echo "edit_file: backup copy failed: $real_path -> $backup_path" >&2
        return 1
    fi

    if ! mv "$tmp" "$real_path"; then
        rm -f "$tmp"
        echo "edit_file: atomic mv failed: $tmp -> $real_path" >&2
        return 1
    fi

    bytes=$(wc -c < "$real_path" | tr -d ' ')
    echo "edit_file: replaced ${occurrences} occurrence(s) in $real_path ($bytes bytes, backup: $backup_path)"
    return 0
}
