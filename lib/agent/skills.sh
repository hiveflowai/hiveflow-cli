#!/bin/bash

# ==========================================
# SKILLS MODULE - skills.sh
# ==========================================
# Registry of prompt skills stored as Markdown files with YAML-ish frontmatter.
# Two directories are searched, in this order:
#   1. $CODER_SKILLS_USER_DIR   (default: $CONFIG_DIR/skills) -- writable by user
#   2. $CODER_SKILLS_BUILTIN_DIR (default: <repo>/skills/builtin) -- shipped
# User skills win on name collision (first match in iteration wins).
# Set either var to "" to disable that source.
#
# Skill file format (extension .md):
#   ---
#   name: my-skill
#   description: one-line description
#   ---
#   <prompt body, may contain {{args}} placeholder>
#
# Frontmatter keys recognized: name (defaults to basename), description (free).
# Unknown keys are parsed and emitted by the internal helper but ignored by the
# public API for now. Files without a closing `---` are treated as having no
# frontmatter and are skipped by the listing.
#
# This file is sourced into the parent shell; do NOT enable `set -euo pipefail`
# globally here (would leak flags into coder.sh and legacy modules).
#
# Public contract:
#   skills_init                       -> mkdir -p user dir; 0 ok, 1 fail
#   skills_list                       -> emits "<name>\t<description>\t<path>"
#                                          per skill, deduped by name (user
#                                          wins), sorted lexically per dir
#   skills_exists <name>              -> 0 if registered, 1 otherwise
#   skills_path <name>                -> echoes absolute path; 1 if missing
#   skills_describe <name>            -> echoes description; 1 if missing
#   skills_body <name>                -> echoes prompt body verbatim; 1 if missing
#   skills_render <name> [args...]    -> echoes body with {{args}} replaced
#                                          (literal), or body + blank + args
#                                          appended if {{args}} absent and
#                                          args non-empty. 1 if missing skill,
#                                          2 if name empty.

# Double-source guard (coder.sh + tests both source us).
if [ -n "${_SKILLS_LOADED:-}" ]; then
    return 0
fi
_SKILLS_LOADED=1

# i18n fallback: hf_t existe aunque i18n.sh no esté cargado (tests sourcean directo).
type hf_t >/dev/null 2>&1 || hf_t() { if [ "${HF_LANG:-en}" = "es" ] && [ -n "${2:-}" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# User skills directory. Override via env for tests.
: "${CODER_SKILLS_USER_DIR:=${CONFIG_DIR:-$HOME/.config/coder-cli}/skills}"

# Built-in skills directory: ships with the repo at <repo>/skills/builtin/.
# Detected from BASH_SOURCE at source-time. Override via env for tests or to
# point to an alternative bundle. Empty string disables built-in lookup.
if [ -z "${CODER_SKILLS_BUILTIN_DIR+x}" ]; then
    _skills_repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)
    if [ -n "${_skills_repo_root:-}" ]; then
        CODER_SKILLS_BUILTIN_DIR="$_skills_repo_root/skills/builtin"
    else
        CODER_SKILLS_BUILTIN_DIR=""
    fi
    unset _skills_repo_root
fi

skills_init() {
    mkdir -p "$CODER_SKILLS_USER_DIR" 2>/dev/null || return 1
    return 0
}

# Internal: emit *.md paths from user dir first then built-in dir, each
# lexically sorted, one path per line. Empty dirs / unset vars skipped silently.
# Order matters: callers rely on user-first to make user skills override
# built-ins on name collision (_skills_resolve_name uses first-match-wins;
# skills_list dedupes by name).
_skills_iter_files() {
    local dir
    for dir in "$CODER_SKILLS_USER_DIR" "$CODER_SKILLS_BUILTIN_DIR"; do
        [ -n "$dir" ] || continue
        [ -d "$dir" ] || continue
        # -maxdepth 1 = top-level only; no recursion in v1.
        find "$dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
            | LC_ALL=C sort
    done
}

# Internal: parse YAML-ish frontmatter (between leading `---` and matching
# closing `---`). Emits "key=value" lines (one per recognized line). Strips
# surrounding ASCII single/double quotes around value. Exit 1 if no
# frontmatter open marker on line 1.
_skills_parse_frontmatter() {
    local file="$1"
    [ -f "$file" ] || return 1
    awk '
        BEGIN { in_fm = 0; started = 0; closed = 0 }
        NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; started = 1; next }
        in_fm && /^---[[:space:]]*$/ { in_fm = 0; closed = 1; exit }
        in_fm {
            line = $0
            # Skip blank or comment lines.
            if (line ~ /^[[:space:]]*$/) next
            if (line ~ /^[[:space:]]*#/) next
            colon = index(line, ":")
            if (colon <= 1) next
            key = substr(line, 1, colon - 1)
            val = substr(line, colon + 1)
            sub(/^[[:space:]]+/, "", key); sub(/[[:space:]]+$/, "", key)
            sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+$/, "", val)
            # Strip wrapping double quotes.
            if (length(val) >= 2 && substr(val, 1, 1) == "\"" && substr(val, length(val), 1) == "\"") {
                val = substr(val, 2, length(val) - 2)
            } else if (length(val) >= 2 && substr(val, 1, 1) == "'\''" && substr(val, length(val), 1) == "'\''") {
                val = substr(val, 2, length(val) - 2)
            }
            print key "=" val
        }
        END {
            if (!started) exit 1
            if (!closed) exit 1
        }
    ' "$file"
}

# Internal: emit body lines (everything after the closing `---`).
# Empty output if file has no closing marker.
_skills_extract_body() {
    local file="$1"
    [ -f "$file" ] || return 1
    awk '
        BEGIN { state = 0 }
        # state 0: before opening ---
        # state 1: inside frontmatter
        # state 2: emitting body
        state == 0 && NR == 1 && /^---[[:space:]]*$/ { state = 1; next }
        state == 0 { next }
        state == 1 && /^---[[:space:]]*$/ { state = 2; next }
        state == 1 { next }
        state == 2 { print }
    ' "$file"
}

# Internal: resolve <name> -> file path by scanning frontmatter `name=` (or
# falling back to basename without .md). First match wins (files are sorted).
_skills_resolve_name() {
    local target="$1"
    [ -n "$target" ] || return 2
    local file fm name
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        fm=$(_skills_parse_frontmatter "$file" 2>/dev/null) || continue
        name=$(printf '%s\n' "$fm" | sed -n 's/^name=//p' | head -1)
        if [ -z "$name" ]; then
            name=$(basename "$file" .md)
        fi
        if [ "$name" = "$target" ]; then
            printf '%s\n' "$file"
            return 0
        fi
    done < <(_skills_iter_files)
    return 1
}

skills_path() {
    _skills_resolve_name "$1"
}

skills_exists() {
    _skills_resolve_name "$1" >/dev/null 2>&1
}

skills_describe() {
    local path
    path=$(_skills_resolve_name "$1") || return 1
    _skills_parse_frontmatter "$path" 2>/dev/null | sed -n 's/^description=//p' | head -1
}

skills_body() {
    local path
    path=$(_skills_resolve_name "$1") || return 1
    _skills_extract_body "$path"
}

skills_list() {
    local file fm name desc seen=""
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        fm=$(_skills_parse_frontmatter "$file" 2>/dev/null) || continue
        name=$(printf '%s\n' "$fm" | sed -n 's/^name=//p' | head -1)
        desc=$(printf '%s\n' "$fm" | sed -n 's/^description=//p' | head -1)
        [ -z "$name" ] && name=$(basename "$file" .md)
        # Dedup by name: user dir is iterated first, so its entry wins.
        # Names are slug-like (no spaces) by convention; this guard relies on it.
        case " $seen " in *" $name "*) continue ;; esac
        seen="$seen $name"
        printf '%s\t%s\t%s\n' "$name" "$desc" "$file"
    done < <(_skills_iter_files)
}

# Render skill: literal {{args}} replacement, or append args after blank line
# if the body does not declare the placeholder.
skills_render() {
    local name="$1"
    [ -n "$name" ] || return 2
    shift
    local args="$*"
    local body
    body=$(skills_body "$name") || return 1
    local pat='{{args}}'
    if [[ "$body" == *"$pat"* ]]; then
        # Bash parameter expansion: literal global replace; $args is literal value.
        printf '%s\n' "${body//$pat/$args}"
    else
        printf '%s\n' "$body"
        if [ -n "$args" ]; then
            printf '\n%s\n' "$args"
        fi
    fi
}

# ==========================================
# CLI dispatcher (`coder skills ...`)
# ==========================================

_skills_cli_usage() {
    printf '%s\n' "$(hf_t "Usage: coder skills <subcommand> [args]" "Uso: coder skills <subcommand> [args]")"
    cat <<'EOF'

Subcommands:
  list                                List installed skills (user + built-in).
  show <name>                         Print the skill metadata + body to stdout.
  install <path> [--force]            Install a .md skill file into the user dir.
  remove <name>                       Remove a user-installed skill.

Examples:
  coder skills list
  coder skills show analyze
  coder skills install ./my-skill.md
  coder skills install ./my-skill.md --force
  coder skills remove my-skill
EOF
}

# Classify a resolved skill path as "user" / "builtin" / "?".
_skills_origin_for_path() {
    local path="$1"
    local user_dir="${CODER_SKILLS_USER_DIR:-}"
    local builtin_dir="${CODER_SKILLS_BUILTIN_DIR:-}"
    if [ -n "$user_dir" ] && [ "${path#"$user_dir"/}" != "$path" ]; then
        echo "user"
    elif [ -n "$builtin_dir" ] && [ "${path#"$builtin_dir"/}" != "$path" ]; then
        echo "builtin"
    else
        echo "?"
    fi
}

# skills_cli <subcommand> [<args>...]
# Exit codes: 0 ok, 1 internal error (file missing, builtin-protected, copy fail),
# 2 usage error (missing/extra args, unknown subcommand).
skills_cli() {
    local sub="${1:-}"
    case "$sub" in
        list)
            shift
            if [ "$#" -ne 0 ]; then
                echo "skills list: unexpected arguments" >&2
                _skills_cli_usage >&2
                return 2
            fi
            local rows
            rows=$(skills_list)
            if [ -z "$rows" ]; then
                echo "(no skills installed)"
                return 0
            fi
            printf '%-24s %-8s %s\n' "NAME" "ORIGIN" "DESCRIPTION"
            local name desc path origin
            while IFS=$'\t' read -r name desc path; do
                [ -n "$name" ] || continue
                origin=$(_skills_origin_for_path "$path")
                printf '%-24s %-8s %s\n' "$name" "$origin" "$desc"
            done <<<"$rows"
            ;;
        show)
            shift
            if [ "$#" -ne 1 ]; then
                echo "skills show: expected <name>" >&2
                _skills_cli_usage >&2
                return 2
            fi
            local target="$1"
            if ! skills_exists "$target"; then
                echo "skills: '$target' not found" >&2
                return 1
            fi
            local path desc origin
            path=$(skills_path "$target")
            desc=$(skills_describe "$target")
            origin=$(_skills_origin_for_path "$path")
            printf 'name: %s\n' "$target"
            printf 'origin: %s\n' "$origin"
            printf 'description: %s\n' "$desc"
            printf 'path: %s\n' "$path"
            printf -- '---\n'
            skills_body "$target"
            ;;
        install)
            shift
            local force=0 src=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --force|-f)
                        force=1
                        ;;
                    -*)
                        echo "skills install: unknown flag '$1'" >&2
                        _skills_cli_usage >&2
                        return 2
                        ;;
                    *)
                        if [ -n "$src" ]; then
                            echo "skills install: only one source file allowed" >&2
                            _skills_cli_usage >&2
                            return 2
                        fi
                        src="$1"
                        ;;
                esac
                shift
            done
            if [ -z "$src" ]; then
                echo "skills install: expected <path>" >&2
                _skills_cli_usage >&2
                return 2
            fi
            if [ ! -f "$src" ]; then
                echo "skills install: file not found: $src" >&2
                return 1
            fi
            local fm
            if ! fm=$(_skills_parse_frontmatter "$src" 2>/dev/null); then
                echo "skills install: '$src' has no valid frontmatter (need leading and closing ---)" >&2
                return 1
            fi
            local name
            name=$(printf '%s\n' "$fm" | sed -n 's/^name=//p' | head -1)
            [ -z "$name" ] && name=$(basename "$src" .md)
            case "$name" in
                "")
                    echo "skills install: resolved name is empty" >&2
                    return 1
                    ;;
                */*|*[[:space:]]*)
                    echo "skills install: invalid name '$name' (no slashes or whitespace)" >&2
                    return 1
                    ;;
            esac
            if ! skills_init >/dev/null; then
                echo "skills install: cannot create user dir: $CODER_SKILLS_USER_DIR" >&2
                return 1
            fi
            local dest="$CODER_SKILLS_USER_DIR/$name.md"
            if [ -e "$dest" ] && [ "$force" -ne 1 ]; then
                echo "skills install: '$dest' already exists (use --force to overwrite)" >&2
                return 1
            fi
            if ! cp "$src" "$dest" 2>/dev/null; then
                echo "skills install: copy failed: $src -> $dest" >&2
                return 1
            fi
            echo "installed: $name -> $dest"
            ;;
        remove)
            shift
            if [ "$#" -ne 1 ]; then
                echo "skills remove: expected <name>" >&2
                _skills_cli_usage >&2
                return 2
            fi
            local target="$1"
            local path
            if ! path=$(skills_path "$target"); then
                echo "skills: '$target' not found" >&2
                return 1
            fi
            local origin
            origin=$(_skills_origin_for_path "$path")
            if [ "$origin" != "user" ]; then
                echo "skills remove: '$target' is a built-in skill and cannot be removed" >&2
                echo "  hint: install a user skill with the same name to override it" >&2
                return 1
            fi
            if ! rm -f "$path" 2>/dev/null; then
                echo "skills remove: failed to delete $path" >&2
                return 1
            fi
            echo "removed: $target ($path)"
            ;;
        -h|--help|help)
            _skills_cli_usage
            return 0
            ;;
        "")
            _skills_cli_usage >&2
            return 2
            ;;
        *)
            echo "skills: unknown subcommand '$sub'" >&2
            _skills_cli_usage >&2
            return 2
            ;;
    esac
}
