#!/bin/bash

# ==========================================
# AGENTIC TOOL: write_file
# ==========================================
# Atomic write with automatic backup for files confined to the cwd.
# Sourced by lib/tool_calling.sh::register_tool. Do NOT set global strict
# mode here (this file is sourced in the parent shell).
#
# Contract:
#   - The path must resolve inside the cwd (same enforcement as read_file).
#   - Symlinks and paths pointing to anything other than a regular file are rejected.
#   - The parent directory MUST exist; intermediate directories are not created.
#   - If the file already exists, it is copied with cp -p to:
#       ${CODER_BACKUP_DIR:-$CONFIG_DIR/backups}/<YYYYMMDD-HHMMSS-XXXXXX>/<basename>
#     before overwriting. If the copy fails, the write is aborted.
#   - Mandatory permission check via confirm_permission (lib/permissions.sh).
#     coder.sh already sources permissions.sh at startup; tests do it explicitly.
#     If confirm_permission is not loaded, the tool refuses to write.
#   - Atomic write: tempfile via mktemp in the target directory + mv.
#
# Env vars:
#   CODER_BACKUP_DIR  - root for backups (default: $CONFIG_DIR/backups)
#   CODER_YES         - "1" => auto-approve needs-confirm without prompting

# tool_write_file_definition
# Emits the JSON schema (internal canonical Anthropic format).
tool_write_file_definition() {
    cat <<'EOF'
{
  "name": "write_file",
  "description": "Write content to a file atomically with automatic backup. If the file exists, the original is copied to a timestamped backup directory before being overwritten. Paths must resolve inside the current working directory; symlinks and non-regular files are rejected. The parent directory must already exist. Returns a confirmation line with bytes written and (when applicable) the backup path.",
  "input_schema": {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Target file path, absolute or relative to cwd. Must resolve inside the current working directory."
      },
      "content": {
        "type": "string",
        "description": "Full content to write. Replaces the entire file when it already exists. Empty string is allowed and produces an empty file."
      }
    },
    "required": ["path", "content"]
  }
}
EOF
}

# tool_write_file_handler <input_json>
# Stdout = success message ("write_file: wrote N bytes to <path> (...)") on success.
# Stderr = diagnostic messages on error.
# Exit codes:
#   0  OK
#   1  symlink / outside cwd / not a regular file / permission denied /
#      backup failed / write failed
#   2  invalid input JSON or missing fields
tool_write_file_handler() {
    local input_json="$1"
    local path content
    local parent real_path real_pwd target_dir
    local backup_root backup_subdir backup_path
    local tmp bytes

    if [ -z "$input_json" ]; then
        echo "write_file: missing input JSON" >&2
        return 2
    fi

    if ! path=$(echo "$input_json" | jq -re '.path' 2>/dev/null); then
        echo "write_file: missing required field 'path'" >&2
        return 2
    fi
    if [ -z "$path" ]; then
        echo "write_file: field 'path' must be a non-empty string" >&2
        return 2
    fi

    # jq -re fails if .content == null. Empty string "" passes (returns "").
    if ! content=$(echo "$input_json" | jq -re '.content' 2>/dev/null); then
        echo "write_file: missing required field 'content'" >&2
        return 2
    fi

    # Symlinks rejected (even if they point to a regular file inside the cwd).
    if [ -L "$path" ]; then
        echo "write_file: refusing to follow symlink: $path" >&2
        return 1
    fi

    if [ -e "$path" ] && [ ! -f "$path" ]; then
        echo "write_file: path exists but is not a regular file: $path" >&2
        return 1
    fi

    # Canonicalize parent dir. The parent MUST exist (intermediate dirs are not created).
    if ! parent=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P); then
        echo "write_file: parent directory does not exist or is unreadable: $(dirname "$path")" >&2
        return 1
    fi
    real_path="$parent/$(basename "$path")"
    real_pwd=$(cd "$PWD" && pwd -P)

    case "$real_path" in
        "$real_pwd"|"$real_pwd"/*) : ;;
        *)
            echo "write_file: path outside cwd is not allowed: $real_path (cwd=$real_pwd)" >&2
            return 1
            ;;
    esac

    if ! declare -f confirm_permission >/dev/null 2>&1; then
        echo "write_file: lib/permissions.sh not loaded (confirm_permission undefined); refusing to write" >&2
        return 1
    fi

    if ! confirm_permission "write_file" "$real_path" "${CODER_YES:-0}"; then
        echo "write_file: permission denied for $real_path" >&2
        return 1
    fi

    target_dir="$parent"
    if [ ! -w "$target_dir" ]; then
        echo "write_file: target directory not writable: $target_dir" >&2
        return 1
    fi

    # Backup if the file already exists.
    backup_path=""
    if [ -f "$real_path" ]; then
        backup_root="${CODER_BACKUP_DIR:-${CONFIG_DIR:-$HOME/.config/coder-cli}/backups}"
        if ! mkdir -p "$backup_root"; then
            echo "write_file: cannot create backup root: $backup_root" >&2
            return 1
        fi
        if ! backup_subdir=$(mktemp -d "$backup_root/$(date +%Y%m%d-%H%M%S)-XXXXXX" 2>/dev/null); then
            echo "write_file: cannot create backup subdir under $backup_root" >&2
            return 1
        fi
        backup_path="$backup_subdir/$(basename "$real_path")"
        if ! cp -p "$real_path" "$backup_path"; then
            echo "write_file: backup copy failed: $real_path -> $backup_path" >&2
            return 1
        fi
    fi

    # Atomic write: temp file in the SAME directory (guarantees mv is an
    # intra-fs rename, not a cross-fs copy).
    if ! tmp=$(mktemp "${real_path}.XXXXXX" 2>/dev/null); then
        echo "write_file: cannot create temp file next to $real_path" >&2
        return 1
    fi

    if ! printf '%s' "$content" > "$tmp"; then
        rm -f "$tmp"
        echo "write_file: failed to write temp file $tmp" >&2
        return 1
    fi

    if ! mv "$tmp" "$real_path"; then
        rm -f "$tmp"
        echo "write_file: atomic mv failed: $tmp -> $real_path" >&2
        return 1
    fi

    bytes=$(printf '%s' "$content" | wc -c | tr -d ' ')
    if [ -n "$backup_path" ]; then
        echo "write_file: wrote $bytes bytes to $real_path (backup: $backup_path)"
    else
        echo "write_file: wrote $bytes bytes to $real_path (new file, no backup)"
    fi
    return 0
}
