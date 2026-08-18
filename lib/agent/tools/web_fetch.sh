#!/bin/bash

# ==========================================
# TOOL AGENTIC: web_fetch
# ==========================================
# GET de una URL HTTP(S) via curl, conversion HTML -> texto y retorno estructurado
# al LLM. Sourceado por lib/tool_calling.sh::register_tool. NO setear strict mode
# global aqui (el archivo se sourcea en el shell padre y filtraria flags al resto).
#
# Contrato:
#   - Inputs: { "url": string, "format"?: "text"|"markdown"|"raw" (default "text"),
#               "max_bytes"?: integer (default 204800, max 2097152),
#               "timeout_seconds"?: integer (default 30, max 300) }
#   - Permission check OBLIGATORIO via confirm_permission "web_fetch" "<url>".
#     web_fetch NO esta en _PERMISSIONS_READ_ONLY_TOOLS porque tiene side-effect
#     de red (egress), puede leak info via URLs sensibles, y el contenido remoto
#     es un vector de prompt-injection indirecta.
#   - Hard-deny en el handler ANTES de tocar permissions (no negociable):
#       - Scheme distinto de http/https (file, ftp, gopher, javascript, data, ...)
#       - URL apunta a 169.254.169.254 (AWS / GCP / Azure metadata service)
#     Estos dos hard-fail aunque el usuario haga `coder permissions allow web_fetch "*"`.
#   - Body conversion (cuando content-type es text/html y format != "raw"):
#       1) lynx -dump -nolist -stdin   (preferido, mejor calidad)
#       2) w3m -dump -T text/html      (fallback)
#       3) pandoc -f html -t {plain,markdown}  (fallback final para format=markdown)
#       4) sed/awk fallback nativo     (script + style strip, tag strip, entity decode)
#     format="raw" devuelve el body verbatim (util para JSON, texto plano).
#   - Truncado: body final cortado a max_bytes con marker explicito.
#
# Salida (stdout, formato estructurado para el LLM):
#   web_fetch: status=<N> bytes=<N> content_type=<...> final_url=<...> renderer=<...>
#   --- body ---
#   <content o "(empty)">
#
# Exit codes (de la TOOL, no del HTTP):
#   0  fetch ejecutado y body emitido (cualquier HTTP status, incluyendo 4xx/5xx)
#   1  permission denied / scheme no permitido / SSRF hard-deny / curl error /
#      modulo permissions.sh no cargado / fallo de infraestructura (mktemp, etc)
#   2  input JSON invalido o campos faltantes
#
# Env vars:
#   CODER_YES                          - "1" => auto-aprueba needs-confirm sin prompt
#   CODER_WEB_FETCH_USER_AGENT         - User-Agent (default "asis-coder/<VERSION o dev>")
#   CODER_WEB_FETCH_MAX_REDIRECTS      - max redirects (default 5)
#   CODER_WEB_FETCH_DEFAULT_MAX_BYTES  - default max_bytes si no se pasa en input (default 204800)

# tool_web_fetch_definition
# Emite el JSON schema (formato Anthropic canonico interno).
tool_web_fetch_definition() {
    cat <<'EOF'
{
  "name": "web_fetch",
  "description": "GET an http(s) URL and return its body, optionally converted from HTML to plain text or Markdown. Requires permission (interactive confirm or persisted allowlist). Hard-denies non-http(s) schemes and the cloud metadata service (169.254.169.254) regardless of overrides. Body is truncated to max_bytes (default 200KB). For HTML content with format='text' the body is rendered with lynx/w3m/pandoc when available, otherwise a fallback strip-tags pipeline. Use format='raw' for JSON or pre-rendered text.",
  "input_schema": {
    "type": "object",
    "properties": {
      "url": {
        "type": "string",
        "description": "Full http:// or https:// URL. Other schemes are rejected."
      },
      "format": {
        "type": "string",
        "description": "Output transform: 'text' (default, strip HTML to readable text), 'markdown' (HTML -> Markdown via pandoc when available, falls back to 'text'), 'raw' (body verbatim, useful for JSON/plain text).",
        "enum": ["text", "markdown", "raw"]
      },
      "max_bytes": {
        "type": "integer",
        "description": "Maximum body bytes to return after rendering. Defaults to 204800 (200KB). Must be in [1024, 2097152].",
        "minimum": 1024,
        "maximum": 2097152
      },
      "timeout_seconds": {
        "type": "integer",
        "description": "Max seconds for the entire request (DNS + connect + transfer). Default 30, must be in [1, 300].",
        "minimum": 1,
        "maximum": 300
      }
    },
    "required": ["url"]
  }
}
EOF
}

# _web_fetch_url_scheme_ok <url>
# 0 si http(s)://, 1 en cualquier otro caso.
_web_fetch_url_scheme_ok() {
    local url="$1"
    [[ "$url" =~ ^https?://[^[:space:]]+$ ]]
}

# _web_fetch_url_blocks_metadata <url>
# 0 si la URL hace match con el servicio de metadata cloud (169.254.169.254) o
# variantes (cualquier puerto, cualquier path). Hard-deny independiente de permissions.
_web_fetch_url_blocks_metadata() {
    local url="$1"
    # Normalizar a lowercase para hostname matching (sin tocar path).
    local lower
    lower=$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')
    # Match: ://169.254.169.254 (optional :port, optional /path)
    [[ "$lower" == *"://169.254.169.254"* ]]
}

# _web_fetch_curl <body_file> <meta_file> <url> <timeout> <max_redirects> <user_agent>
# Wrapper alrededor de curl para que tests puedan overridear sin tocar PATH.
# Escribe el body a $body_file, y a $meta_file 4 lineas con:
#   linea 1: http_code
#   linea 2: content_type
#   linea 3: url_effective
#   linea 4: size_download
# Exit code de curl propagado.
_web_fetch_curl() {
    local body_file="$1"
    local meta_file="$2"
    local url="$3"
    local timeout="$4"
    local max_redirects="$5"
    local user_agent="$6"

    curl --silent --show-error \
         --max-time "$timeout" \
         --max-redirs "$max_redirects" \
         --location \
         --user-agent "$user_agent" \
         --write-out '%{http_code}\n%{content_type}\n%{url_effective}\n%{size_download}\n' \
         --output "$body_file" \
         "$url" \
         > "$meta_file"
}

# _web_fetch_render_html <input_file> <format>
# Convierte el contenido de <input_file> (HTML) a texto/markdown.
# Imprime: <renderer_name>\n<rendered_content> a stdout.
# format: "text" o "markdown". Si "markdown" no esta disponible, fallback a text.
_web_fetch_render_html() {
    local input_file="$1"
    local format="$2"
    local renderer="" rendered=""

    if [ "$format" = "markdown" ]; then
        if command -v pandoc >/dev/null 2>&1; then
            if rendered=$(pandoc -f html -t markdown_strict --wrap=none "$input_file" 2>/dev/null); then
                renderer="pandoc-markdown"
                printf '%s\n%s' "$renderer" "$rendered"
                return 0
            fi
        fi
        # Fallback a text si markdown no disponible.
        format="text"
    fi

    if command -v lynx >/dev/null 2>&1; then
        if rendered=$(lynx -dump -nolist -nonumbers -width=120 -stdin < "$input_file" 2>/dev/null); then
            renderer="lynx"
            printf '%s\n%s' "$renderer" "$rendered"
            return 0
        fi
    fi

    if command -v w3m >/dev/null 2>&1; then
        if rendered=$(w3m -dump -T text/html -cols 120 "$input_file" 2>/dev/null); then
            renderer="w3m"
            printf '%s\n%s' "$renderer" "$rendered"
            return 0
        fi
    fi

    if command -v pandoc >/dev/null 2>&1; then
        if rendered=$(pandoc -f html -t plain --wrap=none "$input_file" 2>/dev/null); then
            renderer="pandoc-plain"
            printf '%s\n%s' "$renderer" "$rendered"
            return 0
        fi
    fi

    # Fallback nativo: strip script/style, strip tags, decode entities basicas,
    # colapsar lineas en blanco consecutivas.
    rendered=$(awk '
        BEGIN { in_skip = 0 }
        {
            line = $0
            while (1) {
                if (in_skip) {
                    idx = index(tolower(line), "</script>")
                    if (idx > 0) { line = substr(line, idx + 9); in_skip = 0; continue }
                    idx = index(tolower(line), "</style>")
                    if (idx > 0) { line = substr(line, idx + 8); in_skip = 0; continue }
                    line = ""; break
                }
                low = tolower(line)
                s_idx = index(low, "<script")
                t_idx = index(low, "<style")
                pick = 0
                if (s_idx > 0 && (t_idx == 0 || s_idx < t_idx)) pick = s_idx
                else if (t_idx > 0) pick = t_idx
                if (pick == 0) break
                before = substr(line, 1, pick - 1)
                rest   = substr(line, pick)
                gt     = index(rest, ">")
                if (gt == 0) { line = before; in_skip = 1; break }
                rest = substr(rest, gt + 1)
                close_idx = index(tolower(rest), (s_idx > 0 && (t_idx == 0 || s_idx < t_idx)) ? "</script>" : "</style>")
                if (close_idx > 0) {
                    skip_len = (s_idx > 0 && (t_idx == 0 || s_idx < t_idx)) ? 9 : 8
                    line = before substr(rest, close_idx + skip_len)
                } else {
                    line = before; in_skip = 1
                }
            }
            gsub(/<!--[^>]*-->/, "", line)
            gsub(/<[^>]+>/, "", line)
            print line
        }
    ' "$input_file" | sed \
        -e 's/&nbsp;/ /g' \
        -e 's/&lt;/</g' \
        -e 's/&gt;/>/g' \
        -e 's/&quot;/"/g' \
        -e "s/&#39;/'/g" \
        -e "s/&apos;/'/g" \
        -e 's/&amp;/\&/g' \
        -e 's/[[:space:]]\{1,\}$//' | \
        awk 'BEGIN{blank=0} /^[[:space:]]*$/ {if(!blank) print ""; blank=1; next} {print; blank=0}')

    renderer="fallback-strip"
    printf '%s\n%s' "$renderer" "$rendered"
}

# _web_fetch_truncate_string <max_bytes> < stdin
# Trunca stdin a max_bytes y agrega marker explicito si recorto. Salida a stdout.
_web_fetch_truncate_string() {
    local max="$1"
    local tmp
    tmp=$(mktemp 2>/dev/null) || return 1
    cat > "$tmp"
    local size
    size=$(wc -c < "$tmp" | tr -d ' ')
    if [ "$size" -le "$max" ]; then
        cat "$tmp"
    else
        head -c "$max" "$tmp"
        printf '\n[...truncated %d of %d bytes...]\n' "$((size - max))" "$size"
    fi
    rm -f "$tmp"
}

# tool_web_fetch_handler <input_json>
tool_web_fetch_handler() {
    local input_json="$1"
    local url format max_bytes timeout_seconds
    local body_file meta_file
    local http_code content_type final_url size_download
    local curl_rc
    local user_agent max_redirects default_max_bytes
    local rendered_full renderer rendered_body

    if [ -z "$input_json" ]; then
        echo "web_fetch: missing input JSON" >&2
        return 2
    fi

    if ! url=$(echo "$input_json" | jq -re '.url' 2>/dev/null); then
        echo "web_fetch: missing required field 'url'" >&2
        return 2
    fi
    if [ -z "$url" ]; then
        echo "web_fetch: field 'url' must be a non-empty string" >&2
        return 2
    fi

    format=$(echo "$input_json" | jq -r '.format // "text"' 2>/dev/null)
    case "$format" in
        text|markdown|raw) : ;;
        *)
            echo "web_fetch: 'format' must be one of text|markdown|raw (got: $format)" >&2
            return 2
            ;;
    esac

    default_max_bytes="${CODER_WEB_FETCH_DEFAULT_MAX_BYTES:-204800}"
    if ! [[ "$default_max_bytes" =~ ^[1-9][0-9]*$ ]]; then
        echo "web_fetch: CODER_WEB_FETCH_DEFAULT_MAX_BYTES must be a positive integer (got: $default_max_bytes)" >&2
        return 1
    fi

    max_bytes=$(echo "$input_json" | jq -r ".max_bytes // ${default_max_bytes}" 2>/dev/null)
    if ! [[ "$max_bytes" =~ ^[1-9][0-9]*$ ]]; then
        echo "web_fetch: 'max_bytes' must be a positive integer (got: $max_bytes)" >&2
        return 2
    fi
    if [ "$max_bytes" -lt 1024 ] || [ "$max_bytes" -gt 2097152 ]; then
        echo "web_fetch: 'max_bytes' out of range [1024, 2097152] (got: $max_bytes)" >&2
        return 2
    fi

    timeout_seconds=$(echo "$input_json" | jq -r '.timeout_seconds // 30' 2>/dev/null)
    if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
        echo "web_fetch: 'timeout_seconds' must be a positive integer (got: $timeout_seconds)" >&2
        return 2
    fi
    if [ "$timeout_seconds" -lt 1 ] || [ "$timeout_seconds" -gt 300 ]; then
        echo "web_fetch: 'timeout_seconds' out of range [1, 300] (got: $timeout_seconds)" >&2
        return 2
    fi

    if ! _web_fetch_url_scheme_ok "$url"; then
        echo "web_fetch: only http:// and https:// URLs are allowed (got: $url)" >&2
        return 1
    fi

    if _web_fetch_url_blocks_metadata "$url"; then
        echo "web_fetch: refusing to fetch cloud metadata endpoint (169.254.169.254): $url" >&2
        return 1
    fi

    if ! declare -f confirm_permission >/dev/null 2>&1; then
        echo "web_fetch: lib/permissions.sh not loaded (confirm_permission undefined); refusing to fetch" >&2
        return 1
    fi

    if ! confirm_permission "web_fetch" "$url" "${CODER_YES:-0}"; then
        echo "web_fetch: permission denied" >&2
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "web_fetch: 'curl' not found in PATH" >&2
        return 1
    fi

    if ! body_file=$(mktemp 2>/dev/null); then
        echo "web_fetch: cannot create body tmpfile" >&2
        return 1
    fi
    if ! meta_file=$(mktemp 2>/dev/null); then
        rm -f "$body_file"
        echo "web_fetch: cannot create meta tmpfile" >&2
        return 1
    fi

    user_agent="${CODER_WEB_FETCH_USER_AGENT:-asis-coder/${VERSION:-dev}}"
    max_redirects="${CODER_WEB_FETCH_MAX_REDIRECTS:-5}"
    if ! [[ "$max_redirects" =~ ^[0-9]+$ ]]; then
        rm -f "$body_file" "$meta_file"
        echo "web_fetch: CODER_WEB_FETCH_MAX_REDIRECTS must be a non-negative integer (got: $max_redirects)" >&2
        return 1
    fi

    _web_fetch_curl "$body_file" "$meta_file" "$url" "$timeout_seconds" "$max_redirects" "$user_agent"
    curl_rc=$?

    if [ "$curl_rc" -ne 0 ]; then
        rm -f "$body_file" "$meta_file"
        echo "web_fetch: curl failed with exit $curl_rc for $url" >&2
        return 1
    fi

    http_code=$(sed -n '1p' "$meta_file")
    content_type=$(sed -n '2p' "$meta_file")
    final_url=$(sed -n '3p' "$meta_file")
    size_download=$(sed -n '4p' "$meta_file")
    [ -z "$http_code" ] && http_code="000"
    [ -z "$content_type" ] && content_type="(unknown)"
    [ -z "$final_url" ] && final_url="$url"
    [ -z "$size_download" ] && size_download="0"

    if [ "$format" = "raw" ]; then
        renderer="raw"
        rendered_body=$(cat "$body_file")
    else
        case "$content_type" in
            *text/html*|*application/xhtml*)
                rendered_full=$(_web_fetch_render_html "$body_file" "$format")
                renderer=$(printf '%s' "$rendered_full" | sed -n '1p')
                rendered_body=$(printf '%s' "$rendered_full" | sed '1d')
                ;;
            *)
                renderer="passthrough"
                rendered_body=$(cat "$body_file")
                ;;
        esac
    fi

    rm -f "$body_file" "$meta_file"

    rendered_body=$(printf '%s' "$rendered_body" | _web_fetch_truncate_string "$max_bytes")

    local final_bytes
    final_bytes=$(printf '%s' "$rendered_body" | wc -c | tr -d ' ')

    echo "web_fetch: status=${http_code} bytes=${final_bytes} content_type=${content_type} final_url=${final_url} renderer=${renderer}"
    echo "--- body ---"
    if [ -n "$rendered_body" ]; then
        printf '%s\n' "$rendered_body"
    else
        echo "(empty)"
    fi
    return 0
}
