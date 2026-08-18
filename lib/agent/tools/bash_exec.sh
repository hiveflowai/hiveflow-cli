#!/bin/bash

# ==========================================
# AGENTIC TOOL: bash_exec
# ==========================================
# Executes a shell command under `bash -c`, captures stdout / stderr / exit code
# and honors a configurable timeout. Sourced by lib/tool_calling.sh::register_tool.
# Do NOT set global strict mode here (this file is sourced in the parent shell).
#
# Contract:
#   - Inputs: { "command": string, "timeout_seconds"?: integer (default 120, max 3600) }.
#   - MANDATORY permission check via confirm_permission (lib/permissions.sh).
#     The hardcoded denylist in permissions.sh (rm -rf /, sudo rm -rf, dd to /dev/sd*,
#     mkfs, fork bomb, redirect to /dev/sd*/nvme*, chmod -R 777 /) hard-fails BEFORE
#     reaching the prompt even with CODER_YES=1.
#   - No allowlist match and no CODER_YES=1 => needs-confirm. No TTY => denied.
#   - The command runs with `bash -c "$cmd"` inheriting the caller's cwd + env.
#   - Bash-native timeout enforcement (does not depend on coreutils `timeout`/`gtimeout`):
#     a watchdog in a parallel subshell sends SIGTERM when exceeded, then SIGKILL if
#     it does not die within 1s.
#   - stdout / stderr captured to separate tmpfiles, each truncated to 32KB
#     (override via CODER_BASH_EXEC_MAX_OUTPUT_BYTES). With an explicit marker if truncated.
#
# Output (stdout, structured format for the LLM):
#   bash_exec: exit=<N> timed_out=<true|false> duration=<Ns>
#   --- stdout ---
#   <content or "(empty)">
#   --- stderr ---
#   <content or "(empty)">
#
# Exit codes (of the TOOL, not the command):
#   0  command executed (any command exit code, including timeout)
#   1  permission denied / permissions.sh module not loaded / infrastructure failure
#      (mktemp, etc) / denylist hard-fail
#   2  invalid input JSON or missing fields
#
# Env vars:
#   CODER_YES                          - "1" => auto-approves needs-confirm without prompting
#   CODER_BASH_EXEC_MAX_OUTPUT_BYTES   - cap per stream (default 32768 = 32KB)
#   CODER_BASH_EXEC_KILL_GRACE_SECONDS - seconds between SIGTERM and SIGKILL (default 1)
#   CODER_TOOL_LIVE_STREAM             - "1" => emits the child command's stdout/stderr to
#                                        the handler's stderr LIVE (via FIFOs + tee),
#                                        while simultaneously capturing to tmpfiles for
#                                        the final canonical output. Default 0 (off) =>
#                                        bit-exact historical behavior. P2.streaming-1.

# tool_bash_exec_definition
# Emits the JSON schema (internal canonical Anthropic format).
tool_bash_exec_definition() {
    cat <<'EOF'
{
  "name": "bash_exec",
  "description": "Execute a shell command via `bash -c` and capture stdout, stderr, and exit code. Runs in the current working directory with the caller's environment. ALWAYS requires permission (interactive confirm or persisted allowlist); a hardcoded denylist hard-fails destructive patterns (rm -rf /, sudo rm -rf, dd to disk devices, mkfs, fork bomb, redirect to /dev/sd*/nvme*, chmod -R 777 /) regardless of overrides. A configurable timeout (default 120s, max 3600s) kills the process if exceeded. stdout and stderr are each truncated to 32KB. Returns a structured block: header line with exit code / timed_out flag / duration, followed by --- stdout --- and --- stderr --- sections.",
  "input_schema": {
    "type": "object",
    "properties": {
      "command": {
        "type": "string",
        "description": "Shell command line. Passed to `bash -c` verbatim, so pipes, redirects, env-var expansions and multi-line scripts (with literal newlines) are supported."
      },
      "timeout_seconds": {
        "type": "integer",
        "description": "Maximum seconds the command is allowed to run before SIGTERM (then SIGKILL after a grace period). Defaults to 120. Must be in [1, 3600].",
        "minimum": 1,
        "maximum": 3600
      }
    },
    "required": ["command"]
  }
}
EOF
}

# _bash_exec_truncate <file> <max_bytes>
# Truncates <file> to <max_bytes> bytes and appends a marker if it trimmed. In-place via tmpfile.
_bash_exec_truncate() {
    local file="$1"
    local max="$2"
    local size
    size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
    [ -z "$size" ] && size=0
    if [ "$size" -le "$max" ]; then
        return 0
    fi
    local tmp
    tmp=$(mktemp "${file}.trunc.XXXXXX") || return 1
    head -c "$max" "$file" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    printf '\n[...truncated %d of %d bytes...]\n' "$((size - max))" "$size" >> "$tmp"
    mv "$tmp" "$file"
}

# _bash_exec_emit_section <label> <file>
# Prints "--- <label> ---" + content (or "(empty)" if empty).
_bash_exec_emit_section() {
    local label="$1"
    local file="$2"
    echo "--- ${label} ---"
    if [ -s "$file" ]; then
        cat "$file"
    else
        echo "(empty)"
    fi
}

# tool_bash_exec_handler <input_json>
tool_bash_exec_handler() {
    local input_json="$1"
    local cmd timeout_seconds
    local max_bytes grace_seconds
    local stdout_file stderr_file
    local cmd_pid wd_pid wd_marker
    local cmd_exit timed_out
    local start_time end_time duration
    local live_stream fifo_dir fifo_stdout fifo_stderr tee_pid_out tee_pid_err

    if [ -z "$input_json" ]; then
        echo "bash_exec: missing input JSON" >&2
        return 2
    fi

    if ! cmd=$(echo "$input_json" | jq -re '.command' 2>/dev/null); then
        echo "bash_exec: missing required field 'command'" >&2
        return 2
    fi
    if [ -z "$cmd" ]; then
        echo "bash_exec: field 'command' must be a non-empty string" >&2
        return 2
    fi

    timeout_seconds=$(echo "$input_json" | jq -r '.timeout_seconds // 120' 2>/dev/null)
    if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
        echo "bash_exec: 'timeout_seconds' must be a positive integer (got: $timeout_seconds)" >&2
        return 2
    fi
    if [ "$timeout_seconds" -lt 1 ] || [ "$timeout_seconds" -gt 3600 ]; then
        echo "bash_exec: 'timeout_seconds' out of range [1, 3600] (got: $timeout_seconds)" >&2
        return 2
    fi

    max_bytes="${CODER_BASH_EXEC_MAX_OUTPUT_BYTES:-32768}"
    if ! [[ "$max_bytes" =~ ^[1-9][0-9]*$ ]]; then
        echo "bash_exec: CODER_BASH_EXEC_MAX_OUTPUT_BYTES must be a positive integer (got: $max_bytes)" >&2
        return 1
    fi

    grace_seconds="${CODER_BASH_EXEC_KILL_GRACE_SECONDS:-1}"
    if ! [[ "$grace_seconds" =~ ^[0-9]+$ ]]; then
        echo "bash_exec: CODER_BASH_EXEC_KILL_GRACE_SECONDS must be a non-negative integer (got: $grace_seconds)" >&2
        return 1
    fi

    if ! declare -f confirm_permission >/dev/null 2>&1; then
        echo "bash_exec: lib/permissions.sh not loaded (confirm_permission undefined); refusing to execute" >&2
        return 1
    fi

    if ! confirm_permission "bash_exec" "$cmd" "${CODER_YES:-0}"; then
        echo "bash_exec: permission denied" >&2
        return 1
    fi

    if ! stdout_file=$(mktemp 2>/dev/null); then
        echo "bash_exec: cannot create stdout tmpfile" >&2
        return 1
    fi
    if ! stderr_file=$(mktemp 2>/dev/null); then
        rm -f "$stdout_file"
        echo "bash_exec: cannot create stderr tmpfile" >&2
        return 1
    fi
    if ! wd_marker=$(mktemp 2>/dev/null); then
        rm -f "$stdout_file" "$stderr_file"
        echo "bash_exec: cannot create watchdog marker tmpfile" >&2
        return 1
    fi

    # Live stream setup: when CODER_TOOL_LIVE_STREAM=1, we redirect cmd.stdout
    # and cmd.stderr to 2 FIFOs read by 2 background tees. Each tee writes
    # to its canonical tmpfile AND duplicates to the handler's stderr (FD 2) so
    # the user sees the output live. The final canonical structured output
    # does NOT change — the LLM still receives the same tool_result.
    live_stream="${CODER_TOOL_LIVE_STREAM:-0}"
    fifo_dir=""
    if [ "$live_stream" = "1" ]; then
        if ! fifo_dir=$(mktemp -d 2>/dev/null); then
            echo "bash_exec: cannot create fifo tmpdir; falling back to non-stream mode" >&2
            live_stream=0
            fifo_dir=""
        else
            fifo_stdout="$fifo_dir/stdout.fifo"
            fifo_stderr="$fifo_dir/stderr.fifo"
            if ! mkfifo "$fifo_stdout" "$fifo_stderr" 2>/dev/null; then
                echo "bash_exec: mkfifo failed; falling back to non-stream mode" >&2
                rm -rf "$fifo_dir"
                fifo_dir=""
                live_stream=0
            fi
        fi
    fi

    start_time=$(date +%s)

    if [ "$live_stream" = "1" ]; then
        # Critical ordering to avoid FIFO deadlock:
        #   1. Spawn tees FIRST. Each tee opens its fifo for reading and blocks
        #      until a writer appears.
        #   2. exec 4>$fifo_stdout 5>$fifo_stderr in the parent shell. Opening
        #      the write side unblocks the tees and keeps the fifo "alive"
        #      for the entire execution (we close them explicitly after
        #      `wait $cmd_pid` so the tees see EOF and drain).
        #   3. Launch bash -c. Its stdout/stderr are additional writers on the
        #      fifo; when it exits, its side closes but the parent's FD 4/5
        #      keep the fifo open until our `exec 4>&-`.
        tee "$stdout_file" < "$fifo_stdout" >&2 &
        tee_pid_out=$!
        tee "$stderr_file" < "$fifo_stderr" >&2 &
        tee_pid_err=$!
        exec 4>"$fifo_stdout" 5>"$fifo_stderr"
        # Launch command in background. bash -c interprets pipes/redirects/multi-line.
        bash -c "$cmd" >"$fifo_stdout" 2>"$fifo_stderr" &
        cmd_pid=$!
    else
        # Historical path: direct redirect to tmpfiles, no tees or fifos.
        bash -c "$cmd" >"$stdout_file" 2>"$stderr_file" &
        cmd_pid=$!
    fi

    # Watchdog polling: checks every 1s whether the command is still alive. If not, clean exit.
    # If it exceeds timeout_seconds, marks and kills (SIGTERM -> grace -> SIGKILL).
    # Polling (instead of a single `sleep $timeout`) avoids the problem of `kill $wd_pid`
    # not propagating to its `sleep` child: the watchdog self-terminates when the command dies
    # and `wait $wd_pid` returns within <=1s without needing external signals.
    (
        elapsed=0
        while [ "$elapsed" -lt "$timeout_seconds" ]; do
            sleep 1
            elapsed=$((elapsed + 1))
            if ! kill -0 "$cmd_pid" 2>/dev/null; then
                exit 0
            fi
        done
        echo "timeout" > "$wd_marker"
        kill -TERM "$cmd_pid" 2>/dev/null || true
        if [ "$grace_seconds" -gt 0 ]; then
            sleep "$grace_seconds"
        fi
        if kill -0 "$cmd_pid" 2>/dev/null; then
            kill -KILL "$cmd_pid" 2>/dev/null || true
        fi
    ) &
    wd_pid=$!

    wait "$cmd_pid" 2>/dev/null
    cmd_exit=$?

    # The watchdog self-exits within 1s upon seeing that cmd_pid died.
    wait "$wd_pid" 2>/dev/null || true

    if [ "$live_stream" = "1" ]; then
        # Close the write side the parent shell keeps open.
        # bash -c already closed its side on exit; with FD 4/5 closed the tees see EOF
        # and drain cleanly. Waiting on each tee guarantees the tmpfile finishes
        # being written BEFORE its content is read in _bash_exec_emit_section.
        exec 4>&- 5>&-
        wait "$tee_pid_out" 2>/dev/null || true
        wait "$tee_pid_err" 2>/dev/null || true
        rm -rf "$fifo_dir"
    fi

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    if [ -s "$wd_marker" ]; then
        timed_out=true
    else
        timed_out=false
    fi
    rm -f "$wd_marker"

    _bash_exec_truncate "$stdout_file" "$max_bytes" || true
    _bash_exec_truncate "$stderr_file" "$max_bytes" || true

    echo "bash_exec: exit=${cmd_exit} timed_out=${timed_out} duration=${duration}s"
    _bash_exec_emit_section "stdout" "$stdout_file"
    _bash_exec_emit_section "stderr" "$stderr_file"

    rm -f "$stdout_file" "$stderr_file"
    return 0
}
