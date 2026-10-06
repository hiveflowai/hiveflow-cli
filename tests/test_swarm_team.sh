#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export CONFIG_DIR="$TMP_DIR/config"
export SWARM_DIR="$CONFIG_DIR/swarm"
export HF_LANG=en
mkdir -p "$SWARM_DIR"

source "$ROOT/lib/engine/swarm_common.sh"
source "$ROOT/lib/engine/cli_orchestrator.sh"
source "$ROOT/lib/engine/swarm_team.sh"
source "$ROOT/lib/core/repl.sh"

assert_contains() {
    local value="$1" expected="$2"
    [[ "$value" == *"$expected"* ]] || { echo "FAIL: expected '$expected' in output" >&2; exit 1; }
}

hf_split_shell_words '/swarm team run "Add a feature with spaces" --no-context'
[[ "${#HF_SHELL_WORDS[@]}" == 5 ]]
[[ "${HF_SHELL_WORDS[3]}" == "Add a feature with spaces" ]]
[[ "${HF_SHELL_WORDS[4]}" == --no-context ]]
if hf_split_shell_words '/swarm team run "unfinished'; then
    echo "FAIL: accepted an unclosed quote" >&2
    exit 1
fi
hf_engine_dispatch() { printf '%s\n' "$@" > "$TMP_DIR/dispatch-args"; }
hf_handle_slash '/swarm team run "Add a feature with spaces" --no-context'
[[ "$(cat "$TMP_DIR/dispatch-args")" == $'team\nrun\nAdd a feature with spaces\n--no-context' ]]

swarm_team_tool_available() { [[ "$1" == claude || "$1" == codex || "$1" == gemini ]]; }

swarm_team_show >/dev/null
[[ "$(jq -r '.lead' "$SWARM_TEAM_FILE")" == claude ]]
[[ "$(jq -r '.reviewer' "$SWARM_TEAM_FILE")" == codex ]]
[[ "$(jq -r '.chair' "$SWARM_TEAM_FILE")" == user ]]
printf '%s\n' '{"lead":"codex","reviewer":"gemini","chair":"user","rules":["legacy rule"]}' > "$SWARM_TEAM_FILE"
swarm_team_config_init
[[ "$(jq -r '.version' "$SWARM_TEAM_FILE")" == 2 ]]
[[ "$(jq -r '.roles[] | select(.name == "coordinator") | .tool' "$SWARM_TEAM_FILE")" == codex ]]
[[ "$(jq -r '.roles[] | select(.name == "reviewer") | .tool' "$SWARM_TEAM_FILE")" == gemini ]]
[[ "$(jq -r '.rules[0]' "$SWARM_TEAM_FILE")" == "legacy rule" ]]
swarm_team_rule_cmd remove 1 >/dev/null

swarm_team_set lead gemini >/dev/null
swarm_team_set chair reviewer >/dev/null
swarm_team_set lead codex >/dev/null
[[ "$(jq -r '.lead' "$SWARM_TEAM_FILE")" == codex ]]
swarm_team_set lead gemini >/dev/null
[[ "$(jq -r '.lead' "$SWARM_TEAM_FILE")" == gemini ]]
[[ "$(jq -r '.chair' "$SWARM_TEAM_FILE")" == reviewer ]]

rule="Preserve 'quoted text'; never expand \$(touch $TMP_DIR/injected)"
swarm_team_rule_cmd add "$rule" >/dev/null
[[ "$(jq -r '.rules[0]' "$SWARM_TEAM_FILE")" == "$rule" ]]
[[ ! -e "$TMP_DIR/injected" ]]
swarm_team_rule_cmd add "Second rule" >/dev/null
swarm_team_rule_cmd remove 2 >/dev/null
[[ "$(jq '.rules | length' "$SWARM_TEAM_FILE")" == 1 ]]
if swarm_team_rule_cmd remove 2 >/dev/null 2>&1; then
    echo "FAIL: removed a non-existent rule" >&2
    exit 1
fi

claude_review="$(swarm_team_build_command claude debate "quote ' and ; echo unsafe")"
codex_review="$(swarm_team_build_command codex debate "read only")"
gemini_review="$(swarm_team_build_command gemini debate "read only")"
assert_contains "$claude_review" "--permission-mode plan"
assert_contains "$codex_review" "-s read-only"
assert_contains "$gemini_review" "--approval-mode=plan"
assert_contains "$claude_review" "--output-format stream-json"
assert_contains "$codex_review" "--json"
assert_contains "$(swarm_team_build_command claude implement "implement")" "--include-partial-messages"
assert_contains "$(swarm_team_build_command codex implement "implement")" "--json"
bash -n -c "$claude_review"
bash -n -c "$codex_review"
bash -n -c "$gemini_review"
assert_contains "$(swarm_team_build_command codex implement "implement")" "workspace-write"
for tool in claude codex gemini; do
    bash -n -c "$(swarm_team_build_command "$tool" implement "quoted ' text; no shell expansion \$(touch $TMP_DIR/unsafe)")"
done
[[ ! -e "$TMP_DIR/unsafe" ]]
invoke_event_start='{"type":"turn.started"}'
invoke_event_message='{"type":"item.completed","item":{"type":"agent_message","text":"Decision: keep the existing renderer."}}'
invoke_output="$(
    swarm_team_build_command() {
        printf "printf '%%s\\n' '%s' '%s'; sleep 1\\n" "$invoke_event_start" "$invoke_event_message"
    }
    swarm_team_invoke codex analyze "mock prompt" "$TMP_DIR/invoke-output.txt" reviewer 2>&1
)"
assert_contains "$invoke_output" "Codex is analyzing the task."
assert_contains "$(cat "$TMP_DIR/invoke-output.txt")" "Decision: keep the existing renderer."

stream_output="$TMP_DIR/stream-output.txt"
stream_assistant="$TMP_DIR/stream-assistant.txt"
stream_result="$TMP_DIR/stream-result.txt"
: > "$stream_output"
: > "$stream_assistant"
: > "$stream_result"
codex_command_event='{"type":"item.started","item":{"type":"command_execution","command":"rg --files src"}}'
assert_contains "$(swarm_team_stream_event codex "$codex_command_event" "$stream_output" "$stream_assistant" "$stream_result" reviewer)" "Running read-only command: rg --files src"
codex_todo_event='{"type":"item.updated","item":{"type":"todo_list","items":[{"text":"Inspect renderer","completed":true},{"text":"Review world generation","completed":false}]}}'
todo_notes="$(swarm_team_stream_event codex "$codex_todo_event" "$stream_output" "$stream_assistant" "$stream_result" reviewer)"
assert_contains "$todo_notes" "✓ Inspect renderer"
assert_contains "$todo_notes" "○ Review world generation"
codex_message_event='{"type":"item.completed","item":{"type":"agent_message","text":"Decision: reuse the current renderer."}}'
swarm_team_stream_event codex "$codex_message_event" "$stream_output" "$stream_assistant" "$stream_result" reviewer >/dev/null
assert_contains "$(cat "$stream_assistant")" "Decision: reuse the current renderer."
claude_tool_event='{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"Read","input":{"file_path":"src/main.js"}}}}'
assert_contains "$(swarm_team_stream_event claude "$claude_tool_event" "$stream_output" "$stream_assistant" "$stream_result" architect)" "Claude is preparing tool: Read"
claude_tool_decision='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"src/main.js"}}]}}'
assert_contains "$(swarm_team_stream_event claude "$claude_tool_decision" "$stream_output" "$stream_assistant" "$stream_result" architect)" "Claude selected tool Read: src/main.js"
gemini_tool_event='{"type":"tool_use","tool_name":"read_file","parameters":{"file_path":"src/world.js"}}'
assert_contains "$(swarm_team_stream_event gemini "$gemini_tool_event" "$stream_output" "$stream_assistant" "$stream_result" architect)" "Gemini tool read_file: src/world.js"
gemini_message_event='{"type":"message","role":"assistant","content":"Plan is ready.","delta":true}'
swarm_team_stream_event gemini "$gemini_message_event" "$stream_output" "$stream_assistant" "$stream_result" architect >/dev/null
assert_contains "$(cat "$stream_assistant")" "Plan is ready."

swarm_team_selected_roles balanced ""
[[ "${SWARM_TEAM_SELECTED_ROLES[*]}" == "coordinator reviewer attacker defender qa" ]]
swarm_team_selected_roles creative "storyteller"
[[ "${SWARM_TEAM_SELECTED_ROLES[*]}" == "coordinator storyteller" ]]
swarm_team_role_add gameplay gemini analysis "Own the core game mechanics" >/dev/null
swarm_team_role_enable gameplay false >/dev/null
[[ "$(jq -r '.roles[] | select(.name == "gameplay") | .enabled' "$SWARM_TEAM_FILE")" == false ]]
swarm_team_role_enable gameplay true >/dev/null

export HF_REPL_SESSION="test-thread"
hf_session_context() { printf '%s\n' 'user: We are using the existing app context.'; }
hf_session_append_exchange() { printf '%s\n%s\n' "$2" "$3" > "$TMP_DIR/session-exchange"; }
swarm_team_invoke() {
    local tool="$1" mode="$2" prompt="$3" output_file="$4" result
    local role
    role="$(printf '%s' "$prompt" | sed -n 's/.*ROLE AGENT: \([a-z_-]*\).*/\1/p' | head -1)"
    printf '%s|%s|%s|%s\n' "$role" "$tool" "$mode" "$prompt" >> "$TMP_DIR/invocations"
    if [ "$role" = "${SWARM_TEAM_TEST_FAIL_ROLE:-}" ]; then
        printf '%s\n' "Mock provider failure for $role" > "$output_file"
        return 17
    fi
    case "$prompt" in
        *"ROLE AS CHAIR:"*) result="Decision: adopt proposal with the reviewer's test." ;;
        *"ROLE AGENT: coordinator"*) result="Proposal: use the existing subsystem." ;;
        *"ROLE AGENT: reviewer"*) result="Review: preserve existing behavior; add a focused test." ;;
        *"ROLE AGENT: attacker"*) result="Attack: check failure paths and misuse cases." ;;
        *"ROLE AGENT: defender"*) result="Defense: scope is small and preserves existing behavior." ;;
        *"ROLE AGENT: qa"*) result="QA: add a focused regression test." ;;
        *"explicitly selected role"*) result="Implementation complete; tests passed." ;;
        *) echo "FAIL: unexpected role prompt" >&2; return 1 ;;
    esac
    printf '%s\n' "$result" > "$output_file"
}

swarm_team_set lead claude >/dev/null
swarm_team_set reviewer codex >/dev/null
swarm_team_set chair reviewer >/dev/null
run_output="$(swarm_team_run --no-prompt "Add a team workflow" 2>&1)"
assert_contains "$run_output" "SWARM TEAM"
assert_contains "$run_output" "PROPOSAL"
assert_contains "$run_output" "REVIEW"
assert_contains "$run_output" "CHAIR DECISION"
assert_contains "$run_output" "ATTACKER"
assert_contains "$run_output" "DEFENDER"
[[ "$(grep -cE '^(coordinator|reviewer|attacker|defender|qa)\|' "$TMP_DIR/invocations")" == 6 ]]
assert_contains "$(cat "$TMP_DIR/invocations")" "We are using the existing app context."
assert_contains "$(cat "$TMP_DIR/session-exchange")" "Decision: adopt proposal"
assert_contains "$(swarm_team_build_command codex implement "implement")" "workspace-write"
run_id="$(jq -r '.id' "$(ls -1 "$SWARM_TEAM_RUNS_DIR"/*.json | tail -1)")"
[[ "$(jq -r '.status' "$(swarm_team_run_path "$run_id")")" == awaiting_decision ]]
assert_contains "$(swarm_team_report "$run_id")" "Review: preserve existing behavior"
if swarm_team_delegate_run "$run_id" developer >/dev/null 2>&1; then
    echo "FAIL: noninteractive terminal delegated implementation" >&2
    exit 1
fi

export SWARM_TEAM_TEST_FAIL_ROLE=attacker
partial_output="$(swarm_team_run --profile balanced --no-context --no-prompt "Recover when the red-team CLI fails" 2>&1)"
unset SWARM_TEAM_TEST_FAIL_ROLE
assert_contains "$partial_output" "Mock provider failure for attacker"
partial_id="$(jq -r --arg task "Recover when the red-team CLI fails" 'select(.task == $task) | .id' "$SWARM_TEAM_RUNS_DIR"/*.json | tail -1)"
[[ "$(jq -r '.status' "$(swarm_team_run_path "$partial_id")")" == partial ]]
assert_contains "$(swarm_team_report "$partial_id")" "Role attacker failed"
assert_contains "$(cat "$TMP_DIR/invocations")" "qa|"

rounds_output="$(swarm_team_run --profile fast --rounds 2 --no-context --no-prompt "Resolve a proposal after one challenge round" 2>&1)"
assert_contains "$rounds_output" "Round 2"
rounds_id="$(jq -r --arg task "Resolve a proposal after one challenge round" 'select(.task == $task) | .id' "$SWARM_TEAM_RUNS_DIR"/*.json | tail -1)"
[[ "$(jq '[.responses[] | select(.round == 2)] | length' "$(swarm_team_run_path "$rounds_id")")" == 3 ]]
round_two_roles="$(jq -r '[.responses[] | select(.round == 2) | .role] | join(" ")' "$(swarm_team_run_path "$rounds_id")")"
[[ "$round_two_roles" == "reviewer coordinator chair" ]]

echo "Resultado: Hiveflow Team suite passed"
