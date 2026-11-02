#!/bin/bash

# ==========================================
# AGENTIC TOOL: hiveflow_mode
# ==========================================
#
# Corre JavaScript contra las herramientas de la cuenta (hiveflow.*) en un sandbox del backend, sin red.
# Solo vuelve lo que el script devuelve o imprime. No ejecuta nada en esta máquina; las tools locales
# (archivos, bash, MCP stdio) siguen siendo llamadas directas.
#
# Requiere sesión (/login) y permiso via confirm_permission "hiveflow_mode".
# Exit codes: 0 script ok · 1 fallo del script, de red o sin permiso · 2 input inválido

tool_hiveflow_mode_definition() {
    cat <<'EOF'
{
  "name": "hiveflow_mode",
  "description": "Run JavaScript in an isolated HiveFlow sandbox with no network, chaining the tools of the user's HiveFlow account through the `hiveflow` object, e.g. `const flows = await hiveflow.flows.list_flows({}); return flows.length;`. Top-level await and return work. Only the returned value and console.log output come back, so large results stay out of context. hiveflow.search('text') finds tools and hiveflow.help('ns.tool') shows a signature. It cannot touch local files or the shell, and destructive tools are not available from it. Bills compute credits.",
  "input_schema": {
    "type": "object",
    "properties": {
      "code": { "type": "string", "description": "JavaScript to run." },
      "intent": { "type": "string", "description": "One line saying what the script does." },
      "timeout_seconds": { "type": "integer", "description": "Script time limit. Default 120, must be in [10, 600].", "minimum": 10, "maximum": 600 }
    },
    "required": ["code"]
  }
}
EOF
}

tool_hiveflow_mode_handler() {
    local input_json="$1"
    local code intent timeout_seconds token base body_file response_file http_code

    if [ -z "$input_json" ]; then
        echo "hiveflow_mode: missing input JSON" >&2
        return 2
    fi
    code=$(printf '%s' "$input_json" | jq -r '.code // empty' 2>/dev/null)
    if [ -z "$code" ]; then
        echo "hiveflow_mode: missing required field 'code'" >&2
        return 2
    fi
    timeout_seconds=$(printf '%s' "$input_json" | jq -r '.timeout_seconds // 120' 2>/dev/null)
    if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || [ "$timeout_seconds" -lt 10 ] || [ "$timeout_seconds" -gt 600 ]; then
        echo "hiveflow_mode: 'timeout_seconds' must be an integer in [10, 600]" >&2
        return 2
    fi
    intent=$(printf '%s' "$input_json" | jq -r '.intent // "script"' 2>/dev/null)

    if ! declare -f confirm_permission >/dev/null 2>&1; then
        echo "hiveflow_mode: lib/permissions.sh not loaded (confirm_permission undefined); refusing to run" >&2
        return 1
    fi
    if ! confirm_permission "hiveflow_mode" "$intent" "${CODER_YES:-0}"; then
        echo "hiveflow_mode: permission denied" >&2
        return 1
    fi

    token="$(hf_auth_token 2>/dev/null)"
    if [ -z "$token" ]; then
        echo "hiveflow_mode: not logged in to HiveFlow (run /login)" >&2
        return 1
    fi
    base="${HIVEFLOW_API_URL:-https://api.hiveflow.ai}"

    body_file=$(mktemp) || return 1
    response_file=$(mktemp) || { rm -f "$body_file"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -f '$body_file' '$response_file'" RETURN
    printf '%s' "$input_json" | jq --argjson t "$timeout_seconds" '{code, intent, timeoutSeconds: $t}' > "$body_file"

    # El token va por stdin para que no aparezca en `ps`
    http_code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -sS -K - \
        -m "$((timeout_seconds + 45))" \
        -o "$response_file" -w '%{http_code}' \
        -X POST "${base%/}/api/hiveflow-mode/run" \
        -H 'Content-Type: application/json' \
        --data-binary "@$body_file") || {
        echo "hiveflow_mode: request failed" >&2
        return 1
    }

    case "$http_code" in
        200) : ;;
        401|403) echo "hiveflow_mode: not authorized (HTTP $http_code); run /login" >&2; return 1 ;;
        402) echo "hiveflow_mode: not enough credits" >&2; return 1 ;;
        404) echo "hiveflow_mode: this backend does not support HiveFlow Mode yet" >&2; return 1 ;;
        503) echo "hiveflow_mode: sandboxes are disabled on this backend" >&2; return 1 ;;
        *) echo "hiveflow_mode: HTTP $http_code" >&2; return 1 ;;
    esac

    jq -r '.data.output // "(no output)"' "$response_file" 2>/dev/null || { echo "hiveflow_mode: invalid response" >&2; return 1; }
    [ "$(jq -r '.data.ok // false' "$response_file" 2>/dev/null)" = "true" ]
}
