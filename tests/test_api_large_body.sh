#!/usr/bin/env bash
# Regresión: hf_api manda el body por stdin. Un tablero de varios MB como argumento
# rompía con "Argument list too long" y las cards perdían sus adjuntos.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"; trap 'rm -rf "$TMP_DIR"' EXIT
export HF_CONFIG_DIR="$TMP_DIR/cfg" HF_CONFIG_FILE="$TMP_DIR/cfg/config.json"
mkdir -p "$HF_CONFIG_DIR" "$TMP_DIR/bin"; echo '{"tickets":{"api_url":"http://stub"}}' > "$HF_CONFIG_FILE"
# curl falso: guarda lo que llega por stdin y responde ok
cat > "$TMP_DIR/bin/curl" <<'C'
#!/usr/bin/env bash
cat > "$CURL_BODY_OUT"; echo '{"success":true,"data":{"ok":true}}'
C
chmod +x "$TMP_DIR/bin/curl"; export PATH="$TMP_DIR/bin:$PATH" CURL_BODY_OUT="$TMP_DIR/body.json"
hf_t() { printf '%s' "${2:-$1}"; }; hf_config_get() { jq -r "$1 // empty" "$HF_CONFIG_FILE" 2>/dev/null; }; hf_auth_token() { echo tok; }
# shellcheck source=../lib/core/tickets.sh disable=SC1091
source "$REPO_ROOT/lib/core/tickets.sh"
pass=0; fail=0
cards="$(python3 -c 'import json;print(json.dumps([{"id":f"c{i}","description":"x"*40000} for i in range(100)]))')"
body="$(printf '%s' "$cards" | jq -c '{op:"set", payload:{fields:{cards:.}}}')"
out="$(hf_api PATCH /app-instances/b1/data "$body")"
if [ "$(jq -r '.ok' <<<"$out")" = "true" ] && [ "$(wc -c < "$TMP_DIR/body.json")" -gt 3000000 ]; then pass=$((pass+1)); echo "  ✓ body de $(wc -c < "$TMP_DIR/body.json" | tr -d ' ') bytes llega completo por stdin"; else fail=$((fail+1)); echo "  ✗ body grande no llegó completo"; fi
echo "Resultado: $pass ok, $fail fallos"; [ "$fail" -eq 0 ]
