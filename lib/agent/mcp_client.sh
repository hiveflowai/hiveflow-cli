#!/bin/bash

# ==========================================
# MCP CLIENT MODULE - mcp_client.sh
# ==========================================
# JSON-RPC 2.0 client over stdio for Model Context Protocol servers
# (P1.mcp-1 = transport, P1.mcp-2 = tool discovery + invocation).
#
# The transport layer (P1.mcp-1) spawns a child MCP server, performs the
# `initialize` handshake and ships request/notification messages over its
# stdio. The tools API on top (P1.mcp-2) adds:
#   mcp_list_tools <conn>                       -> emits JSON array of tool
#                                                  definitions (paginated server
#                                                  responses are accumulated)
#   mcp_call_tool  <conn> <name> [input_json]   -> emits result.content array;
#                                                  rc 1 if isError:true or
#                                                  server returned a JSON-RPC
#                                                  error envelope
# Registry wire-up into `_register_agentic_tools` is P1.mcp-3.
#
# Wire protocol:
#   Newline-delimited JSON-RPC 2.0. Each direction writes one JSON object per
#   line, terminated by '\n'. No Content-Length headers (LSP-style framing is
#   only for HTTP/SSE transport, NOT stdio).
#
# Connection state:
#   Parallel arrays indexed by connection name (bash 3.2 compat — no associative
#   arrays). Each connection owns a tmpdir with two fifos and two file
#   descriptors opened in the parent shell (writer to child stdin, reader from
#   child stdout). FDs are allocated dynamically from CODER_MCP_FD_BASE upward.
#
# This file is sourced into the parent shell; do NOT enable `set -euo pipefail`
# globally here (would leak flags into coder.sh and legacy modules).
#
# Public contract:
#   mcp_connect <name> <cmd> [args...]              -> 0 ok, 1 spawn/handshake fail,
#                                                       2 invalid args / already conn
#   mcp_send_request <name> <method> [params_json]  -> echoes raw response line;
#                                                       0 ok (incl. JSON-RPC error
#                                                       envelope), 1 io/timeout fail,
#                                                       2 unknown connection / args
#   mcp_send_notification <name> <method> [params]  -> 0 ok, 1 io fail,
#                                                       2 unknown connection / args
#   mcp_close <name>                                -> 0 ok, 2 unknown connection
#   mcp_list_connections                            -> emits "<name>\t<pid>" lines
#   mcp_is_connected <name>                         -> 0 if registered, 1 otherwise
#   mcp_list_tools <name>                           -> emits JSON array on stdout
#                                                       (accumulated across pages);
#                                                       0 ok, 1 transport/server error,
#                                                       2 invalid args
#   mcp_call_tool <name> <tool> [input_json]        -> emits result.content (JSON array)
#                                                       on stdout. 0 ok, 1 tool isError
#                                                       or server error envelope, 2 invalid
#                                                       args. Default input_json is `{}`.
#
# Tunables (env, read at call time):
#   CODER_MCP_TIMEOUT             seconds to wait for a response (default 30)
#   CODER_MCP_FD_BASE             starting fd for dynamic allocation (default 100)
#   CODER_MCP_PROTOCOL_VERSION    MCP protocol version sent in `initialize`
#                                  (default 2024-11-05)
#   CODER_MCP_CLIENT_NAME         clientInfo.name (default "asis-coder")
#   CODER_MCP_CLIENT_VERSION      clientInfo.version (default "0.0.1")
#   CODER_MCP_SERVER_STDERR_LOG   if set, child stderr is redirected here;
#                                  otherwise it goes to /dev/null

# Double-source guard (coder.sh + tests both source us).
if [ -n "${_MCP_CLIENT_LOADED:-}" ]; then
    return 0
fi
_MCP_CLIENT_LOADED=1

# i18n fallback: hf_t existe aunque i18n.sh no esté cargado (tests sourcean directo).
type hf_t >/dev/null 2>&1 || hf_t() { if [ "${HF_LANG:-en}" = "es" ] && [ -n "${2:-}" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# Tunables: only set if caller did not.
: "${CODER_MCP_TIMEOUT:=30}"
: "${CODER_MCP_FD_BASE:=100}"
: "${CODER_MCP_PROTOCOL_VERSION:=2024-11-05}"
: "${CODER_MCP_CLIENT_NAME:=asis-coder}"
: "${CODER_MCP_CLIENT_VERSION:=0.0.1}"
: "${CODER_MCP_CONFIG:=${CONFIG_DIR:-$HOME/.config/coder-cli}/mcp.json}"

# Parallel-array registry (bash 3.2 compatible).
_MCP_CONN_NAMES=()
_MCP_CONN_PIDS=()
_MCP_CONN_FD_IN=()
_MCP_CONN_FD_OUT=()
_MCP_CONN_FIFO_IN=()
_MCP_CONN_FIFO_OUT=()
_MCP_CONN_TMPDIR=()
# Path to a tmpfile holding the next request id (decimal ASCII, single line).
# Persisted on disk because mcp_send_request is typically called inside
# `$(...)` command substitution — a subshell that cannot mutate parent arrays
# but CAN read/write a file we set up in the parent.
_MCP_CONN_NEXT_ID_FILE=()

# ---------- Internal: registry helpers ----------

# _mcp_conn_index <name> -> echoes 0-based index, rc 0 if found, 1 otherwise.
_mcp_conn_index() {
    local name="$1" i
    for i in "${!_MCP_CONN_NAMES[@]}"; do
        if [ "${_MCP_CONN_NAMES[$i]}" = "$name" ]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

# _mcp_alloc_fds -> echoes "<fd_in> <fd_out>"; uses the next free pair above
# CODER_MCP_FD_BASE, skipping over fds already used by current connections.
_mcp_alloc_fds() {
    local base="${CODER_MCP_FD_BASE:-100}"
    local fd_in fd_out i used
    fd_in=$base
    while :; do
        fd_out=$((fd_in + 1))
        used=0
        for i in "${!_MCP_CONN_FD_IN[@]}"; do
            if [ "${_MCP_CONN_FD_IN[$i]}" = "$fd_in" ] \
               || [ "${_MCP_CONN_FD_OUT[$i]}" = "$fd_in" ] \
               || [ "${_MCP_CONN_FD_IN[$i]}" = "$fd_out" ] \
               || [ "${_MCP_CONN_FD_OUT[$i]}" = "$fd_out" ]; then
                used=1
                break
            fi
        done
        if [ "$used" -eq 0 ]; then
            echo "$fd_in $fd_out"
            return 0
        fi
        fd_in=$((fd_in + 2))
    done
}

# _mcp_registry_remove <idx>: removes the entry at idx, preserving order.
_mcp_registry_remove() {
    local idx="$1" i
    local n_names=() n_pids=() n_fdi=() n_fdo=() n_fifoi=() n_fifoo=() n_tmpdir=() n_idfile=()
    for i in "${!_MCP_CONN_NAMES[@]}"; do
        if [ "$i" != "$idx" ]; then
            n_names+=("${_MCP_CONN_NAMES[$i]}")
            n_pids+=("${_MCP_CONN_PIDS[$i]}")
            n_fdi+=("${_MCP_CONN_FD_IN[$i]}")
            n_fdo+=("${_MCP_CONN_FD_OUT[$i]}")
            n_fifoi+=("${_MCP_CONN_FIFO_IN[$i]}")
            n_fifoo+=("${_MCP_CONN_FIFO_OUT[$i]}")
            n_tmpdir+=("${_MCP_CONN_TMPDIR[$i]}")
            n_idfile+=("${_MCP_CONN_NEXT_ID_FILE[$i]}")
        fi
    done
    _MCP_CONN_NAMES=("${n_names[@]:-}")
    _MCP_CONN_PIDS=("${n_pids[@]:-}")
    _MCP_CONN_FD_IN=("${n_fdi[@]:-}")
    _MCP_CONN_FD_OUT=("${n_fdo[@]:-}")
    _MCP_CONN_FIFO_IN=("${n_fifoi[@]:-}")
    _MCP_CONN_FIFO_OUT=("${n_fifoo[@]:-}")
    _MCP_CONN_TMPDIR=("${n_tmpdir[@]:-}")
    _MCP_CONN_NEXT_ID_FILE=("${n_idfile[@]:-}")
    # Trim the sentinel empty element introduced by the ":-" expansion when the
    # source array was empty (bash 3.2 doesn't have `${arr[@]+...}`).
    if [ "${#_MCP_CONN_NAMES[@]}" -eq 1 ] && [ -z "${_MCP_CONN_NAMES[0]}" ]; then
        _MCP_CONN_NAMES=()
        _MCP_CONN_PIDS=()
        _MCP_CONN_FD_IN=()
        _MCP_CONN_FD_OUT=()
        _MCP_CONN_FIFO_IN=()
        _MCP_CONN_FIFO_OUT=()
        _MCP_CONN_TMPDIR=()
        _MCP_CONN_NEXT_ID_FILE=()
    fi
}

# _mcp_next_id <id_file> -> echoes the current id and atomically increments
# the value on disk. Works across subshells since the state lives in the file.
_mcp_next_id() {
    local id_file="$1" cur next
    cur=$(cat "$id_file" 2>/dev/null)
    [ -z "$cur" ] && cur=1
    next=$((cur + 1))
    printf '%s\n' "$next" > "$id_file" 2>/dev/null
    printf '%s\n' "$cur"
}

# ---------- Pure helpers: JSON-RPC 2.0 framing ----------

# _mcp_build_request <id> <method> [params_json]
# Emits a single-line JSON-RPC 2.0 request envelope.
_mcp_build_request() {
    local id="$1" method="$2" params="${3:-}"
    if [ -z "$method" ]; then
        echo "_mcp_build_request: method required" >&2
        return 2
    fi
    if [ -z "$params" ]; then
        jq -nc --argjson id "$id" --arg method "$method" \
            '{jsonrpc:"2.0", id:$id, method:$method}'
    else
        jq -nc --argjson id "$id" --arg method "$method" --argjson params "$params" \
            '{jsonrpc:"2.0", id:$id, method:$method, params:$params}'
    fi
}

# _mcp_build_notification <method> [params_json]
# Emits a single-line JSON-RPC 2.0 notification (no id).
_mcp_build_notification() {
    local method="$1" params="${2:-}"
    if [ -z "$method" ]; then
        echo "_mcp_build_notification: method required" >&2
        return 2
    fi
    if [ -z "$params" ]; then
        jq -nc --arg method "$method" \
            '{jsonrpc:"2.0", method:$method}'
    else
        jq -nc --arg method "$method" --argjson params "$params" \
            '{jsonrpc:"2.0", method:$method, params:$params}'
    fi
}

# _mcp_parse_message <line>
# Classifies a JSON-RPC line. Emits "<type><US><id><US><line>" where <US> is the
# ASCII Unit Separator (0x1f, chosen because it cannot appear inside JSON text
# and unlike \t it is NOT IFS whitespace, so consecutive separators preserve
# empty fields under `IFS=$'\x1f' read`). Type is one of:
#   response       has id + (result or error)
#   request        has id + method (server->client request, rare)
#   notification   has method, no id
#   invalid        not valid JSON-RPC 2.0
# Always rc 0 (callers decide how to react to invalid).
_mcp_parse_message() {
    local line="$1" us=$'\x1f'
    if ! printf '%s' "$line" | jq -e '.jsonrpc == "2.0"' >/dev/null 2>&1; then
        printf 'invalid%s%s%s\n' "$us" "$us" "$line"
        return 0
    fi
    local has_id has_method has_result has_error
    has_id=$(printf '%s' "$line" | jq -r 'has("id")')
    has_method=$(printf '%s' "$line" | jq -r 'has("method")')
    has_result=$(printf '%s' "$line" | jq -r 'has("result")')
    has_error=$(printf '%s' "$line" | jq -r 'has("error")')
    if [ "$has_id" = "true" ] && { [ "$has_result" = "true" ] || [ "$has_error" = "true" ]; }; then
        local id_val
        id_val=$(printf '%s' "$line" | jq -r '.id')
        printf 'response%s%s%s%s\n' "$us" "$id_val" "$us" "$line"
    elif [ "$has_method" = "true" ] && [ "$has_id" = "true" ]; then
        local id_val
        id_val=$(printf '%s' "$line" | jq -r '.id')
        printf 'request%s%s%s%s\n' "$us" "$id_val" "$us" "$line"
    elif [ "$has_method" = "true" ]; then
        printf 'notification%s%s%s\n' "$us" "$us" "$line"
    else
        printf 'invalid%s%s%s\n' "$us" "$us" "$line"
    fi
    return 0
}

# ---------- Internal: low-level IO ----------

# _mcp_write_line <fd> <line>: writes <line>\n to <fd>. rc 0 ok, 1 io fail.
_mcp_write_line() {
    local fd="$1" line="$2"
    if ! eval "printf '%s\n' \"\$line\" >&$fd" 2>/dev/null; then
        return 1
    fi
    return 0
}

# _mcp_read_line <fd> <timeout> -> echoes line on stdout. rc 0 ok, 1 timeout/EOF.
_mcp_read_line() {
    local fd="$1" timeout="$2" line
    if ! IFS= read -r -t "$timeout" -u "$fd" line; then
        return 1
    fi
    printf '%s\n' "$line"
    return 0
}

# ---------- Public API ----------

# mcp_is_connected <name> -> 0 if registered, 1 otherwise.
mcp_is_connected() {
    local name="${1:-}"
    [ -n "$name" ] || return 1
    _mcp_conn_index "$name" >/dev/null
}

# mcp_list_connections -> emits "<name>\t<pid>" per active connection.
mcp_list_connections() {
    local i
    for i in "${!_MCP_CONN_NAMES[@]}"; do
        printf '%s\t%s\n' "${_MCP_CONN_NAMES[$i]}" "${_MCP_CONN_PIDS[$i]}"
    done
}

# mcp_connect <name> <cmd> [args...]
# Spawns the child MCP server, allocates fifos + fds, and performs the
# `initialize` -> `notifications/initialized` handshake.
# rc 0 connected; 1 spawn/handshake fail; 2 invalid args / name collision.
mcp_connect() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "mcp_connect: usage: mcp_connect <name> <cmd> [args...]" >&2
        return 2
    fi
    shift
    if [ $# -eq 0 ]; then
        echo "mcp_connect: usage: mcp_connect <name> <cmd> [args...]" >&2
        return 2
    fi
    if _mcp_conn_index "$name" >/dev/null; then
        echo "mcp_connect: connection '$name' already exists" >&2
        return 2
    fi

    local tmpdir fifo_in fifo_out
    if ! tmpdir=$(mktemp -d 2>/dev/null); then
        echo "mcp_connect: failed to create tmpdir" >&2
        return 1
    fi
    fifo_in="$tmpdir/stdin"
    fifo_out="$tmpdir/stdout"
    if ! mkfifo "$fifo_in" "$fifo_out" 2>/dev/null; then
        rm -rf "$tmpdir" 2>/dev/null
        echo "mcp_connect: failed to mkfifo" >&2
        return 1
    fi

    # Spawn child: stdin from fifo_in, stdout to fifo_out, stderr to log or null.
    # The child blocks until BOTH fifo ends are opened in this shell. We disown
    # immediately so bash's job-control machinery doesn't print "Terminated: 15"
    # to stderr when we later SIGTERM it during mcp_close — we still poll
    # `kill -0` to confirm death, just without the noise.
    local stderr_target="${CODER_MCP_SERVER_STDERR_LOG:-/dev/null}"
    "$@" < "$fifo_in" > "$fifo_out" 2>>"$stderr_target" &
    local pid=$!
    disown "$pid" 2>/dev/null || true

    # Allocate FDs.
    local fds fd_in fd_out
    fds=$(_mcp_alloc_fds)
    fd_in=${fds%% *}
    fd_out=${fds##* }

    # Open writer-to-child first; this unblocks the child's stdin redirection.
    if ! eval "exec $fd_in>\"\$fifo_in\"" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null
        rm -rf "$tmpdir" 2>/dev/null
        echo "mcp_connect: failed to open stdin fd" >&2
        return 1
    fi
    # Then open reader-from-child. The child completes its stdout redirection
    # and then starts executing.
    if ! eval "exec $fd_out<\"\$fifo_out\"" 2>/dev/null; then
        eval "exec $fd_in>&-" 2>/dev/null
        kill -KILL "$pid" 2>/dev/null
        rm -rf "$tmpdir" 2>/dev/null
        echo "mcp_connect: failed to open stdout fd" >&2
        return 1
    fi

    # Seed the per-connection id file (starts at 1).
    local id_file="$tmpdir/next_id"
    printf '1\n' > "$id_file"

    # Register BEFORE handshake so mcp_send_request can find the connection.
    _MCP_CONN_NAMES+=("$name")
    _MCP_CONN_PIDS+=("$pid")
    _MCP_CONN_FD_IN+=("$fd_in")
    _MCP_CONN_FD_OUT+=("$fd_out")
    _MCP_CONN_FIFO_IN+=("$fifo_in")
    _MCP_CONN_FIFO_OUT+=("$fifo_out")
    _MCP_CONN_TMPDIR+=("$tmpdir")
    _MCP_CONN_NEXT_ID_FILE+=("$id_file")

    # initialize handshake.
    local init_params init_response
    init_params=$(jq -nc \
        --arg pv "$CODER_MCP_PROTOCOL_VERSION" \
        --arg cn "$CODER_MCP_CLIENT_NAME" \
        --arg cv "$CODER_MCP_CLIENT_VERSION" \
        '{
            protocolVersion: $pv,
            capabilities: {},
            clientInfo: { name: $cn, version: $cv }
        }')
    if ! init_response=$(mcp_send_request "$name" "initialize" "$init_params"); then
        echo "mcp_connect: initialize handshake failed for '$name'" >&2
        mcp_close "$name" >/dev/null 2>&1
        return 1
    fi
    # Reject responses that carry a JSON-RPC error envelope.
    if printf '%s' "$init_response" | jq -e 'has("error")' >/dev/null 2>&1; then
        local err_msg
        err_msg=$(printf '%s' "$init_response" | jq -r '.error.message // "unknown"')
        echo "mcp_connect: initialize returned error: $err_msg" >&2
        mcp_close "$name" >/dev/null 2>&1
        return 1
    fi

    # Notify server we're ready.
    mcp_send_notification "$name" "notifications/initialized" "{}" || true

    return 0
}

# mcp_send_request <name> <method> [params_json]
# Writes a request to the connection, blocks until the matching id arrives or
# timeout. Echoes the raw response line on stdout. Notifications and
# server-to-client requests received while waiting are logged to stderr and
# discarded (queueing is a later sub-task).
mcp_send_request() {
    local name="${1:-}" method="${2:-}" params="${3:-}"
    if [ -z "$name" ] || [ -z "$method" ]; then
        echo "mcp_send_request: usage: mcp_send_request <name> <method> [params_json]" >&2
        return 2
    fi
    local idx
    if ! idx=$(_mcp_conn_index "$name"); then
        echo "mcp_send_request: no such connection: $name" >&2
        return 2
    fi
    local fd_in="${_MCP_CONN_FD_IN[$idx]}"
    local fd_out="${_MCP_CONN_FD_OUT[$idx]}"
    local id_file="${_MCP_CONN_NEXT_ID_FILE[$idx]}"
    local next_id
    next_id=$(_mcp_next_id "$id_file")

    local req
    if ! req=$(_mcp_build_request "$next_id" "$method" "$params"); then
        echo "mcp_send_request: failed to build request" >&2
        return 1
    fi
    if ! _mcp_write_line "$fd_in" "$req"; then
        echo "mcp_send_request: write to '$name' failed" >&2
        return 1
    fi

    local timeout="${CODER_MCP_TIMEOUT:-30}"
    local line parsed type msg_id msg_body
    while line=$(_mcp_read_line "$fd_out" "$timeout"); do
        if [ -z "$line" ]; then
            continue
        fi
        parsed=$(_mcp_parse_message "$line")
        IFS=$'\x1f' read -r type msg_id msg_body <<<"$parsed"
        case "$type" in
            response)
                if [ "$msg_id" = "$next_id" ]; then
                    printf '%s\n' "$line"
                    return 0
                fi
                echo "mcp_send_request: discarding response with id=$msg_id (waiting id=$next_id)" >&2
                ;;
            notification)
                echo "mcp_send_request: discarding notification from '$name'" >&2
                ;;
            request)
                echo "mcp_send_request: discarding server->client request id=$msg_id from '$name'" >&2
                ;;
            invalid|*)
                echo "mcp_send_request: invalid message from '$name': $msg_body" >&2
                ;;
        esac
    done
    echo "mcp_send_request: timeout/EOF waiting for id=$next_id from '$name'" >&2
    return 1
}

# mcp_send_notification <name> <method> [params_json]
# Fire-and-forget; no response is awaited.
mcp_send_notification() {
    local name="${1:-}" method="${2:-}" params="${3:-}"
    if [ -z "$name" ] || [ -z "$method" ]; then
        echo "mcp_send_notification: usage: mcp_send_notification <name> <method> [params_json]" >&2
        return 2
    fi
    local idx
    if ! idx=$(_mcp_conn_index "$name"); then
        echo "mcp_send_notification: no such connection: $name" >&2
        return 2
    fi
    local fd_in="${_MCP_CONN_FD_IN[$idx]}"
    local note
    if ! note=$(_mcp_build_notification "$method" "$params"); then
        echo "mcp_send_notification: failed to build notification" >&2
        return 1
    fi
    if ! _mcp_write_line "$fd_in" "$note"; then
        echo "mcp_send_notification: write to '$name' failed" >&2
        return 1
    fi
    return 0
}

# mcp_close <name>
# Closes fds, signals the child, waits, removes fifos + tmpdir, removes entry.
mcp_close() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "mcp_close: usage: mcp_close <name>" >&2
        return 2
    fi
    local idx
    if ! idx=$(_mcp_conn_index "$name"); then
        echo "mcp_close: no such connection: $name" >&2
        return 2
    fi
    local pid="${_MCP_CONN_PIDS[$idx]}"
    local fd_in="${_MCP_CONN_FD_IN[$idx]}"
    local fd_out="${_MCP_CONN_FD_OUT[$idx]}"
    local tmpdir="${_MCP_CONN_TMPDIR[$idx]}"

    # Close fds first; this gives the child EOF on its stdin and may cause it
    # to exit naturally.
    eval "exec $fd_in>&-" 2>/dev/null
    eval "exec $fd_out<&-" 2>/dev/null

    # Best-effort terminate.
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null
        local waited=0
        while [ "$waited" -lt 3 ] && kill -0 "$pid" 2>/dev/null; do
            sleep 1
            waited=$((waited + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null
        fi
    fi
    wait "$pid" 2>/dev/null || true

    [ -n "$tmpdir" ] && [ -d "$tmpdir" ] && rm -rf "$tmpdir" 2>/dev/null

    _mcp_registry_remove "$idx"
    return 0
}

# ---------- Tools API (P1.mcp-2) ----------

# mcp_list_tools <name>
# Calls `tools/list` and accumulates pages via `nextCursor` into a single JSON
# array of tool definitions emitted on stdout. Each element conforms to the MCP
# tool schema: `{name, description, inputSchema}`.
# rc 0 ok; 1 transport / JSON-RPC error / malformed response; 2 invalid args.
# Pagination guard: caps at CODER_MCP_TOOLS_LIST_MAX_PAGES (default 64) to avoid
# an infinite loop if a buggy server keeps returning the same cursor.
mcp_list_tools() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "mcp_list_tools: usage: mcp_list_tools <name>" >&2
        return 2
    fi
    if ! mcp_is_connected "$name"; then
        echo "mcp_list_tools: no such connection: $name" >&2
        return 2
    fi

    local max_pages="${CODER_MCP_TOOLS_LIST_MAX_PAGES:-64}"
    local tools_acc='[]'
    local cursor='' params resp err_msg seen_cursors=''
    local pages=0
    while :; do
        if [ -n "$cursor" ]; then
            params=$(jq -nc --arg c "$cursor" '{cursor: $c}')
        else
            params='{}'
        fi
        if ! resp=$(mcp_send_request "$name" "tools/list" "$params"); then
            echo "mcp_list_tools: tools/list request failed for '$name'" >&2
            return 1
        fi
        if printf '%s' "$resp" | jq -e 'has("error")' >/dev/null 2>&1; then
            err_msg=$(printf '%s' "$resp" | jq -r '.error.message // "unknown"')
            echo "mcp_list_tools: server returned error: $err_msg" >&2
            return 1
        fi
        if ! printf '%s' "$resp" | jq -e '(.result.tools | type) == "array"' >/dev/null 2>&1; then
            echo "mcp_list_tools: invalid response (result.tools is not an array)" >&2
            return 1
        fi
        tools_acc=$(jq -nc --argjson acc "$tools_acc" --argjson resp "$resp" \
            '$acc + ($resp.result.tools)')
        cursor=$(printf '%s' "$resp" | jq -r '.result.nextCursor // empty')
        if [ -z "$cursor" ]; then
            break
        fi
        # Detect server bug: same cursor returned twice in a row.
        case " $seen_cursors " in
            *" $cursor "*)
                echo "mcp_list_tools: server returned repeating cursor '$cursor', aborting" >&2
                return 1
                ;;
        esac
        seen_cursors="$seen_cursors $cursor"
        pages=$((pages + 1))
        if [ "$pages" -ge "$max_pages" ]; then
            echo "mcp_list_tools: exceeded max pages ($max_pages) for '$name'" >&2
            return 1
        fi
    done
    printf '%s\n' "$tools_acc"
    return 0
}

# mcp_call_tool <name> <tool_name> [input_json]
# Calls `tools/call` with `{name: <tool_name>, arguments: <input_json>}` and
# emits the response's `result.content` (JSON array) on stdout. When the result
# carries `isError:true` the content is still emitted (so the caller can show
# it to the LLM) but rc is 1. JSON-RPC error envelopes also yield rc 1 with the
# message logged to stderr.
# Default input_json is `{}` when omitted or empty.
# rc 0 ok, 1 tool isError / server error envelope / transport fail,
# 2 invalid args (empty name / unknown conn / input not a JSON object).
mcp_call_tool() {
    local name="${1:-}" tool_name="${2:-}" input_json="${3:-}"
    if [ -z "$name" ] || [ -z "$tool_name" ]; then
        echo "mcp_call_tool: usage: mcp_call_tool <name> <tool_name> [input_json]" >&2
        return 2
    fi
    if ! mcp_is_connected "$name"; then
        echo "mcp_call_tool: no such connection: $name" >&2
        return 2
    fi
    if [ -z "$input_json" ]; then
        input_json='{}'
    fi
    if ! printf '%s' "$input_json" | jq -e '. | type == "object"' >/dev/null 2>&1; then
        echo "mcp_call_tool: input must be a JSON object" >&2
        return 2
    fi
    local params resp err_msg content is_error
    params=$(jq -nc --arg n "$tool_name" --argjson args "$input_json" \
        '{name: $n, arguments: $args}')
    if ! resp=$(mcp_send_request "$name" "tools/call" "$params"); then
        echo "mcp_call_tool: tools/call request failed for '$name'" >&2
        return 1
    fi
    if printf '%s' "$resp" | jq -e 'has("error")' >/dev/null 2>&1; then
        err_msg=$(printf '%s' "$resp" | jq -r '.error.message // "unknown"')
        echo "mcp_call_tool: server returned error for '$tool_name': $err_msg" >&2
        return 1
    fi
    content=$(printf '%s' "$resp" | jq -c '.result.content // []')
    is_error=$(printf '%s' "$resp" | jq -r '.result.isError // false')
    printf '%s\n' "$content"
    if [ "$is_error" = "true" ]; then
        return 1
    fi
    return 0
}

# ---------- Agentic registry integration (P1.mcp-3) ----------
#
# MCP tools are surfaced into the agentic loop's `REGISTERED_TOOLS` registry as
# *proxy* tools: each proxy reuses the standard `tool_<name>_definition` /
# `tool_<name>_handler` contract expected by `dispatch_tool` so the loop does
# not need to know about MCP at all. Proxies are generated dynamically (no
# `lib/tools/<name>.sh` file) via `eval` of a tiny shim that delegates to
# `_mcp_proxy_definition` / `_mcp_proxy_handler`, both of which look up the
# original (conn, tool, definition) by sanitized proxy name in parallel arrays.
#
# Name convention: `mcp__<sanitized_conn>__<sanitized_tool>` (mirrors the
# Claude Code MCP naming). Sanitization replaces every non-[A-Za-z0-9_] byte
# with `_` so the name is a valid bash identifier (function-name safe). When
# two MCP tools sanitize to the same fn name (e.g., "do-thing" vs "do_thing"
# from the same conn), the first one wins and subsequent ones are silently
# deduplicated — matching the dedup semantics of `register_tool`.
#
# The JSON definition stored for each proxy uses the internal Anthropic-style
# format ({name, description, input_schema}) with `inputSchema` renamed to
# `input_schema` and the prefixed name embedded. Missing `inputSchema` defaults
# to `{"type":"object"}`. Missing `description` defaults to "".
#
# Conditional contract with tool_calling.sh: `_register_agentic_tools` calls
# `mcp_register_all_tools` when (and only when) that fn is declared. So if
# mcp_client.sh is not sourced at all, the agentic loop is unaffected.

# Parallel-array proxy registry (bash 3.2 compatible — no associative arrays).
_MCP_PROXY_FN_NAMES=()
_MCP_PROXY_CONNS=()
_MCP_PROXY_ORIG_NAMES=()
_MCP_PROXY_DEFINITIONS=()

# _mcp_sanitize_name <s> -> echoes s with every non-[A-Za-z0-9_] byte replaced by '_'.
# Empty input -> empty output (caller validates upstream).
_mcp_sanitize_name() {
    printf '%s' "${1:-}" | LC_ALL=C sed 's/[^A-Za-z0-9_]/_/g'
}

# _mcp_proxy_index <fn_name> -> echoes 0-based index of matching proxy, rc 0;
# rc 1 if not found.
_mcp_proxy_index() {
    local needle="${1:-}" i
    if [ "${#_MCP_PROXY_FN_NAMES[@]}" -eq 0 ]; then
        return 1
    fi
    for i in "${!_MCP_PROXY_FN_NAMES[@]}"; do
        if [ "${_MCP_PROXY_FN_NAMES[$i]}" = "$needle" ]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

# _mcp_proxy_definition <fn_name>
# Emits the stored Anthropic-style JSON definition for a proxy tool.
# rc 0 ok, 1 unknown proxy.
_mcp_proxy_definition() {
    local fn_name="${1:-}" idx
    if ! idx=$(_mcp_proxy_index "$fn_name"); then
        echo "_mcp_proxy_definition: unknown proxy: $fn_name" >&2
        return 1
    fi
    printf '%s\n' "${_MCP_PROXY_DEFINITIONS[$idx]}"
}

# _mcp_proxy_handler <fn_name> <input_json>
# Invokes the underlying MCP tool via mcp_call_tool, translates the result.
# When all content blocks are type=text, emits concatenated texts (one per
# block, joined by \n). Otherwise emits the JSON array verbatim so the model
# can inspect non-text content (image/resource). When isError:true the content
# is still emitted (so the LLM sees the failure) but rc is 1.
# rc 0 ok, 1 transport/protocol/tool-error / connection gone / unknown proxy.
_mcp_proxy_handler() {
    local fn_name="${1:-}"
    local input_json="${2:-}"
    [ -n "$input_json" ] || input_json='{}'
    local idx conn orig content rc
    if ! idx=$(_mcp_proxy_index "$fn_name"); then
        echo "_mcp_proxy_handler: unknown proxy: $fn_name" >&2
        return 1
    fi
    conn="${_MCP_PROXY_CONNS[$idx]}"
    orig="${_MCP_PROXY_ORIG_NAMES[$idx]}"
    if ! mcp_is_connected "$conn"; then
        echo "_mcp_proxy_handler: connection '$conn' no longer active" >&2
        return 1
    fi
    content=$(mcp_call_tool "$conn" "$orig" "$input_json")
    rc=$?
    if [ -n "$content" ]; then
        if printf '%s' "$content" | jq -e 'type == "array" and (map(.type == "text") | all)' >/dev/null 2>&1; then
            printf '%s' "$content" | jq -r 'map(.text) | join("\n")'
        else
            printf '%s\n' "$content"
        fi
    fi
    return "$rc"
}

# _mcp_register_proxy <conn> <tool_def_json>
# Internal: registers a single MCP tool (one entry from `tools/list`) as an
# agentic proxy. Idempotent: if the sanitized fn name is already in
# REGISTERED_TOOLS, returns 0 without re-adding (first wins, matching
# register_tool dedup).
# rc 0 ok / already-registered, 1 missing .name on the tool def, 2 missing
# args.
_mcp_register_proxy() {
    local conn="${1:-}" tool_def="${2:-}"
    if [ -z "$conn" ] || [ -z "$tool_def" ]; then
        echo "_mcp_register_proxy: usage: _mcp_register_proxy <conn> <tool_def_json>" >&2
        return 2
    fi
    local orig_name desc raw_schema fn_name def existing
    orig_name=$(printf '%s' "$tool_def" | jq -r '.name // empty')
    if [ -z "$orig_name" ]; then
        echo "_mcp_register_proxy: tool definition missing .name (conn=$conn)" >&2
        return 1
    fi
    desc=$(printf '%s' "$tool_def" | jq -r '.description // ""')
    raw_schema=$(printf '%s' "$tool_def" | jq -c '.inputSchema // {type:"object"}')

    fn_name="mcp__$(_mcp_sanitize_name "$conn")__$(_mcp_sanitize_name "$orig_name")"

    # Dedup against REGISTERED_TOOLS (also catches collisions w/ native tools
    # that happen to share the sanitized name — first wins). REGISTERED_TOOLS
    # is always defined as `()` by tool_calling.sh, so the length check alone
    # is safe.
    if [ "${#REGISTERED_TOOLS[@]}" -gt 0 ]; then
        for existing in "${REGISTERED_TOOLS[@]}"; do
            if [ "$existing" = "$fn_name" ]; then
                return 0
            fi
        done
    fi

    def=$(jq -nc \
        --arg name "$fn_name" \
        --arg desc "$desc" \
        --argjson schema "$raw_schema" \
        '{name: $name, description: $desc, input_schema: $schema}')

    _MCP_PROXY_FN_NAMES+=("$fn_name")
    _MCP_PROXY_CONNS+=("$conn")
    _MCP_PROXY_ORIG_NAMES+=("$orig_name")
    _MCP_PROXY_DEFINITIONS+=("$def")

    # Generate handler + definition fns via eval. fn_name is sanitized to
    # [A-Za-z0-9_] only, so embedding it in single quotes is safe — no quote
    # injection possible.
    eval "tool_${fn_name}_definition() { _mcp_proxy_definition '${fn_name}'; }"
    eval "tool_${fn_name}_handler() { _mcp_proxy_handler '${fn_name}' \"\$1\"; }"

    REGISTERED_TOOLS+=("$fn_name")
    return 0
}

# mcp_register_tools_for_connection <conn>
# Discovers tools from <conn> via tools/list and registers each as an agentic
# proxy. Tools that fail to register (missing .name) are skipped with a
# warning; remaining tools are still attempted.
# rc 0 ok (possibly partial), 1 tools/list failed, 2 invalid args.
mcp_register_tools_for_connection() {
    local conn="${1:-}"
    if [ -z "$conn" ]; then
        echo "mcp_register_tools_for_connection: usage: mcp_register_tools_for_connection <conn>" >&2
        return 2
    fi
    if ! mcp_is_connected "$conn"; then
        echo "mcp_register_tools_for_connection: no such connection: $conn" >&2
        return 2
    fi
    local tools_json count i tool_def
    if ! tools_json=$(mcp_list_tools "$conn"); then
        return 1
    fi
    count=$(printf '%s' "$tools_json" | jq -r 'length')
    [ "$count" -gt 0 ] || return 0
    for ((i = 0; i < count; i++)); do
        tool_def=$(printf '%s' "$tools_json" | jq -c ".[$i]")
        _mcp_register_proxy "$conn" "$tool_def" || true
    done
    return 0
}

# mcp_register_all_tools
# Registers tools from every currently-active MCP connection. Best-effort: a
# failure on one connection does not abort the rest. rc 0 always.
mcp_register_all_tools() {
    local conn_names conn
    conn_names=$(mcp_list_connections 2>/dev/null | awk -F'\t' '{print $1}')
    [ -n "$conn_names" ] || return 0
    while IFS= read -r conn; do
        [ -n "$conn" ] || continue
        mcp_register_tools_for_connection "$conn" >/dev/null 2>&1 || true
    done <<< "$conn_names"
    return 0
}

# mcp_unregister_tools_for_connection <conn>
# Removes every proxy registered from <conn>: unsets the generated
# tool_<fn>_definition / tool_<fn>_handler fns and prunes the parallel arrays
# and REGISTERED_TOOLS. Idempotent: unknown conn = no-op rc 0.
# rc 0 ok, 2 missing args.
mcp_unregister_tools_for_connection() {
    local conn="${1:-}"
    if [ -z "$conn" ]; then
        echo "mcp_unregister_tools_for_connection: usage: <conn>" >&2
        return 2
    fi
    [ "${#_MCP_PROXY_FN_NAMES[@]}" -gt 0 ] || return 0

    local i fn_name
    local new_fn=() new_conn=() new_orig=() new_def=()
    local removed_names=()
    for i in "${!_MCP_PROXY_FN_NAMES[@]}"; do
        if [ "${_MCP_PROXY_CONNS[$i]}" = "$conn" ]; then
            fn_name="${_MCP_PROXY_FN_NAMES[$i]}"
            unset -f "tool_${fn_name}_definition" 2>/dev/null || true
            unset -f "tool_${fn_name}_handler" 2>/dev/null || true
            removed_names+=("$fn_name")
        else
            new_fn+=("${_MCP_PROXY_FN_NAMES[$i]}")
            new_conn+=("${_MCP_PROXY_CONNS[$i]}")
            new_orig+=("${_MCP_PROXY_ORIG_NAMES[$i]}")
            new_def+=("${_MCP_PROXY_DEFINITIONS[$i]}")
        fi
    done
    _MCP_PROXY_FN_NAMES=("${new_fn[@]+"${new_fn[@]}"}")
    _MCP_PROXY_CONNS=("${new_conn[@]+"${new_conn[@]}"}")
    _MCP_PROXY_ORIG_NAMES=("${new_orig[@]+"${new_orig[@]}"}")
    _MCP_PROXY_DEFINITIONS=("${new_def[@]+"${new_def[@]}"}")

    # Also prune REGISTERED_TOOLS.
    if [ "${#removed_names[@]}" -gt 0 ] && [ "${#REGISTERED_TOOLS[@]}" -gt 0 ]; then
        local j keep new_reg=() candidate
        for j in "${!REGISTERED_TOOLS[@]}"; do
            candidate="${REGISTERED_TOOLS[$j]}"
            keep=1
            for fn_name in "${removed_names[@]}"; do
                if [ "$candidate" = "$fn_name" ]; then
                    keep=0
                    break
                fi
            done
            [ "$keep" = "1" ] && new_reg+=("$candidate")
        done
        REGISTERED_TOOLS=("${new_reg[@]+"${new_reg[@]}"}")
    fi
    return 0
}

# ==========================================
# Config + CLI (P1.mcp-4a)
# ==========================================
# Storage: $CODER_MCP_CONFIG (default $CONFIG_DIR/mcp.json).
#
# Config schema (JSON):
#   {
#     "servers": {
#       "<name>": { "command": "<cmd>", "args": [<arg>...], "enabled": <bool> }
#     }
#   }
#
# Public API:
#   mcp_config_path                       -> echoes config path
#   mcp_config_init                       -> 0 ok, 1 fail (idempotent)
#   mcp_config_list_servers               -> emits names, one per line
#   mcp_config_get_server <name>          -> emits server JSON object; 1 not found
#   mcp_autoconnect_enabled_servers       -> connect every enabled server; rc 0
#   mcp_cli <sub> [args...]               -> 0 ok, 1 internal, 2 usage

mcp_config_path() {
    printf '%s\n' "$CODER_MCP_CONFIG"
}

# Internal: load current config as compact JSON. Missing/empty file => empty
# schema. Malformed => rc 1.
_mcp_config_load() {
    local path
    path=$(mcp_config_path)
    if [ ! -f "$path" ] || [ ! -s "$path" ]; then
        printf '%s\n' '{"servers":{}}'
        return 0
    fi
    local content
    if ! content=$(jq -c '.' "$path" 2>/dev/null); then
        return 1
    fi
    printf '%s\n' "$content"
}

# Internal: atomic write of new JSON content.
_mcp_config_write() {
    local new_json="$1"
    local path tmp dir
    path=$(mcp_config_path)
    dir=$(dirname "$path")
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 1
    tmp=$(mktemp "${path}.XXXXXX" 2>/dev/null) || return 1
    printf '%s\n' "$new_json" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

mcp_config_init() {
    local path
    path=$(mcp_config_path)
    if [ -f "$path" ] && [ -s "$path" ]; then
        # Already exists; respect content (caller may have edited).
        return 0
    fi
    _mcp_config_write '{"servers":{}}'
}

mcp_config_list_servers() {
    local json
    if ! json=$(_mcp_config_load); then
        return 1
    fi
    printf '%s\n' "$json" | jq -r '(.servers // {}) | keys[]' 2>/dev/null
}

mcp_config_get_server() {
    local name="${1:-}"
    [ -n "$name" ] || return 2
    local json
    if ! json=$(_mcp_config_load); then
        return 1
    fi
    local has
    has=$(printf '%s' "$json" | jq -r --arg n "$name" '(.servers // {}) | has($n)')
    [ "$has" = "true" ] || return 1
    printf '%s' "$json" | jq -c --arg n "$name" '.servers[$n]'
}

# mcp_autoconnect_enabled_servers
# Reads $CODER_MCP_CONFIG and connects (via mcp_connect) to every server with
# `enabled: true` (or where the key is omitted — defaults to true). Each
# connection is best-effort: a failure on one server emits a warning to stderr
# and the remaining servers are still attempted. Already-connected servers and
# servers without a `command` are skipped silently / with a warning.
#
# Opt-out: set CODER_MCP_AUTOCONNECT=0 to skip entirely.
#
# Always returns 0 — failures must not abort the agentic loop (native tools
# still register without MCP).
mcp_autoconnect_enabled_servers() {
    if [ "${CODER_MCP_AUTOCONNECT:-1}" = "0" ]; then
        return 0
    fi

    local path
    path=$(mcp_config_path)
    if [ ! -f "$path" ] || [ ! -s "$path" ]; then
        return 0
    fi

    local json
    if ! json=$(_mcp_config_load); then
        echo "mcp_autoconnect: malformed JSON in $path; skipping autoconnect" >&2
        return 0
    fi

    local names
    names=$(printf '%s' "$json" | jq -r '
        (.servers // {})
        | to_entries
        | map(select((.value | if has("enabled") then .enabled else true end) == true))
        | .[]
        | .key
    ' 2>/dev/null)
    [ -n "$names" ] || return 0

    local name server_json cmd args_lines server_args a
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if mcp_is_connected "$name"; then
            continue
        fi
        server_json=$(printf '%s' "$json" | jq -c --arg n "$name" '.servers[$n]' 2>/dev/null)
        cmd=$(printf '%s' "$server_json" | jq -r '.command // ""' 2>/dev/null)
        if [ -z "$cmd" ]; then
            echo "mcp_autoconnect: server '$name' has no command; skipping" >&2
            continue
        fi
        args_lines=$(printf '%s' "$server_json" | jq -r '(.args // []) | .[]' 2>/dev/null)
        server_args=()
        if [ -n "$args_lines" ]; then
            while IFS= read -r a; do
                server_args+=("$a")
            done <<<"$args_lines"
        fi
        if ! mcp_connect "$name" "$cmd" "${server_args[@]+"${server_args[@]}"}" >/dev/null 2>&1; then
            echo "mcp_autoconnect: failed to connect to '$name' (cmd=$cmd); skipping" >&2
            continue
        fi
    done <<<"$names"

    return 0
}

# Validate server name: non-empty, no whitespace, no slash.
_mcp_cli_valid_name() {
    local name="$1"
    [ -n "$name" ] || return 1
    case "$name" in
        *[[:space:]]*|*/*) return 1 ;;
    esac
    return 0
}

_mcp_cli_usage() {
    printf '%s\n' "$(hf_t "Usage: coder mcp <subcommand> [args]" "Uso: coder mcp <subcommand> [args]")"
    cat <<'EOF'

Subcommands:
  list                              List configured MCP servers.
  add <name> <cmd> [args...]        Register a server (default enabled).
                                    Use --force to overwrite an existing entry.
  remove <name>                     Delete a server from the config.
  test <name>                       Connect, run tools/list, disconnect.

Examples:
  coder mcp list
  coder mcp add fs npx -y @modelcontextprotocol/server-filesystem /tmp
  coder mcp add github node /opt/mcp-github/index.js
  coder mcp remove fs
  coder mcp test fs
EOF
}

# mcp_cli <subcommand> [args...]
# Exit codes: 0 ok, 1 internal (jq/io/connect/missing), 2 usage.
mcp_cli() {
    local sub="${1:-}"

    case "$sub" in
        list)
            shift
            if [ "$#" -ne 0 ]; then
                echo "mcp list: unexpected arguments" >&2
                _mcp_cli_usage >&2
                return 2
            fi
            local json
            if ! json=$(_mcp_config_load); then
                echo "mcp list: malformed JSON in $(mcp_config_path)" >&2
                return 1
            fi
            local rows
            rows=$(printf '%s' "$json" | jq -r '
                (.servers // {})
                | to_entries
                | map([
                    .key,
                    ((if .value | has("enabled") then .value.enabled else true end) | tostring),
                    (.value.command // ""),
                    ((.value.args // []) | join(" "))
                  ] | @tsv)
                | .[]
            ' 2>/dev/null)
            if [ -z "$rows" ]; then
                echo "(no MCP servers configured)"
                return 0
            fi
            printf '%-20s %-8s %-20s %s\n' "NAME" "ENABLED" "COMMAND" "ARGS"
            local name enabled cmd args
            while IFS=$'\t' read -r name enabled cmd args; do
                [ -n "$name" ] || continue
                printf '%-20s %-8s %-20s %s\n' "$name" "$enabled" "$cmd" "$args"
            done <<<"$rows"
            ;;
        add)
            shift
            local force=0
            local positional=()
            local a
            for a in "$@"; do
                case "$a" in
                    --force|-f) force=1 ;;
                    *) positional+=("$a") ;;
                esac
            done
            if [ "${#positional[@]}" -lt 2 ]; then
                echo "mcp add: expected <name> <cmd> [args...]" >&2
                _mcp_cli_usage >&2
                return 2
            fi
            local name="${positional[0]}"
            local cmd="${positional[1]}"
            if ! _mcp_cli_valid_name "$name"; then
                echo "mcp add: invalid server name '$name' (no whitespace or slash)" >&2
                return 2
            fi
            if [ -z "$cmd" ]; then
                echo "mcp add: command cannot be empty" >&2
                return 2
            fi
            local server_args=()
            if [ "${#positional[@]}" -gt 2 ]; then
                server_args=("${positional[@]:2}")
            fi
            mcp_config_init >/dev/null || {
                echo "mcp add: cannot initialize config at $(mcp_config_path)" >&2
                return 1
            }
            local json
            if ! json=$(_mcp_config_load); then
                echo "mcp add: malformed JSON in $(mcp_config_path)" >&2
                return 1
            fi
            local exists
            exists=$(printf '%s' "$json" | jq -r --arg n "$name" '(.servers // {}) | has($n)')
            if [ "$exists" = "true" ] && [ "$force" != "1" ]; then
                echo "mcp add: server '$name' already exists (use --force to overwrite)" >&2
                return 1
            fi
            local args_json
            if [ "${#server_args[@]}" -eq 0 ]; then
                args_json='[]'
            else
                args_json=$(printf '%s\n' "${server_args[@]}" | jq -R . | jq -s -c .)
            fi
            local new_json
            if ! new_json=$(printf '%s' "$json" | jq -c \
                --arg n "$name" --arg c "$cmd" --argjson a "$args_json" '
                  .servers = (.servers // {})
                  | .servers[$n] = {command: $c, args: $a, enabled: true}
                ' 2>/dev/null); then
                echo "mcp add: jq transform failed" >&2
                return 1
            fi
            if ! _mcp_config_write "$new_json"; then
                echo "mcp add: failed to write $(mcp_config_path)" >&2
                return 1
            fi
            if [ "$exists" = "true" ]; then
                echo "updated: $name"
            else
                echo "added: $name"
            fi
            ;;
        remove)
            shift
            if [ "$#" -ne 1 ]; then
                echo "mcp remove: expected <name>" >&2
                _mcp_cli_usage >&2
                return 2
            fi
            local name="$1"
            if ! _mcp_cli_valid_name "$name"; then
                echo "mcp remove: invalid server name '$name'" >&2
                return 2
            fi
            local json
            if ! json=$(_mcp_config_load); then
                echo "mcp remove: malformed JSON in $(mcp_config_path)" >&2
                return 1
            fi
            local exists
            exists=$(printf '%s' "$json" | jq -r --arg n "$name" '(.servers // {}) | has($n)')
            if [ "$exists" != "true" ]; then
                echo "mcp remove: no such server '$name'" >&2
                return 1
            fi
            local new_json
            if ! new_json=$(printf '%s' "$json" | jq -c --arg n "$name" 'del(.servers[$n])' 2>/dev/null); then
                echo "mcp remove: jq transform failed" >&2
                return 1
            fi
            if ! _mcp_config_write "$new_json"; then
                echo "mcp remove: failed to write $(mcp_config_path)" >&2
                return 1
            fi
            echo "removed: $name"
            ;;
        test)
            shift
            if [ "$#" -ne 1 ]; then
                echo "mcp test: expected <name>" >&2
                _mcp_cli_usage >&2
                return 2
            fi
            local name="$1"
            local server_json
            if ! server_json=$(mcp_config_get_server "$name"); then
                echo "mcp test: no such server '$name'" >&2
                return 1
            fi
            local cmd enabled
            cmd=$(printf '%s' "$server_json" | jq -r '.command // ""')
            enabled=$(printf '%s' "$server_json" | jq -r 'if has("enabled") then .enabled else true end')
            if [ -z "$cmd" ]; then
                echo "mcp test: server '$name' has no command" >&2
                return 1
            fi
            if [ "$enabled" != "true" ]; then
                echo "WARN: server '$name' is disabled (testing anyway)" >&2
            fi
            local args_lines
            args_lines=$(printf '%s' "$server_json" | jq -r '(.args // []) | .[]')
            local server_args=()
            if [ -n "$args_lines" ]; then
                while IFS= read -r a; do
                    server_args+=("$a")
                done <<<"$args_lines"
            fi
            echo "Connecting to '$name' ($cmd${server_args[*]:+ ${server_args[*]}})..."
            if ! mcp_connect "$name" "$cmd" "${server_args[@]+"${server_args[@]}"}"; then
                echo "mcp test: connection failed" >&2
                return 1
            fi
            local tools_json rc
            tools_json=$(mcp_list_tools "$name")
            rc=$?
            if [ "$rc" -ne 0 ]; then
                echo "mcp test: tools/list failed (rc=$rc)" >&2
                mcp_close "$name" >/dev/null 2>&1 || true
                return 1
            fi
            local count
            count=$(printf '%s' "$tools_json" | jq -r 'length' 2>/dev/null)
            [ -n "$count" ] || count=0
            echo "OK: $count tool(s) discovered"
            if [ "$count" -gt 0 ]; then
                printf '%s' "$tools_json" | jq -r '.[] | "  - \(.name)\t\(.description // "")"'
            fi
            mcp_close "$name" >/dev/null 2>&1 || true
            ;;
        -h|--help|help)
            _mcp_cli_usage
            return 0
            ;;
        "")
            _mcp_cli_usage >&2
            return 2
            ;;
        *)
            echo "mcp: unknown subcommand '$sub'" >&2
            _mcp_cli_usage >&2
            return 2
            ;;
    esac
}
