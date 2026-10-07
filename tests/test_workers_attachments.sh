#!/bin/bash
#
# Workers con adjuntos grandes + motor Claude Code (lib/core/workers.sh):
#   · descarga de card.files a <cwd>/.hiveflow/cards/<id>/raw (403 → refresh-url, skip si mismo tamaño)
#   · parseo de líneas HF_ATTACH
#   · subida multipart simulada (init → PUT de partes → complete; abort si falla)
#   · engine=claude arma bien el comando (claude falso en el PATH, cwd correcto)
#   · pasada completa: sube el HF_ATTACH, updateCard con el archivo y comentario
#   · worker clásico (sin campos nuevos) se comporta igual que antes
#   · /worker set, /worker import y la línea del cron
# API simulada con HF_API_STUB; curl y claude falsos en el PATH. Sin red.
# Compatible con bash 3.2.

# shellcheck disable=SC2034  # variables leídas dentro de eval (check)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

TMP_DIR="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

export HOME="$TMP_DIR/home"
mkdir -p "$HOME"
export HF_CONFIG_DIR="$TMP_DIR/cfg"
export HF_CONFIG_FILE="$HF_CONFIG_DIR/config.json"
mkdir -p "$HF_CONFIG_DIR"
export HF_LANG=es
export HOSTNAME="${HOSTNAME:-testhost}"
BRAND="$TMP_DIR/marca"
mkdir -p "$BRAND"

cat > "$HF_CONFIG_FILE" <<EOF
{"workers":{
  "editor":{"board_id":"b1","chat_id":"","every":5,"playbook":"Edita el reel","parallel":false,
            "engine":"claude","cwd":"$BRAND","download_attachments":true,
            "columns":{"trigger":"To Do","working":"In Progress","review":"QA","human":"Human in the loop","error":"Error Auto"}},
  "clasico":{"board_id":"b1","chat_id":"","every":5,"playbook":"Califica el lead","parallel":false,
            "columns":{"trigger":"To Do","working":"In Progress","review":"QA","human":"Human in the loop","error":"Error Auto"}}
}}
EOF

# ── stubs de la base del CLI ─────────────────────────────────────────
HF_C_BOLD=''; HF_C_RESET=''; HF_C_DIM=''; HF_C_GREEN=''; HF_C_RED=''; HF_C_CYAN=''; HF_C_YELLOW=''
hf_t() { if [ "$HF_LANG" = "es" ] && [ $# -ge 2 ] && [ -n "$2" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
hf_config_get() { jq -r "$1 // empty" "$HF_CONFIG_FILE" 2>/dev/null; }
hf_auth_token() { echo tok; }
hf_ok() { echo "  ✓ $*"; }
hf_err() { echo "  ✗ $*" >&2; }
hf_info() { echo "  › $*"; }
hf_warn() { echo "  ! $*"; }
hf_dim() { echo "  $*"; }
hf_prompt() { return 1; }   # sin prompt-pack: usa el fallback local

# shellcheck source=../lib/core/tools.sh disable=SC1091
source "$REPO_ROOT/lib/core/tools.sh"
# shellcheck source=../lib/core/tickets.sh disable=SC1091
source "$REPO_ROOT/lib/core/tickets.sh"
# shellcheck source=../lib/core/workers.sh disable=SC1091
source "$REPO_ROOT/lib/core/workers.sh"

# Agente nativo falso: registra dónde corrió y el prompt
hf_agent_run() {
  pwd -P > "$TMP_DIR/native.pwd"
  printf '%s' "$1" > "$TMP_DIR/native.prompt"
  echo "RESULT: done | ok nativo"
}

# crontab en un archivo
crontab() {
  if [ "${1:-}" = "-l" ]; then cat "$TMP_DIR/crontab" 2>/dev/null; else cat > "$TMP_DIR/crontab"; fi
}

# ── tablero simulado ─────────────────────────────────────────────────
CARD_FILES='[]'
write_board() {
  jq -nc --argjson f "$CARD_FILES" '{_id:"b1", name:"Hiveflow Content", data:{
    columns:["To Do","In Progress","QA","Human in the loop"],
    cards:[{id:"c1", title:"Reel de prueba", description:"edita", column:"To Do", files:$f, comments:[]}]}}' \
    > "$TMP_DIR/board.json"
}

# ── API falsa (HF_API_STUB): log + respuestas por ruta ───────────────
export API_LOG="$TMP_DIR/api.log" TMP_DIR
: > "$API_LOG"
cat > "$TMP_DIR/api_stub.sh" <<'STUB'
#!/bin/bash
method="$1"; path="$2"; body="${3:-}"
printf '%s %s %s\n' "$method" "$path" "$body" >> "$API_LOG"
case "$method $path" in
  "GET /app-instances/b1") cat "$TMP_DIR/board.json" ;;
  "PATCH /app-instances/b1/data") echo '{"ok":true}' ;;
  "POST /files/refresh-url") echo '{"success":true,"url":"http://fake/ok/refirmado.bin","expiresIn":86400}' ;;
  "POST /files/multipart/init")
    if [ -f "$TMP_DIR/init_fail_parts" ]; then
      echo '{"uploadId":"U1","key":"user-data/u1/kanban/1-x.mp4","partSize":10,"parts":[{"partNumber":1,"url":"http://s3/fail1"},{"partNumber":2,"url":"http://s3/fail2"},{"partNumber":3,"url":"http://s3/fail3"}]}'
    else
      echo '{"uploadId":"U1","key":"user-data/u1/kanban/1-x.mp4","partSize":10,"parts":[{"partNumber":2,"url":"http://s3/p2"},{"partNumber":1,"url":"http://s3/p1"},{"partNumber":3,"url":"http://s3/p3"}]}'
    fi ;;
  "POST /files/multipart/complete")
    name="$(printf '%s' "$body" | jq -r '.key | split("/") | last')"
    jq -nc --arg n "$name" '{id:"f-1", name:"edit.mp4", key:"user-data/u1/kanban/1-x.mp4", url:"https://s3/get/1-x.mp4?sig=1", mimeType:"video/mp4", size:25}' ;;
  "POST /files/multipart/abort") echo '{"success":true}' ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$TMP_DIR/api_stub.sh"
export HF_API_STUB="$TMP_DIR/api_stub.sh"

# ── curl y claude falsos en el PATH ──────────────────────────────────
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/s3"
export CURL_LOG="$TMP_DIR/curl.log"
: > "$CURL_LOG"
cat > "$TMP_DIR/bin/curl" <<'FAKE'
#!/bin/bash
out=""; wfmt=""; upload=""; hdr=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -w) wfmt="$2"; shift ;;
    -T) upload="$2"; shift ;;
    -D) hdr="$2"; shift ;;
    -X|-H|--connect-timeout|--retry|-m|-d) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
echo "$url" >> "$CURL_LOG"
code=200
case "$url" in
  http://fake/expired/*) code=403 ;;
  http://fake/ok/*) printf 'VIDEO-%s' "${url##*/}" > "$out" ;;
  http://s3/fail*) code=500 ;;
  http://s3/p*) n="${url##*/p}"; cp "$upload" "$TMP_DIR/s3/part$n"
                printf 'HTTP/1.1 200 OK\r\nETag: "etag-%s"\r\n\r\n' "$n" > "$hdr" ;;
  *) code=404 ;;
esac
[ -n "$wfmt" ] && printf '%s' "$code"
exit 0
FAKE
cat > "$TMP_DIR/bin/claude" <<'FAKE'
#!/bin/bash
pwd -P > "$TMP_DIR/claude.pwd"
: > "$TMP_DIR/claude.args"
for a in "$@"; do printf '%s\n---\n' "$a" >> "$TMP_DIR/claude.args"; done
outd="$PWD/.hiveflow/cards/c1/out"
printf '0123456789abcdefghijKLMNO' > "$outd/edit.mp4"
echo "Listo, edité el reel."
echo "HF_ATTACH: $outd/edit.mp4"
echo "HF_ATTACH: /etc/passwd"
echo "RESULT: done | reel editado"
FAKE
chmod +x "$TMP_DIR/bin/curl" "$TMP_DIR/bin/claude"
export PATH="$TMP_DIR/bin:$PATH"

# ── mini framework ───────────────────────────────────────────────────
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ✓ $1"; }
bad() { fail=$((fail + 1)); echo "  ✗ $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "== parseo de HF_ATTACH =="
parsed="$(_hf_parse_attach "hola
HF_ATTACH: /a/b/uno.mp4
  - HF_ATTACH: \`/a/b/dos.mov\`
HF_ATTACH: \"/a/b/tres con espacio.wav\"
texto HF_ATTACH: /no/cuenta
HF_ATTACH: /a/b/uno.mp4
RESULT: done | x")"
check "tres rutas únicas" '[ "$(printf "%s\n" "$parsed" | wc -l | tr -d " ")" = "3" ]'
check "ruta simple" 'printf "%s\n" "$parsed" | grep -qx "/a/b/uno.mp4"'
check "quita backticks y viñeta" 'printf "%s\n" "$parsed" | grep -qx "/a/b/dos.mov"'
check "quita comillas, conserva espacios" 'printf "%s\n" "$parsed" | grep -qx "/a/b/tres con espacio.wav"'
check "no toma HF_ATTACH a media línea" '! printf "%s\n" "$parsed" | grep -q "/no/cuenta"'

echo "== descarga de adjuntos =="
RAW="$TMP_DIR/dl/raw"
CARD="$(jq -nc '{id:"c1", files:[
  {name:"crudo.mp4", url:"http://fake/ok/crudo.mp4", size:15, mimeType:"video/mp4"},
  {name:"viejo.mov", url:"http://fake/expired/viejo.mov", key:"user-data/u1/kanban/viejo.mov"},
  {name:"../../malo.wav", url:"http://fake/ok/malo.wav"},
  {name:"perdido.mp4", url:"http://fake/expired/perdido.mp4"}]}')"
dl_out="$(_hf_worker_download_files editor "$CARD" "$RAW")"
check "baja el adjunto con su URL" '[ "$(cat "$RAW/crudo.mp4")" = "VIDEO-crudo.mp4" ]'
check "403 + key → refresh-url y reintento" '[ -f "$RAW/viejo.mov" ] && grep -q "POST /files/refresh-url .*user-data/u1/kanban/viejo.mov" "$API_LOG"'
check "el nombre no escapa de raw/" '[ -f "$RAW/malo.wav" ] && [ ! -e "$TMP_DIR/malo.wav" ]'
check "403 sin key → aviso, sin archivo" '[ ! -e "$RAW/perdido.mp4" ] && printf "%s" "$dl_out" | grep -q "no se pudo descargar perdido.mp4"'
check "no deja .part" '[ -z "$(find "$RAW" -name "*.part")" ]'
n_before="$(grep -c "fake/ok/crudo.mp4" "$CURL_LOG")"
dl_out2="$(_hf_worker_download_files editor "$CARD" "$RAW")"
check "mismo tamaño → se salta" '[ "$(grep -c "fake/ok/crudo.mp4" "$CURL_LOG")" = "$n_before" ] && printf "%s" "$dl_out2" | grep -q "ya descargado: crudo.mp4"'

echo "== subida multipart simulada =="
UP="$TMP_DIR/up/edit.mp4"; mkdir -p "$TMP_DIR/up"
printf '0123456789abcdefghijKLMNO' > "$UP"   # 25 B → 3 partes de 10
: > "$API_LOG"
fjson="$(hf_files_upload_multipart "$UP" kanban)"; rc=$?
check "rc 0 y JSON con key" '[ "$rc" = 0 ] && [ "$(printf "%s" "$fjson" | jq -r .key)" = "user-data/u1/kanban/1-x.mp4" ]'
check "init manda nombre, tamaño y folder" 'grep "POST /files/multipart/init" "$API_LOG" | grep -q "\"fileName\":\"edit.mp4\".*\"size\":25,\"folder\":\"kanban\""'
check "las partes reconstruyen el archivo" '[ "$(cat "$TMP_DIR/s3/part1" "$TMP_DIR/s3/part2" "$TMP_DIR/s3/part3")" = "$(cat "$UP")" ]'
cbody="$(grep "POST /files/multipart/complete" "$API_LOG" | sed "s|^POST /files/multipart/complete ||")"
check "complete con ETags en orden" '[ "$(printf "%s" "$cbody" | jq -c "[.parts[] | [.PartNumber, .ETag]]")" = "[[1,\"\\\"etag-1\\\"\"],[2,\"\\\"etag-2\\\"\"],[3,\"\\\"etag-3\\\"\"]]" ]'
touch "$TMP_DIR/init_fail_parts"; : > "$API_LOG"
hf_files_upload_multipart "$UP" kanban >/dev/null 2>"$TMP_DIR/up.err"; rc=$?
rm -f "$TMP_DIR/init_fail_parts"
check "PUT falla → rc≠0 y abort" '[ "$rc" != 0 ] && grep -q "POST /files/multipart/abort .*U1" "$API_LOG" && ! grep -q "multipart/complete" "$API_LOG"'

echo "== engine=claude arma el comando =="
CARD_FILES='[{"name":"crudo.mp4","url":"http://fake/ok/crudo.mp4","size":15}]'
write_board
card1="$(jq -c '.data.cards[0]' "$TMP_DIR/board.json")"
aout="$(_hf_worker_agent_card editor "$card1")"
check "claude corre en el cwd del worker" '[ "$(cat "$TMP_DIR/claude.pwd")" = "$BRAND" ]'
check "args: -p <prompt> ... --dangerously-skip-permissions --output-format text" \
  'awk "/^---\$/{next} {print}" "$TMP_DIR/claude.args" | head -1 | grep -qx -- "-p" && grep -qx -- "--dangerously-skip-permissions" "$TMP_DIR/claude.args" && grep -A2 -x -- "--output-format" "$TMP_DIR/claude.args" | grep -qx text'
check "el prompt trae la ruta de los adjuntos descargados" 'grep -q "$BRAND/.hiveflow/cards/c1/raw/crudo.mp4" "$TMP_DIR/claude.args"'
check "el prompt trae la regla HF_ATTACH y la carpeta out/" 'grep -q "HF_ATTACH:" "$TMP_DIR/claude.args" && grep -q "$BRAND/.hiveflow/cards/c1/out/" "$TMP_DIR/claude.args"'
check "salida con RESULT" 'printf "%s" "$aout" | grep -q "^RESULT: done | reel editado"'
check "adjunto descargado en raw/" '[ -f "$BRAND/.hiveflow/cards/c1/raw/crudo.mp4" ]'
check ".hiveflow/ ignorado por git" '[ "$(cat "$BRAND/.hiveflow/.gitignore")" = "*" ]'

echo "== pasada completa: sube HF_ATTACH y lo agrega a la card =="
rm -rf "$BRAND/.hiveflow"; : > "$API_LOG"
pass_out="$(_hf_worker_run_inner editor 2>&1)"
check "multipart init + complete" 'grep -q "POST /files/multipart/init" "$API_LOG" && grep -q "POST /files/multipart/complete" "$API_LOG"'
upd="$(grep "PATCH /app-instances/b1/data .*\"op\":\"updateCard\"" "$API_LOG" | grep "user-data/u1/kanban/1-x.mp4" | head -1 | sed "s|^PATCH /app-instances/b1/data ||")"
check "updateCard agrega el archivo a card.files (conserva los previos)" '[ "$(printf "%s" "$upd" | jq -r ".payload.cardId")" = "c1" ] && [ "$(printf "%s" "$upd" | jq -r "[.payload.updates.files[].name] | join(\",\")")" = "crudo.mp4,edit.mp4" ]'
check "comenta 'adjunté edit.mp4 (… MB)'" 'printf "%s" "$upd" | jq -r ".payload.updates.comments[-1] | \"\(.author): \(.text)\"" | grep -q "^worker:editor: adjunté edit.mp4 (0.0 MB)"'
check "HF_ATTACH fuera de out/ no se sube" 'printf "%s" "$pass_out" | grep -q "fuera de out/, ignorado: /etc/passwd" && [ "$(grep -c "POST /files/multipart/init" "$API_LOG")" = 1 ]'
check "la card termina en QA" 'grep "PATCH /app-instances/b1/data" "$API_LOG" | tail -1 | grep -q "\"column\":\"QA\""'
check "el archivo sigue en disco" '[ -f "$BRAND/.hiveflow/cards/c1/out/edit.mp4" ]'

echo "== subida fallida: comenta el error y deja el archivo =="
touch "$TMP_DIR/init_fail_parts"; : > "$API_LOG"
_hf_worker_attach_outputs editor b1 c1 "$BRAND/.hiveflow/cards/c1" "HF_ATTACH: $BRAND/.hiveflow/cards/c1/out/edit.mp4" >/dev/null
rm -f "$TMP_DIR/init_fail_parts"
check "comentario de error y archivo intacto" 'grep "updateCard" "$API_LOG" | grep -q "no pude subir edit.mp4" && [ -f "$BRAND/.hiveflow/cards/c1/out/edit.mp4" ]'

echo "== worker clásico: igual que antes =="
: > "$CURL_LOG"; : > "$API_LOG"
CARD_FILES='[{"name":"crudo.mp4","url":"http://fake/ok/crudo.mp4","size":15}]'
write_board
mkdir -p "$TMP_DIR/elsewhere"
cout="$(cd "$TMP_DIR/elsewhere" && _hf_worker_agent_card clasico "$card1")"
check "corre donde lo lanzan (sin cd)" '[ "$(cat "$TMP_DIR/native.pwd")" = "$TMP_DIR/elsewhere" ]'
check "sin descargas" '[ ! -s "$CURL_LOG" ] && [ ! -e "$HOME/.hiveflow" ] && [ ! -e "$TMP_DIR/elsewhere/.hiveflow" ]'
check "prompt sin regla HF_ATTACH" '! grep -q "HF_ATTACH" "$TMP_DIR/native.prompt"'
check "salida intacta" '[ "$cout" = "RESULT: done | ok nativo" ]'

echo "== engine=native con cwd =="
jq --arg d "$BRAND" '.workers.nativo = (.workers.clasico + {engine:"native", cwd:$d, download_attachments:false})' "$HF_CONFIG_FILE" > "$TMP_DIR/c.json" && mv "$TMP_DIR/c.json" "$HF_CONFIG_FILE"
: > "$CURL_LOG"
_hf_worker_agent_card nativo "$card1" >/dev/null
check "agente nativo corre en cwd" '[ "$(cat "$TMP_DIR/native.pwd")" = "$BRAND" ]'
check "download_attachments=false no descarga" '[ ! -s "$CURL_LOG" ] && grep -q "HF_ATTACH" "$TMP_DIR/native.prompt"'

echo "== /worker set, import y cron =="
hf_worker_set clasico cwd relativo/x >/dev/null 2>&1
check "set cwd relativo se rechaza" '[ -z "$(jq -r ".workers.clasico.cwd // empty" "$HF_CONFIG_FILE")" ]'
hf_worker_set clasico download_attachments false >/dev/null
check "set download_attachments false (bool)" '[ "$(jq -c ".workers.clasico.download_attachments" "$HF_CONFIG_FILE")" = "false" ] && [ "$(_hf_worker_dl clasico)" = "false" ]'
hf_worker_set clasico engine gpt >/dev/null 2>&1
check "set engine inválido se rechaza" '[ -z "$(jq -r ".workers.clasico.engine // empty" "$HF_CONFIG_FILE")" ]'
hf_worker_set clasico timeout 3600 >/dev/null
check "set timeout" '[ "$(jq -c ".workers.clasico.timeout" "$HF_CONFIG_FILE")" = "3600" ]'
mkdir -p "$TMP_DIR/con espacio"
hf_worker_set clasico cwd "$TMP_DIR/con" "espacio" >/dev/null
check "set cwd con espacios" '[ "$(jq -r ".workers.clasico.cwd" "$HF_CONFIG_FILE")" = "$TMP_DIR/con espacio" ]'

hf_worker_run() { :; }   # import lanza una pasada en segundo plano: no aquí
b64="$(jq -nc --arg d "$BRAND" '{name:"web-claude", board_id:"b1", playbook:"x", engine:"claude", cwd:$d, download_attachments:false, cron:false}' | base64 | tr -d '\n')"
hf_worker_import "$b64" >/dev/null
check "import con campos nuevos" '[ "$(jq -c ".workers[\"web-claude\"] | [.engine, .cwd, .download_attachments]" "$HF_CONFIG_FILE")" = "$(jq -nc --arg d "$BRAND" "[\"claude\", \$d, false]")" ]'
b64="$(jq -nc '{name:"web-viejo", board_id:"b1", playbook:"x", cron:false}' | base64 | tr -d '\n')"
hf_worker_import "$b64" >/dev/null
check "import sin campos nuevos → worker clásico" '! _hf_worker_has_new_fields web-viejo'

hf_worker_cron on editor >/dev/null
check "cron hace cd al cwd" 'grep "# hiveflow-worker-editor$" "$TMP_DIR/crontab" | grep -q "^\*/5 \* \* \* \* cd $BRAND && PATH="'
check "cron con el bin de claude en el PATH" 'grep "# hiveflow-worker-editor$" "$TMP_DIR/crontab" | grep -q "PATH=[^ ]*$TMP_DIR/bin"'
hf_worker_cron on web-viejo >/dev/null
check "cron de un worker clásico sin cd" 'grep "# hiveflow-worker-web-viejo$" "$TMP_DIR/crontab" | grep -q "^\*/5 \* \* \* \* PATH="'
show_out="$(hf_worker_show editor)"
check "show muestra motor y carpeta" 'printf "%s" "$show_out" | grep -q "Motor:    claude" && printf "%s" "$show_out" | grep -q "Carpeta:  $BRAND"'

echo ""
echo "Resultado: $pass ok, $fail fallos"
[ "$fail" -eq 0 ]
