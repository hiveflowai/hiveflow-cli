#!/bin/bash
#
# Smoke test de lib/agent/tools/hiveflow_mode.sh contra un servidor HTTP local.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
source "$REPO_ROOT/lib/agent/tool_calling.sh"
source "$REPO_ROOT/lib/agent/permissions.sh"
source "$REPO_ROOT/lib/agent/tools/hiveflow_mode.sh"

TMP=$(mktemp -d)
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM
export PERMISSIONS_CONFIG="$TMP/permissions.json" CONFIG_DIR="$TMP/cfg" CODER_YES=1
hf_auth_token() { printf '%s' "${FAKE_TOKEN-hf_test}"; }

cat > "$TMP/server.py" <<'EOF'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        open(sys.argv[2], 'w').write(json.dumps({'path': self.path, 'auth': self.headers.get('Authorization'), 'body': body}))
        code = body['code']
        status, out = 200, {'success': True, 'data': {'ok': True, 'output': 'result: 42'}}
        if code == 'fail': out = {'success': False, 'data': {'ok': False, 'output': 'error: [denied] no'}}
        if code == 'nocredits': status, out = 402, {'success': False}
        if code == 'old': status, out = 404, {}
        raw = json.dumps(out).encode()
        self.send_response(status); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
srv = http.server.HTTPServer(('127.0.0.1', 0), H)
open(sys.argv[1], 'w').write(str(srv.server_port))
srv.serve_forever()
EOF
python3 "$TMP/server.py" "$TMP/port" "$TMP/request.json" &
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
export HIVEFLOW_API_URL="http://127.0.0.1:$(cat "$TMP/port")"

PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
run() { OUT=$(tool_hiveflow_mode_handler "$1" 2>&1); RC=$?; }

check "definition is valid JSON" "hiveflow_mode" "$(tool_hiveflow_mode_definition | jq -r .name)"

run '{"code":"return \"ñ\"; // \"x\"","intent":"probar","timeout_seconds":30}'
check "ok exit code" "0" "$RC"
check "prints only the output" "result: 42" "$OUT"
check "posts to the run endpoint" "/api/hiveflow-mode/run" "$(jq -r .path "$TMP/request.json")"
check "sends the bearer token" "Bearer hf_test" "$(jq -r .auth "$TMP/request.json")"
check "keeps code intact" 'return "ñ"; // "x"' "$(jq -r .body.code "$TMP/request.json")"
check "maps timeout" "30" "$(jq -r .body.timeoutSeconds "$TMP/request.json")"

run '{"code":"fail"}';      check "failed script exit code" "1" "$RC"; check "failed script output" "error: [denied] no" "$OUT"
run '{"code":"nocredits"}'; check "402 exit code" "1" "$RC"; check "402 message" "hiveflow_mode: not enough credits" "$OUT"
run '{"code":"old"}';       check "404 explains" "hiveflow_mode: this backend does not support HiveFlow Mode yet" "$OUT"
run '{}';                   check "missing code" "2" "$RC"
run '{"code":"x","timeout_seconds":5}'; check "timeout out of range" "2" "$RC"

FAKE_TOKEN="" run '{"code":"x"}'
check "without session" "1" "$RC"

CODER_YES=0 run '{"code":"x"}' </dev/null
check "without permission" "1" "$RC"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
