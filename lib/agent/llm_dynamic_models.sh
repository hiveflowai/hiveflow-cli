#!/bin/bash
# lib/llm_dynamic_models.sh
#
# Dynamic model-list fetching from provider APIs (Anthropic / OpenAI / Gemini).
# Each `_dynamic_fetch_<provider>_models` outputs model IDs (one per line) on
# stdout and returns:
#   0 — OK, at least one ID emitted.
#   1 — HTTP error, parse error, or empty list.
#   2 — Missing or empty api_key argument.
#
# URL endpoints and the curl binary are overridable via env vars for test
# injection (see ANTHROPIC_MODELS_URL, CODER_DYNAMIC_MODELS_CURL_BIN below).
#
# This module is sourced into coder.sh by the wire-up sub-task. It does not
# enable strict mode at file scope (per CLAUDE.md "Conflicto con CLAUDE.md")
# because that would leak `set -euo pipefail` into legacy callers. Each fn
# uses explicit returns and `jq -e` validation instead.

# Guard against double-source. This file is only ever sourced (not executed
# directly), so a bare `return` is correct.
if [ -n "${_LLM_DYNAMIC_MODELS_LOADED:-}" ]; then
    return 0
fi
_LLM_DYNAMIC_MODELS_LOADED=1

# ---------------------------------------------------------------------------
# Env-overridable defaults are resolved INSIDE each function (via ${VAR:-DEFAULT})
# rather than at file scope, so callers can `unset` to revert to the default or
# re-export between invocations without sourcing the module again. Recognized:
#   ANTHROPIC_MODELS_URL                  (default https://api.anthropic.com/v1/models)
#   ANTHROPIC_MODELS_VERSION_HEADER       (default 2023-06-01)
#   OPENAI_MODELS_URL                     (default https://api.openai.com/v1/models)
#   CODER_DYNAMIC_MODELS_OPENAI_FILTER    (default '^(gpt-|chatgpt-|o[0-9])')
#   GEMINI_MODELS_URL                     (default https://generativelanguage.googleapis.com/v1beta/models)
#   CODER_DYNAMIC_MODELS_CURL_BIN         (default curl)
#   CODER_DYNAMIC_MODELS_TIMEOUT          (default 10 seconds)
#   CODER_DYNAMIC_MODELS_MAX_PAGES        (default 5 pages × 100 IDs each)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _dynamic_fetch_anthropic_models <api_key>
#
# Output: model IDs, one per line on stdout.
# Pagination: follows .has_more + .last_id up to CODER_DYNAMIC_MODELS_MAX_PAGES
# pages of 100 IDs each, hard-capped to avoid infinite loops if the API ever
# echoes the same cursor.
# ---------------------------------------------------------------------------
_dynamic_fetch_anthropic_models() {
    local api_key="${1:-}"
    if [ -z "$api_key" ]; then
        echo "_dynamic_fetch_anthropic_models: empty api_key" >&2
        return 2
    fi

    local tmpf
    tmpf=$(mktemp -t coder_models_anthropic.XXXXXX 2>/dev/null || mktemp)
    if [ -z "$tmpf" ] || [ ! -f "$tmpf" ]; then
        echo "_dynamic_fetch_anthropic_models: mktemp failed" >&2
        return 1
    fi

    local all_ids=""
    local page=0
    local cursor=""
    local seen_cursors=""
    local max_pages="${CODER_DYNAMIC_MODELS_MAX_PAGES:-5}"
    local base_url="${ANTHROPIC_MODELS_URL:-https://api.anthropic.com/v1/models}"
    local version_header="${ANTHROPIC_MODELS_VERSION_HEADER:-2023-06-01}"
    local curl_bin="${CODER_DYNAMIC_MODELS_CURL_BIN:-curl}"
    local timeout="${CODER_DYNAMIC_MODELS_TIMEOUT:-10}"

    while [ "$page" -lt "$max_pages" ]; do
        local url="${base_url}?limit=100"
        if [ -n "$cursor" ]; then
            url="${url}&after_id=${cursor}"
        fi

        local http_code
        http_code=$("$curl_bin" -sS \
            -m "$timeout" \
            -w '%{http_code}' -o "$tmpf" \
            -H "x-api-key: $api_key" \
            -H "anthropic-version: $version_header" \
            "$url" 2>/dev/null)
        local curl_rc=$?
        if [ "$curl_rc" -ne 0 ] || [ -z "$http_code" ]; then
            echo "_dynamic_fetch_anthropic_models: curl failed (rc=$curl_rc)" >&2
            rm -f "$tmpf"
            return 1
        fi

        if [ "$http_code" != "200" ]; then
            echo "_dynamic_fetch_anthropic_models: HTTP $http_code" >&2
            if [ -s "$tmpf" ]; then
                head -c 512 "$tmpf" >&2
                echo >&2
            fi
            rm -f "$tmpf"
            return 1
        fi

        local body
        body=$(cat "$tmpf")
        if ! printf '%s' "$body" | jq -e 'has("data")' >/dev/null 2>&1; then
            echo "_dynamic_fetch_anthropic_models: response missing 'data' field" >&2
            rm -f "$tmpf"
            return 1
        fi

        local ids
        ids=$(printf '%s' "$body" | jq -r '.data[]?.id // empty' 2>/dev/null)
        if [ -n "$ids" ]; then
            all_ids="${all_ids}${ids}"$'\n'
        fi

        local has_more
        has_more=$(printf '%s' "$body" | jq -r '.has_more // false' 2>/dev/null)
        if [ "$has_more" != "true" ]; then
            break
        fi

        local next_cursor
        next_cursor=$(printf '%s' "$body" | jq -r '.last_id // empty' 2>/dev/null)
        if [ -z "$next_cursor" ]; then
            break
        fi
        case "$seen_cursors" in
            *"|${next_cursor}|"*)
                echo "_dynamic_fetch_anthropic_models: cursor loop detected ('$next_cursor')" >&2
                rm -f "$tmpf"
                return 1
                ;;
        esac
        seen_cursors="${seen_cursors}|${next_cursor}|"
        cursor="$next_cursor"
        page=$((page + 1))
    done

    rm -f "$tmpf"

    if [ -z "$all_ids" ]; then
        echo "_dynamic_fetch_anthropic_models: empty model list" >&2
        return 1
    fi

    # Trim trailing newline + dedupe defensively (server should not repeat IDs
    # across pages, but be safe).
    printf '%s' "$all_ids" | awk 'NF && !seen[$0]++'
    return 0
}

# ---------------------------------------------------------------------------
# _dynamic_fetch_openai_models <api_key>
#
# GET https://api.openai.com/v1/models with `Authorization: Bearer`. The
# endpoint returns the full catalog in a single response (no pagination),
# including non-chat models (embeddings, moderation, tts, whisper, dall-e).
# We filter to chat-capable IDs via CODER_DYNAMIC_MODELS_OPENAI_FILTER (a
# basic ERE matched with `grep -E`; default `^(gpt-|chatgpt-|o[0-9])` keeps
# gpt-*, chatgpt-4o-latest, and the o<digit> reasoning series while excluding
# `omni-moderation-*`, `text-embedding-*`, `tts-*`, `whisper-*`, `dall-e-*`).
#
# Output: filtered model IDs, one per line on stdout, in API-response order.
# ---------------------------------------------------------------------------
_dynamic_fetch_openai_models() {
    local api_key="${1:-}"
    if [ -z "$api_key" ]; then
        echo "_dynamic_fetch_openai_models: empty api_key" >&2
        return 2
    fi

    local tmpf
    tmpf=$(mktemp -t coder_models_openai.XXXXXX 2>/dev/null || mktemp)
    if [ -z "$tmpf" ] || [ ! -f "$tmpf" ]; then
        echo "_dynamic_fetch_openai_models: mktemp failed" >&2
        return 1
    fi

    local base_url="${OPENAI_MODELS_URL:-https://api.openai.com/v1/models}"
    local curl_bin="${CODER_DYNAMIC_MODELS_CURL_BIN:-curl}"
    local timeout="${CODER_DYNAMIC_MODELS_TIMEOUT:-10}"
    local filter_regex="${CODER_DYNAMIC_MODELS_OPENAI_FILTER:-^(gpt-|chatgpt-|o[0-9])}"

    local http_code
    http_code=$("$curl_bin" -sS \
        -m "$timeout" \
        -w '%{http_code}' -o "$tmpf" \
        -H "Authorization: Bearer $api_key" \
        "$base_url" 2>/dev/null)
    local curl_rc=$?
    if [ "$curl_rc" -ne 0 ] || [ -z "$http_code" ]; then
        echo "_dynamic_fetch_openai_models: curl failed (rc=$curl_rc)" >&2
        rm -f "$tmpf"
        return 1
    fi

    if [ "$http_code" != "200" ]; then
        echo "_dynamic_fetch_openai_models: HTTP $http_code" >&2
        if [ -s "$tmpf" ]; then
            head -c 512 "$tmpf" >&2
            echo >&2
        fi
        rm -f "$tmpf"
        return 1
    fi

    local body
    body=$(cat "$tmpf")
    rm -f "$tmpf"
    if ! printf '%s' "$body" | jq -e 'has("data")' >/dev/null 2>&1; then
        echo "_dynamic_fetch_openai_models: response missing 'data' field" >&2
        return 1
    fi

    local ids
    ids=$(printf '%s' "$body" | jq -r '.data[]?.id // empty' 2>/dev/null)
    if [ -z "$ids" ]; then
        echo "_dynamic_fetch_openai_models: empty model list" >&2
        return 1
    fi

    local filtered
    filtered=$(printf '%s\n' "$ids" | grep -E "$filter_regex" || true)
    if [ -z "$filtered" ]; then
        echo "_dynamic_fetch_openai_models: no chat-capable models after filter '$filter_regex'" >&2
        return 1
    fi

    # Dedupe defensively while preserving order (API should not repeat IDs).
    printf '%s\n' "$filtered" | awk 'NF && !seen[$0]++'
    return 0
}

# ---------------------------------------------------------------------------
# _dynamic_fetch_gemini_models <api_key>
#
# GET https://generativelanguage.googleapis.com/v1beta/models with the API key
# in the `x-goog-api-key` header. The endpoint paginates via `nextPageToken`
# (no `has_more` flag — end is signaled by an empty/missing token); we follow
# up to CODER_DYNAMIC_MODELS_MAX_PAGES pages with the same cursor-loop guard
# as the Anthropic adapter.
#
# Filter: only models whose `supportedGenerationMethods` includes
# `generateContent` are emitted. The `models/` prefix on `.name` is stripped
# so callers get bare IDs (`gemini-1.5-pro` not `models/gemini-1.5-pro`),
# matching what `list_gemini_models()` in llm_models.sh uses today.
#
# Output: filtered model IDs, one per line on stdout, in API-response order.
# ---------------------------------------------------------------------------
_dynamic_fetch_gemini_models() {
    local api_key="${1:-}"
    if [ -z "$api_key" ]; then
        echo "_dynamic_fetch_gemini_models: empty api_key" >&2
        return 2
    fi

    local tmpf
    tmpf=$(mktemp -t coder_models_gemini.XXXXXX 2>/dev/null || mktemp)
    if [ -z "$tmpf" ] || [ ! -f "$tmpf" ]; then
        echo "_dynamic_fetch_gemini_models: mktemp failed" >&2
        return 1
    fi

    local all_ids=""
    local page=0
    local cursor=""
    local seen_cursors=""
    local max_pages="${CODER_DYNAMIC_MODELS_MAX_PAGES:-5}"
    local base_url="${GEMINI_MODELS_URL:-https://generativelanguage.googleapis.com/v1beta/models}"
    local curl_bin="${CODER_DYNAMIC_MODELS_CURL_BIN:-curl}"
    local timeout="${CODER_DYNAMIC_MODELS_TIMEOUT:-10}"

    while [ "$page" -lt "$max_pages" ]; do
        local url="${base_url}?pageSize=100"
        if [ -n "$cursor" ]; then
            url="${url}&pageToken=${cursor}"
        fi

        local http_code
        http_code=$("$curl_bin" -sS \
            -m "$timeout" \
            -w '%{http_code}' -o "$tmpf" \
            -H "x-goog-api-key: $api_key" \
            "$url" 2>/dev/null)
        local curl_rc=$?
        if [ "$curl_rc" -ne 0 ] || [ -z "$http_code" ]; then
            echo "_dynamic_fetch_gemini_models: curl failed (rc=$curl_rc)" >&2
            rm -f "$tmpf"
            return 1
        fi

        if [ "$http_code" != "200" ]; then
            echo "_dynamic_fetch_gemini_models: HTTP $http_code" >&2
            if [ -s "$tmpf" ]; then
                head -c 512 "$tmpf" >&2
                echo >&2
            fi
            rm -f "$tmpf"
            return 1
        fi

        local body
        body=$(cat "$tmpf")
        if ! printf '%s' "$body" | jq -e 'has("models")' >/dev/null 2>&1; then
            echo "_dynamic_fetch_gemini_models: response missing 'models' field" >&2
            rm -f "$tmpf"
            return 1
        fi

        local ids
        ids=$(printf '%s' "$body" | jq -r '
            .models[]?
            | select((.supportedGenerationMethods // []) | index("generateContent"))
            | .name // empty
            | sub("^models/"; "")
        ' 2>/dev/null)
        if [ -n "$ids" ]; then
            all_ids="${all_ids}${ids}"$'\n'
        fi

        local next_cursor
        next_cursor=$(printf '%s' "$body" | jq -r '.nextPageToken // empty' 2>/dev/null)
        if [ -z "$next_cursor" ]; then
            break
        fi
        case "$seen_cursors" in
            *"|${next_cursor}|"*)
                echo "_dynamic_fetch_gemini_models: cursor loop detected ('$next_cursor')" >&2
                rm -f "$tmpf"
                return 1
                ;;
        esac
        seen_cursors="${seen_cursors}|${next_cursor}|"
        cursor="$next_cursor"
        page=$((page + 1))
    done

    rm -f "$tmpf"

    if [ -z "$all_ids" ]; then
        echo "_dynamic_fetch_gemini_models: empty model list (no models with generateContent)" >&2
        return 1
    fi

    printf '%s' "$all_ids" | awk 'NF && !seen[$0]++'
    return 0
}
