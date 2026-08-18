#!/bin/bash
#
# Smoke test standalone para lib/tools/web_fetch.sh
# - Aisla PERMISSIONS_CONFIG / CONFIG_DIR en tmpdir.
# - Stubea _web_fetch_curl en una fn override que escribe fixture body+meta
#   sin tocar la red. Estado entre invocaciones (counter / captura) via filesystem
#   (heredado del patron iter 9 de tests del agentic loop).
# - CODER_YES=1 por default; tests de "denied" lo overridean en la invocacion.
# - Exit != 0 si algun assert falla.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# shellcheck source=../lib/tool_calling.sh disable=SC1091
source "$REPO_ROOT/lib/agent/tool_calling.sh"
# shellcheck source=../lib/permissions.sh disable=SC1091
source "$REPO_ROOT/lib/agent/permissions.sh"

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT INT TERM

export PERMISSIONS_CONFIG="$TMPDIR_TEST/permissions.json"
export CONFIG_DIR="$TMPDIR_TEST/cfg"
export CODER_YES=1

mkdir -p "$TMPDIR_TEST/work"
cd "$TMPDIR_TEST/work"

# Fixture dirs para el stub de curl.
FIXTURE_DIR="$TMPDIR_TEST/fixtures"
mkdir -p "$FIXTURE_DIR"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1"; local expected="$2"; local actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1"; local needle="$2"; local haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (missing: '$needle')"
        echo "       output was: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1"; local needle="$2"; local haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo "  FAIL: $desc (should NOT contain: '$needle')"
        echo "       output was: $haystack"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    fi
}

# --- Registracion + definition ---
# IMPORTANTE: el override de _web_fetch_curl debe ir DESPUES de register_tool,
# porque al sourcear lib/tools/web_fetch.sh se define la version real (sobreescribiendo
# cualquier stub previo). Define stubs post-registracion.
echo "=== Test: registracion"
register_tool web_fetch

# Helper: setea una fixture (status, content_type, body) y override _web_fetch_curl
# para emitirla. Fixture-id es un slug usado para localizar en $FIXTURE_DIR.
_set_fixture() {
    local fid="$1"
    local status="$2"
    local content_type="$3"
    local body_path="$4"   # path a archivo con body
    local final_url="${5:-}"

    mkdir -p "$FIXTURE_DIR/$fid"
    echo "$status" > "$FIXTURE_DIR/$fid/status"
    echo "$content_type" > "$FIXTURE_DIR/$fid/ctype"
    cp "$body_path" "$FIXTURE_DIR/$fid/body"
    echo "${final_url}" > "$FIXTURE_DIR/$fid/final_url"
    export _WEB_FETCH_TEST_FIXTURE="$FIXTURE_DIR/$fid"
}

# Override real curl wrapper. Tests pueden cambiar comportamiento setando
# $_WEB_FETCH_TEST_FIXTURE a un dir con archivos status/ctype/body/final_url.
# Si $_WEB_FETCH_TEST_FORCE_RC esta seteado (entero), retornamos ese rc sin escribir nada.
# shellcheck disable=SC2317  # invocada indirectamente via tool_web_fetch_handler
_web_fetch_curl() {
    local body_file="$1"
    local meta_file="$2"
    local url="$3"

    if [ -n "${_WEB_FETCH_TEST_FORCE_RC:-}" ]; then
        return "$_WEB_FETCH_TEST_FORCE_RC"
    fi
    local fdir="${_WEB_FETCH_TEST_FIXTURE:-}"
    if [ -z "$fdir" ] || [ ! -d "$fdir" ]; then
        echo "TEST BUG: _web_fetch_curl called without fixture" >&2
        return 99
    fi
    local status ctype final_url size body_path
    status=$(cat "$fdir/status")
    ctype=$(cat "$fdir/ctype")
    final_url=$(cat "$fdir/final_url")
    [ -z "$final_url" ] && final_url="$url"
    body_path="$fdir/body"
    cp "$body_path" "$body_file"
    size=$(wc -c < "$body_path" | tr -d ' ')
    {
        echo "$status"
        echo "$ctype"
        echo "$final_url"
        echo "$size"
    } > "$meta_file"
    return 0
}

if list_registered_tools | grep -q '^web_fetch$'; then
    echo "  PASS: web_fetch en REGISTERED_TOOLS"; PASS=$((PASS + 1))
else
    echo "  FAIL: web_fetch no aparece en REGISTERED_TOOLS"; FAIL=$((FAIL + 1))
fi

echo "=== Test: definition emite JSON valido"
def=$(get_tool_definition web_fetch)
if echo "$def" | jq -e '.name == "web_fetch"' >/dev/null; then
    echo "  PASS: definition.name == web_fetch"; PASS=$((PASS + 1))
else
    echo "  FAIL: definition.name != web_fetch"; FAIL=$((FAIL + 1))
fi
if echo "$def" | jq -e '.input_schema.required | index("url")' >/dev/null; then
    echo "  PASS: definition requiere url"; PASS=$((PASS + 1))
else
    echo "  FAIL: definition no marca url como required"; FAIL=$((FAIL + 1))
fi
if echo "$def" | jq -e '.input_schema.properties.format.enum | sort == ["markdown","raw","text"]' >/dev/null; then
    echo "  PASS: format enum = [text, markdown, raw]"; PASS=$((PASS + 1))
else
    echo "  FAIL: format enum incorrecto"; FAIL=$((FAIL + 1))
fi

# --- Input validation ---
echo "=== Test: input vacio retorna exit 2"
set +e
out=$(tool_web_fetch_handler '' 2>&1); rc=$?
set -e
assert_eq "exit 2 input vacio" "2" "$rc"
assert_contains "menciona missing input JSON" "missing input JSON" "$out"

echo "=== Test: input sin url retorna exit 2"
set +e
out=$(tool_web_fetch_handler '{}' 2>&1); rc=$?
set -e
assert_eq "exit 2 sin url" "2" "$rc"
assert_contains "menciona missing url" "missing required field 'url'" "$out"

echo "=== Test: url vacia retorna exit 2"
set +e
out=$(tool_web_fetch_handler '{"url":""}' 2>&1); rc=$?
set -e
assert_eq "exit 2 url vacia" "2" "$rc"
assert_contains "menciona non-empty string" "non-empty string" "$out"

echo "=== Test: format invalido retorna exit 2"
set +e
out=$(tool_web_fetch_handler '{"url":"http://x","format":"yaml"}' 2>&1); rc=$?
set -e
assert_eq "exit 2 format invalido" "2" "$rc"
assert_contains "menciona format must be one of" "must be one of text|markdown|raw" "$out"

echo "=== Test: max_bytes fuera de rango retorna exit 2"
set +e
out=$(tool_web_fetch_handler '{"url":"http://x","max_bytes":100}' 2>&1); rc=$?
set -e
assert_eq "exit 2 max_bytes < 1024" "2" "$rc"
assert_contains "menciona out of range" "out of range" "$out"

set +e
out=$(tool_web_fetch_handler '{"url":"http://x","max_bytes":99999999}' 2>&1); rc=$?
set -e
assert_eq "exit 2 max_bytes > 2MB" "2" "$rc"

echo "=== Test: timeout_seconds fuera de rango retorna exit 2"
set +e
out=$(tool_web_fetch_handler '{"url":"http://x","timeout_seconds":0}' 2>&1); rc=$?
set -e
assert_eq "exit 2 timeout < 1" "2" "$rc"

set +e
out=$(tool_web_fetch_handler '{"url":"http://x","timeout_seconds":3600}' 2>&1); rc=$?
set -e
assert_eq "exit 2 timeout > 300" "2" "$rc"

set +e
out=$(tool_web_fetch_handler '{"url":"http://x","timeout_seconds":"abc"}' 2>&1); rc=$?
set -e
assert_eq "exit 2 timeout no integer" "2" "$rc"

# --- Scheme guards ---
echo "=== Test: scheme file:// rechazado"
set +e
out=$(tool_web_fetch_handler '{"url":"file:///etc/passwd"}' 2>&1); rc=$?
set -e
assert_eq "exit 1 file://" "1" "$rc"
assert_contains "menciona only http(s)" "only http:// and https://" "$out"

echo "=== Test: scheme ftp:// rechazado"
set +e
out=$(tool_web_fetch_handler '{"url":"ftp://ftp.example.com/x"}' 2>&1); rc=$?
set -e
assert_eq "exit 1 ftp://" "1" "$rc"

echo "=== Test: scheme javascript: rechazado"
set +e
out=$(tool_web_fetch_handler '{"url":"javascript:alert(1)"}' 2>&1); rc=$?
set -e
assert_eq "exit 1 javascript:" "1" "$rc"

echo "=== Test: scheme data: rechazado"
set +e
out=$(tool_web_fetch_handler '{"url":"data:text/html,foo"}' 2>&1); rc=$?
set -e
assert_eq "exit 1 data:" "1" "$rc"

echo "=== Test: scheme gopher:// rechazado"
set +e
out=$(tool_web_fetch_handler '{"url":"gopher://host:70/x"}' 2>&1); rc=$?
set -e
assert_eq "exit 1 gopher://" "1" "$rc"

echo "=== Test: url sin scheme rechazada"
set +e
out=$(tool_web_fetch_handler '{"url":"example.com/x"}' 2>&1); rc=$?
set -e
assert_eq "exit 1 sin scheme" "1" "$rc"

# --- SSRF / metadata service ---
echo "=== Test: metadata service 169.254.169.254 hard-deny"
set +e
out=$(tool_web_fetch_handler '{"url":"http://169.254.169.254/latest/meta-data"}' 2>&1); rc=$?
set -e
assert_eq "exit 1 metadata bare" "1" "$rc"
assert_contains "menciona metadata endpoint" "cloud metadata endpoint" "$out"

echo "=== Test: metadata service con puerto hard-deny"
set +e
out=$(tool_web_fetch_handler '{"url":"http://169.254.169.254:80/iam"}' 2>&1); rc=$?
set -e
assert_eq "exit 1 metadata con puerto" "1" "$rc"

echo "=== Test: metadata service con HTTPS hard-deny"
set +e
out=$(tool_web_fetch_handler '{"url":"https://169.254.169.254/computeMetadata/v1/"}' 2>&1); rc=$?
set -e
assert_eq "exit 1 metadata HTTPS" "1" "$rc"

echo "=== Test: metadata hard-deny gana sobre allowlist + CODER_YES=1"
permissions_init >/dev/null 2>&1 || true
permissions_allow "web_fetch" "*" >/dev/null 2>&1
set +e
out=$(tool_web_fetch_handler '{"url":"http://169.254.169.254/"}' 2>&1); rc=$?
set -e
assert_eq "exit 1 metadata aun con allow *" "1" "$rc"
permissions_remove "allow" "web_fetch" "*" >/dev/null 2>&1 || true

# --- Happy paths con fixture stub ---
echo "=== Test: format=raw devuelve body verbatim"
echo "hello world" > "$TMPDIR_TEST/plain.txt"
_set_fixture raw1 "200" "text/plain; charset=utf-8" "$TMPDIR_TEST/plain.txt" "http://example.com/plain"
set +e
out=$(tool_web_fetch_handler '{"url":"http://example.com/plain","format":"raw"}' 2>&1); rc=$?
set -e
assert_eq "exit 0 happy raw" "0" "$rc"
assert_contains "header status=200" "status=200" "$out"
assert_contains "header content_type=text/plain" "content_type=text/plain" "$out"
assert_contains "renderer=raw" "renderer=raw" "$out"
assert_contains "body --- body ---" "--- body ---" "$out"
assert_contains "body contains hello world" "hello world" "$out"

echo "=== Test: text/html con format=text strip HTML"
cat > "$TMPDIR_TEST/page.html" <<'EOF'
<!DOCTYPE html>
<html>
<head>
  <title>Demo</title>
  <style>body{color:red}</style>
  <script>alert("XSS_PAYLOAD")</script>
</head>
<body>
  <h1>Hola Mundo</h1>
  <p>Esto es un parrafo &amp; con entidades &lt;br&gt;.</p>
  <script>console.log("MORE_SCRIPT")</script>
</body>
</html>
EOF
_set_fixture html1 "200" "text/html; charset=utf-8" "$TMPDIR_TEST/page.html" "http://example.com/page"
set +e
out=$(tool_web_fetch_handler '{"url":"http://example.com/page","format":"text"}' 2>&1); rc=$?
set -e
assert_eq "exit 0 happy html" "0" "$rc"
assert_contains "header status=200" "status=200" "$out"
assert_contains "body contains Hola Mundo" "Hola Mundo" "$out"
assert_contains "body contains parrafo" "parrafo" "$out"
assert_not_contains "no XSS_PAYLOAD del script" "XSS_PAYLOAD" "$out"
assert_not_contains "no MORE_SCRIPT" "MORE_SCRIPT" "$out"
assert_not_contains "no etiqueta <h1>" "<h1>" "$out"
assert_not_contains "no &amp; literal" "&amp;" "$out"
assert_contains "decodifica & entity" "parrafo &" "$out"

echo "=== Test: non-HTML content-type pasa por passthrough"
echo '{"foo":"bar","n":42}' > "$TMPDIR_TEST/data.json"
_set_fixture json1 "200" "application/json" "$TMPDIR_TEST/data.json" "http://example.com/api"
set +e
out=$(tool_web_fetch_handler '{"url":"http://example.com/api"}' 2>&1); rc=$?
set -e
assert_eq "exit 0 json passthrough" "0" "$rc"
assert_contains "renderer=passthrough" "renderer=passthrough" "$out"
assert_contains "body has json content" '"foo":"bar"' "$out"

echo "=== Test: 404 status no rompe la tool"
echo "not found" > "$TMPDIR_TEST/404.txt"
_set_fixture err404 "404" "text/plain" "$TMPDIR_TEST/404.txt" "http://example.com/missing"
set +e
out=$(tool_web_fetch_handler '{"url":"http://example.com/missing","format":"raw"}' 2>&1); rc=$?
set -e
assert_eq "exit 0 con 404" "0" "$rc"
assert_contains "header status=404" "status=404" "$out"

echo "=== Test: body grande truncado a max_bytes con marker"
# Generar body de 5KB
yes "abcdefghij" 2>/dev/null | head -c 5120 > "$TMPDIR_TEST/big.txt" || true
_set_fixture big1 "200" "text/plain" "$TMPDIR_TEST/big.txt" "http://example.com/big"
set +e
out=$(tool_web_fetch_handler '{"url":"http://example.com/big","format":"raw","max_bytes":1024}' 2>&1); rc=$?
set -e
assert_eq "exit 0 big body" "0" "$rc"
assert_contains "marker de truncado" "truncated" "$out"
assert_contains "marker menciona bytes" "of 5120 bytes" "$out"

echo "=== Test: HTTPS scheme aceptado"
echo "ok" > "$TMPDIR_TEST/https.txt"
_set_fixture https1 "200" "text/plain" "$TMPDIR_TEST/https.txt" "https://example.com/x"
set +e
out=$(tool_web_fetch_handler '{"url":"https://example.com/x","format":"raw"}' 2>&1); rc=$?
set -e
assert_eq "exit 0 https" "0" "$rc"
assert_contains "https body ok" "ok" "$out"

# --- curl failure ---
echo "=== Test: curl fail (DNS / connect) propaga exit 1"
unset _WEB_FETCH_TEST_FIXTURE
export _WEB_FETCH_TEST_FORCE_RC=6   # 6 = couldn't resolve host
set +e
out=$(tool_web_fetch_handler '{"url":"http://nonexistent.invalid/x","format":"raw"}' 2>&1); rc=$?
set -e
unset _WEB_FETCH_TEST_FORCE_RC
assert_eq "exit 1 curl rc=6" "1" "$rc"
assert_contains "menciona curl failed" "curl failed with exit 6" "$out"

# --- Permission gating ---
echo "=== Test: permissions.sh no cargado -> exit 1"
echo "x" > "$TMPDIR_TEST/x.txt"
_set_fixture perm0 "200" "text/plain" "$TMPDIR_TEST/x.txt" "http://example.com/x"
set +e
out=$(bash -c "
    set -uo pipefail
    source '$REPO_ROOT/lib/agent/tool_calling.sh'
    # _web_fetch_curl override y CODER_YES vienen del padre; bash -c no los hereda
    # como functions, asi que esta variante prueba el caso real 'modulo no cargado'.
    export CODER_YES=1
    register_tool web_fetch >/dev/null 2>&1
    tool_web_fetch_handler '{\"url\":\"http://example.com/x\",\"format\":\"raw\"}' 2>&1
" 2>&1); rc=$?
set -e
assert_eq "exit 1 sin permissions.sh" "1" "$rc"
assert_contains "menciona permissions no cargado" "lib/permissions.sh not loaded" "$out"

echo "=== Test: denylist gana sobre CODER_YES=1"
permissions_init >/dev/null 2>&1 || true
permissions_deny "web_fetch" "http://blocked.example.com/*" >/dev/null 2>&1
echo "x" > "$TMPDIR_TEST/blocked.txt"
_set_fixture deny1 "200" "text/plain" "$TMPDIR_TEST/blocked.txt" "http://blocked.example.com/x"
set +e
out=$(CODER_YES=1 tool_web_fetch_handler '{"url":"http://blocked.example.com/x","format":"raw"}' 2>&1); rc=$?
set -e
assert_eq "exit 1 denylist match" "1" "$rc"
assert_contains "menciona permission denied" "permission denied" "$out"

echo "=== Test: allowlist con CODER_YES=0 permite"
permissions_allow "web_fetch" "http://allowed.example.com/*" >/dev/null 2>&1
echo "ok" > "$TMPDIR_TEST/allowed.txt"
_set_fixture allow1 "200" "text/plain" "$TMPDIR_TEST/allowed.txt" "http://allowed.example.com/x"
set +e
out=$(CODER_YES=0 tool_web_fetch_handler '{"url":"http://allowed.example.com/x","format":"raw"}' 2>&1); rc=$?
set -e
assert_eq "exit 0 allowlist con CODER_YES=0" "0" "$rc"
assert_contains "body contains ok" "ok" "$out"

echo "=== Test: needs-confirm sin TTY ni allowlist -> denied"
permissions_remove "allow" "web_fetch" "http://allowed.example.com/*" >/dev/null 2>&1 || true
set +e
out=$(CODER_YES=0 tool_web_fetch_handler '{"url":"http://noconfirm.example.com/x","format":"raw"}' 2>&1); rc=$?
set -e
assert_eq "exit 1 needs-confirm denied" "1" "$rc"

# --- dispatch via tool_calling registry ---
echo "=== Test: dispatch_tool web_fetch routing"
_set_fixture disp1 "200" "text/plain" "$TMPDIR_TEST/https.txt" "http://example.com/d"
set +e
out=$(dispatch_tool web_fetch '{"url":"http://example.com/d","format":"raw"}' 2>&1); rc=$?
set -e
assert_eq "dispatch exit 0" "0" "$rc"
assert_contains "dispatch body" "ok" "$out"

# --- Resumen ---
echo
echo "============================="
echo "Resultado: $PASS pass, $FAIL fail"
echo "============================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
