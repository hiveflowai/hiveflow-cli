#!/bin/bash
# tests/test_dynamic_models.sh
#
# Offline unit tests for lib/llm_dynamic_models.sh.
# Uses a tiny mock curl script (written into a tmpdir) that emits a canned
# JSON body to the file passed via `-o` and prints CODER_TEST_MOCK_HTTP_CODE
# (parsed by curl callers via `-w '%{http_code}'`).
#
# For pagination tests, the mock inspects the requested URL: if it contains
# either `after_id=` (Anthropic) or `pageToken=` (Gemini), it emits
# CODER_TEST_MOCK_BODY_PAGE2 / CODER_TEST_MOCK_HTTP_CODE_PAGE2; otherwise
# CODER_TEST_MOCK_BODY_PAGE1 / CODER_TEST_MOCK_HTTP_CODE_PAGE1, falling back
# to CODER_TEST_MOCK_BODY / CODER_TEST_MOCK_HTTP_CODE.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
TMPDIR_TEST=$(mktemp -d 2>/dev/null || mktemp -d -t coder_test_dyn_models)
# shellcheck disable=SC2317
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

note() { echo "$@"; }
pass_msg() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local actual="$1"
    local expected="$2"
    local desc="$3"
    if [ "$actual" = "$expected" ]; then
        pass_msg "$desc"
    else
        fail_msg "$desc (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local needle="$1"
    local haystack="$2"
    local desc="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        pass_msg "$desc"
    else
        fail_msg "$desc (missing: '$needle'; got: '$haystack')"
    fi
}

# ---------------------------------------------------------------------------
# Mock curl
# ---------------------------------------------------------------------------
cat > "$TMPDIR_TEST/mock_curl.sh" <<'MOCK_EOF'
#!/bin/bash
# Minimal mock of curl supporting the flags used by _dynamic_fetch_*_models.
output_file=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) output_file="$2"; shift 2 ;;
        -w) shift 2 ;;
        -m) shift 2 ;;
        -H) shift 2 ;;
        -s|-S|-sS) shift ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done

# Decide which body/http_code to emit based on URL contents (pagination).
# Cursor query params we recognize: `after_id=` (Anthropic), `pageToken=` (Gemini).
if [[ "$url" == *"after_id="* || "$url" == *"pageToken="* ]] && [ -n "${CODER_TEST_MOCK_BODY_PAGE2:-}" ]; then
    body="$CODER_TEST_MOCK_BODY_PAGE2"
    http="${CODER_TEST_MOCK_HTTP_CODE_PAGE2:-200}"
elif [ -n "${CODER_TEST_MOCK_BODY_PAGE1:-}" ]; then
    body="$CODER_TEST_MOCK_BODY_PAGE1"
    http="${CODER_TEST_MOCK_HTTP_CODE_PAGE1:-200}"
else
    body="${CODER_TEST_MOCK_BODY:-}"
    http="${CODER_TEST_MOCK_HTTP_CODE:-200}"
fi

if [ -n "$output_file" ]; then
    printf '%s' "$body" > "$output_file"
fi
printf '%s' "$http"
MOCK_EOF
chmod +x "$TMPDIR_TEST/mock_curl.sh"

export CODER_DYNAMIC_MODELS_CURL_BIN="$TMPDIR_TEST/mock_curl.sh"

# Source the module under test.
# shellcheck source=../lib/llm_dynamic_models.sh disable=SC1091
source "$REPO_ROOT/lib/agent/llm_dynamic_models.sh"

# ---------------------------------------------------------------------------
note "## Module wiring"
# ---------------------------------------------------------------------------
if declare -f _dynamic_fetch_anthropic_models >/dev/null 2>&1; then
    pass_msg "_dynamic_fetch_anthropic_models defined"
else
    fail_msg "_dynamic_fetch_anthropic_models not defined"
fi
assert_eq "${_LLM_DYNAMIC_MODELS_LOADED:-}" "1" "guard _LLM_DYNAMIC_MODELS_LOADED set"

# Double-source should be a no-op (guard works).
# shellcheck source=../lib/llm_dynamic_models.sh disable=SC1091
source "$REPO_ROOT/lib/agent/llm_dynamic_models.sh"
pass_msg "double-source guard (no error)"

# ---------------------------------------------------------------------------
note ""
note "## Anthropic: input validation"
# ---------------------------------------------------------------------------

set +e
out=$(_dynamic_fetch_anthropic_models "" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "2" "rc=2 on missing key (no arg)"
assert_eq "$out" "" "stdout empty on missing key"

set +e
err=$(_dynamic_fetch_anthropic_models "" 2>&1 >/dev/null)
set -e 2>/dev/null
assert_contains "empty api_key" "$err" "stderr mentions empty api_key"

# ---------------------------------------------------------------------------
note ""
note "## Anthropic: HTTP errors"
# ---------------------------------------------------------------------------

export CODER_TEST_MOCK_HTTP_CODE=401
export CODER_TEST_MOCK_BODY='{"type":"error","error":{"type":"invalid_request_error","message":"x-api-key header is invalid"}}'
unset CODER_TEST_MOCK_BODY_PAGE1 CODER_TEST_MOCK_BODY_PAGE2

set +e
out=$(_dynamic_fetch_anthropic_models "sk-ant-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "rc=1 on HTTP 401"
assert_eq "$out" "" "stdout empty on HTTP 401"

set +e
err=$(_dynamic_fetch_anthropic_models "sk-ant-fake" 2>&1 >/dev/null)
set -e 2>/dev/null
assert_contains "HTTP 401" "$err" "stderr mentions HTTP 401"

# HTTP 500 also surfaces as rc=1.
export CODER_TEST_MOCK_HTTP_CODE=500
export CODER_TEST_MOCK_BODY='{"type":"error","error":{"type":"overloaded_error"}}'
set +e
out=$(_dynamic_fetch_anthropic_models "sk-ant-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "rc=1 on HTTP 500"

# ---------------------------------------------------------------------------
note ""
note "## Anthropic: happy path (single page)"
# ---------------------------------------------------------------------------

export CODER_TEST_MOCK_HTTP_CODE=200
export CODER_TEST_MOCK_BODY='{"data":[{"id":"claude-opus-4-20250514","type":"model","display_name":"Claude Opus 4"},{"id":"claude-3-5-sonnet-20241022","type":"model"},{"id":"claude-3-5-haiku-20241022","type":"model"}],"has_more":false}'

set +e
out=$(_dynamic_fetch_anthropic_models "sk-ant-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "0" "rc=0 on happy path"
n=$(printf '%s\n' "$out" | grep -c .)
assert_eq "$n" "3" "3 model IDs emitted"
assert_contains "claude-opus-4-20250514" "$out" "stdout includes claude-opus-4-20250514"
assert_contains "claude-3-5-sonnet-20241022" "$out" "stdout includes claude-3-5-sonnet-20241022"
assert_contains "claude-3-5-haiku-20241022" "$out" "stdout includes claude-3-5-haiku-20241022"

# Order is preserved (first model in data[] is first on stdout).
first=$(printf '%s\n' "$out" | head -1)
assert_eq "$first" "claude-opus-4-20250514" "first emitted line preserves data[0].id"

# ---------------------------------------------------------------------------
note ""
note "## Anthropic: empty data + malformed responses"
# ---------------------------------------------------------------------------

export CODER_TEST_MOCK_BODY='{"data":[],"has_more":false}'
set +e
out=$(_dynamic_fetch_anthropic_models "sk-ant-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "rc=1 on empty data array"
assert_eq "$out" "" "stdout empty on empty data array"

set +e
err=$(_dynamic_fetch_anthropic_models "sk-ant-fake" 2>&1 >/dev/null)
set -e 2>/dev/null
assert_contains "empty model list" "$err" "stderr mentions empty model list"

# Malformed: missing `data` field entirely.
export CODER_TEST_MOCK_BODY='{"oops":"no data field"}'
set +e
out=$(_dynamic_fetch_anthropic_models "sk-ant-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "rc=1 on missing 'data' field"

set +e
err=$(_dynamic_fetch_anthropic_models "sk-ant-fake" 2>&1 >/dev/null)
set -e 2>/dev/null
assert_contains "missing 'data'" "$err" "stderr mentions missing 'data' field"

# Not even valid JSON.
export CODER_TEST_MOCK_BODY='<html>internal server error</html>'
set +e
out=$(_dynamic_fetch_anthropic_models "sk-ant-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "rc=1 on non-JSON body"

# ---------------------------------------------------------------------------
note ""
note "## Anthropic: pagination (2 pages)"
# ---------------------------------------------------------------------------

unset CODER_TEST_MOCK_BODY CODER_TEST_MOCK_HTTP_CODE
export CODER_TEST_MOCK_HTTP_CODE_PAGE1=200
export CODER_TEST_MOCK_HTTP_CODE_PAGE2=200
export CODER_TEST_MOCK_BODY_PAGE1='{"data":[{"id":"claude-opus-4-20250514"},{"id":"claude-sonnet-4-20250514"}],"has_more":true,"last_id":"claude-sonnet-4-20250514"}'
export CODER_TEST_MOCK_BODY_PAGE2='{"data":[{"id":"claude-3-5-sonnet-20241022"},{"id":"claude-3-5-haiku-20241022"}],"has_more":false}'

set +e
out=$(_dynamic_fetch_anthropic_models "sk-ant-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "0" "rc=0 on 2-page pagination"
n=$(printf '%s\n' "$out" | grep -c .)
assert_eq "$n" "4" "4 IDs emitted across 2 pages"
assert_contains "claude-opus-4-20250514" "$out" "page-1 model claude-opus-4-20250514 present"
assert_contains "claude-3-5-haiku-20241022" "$out" "page-2 model claude-3-5-haiku-20241022 present"

# Order is preserved across pages.
first=$(printf '%s\n' "$out" | head -1)
last=$(printf '%s\n' "$out" | grep . | tail -1)
assert_eq "$first" "claude-opus-4-20250514" "page-1 first ID first overall"
assert_eq "$last" "claude-3-5-haiku-20241022" "page-2 last ID last overall"

# ---------------------------------------------------------------------------
note ""
note "## Anthropic: dedupe across pages (defensive)"
# ---------------------------------------------------------------------------

export CODER_TEST_MOCK_BODY_PAGE1='{"data":[{"id":"claude-opus-4-20250514"},{"id":"claude-sonnet-4-20250514"}],"has_more":true,"last_id":"claude-sonnet-4-20250514"}'
export CODER_TEST_MOCK_BODY_PAGE2='{"data":[{"id":"claude-sonnet-4-20250514"},{"id":"claude-3-5-haiku-20241022"}],"has_more":false}'

set +e
out=$(_dynamic_fetch_anthropic_models "sk-ant-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "0" "rc=0 with duplicate ID across pages"
n=$(printf '%s\n' "$out" | grep -c .)
assert_eq "$n" "3" "duplicate claude-sonnet-4 deduped (3 unique IDs)"
sonnet_count=$(printf '%s\n' "$out" | grep -c '^claude-sonnet-4-20250514$')
assert_eq "$sonnet_count" "1" "claude-sonnet-4 appears exactly once after dedupe"

# ---------------------------------------------------------------------------
note ""
note "## Anthropic: pagination max_pages cap"
# ---------------------------------------------------------------------------

# Server keeps returning has_more=true with a fresh cursor each time. With
# CODER_DYNAMIC_MODELS_MAX_PAGES=2, the loop should fetch at most 2 pages and
# return what it has so far (still rc=0 since IDs were collected).
export CODER_DYNAMIC_MODELS_MAX_PAGES=2
export CODER_TEST_MOCK_BODY_PAGE1='{"data":[{"id":"m1"}],"has_more":true,"last_id":"m1"}'
# Page 2: also has_more=true but we should stop after this fetch.
export CODER_TEST_MOCK_BODY_PAGE2='{"data":[{"id":"m2"}],"has_more":true,"last_id":"m2"}'

set +e
out=$(_dynamic_fetch_anthropic_models "sk-ant-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "0" "rc=0 when max_pages reached with IDs collected"
n=$(printf '%s\n' "$out" | grep -c .)
# 2 pages requested → m1 + m2.
assert_eq "$n" "2" "max_pages cap stops at 2 pages (got m1+m2)"

unset CODER_DYNAMIC_MODELS_MAX_PAGES

# ---------------------------------------------------------------------------
note ""
note "## Anthropic: cursor loop detection"
# ---------------------------------------------------------------------------

# Both pages claim has_more=true and return the same last_id → infinite-loop
# guard kicks in and the fn returns rc=1.
unset CODER_TEST_MOCK_BODY_PAGE1 CODER_TEST_MOCK_BODY_PAGE2
# A bug server: every response (page 1 + page 2) returns has_more=true with
# the same last_id="stuck". The mock can't distinguish page indexes by URL
# alone here — it only switches on after_id=. We exploit that: page 1 has no
# after_id, page 2+ all have after_id=stuck and get the same page-2 body
# which again says has_more+last_id=stuck.
export CODER_TEST_MOCK_BODY_PAGE1='{"data":[{"id":"m1"}],"has_more":true,"last_id":"stuck"}'
export CODER_TEST_MOCK_BODY_PAGE2='{"data":[{"id":"m1"}],"has_more":true,"last_id":"stuck"}'

set +e
err=$(_dynamic_fetch_anthropic_models "sk-ant-fake" 2>&1 >/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "rc=1 when cursor loops on same last_id"
assert_contains "cursor loop detected" "$err" "stderr mentions cursor loop"

# ===========================================================================
# OpenAI fetcher
# ===========================================================================

# Reset to single-body mock (OpenAI endpoint is non-paginated).
unset CODER_TEST_MOCK_BODY_PAGE1 CODER_TEST_MOCK_BODY_PAGE2
unset CODER_TEST_MOCK_HTTP_CODE_PAGE1 CODER_TEST_MOCK_HTTP_CODE_PAGE2
unset CODER_DYNAMIC_MODELS_OPENAI_FILTER

# ---------------------------------------------------------------------------
note ""
note "## OpenAI: module wiring"
# ---------------------------------------------------------------------------
if declare -f _dynamic_fetch_openai_models >/dev/null 2>&1; then
    pass_msg "_dynamic_fetch_openai_models defined"
else
    fail_msg "_dynamic_fetch_openai_models not defined"
fi

# ---------------------------------------------------------------------------
note ""
note "## OpenAI: input validation"
# ---------------------------------------------------------------------------

set +e
out=$(_dynamic_fetch_openai_models "" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "2" "openai rc=2 on missing key"
assert_eq "$out" "" "openai stdout empty on missing key"

set +e
err=$(_dynamic_fetch_openai_models "" 2>&1 >/dev/null)
set -e 2>/dev/null
assert_contains "empty api_key" "$err" "openai stderr mentions empty api_key"

# ---------------------------------------------------------------------------
note ""
note "## OpenAI: HTTP errors"
# ---------------------------------------------------------------------------

export CODER_TEST_MOCK_HTTP_CODE=401
export CODER_TEST_MOCK_BODY='{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}'

set +e
out=$(_dynamic_fetch_openai_models "sk-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "openai rc=1 on HTTP 401"
assert_eq "$out" "" "openai stdout empty on HTTP 401"

set +e
err=$(_dynamic_fetch_openai_models "sk-fake" 2>&1 >/dev/null)
set -e 2>/dev/null
assert_contains "HTTP 401" "$err" "openai stderr mentions HTTP 401"

export CODER_TEST_MOCK_HTTP_CODE=500
export CODER_TEST_MOCK_BODY='{"error":{"message":"server overloaded"}}'
set +e
out=$(_dynamic_fetch_openai_models "sk-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "openai rc=1 on HTTP 500"

# ---------------------------------------------------------------------------
note ""
note "## OpenAI: happy path (mixed catalog with filter)"
# ---------------------------------------------------------------------------

# A realistic-looking response containing chat models, embeddings, moderation,
# tts, whisper and dall-e. After default filter only chat-capable should survive.
export CODER_TEST_MOCK_HTTP_CODE=200
export CODER_TEST_MOCK_BODY='{"object":"list","data":[
    {"id":"gpt-4o","object":"model"},
    {"id":"gpt-4o-mini","object":"model"},
    {"id":"chatgpt-4o-latest","object":"model"},
    {"id":"o1","object":"model"},
    {"id":"o1-mini","object":"model"},
    {"id":"o3-mini","object":"model"},
    {"id":"text-embedding-3-small","object":"model"},
    {"id":"text-embedding-3-large","object":"model"},
    {"id":"tts-1","object":"model"},
    {"id":"whisper-1","object":"model"},
    {"id":"dall-e-3","object":"model"},
    {"id":"omni-moderation-latest","object":"model"}
]}'

set +e
out=$(_dynamic_fetch_openai_models "sk-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "0" "openai rc=0 on happy path"
n=$(printf '%s\n' "$out" | grep -c .)
assert_eq "$n" "6" "openai 6 chat-capable models survive filter"
assert_contains "gpt-4o" "$out" "openai stdout includes gpt-4o"
assert_contains "gpt-4o-mini" "$out" "openai stdout includes gpt-4o-mini"
assert_contains "chatgpt-4o-latest" "$out" "openai stdout includes chatgpt-4o-latest"
assert_contains "o1" "$out" "openai stdout includes o1"
assert_contains "o3-mini" "$out" "openai stdout includes o3-mini"

# Excluded by filter — assert NOT present.
if printf '%s' "$out" | grep -qE '^text-embedding-3-small$'; then
    fail_msg "openai text-embedding-3-small filtered out"
else
    pass_msg "openai text-embedding-3-small filtered out"
fi
if printf '%s' "$out" | grep -qE '^tts-1$'; then
    fail_msg "openai tts-1 filtered out"
else
    pass_msg "openai tts-1 filtered out"
fi
if printf '%s' "$out" | grep -qE '^whisper-1$'; then
    fail_msg "openai whisper-1 filtered out"
else
    pass_msg "openai whisper-1 filtered out"
fi
if printf '%s' "$out" | grep -qE '^dall-e-3$'; then
    fail_msg "openai dall-e-3 filtered out"
else
    pass_msg "openai dall-e-3 filtered out"
fi
if printf '%s' "$out" | grep -qE '^omni-moderation-latest$'; then
    fail_msg "openai omni-moderation-latest filtered out"
else
    pass_msg "openai omni-moderation-latest filtered out"
fi

# Order preserved (gpt-4o appears before o3-mini in the source).
gpt4o_line=$(printf '%s\n' "$out" | grep -n '^gpt-4o$' | head -1 | cut -d: -f1)
o3mini_line=$(printf '%s\n' "$out" | grep -n '^o3-mini$' | head -1 | cut -d: -f1)
if [ -n "$gpt4o_line" ] && [ -n "$o3mini_line" ] && [ "$gpt4o_line" -lt "$o3mini_line" ]; then
    pass_msg "openai order preserved (gpt-4o before o3-mini)"
else
    fail_msg "openai order broken (gpt-4o line=$gpt4o_line, o3-mini line=$o3mini_line)"
fi

# ---------------------------------------------------------------------------
note ""
note "## OpenAI: empty / malformed responses"
# ---------------------------------------------------------------------------

export CODER_TEST_MOCK_BODY='{"object":"list","data":[]}'
set +e
out=$(_dynamic_fetch_openai_models "sk-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "openai rc=1 on empty data array"
assert_eq "$out" "" "openai stdout empty on empty data array"

set +e
err=$(_dynamic_fetch_openai_models "sk-fake" 2>&1 >/dev/null)
set -e 2>/dev/null
assert_contains "empty model list" "$err" "openai stderr mentions empty model list"

# Missing data field
export CODER_TEST_MOCK_BODY='{"object":"list","oops":"no data field"}'
set +e
out=$(_dynamic_fetch_openai_models "sk-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "openai rc=1 on missing 'data' field"

set +e
err=$(_dynamic_fetch_openai_models "sk-fake" 2>&1 >/dev/null)
set -e 2>/dev/null
assert_contains "missing 'data'" "$err" "openai stderr mentions missing 'data' field"

# Not valid JSON
export CODER_TEST_MOCK_BODY='<html>internal server error</html>'
set +e
out=$(_dynamic_fetch_openai_models "sk-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "openai rc=1 on non-JSON body"

# ---------------------------------------------------------------------------
note ""
note "## OpenAI: all filtered out → rc=1 + stderr mentions filter"
# ---------------------------------------------------------------------------

# Catalog containing only non-chat models — after default filter nothing remains.
export CODER_TEST_MOCK_BODY='{"object":"list","data":[
    {"id":"text-embedding-3-small"},
    {"id":"tts-1"},
    {"id":"whisper-1"},
    {"id":"dall-e-3"}
]}'

set +e
out=$(_dynamic_fetch_openai_models "sk-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "openai rc=1 when filter excludes everything"
assert_eq "$out" "" "openai stdout empty when filter excludes everything"

set +e
err=$(_dynamic_fetch_openai_models "sk-fake" 2>&1 >/dev/null)
set -e 2>/dev/null
assert_contains "no chat-capable models" "$err" "openai stderr mentions filter exclusion"

# ---------------------------------------------------------------------------
note ""
note "## OpenAI: filter override via env"
# ---------------------------------------------------------------------------

# Override filter to admit `text-embedding-*` (e.g. for callers wanting all
# models). Catalog from prior test still in CODER_TEST_MOCK_BODY: 4 entries,
# only text-embedding-3-small matches the override.
export CODER_DYNAMIC_MODELS_OPENAI_FILTER='^text-embedding-'

set +e
out=$(_dynamic_fetch_openai_models "sk-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "0" "openai rc=0 with custom filter matching text-embedding-*"
n=$(printf '%s\n' "$out" | grep -c .)
assert_eq "$n" "1" "openai filter override yields 1 model"
assert_contains "text-embedding-3-small" "$out" "openai custom filter admits text-embedding-3-small"

unset CODER_DYNAMIC_MODELS_OPENAI_FILTER

# ---------------------------------------------------------------------------
note ""
note "## OpenAI: dedupe (defensive)"
# ---------------------------------------------------------------------------

# API shouldn't repeat IDs but be safe.
export CODER_TEST_MOCK_BODY='{"object":"list","data":[
    {"id":"gpt-4o"},
    {"id":"gpt-4o"},
    {"id":"gpt-4o-mini"}
]}'

set +e
out=$(_dynamic_fetch_openai_models "sk-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "0" "openai rc=0 with duplicates"
n=$(printf '%s\n' "$out" | grep -c .)
assert_eq "$n" "2" "openai deduped to 2 unique IDs"
gpt4o_count=$(printf '%s\n' "$out" | grep -c '^gpt-4o$')
assert_eq "$gpt4o_count" "1" "openai gpt-4o appears exactly once after dedupe"

# ===========================================================================
# Gemini fetcher
# ===========================================================================

# Reset mock state — Gemini paginates differently (pageToken vs after_id) and
# has its own response shape (.models[].name + supportedGenerationMethods).
unset CODER_TEST_MOCK_BODY CODER_TEST_MOCK_HTTP_CODE
unset CODER_TEST_MOCK_BODY_PAGE1 CODER_TEST_MOCK_BODY_PAGE2
unset CODER_TEST_MOCK_HTTP_CODE_PAGE1 CODER_TEST_MOCK_HTTP_CODE_PAGE2

# ---------------------------------------------------------------------------
note ""
note "## Gemini: module wiring"
# ---------------------------------------------------------------------------
if declare -f _dynamic_fetch_gemini_models >/dev/null 2>&1; then
    pass_msg "_dynamic_fetch_gemini_models defined"
else
    fail_msg "_dynamic_fetch_gemini_models not defined"
fi

# ---------------------------------------------------------------------------
note ""
note "## Gemini: input validation"
# ---------------------------------------------------------------------------

set +e
out=$(_dynamic_fetch_gemini_models "" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "2" "gemini rc=2 on missing key"
assert_eq "$out" "" "gemini stdout empty on missing key"

set +e
err=$(_dynamic_fetch_gemini_models "" 2>&1 >/dev/null)
set -e 2>/dev/null
assert_contains "empty api_key" "$err" "gemini stderr mentions empty api_key"

# ---------------------------------------------------------------------------
note ""
note "## Gemini: HTTP errors"
# ---------------------------------------------------------------------------

export CODER_TEST_MOCK_HTTP_CODE=401
export CODER_TEST_MOCK_BODY='{"error":{"code":401,"message":"API key not valid","status":"UNAUTHENTICATED"}}'

set +e
out=$(_dynamic_fetch_gemini_models "AIza-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "gemini rc=1 on HTTP 401"
assert_eq "$out" "" "gemini stdout empty on HTTP 401"

set +e
err=$(_dynamic_fetch_gemini_models "AIza-fake" 2>&1 >/dev/null)
set -e 2>/dev/null
assert_contains "HTTP 401" "$err" "gemini stderr mentions HTTP 401"

export CODER_TEST_MOCK_HTTP_CODE=500
export CODER_TEST_MOCK_BODY='{"error":{"code":500,"message":"Internal server error"}}'
set +e
out=$(_dynamic_fetch_gemini_models "AIza-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "gemini rc=1 on HTTP 500"

# ---------------------------------------------------------------------------
note ""
note "## Gemini: happy path (mixed catalog filtered by generateContent)"
# ---------------------------------------------------------------------------

# Realistic-ish catalog mixing chat (generateContent), embedding (embedContent)
# and bidi (bidiGenerateContent) models. Only generateContent should survive.
# Also exercises the `models/` prefix strip.
export CODER_TEST_MOCK_HTTP_CODE=200
export CODER_TEST_MOCK_BODY='{"models":[
    {"name":"models/gemini-1.5-pro","supportedGenerationMethods":["generateContent","countTokens"]},
    {"name":"models/gemini-1.5-flash","supportedGenerationMethods":["generateContent","countTokens"]},
    {"name":"models/gemini-2.0-flash","supportedGenerationMethods":["generateContent"]},
    {"name":"models/gemini-2.0-flash-exp","supportedGenerationMethods":["generateContent","bidiGenerateContent"]},
    {"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]},
    {"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]},
    {"name":"models/aqa","supportedGenerationMethods":["generateAnswer"]}
]}'

set +e
out=$(_dynamic_fetch_gemini_models "AIza-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "0" "gemini rc=0 on happy path"
n=$(printf '%s\n' "$out" | grep -c .)
assert_eq "$n" "4" "gemini 4 generateContent-capable models survive filter"
assert_contains "gemini-1.5-pro" "$out" "gemini stdout includes gemini-1.5-pro"
assert_contains "gemini-1.5-flash" "$out" "gemini stdout includes gemini-1.5-flash"
assert_contains "gemini-2.0-flash" "$out" "gemini stdout includes gemini-2.0-flash"
assert_contains "gemini-2.0-flash-exp" "$out" "gemini stdout includes gemini-2.0-flash-exp"

# `models/` prefix stripped — assert NOT present anywhere in output.
if printf '%s' "$out" | grep -qE '^models/'; then
    fail_msg "gemini models/ prefix stripped from all IDs"
else
    pass_msg "gemini models/ prefix stripped from all IDs"
fi

# Excluded by filter — embedding + aqa NOT present.
if printf '%s' "$out" | grep -qE '^text-embedding-004$'; then
    fail_msg "gemini text-embedding-004 filtered out"
else
    pass_msg "gemini text-embedding-004 filtered out"
fi
if printf '%s' "$out" | grep -qE '^embedding-001$'; then
    fail_msg "gemini embedding-001 filtered out"
else
    pass_msg "gemini embedding-001 filtered out"
fi
if printf '%s' "$out" | grep -qE '^aqa$'; then
    fail_msg "gemini aqa filtered out"
else
    pass_msg "gemini aqa filtered out"
fi

# Order preserved — gemini-1.5-pro before gemini-2.0-flash in source.
first=$(printf '%s\n' "$out" | head -1)
assert_eq "$first" "gemini-1.5-pro" "gemini first emitted ID preserves source order"
pro_line=$(printf '%s\n' "$out" | grep -n '^gemini-1.5-pro$' | head -1 | cut -d: -f1)
flash20_line=$(printf '%s\n' "$out" | grep -n '^gemini-2.0-flash$' | head -1 | cut -d: -f1)
if [ -n "$pro_line" ] && [ -n "$flash20_line" ] && [ "$pro_line" -lt "$flash20_line" ]; then
    pass_msg "gemini order preserved (gemini-1.5-pro before gemini-2.0-flash)"
else
    fail_msg "gemini order broken (pro=$pro_line, flash20=$flash20_line)"
fi

# ---------------------------------------------------------------------------
note ""
note "## Gemini: empty / malformed responses"
# ---------------------------------------------------------------------------

# Empty models array → rc=1.
export CODER_TEST_MOCK_BODY='{"models":[]}'
set +e
out=$(_dynamic_fetch_gemini_models "AIza-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "gemini rc=1 on empty models array"
assert_eq "$out" "" "gemini stdout empty on empty models array"

set +e
err=$(_dynamic_fetch_gemini_models "AIza-fake" 2>&1 >/dev/null)
set -e 2>/dev/null
assert_contains "empty model list" "$err" "gemini stderr mentions empty model list"

# Models present but none have generateContent → also rc=1 (same exit path).
export CODER_TEST_MOCK_BODY='{"models":[
    {"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]},
    {"name":"models/aqa","supportedGenerationMethods":["generateAnswer"]}
]}'
set +e
out=$(_dynamic_fetch_gemini_models "AIza-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "gemini rc=1 when no model supports generateContent"
assert_eq "$out" "" "gemini stdout empty when filter excludes everything"

# Missing models field.
export CODER_TEST_MOCK_BODY='{"oops":"no models field"}'
set +e
out=$(_dynamic_fetch_gemini_models "AIza-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "gemini rc=1 on missing 'models' field"

set +e
err=$(_dynamic_fetch_gemini_models "AIza-fake" 2>&1 >/dev/null)
set -e 2>/dev/null
assert_contains "missing 'models'" "$err" "gemini stderr mentions missing 'models' field"

# Not valid JSON.
export CODER_TEST_MOCK_BODY='<html>internal server error</html>'
set +e
out=$(_dynamic_fetch_gemini_models "AIza-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "gemini rc=1 on non-JSON body"

# ---------------------------------------------------------------------------
note ""
note "## Gemini: pagination (2 pages)"
# ---------------------------------------------------------------------------

unset CODER_TEST_MOCK_BODY CODER_TEST_MOCK_HTTP_CODE
export CODER_TEST_MOCK_HTTP_CODE_PAGE1=200
export CODER_TEST_MOCK_HTTP_CODE_PAGE2=200
export CODER_TEST_MOCK_BODY_PAGE1='{"models":[
    {"name":"models/gemini-1.5-pro","supportedGenerationMethods":["generateContent"]},
    {"name":"models/gemini-1.5-flash","supportedGenerationMethods":["generateContent"]}
],"nextPageToken":"tok-page2"}'
export CODER_TEST_MOCK_BODY_PAGE2='{"models":[
    {"name":"models/gemini-2.0-flash","supportedGenerationMethods":["generateContent"]},
    {"name":"models/gemini-2.0-flash-thinking-exp","supportedGenerationMethods":["generateContent"]}
]}'

set +e
out=$(_dynamic_fetch_gemini_models "AIza-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "0" "gemini rc=0 on 2-page pagination"
n=$(printf '%s\n' "$out" | grep -c .)
assert_eq "$n" "4" "gemini 4 IDs emitted across 2 pages"
assert_contains "gemini-1.5-pro" "$out" "gemini page-1 model gemini-1.5-pro present"
assert_contains "gemini-2.0-flash-thinking-exp" "$out" "gemini page-2 model gemini-2.0-flash-thinking-exp present"

first=$(printf '%s\n' "$out" | head -1)
last=$(printf '%s\n' "$out" | grep . | tail -1)
assert_eq "$first" "gemini-1.5-pro" "gemini page-1 first ID first overall"
assert_eq "$last" "gemini-2.0-flash-thinking-exp" "gemini page-2 last ID last overall"

# ---------------------------------------------------------------------------
note ""
note "## Gemini: dedupe across pages (defensive)"
# ---------------------------------------------------------------------------

export CODER_TEST_MOCK_BODY_PAGE1='{"models":[
    {"name":"models/gemini-1.5-pro","supportedGenerationMethods":["generateContent"]},
    {"name":"models/gemini-1.5-flash","supportedGenerationMethods":["generateContent"]}
],"nextPageToken":"tok-page2"}'
export CODER_TEST_MOCK_BODY_PAGE2='{"models":[
    {"name":"models/gemini-1.5-flash","supportedGenerationMethods":["generateContent"]},
    {"name":"models/gemini-2.0-flash","supportedGenerationMethods":["generateContent"]}
]}'

set +e
out=$(_dynamic_fetch_gemini_models "AIza-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "0" "gemini rc=0 with duplicate ID across pages"
n=$(printf '%s\n' "$out" | grep -c .)
assert_eq "$n" "3" "gemini duplicate gemini-1.5-flash deduped (3 unique IDs)"
flash_count=$(printf '%s\n' "$out" | grep -c '^gemini-1.5-flash$')
assert_eq "$flash_count" "1" "gemini gemini-1.5-flash appears exactly once after dedupe"

# ---------------------------------------------------------------------------
note ""
note "## Gemini: pagination max_pages cap"
# ---------------------------------------------------------------------------

# Server keeps returning a fresh nextPageToken with cap=2 → stop after 2 pages.
export CODER_DYNAMIC_MODELS_MAX_PAGES=2
export CODER_TEST_MOCK_BODY_PAGE1='{"models":[
    {"name":"models/m1","supportedGenerationMethods":["generateContent"]}
],"nextPageToken":"t1"}'
export CODER_TEST_MOCK_BODY_PAGE2='{"models":[
    {"name":"models/m2","supportedGenerationMethods":["generateContent"]}
],"nextPageToken":"t2"}'

set +e
out=$(_dynamic_fetch_gemini_models "AIza-fake" 2>/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "0" "gemini rc=0 when max_pages reached with IDs collected"
n=$(printf '%s\n' "$out" | grep -c .)
assert_eq "$n" "2" "gemini max_pages cap stops at 2 pages (got m1+m2)"

unset CODER_DYNAMIC_MODELS_MAX_PAGES

# ---------------------------------------------------------------------------
note ""
note "## Gemini: cursor loop detection"
# ---------------------------------------------------------------------------

# Both pages return the same nextPageToken — infinite-loop guard kicks in.
export CODER_TEST_MOCK_BODY_PAGE1='{"models":[
    {"name":"models/m1","supportedGenerationMethods":["generateContent"]}
],"nextPageToken":"stuck"}'
export CODER_TEST_MOCK_BODY_PAGE2='{"models":[
    {"name":"models/m1","supportedGenerationMethods":["generateContent"]}
],"nextPageToken":"stuck"}'

set +e
err=$(_dynamic_fetch_gemini_models "AIza-fake" 2>&1 >/dev/null)
rc=$?
set -e 2>/dev/null
assert_eq "$rc" "1" "gemini rc=1 when cursor loops on same nextPageToken"
assert_contains "cursor loop detected" "$err" "gemini stderr mentions cursor loop"

unset CODER_TEST_MOCK_BODY_PAGE1 CODER_TEST_MOCK_BODY_PAGE2
unset CODER_TEST_MOCK_HTTP_CODE_PAGE1 CODER_TEST_MOCK_HTTP_CODE_PAGE2

# ---------------------------------------------------------------------------
note ""
note "## Meta: shellcheck + bash -n"
# ---------------------------------------------------------------------------

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -e SC1091 "$REPO_ROOT/lib/agent/llm_dynamic_models.sh" 2>/dev/null; then
        pass_msg "shellcheck lib/llm_dynamic_models.sh clean"
    else
        fail_msg "shellcheck lib/llm_dynamic_models.sh has warnings"
    fi
else
    note "  SKIP shellcheck not installed"
fi

if bash -n "$REPO_ROOT/lib/agent/llm_dynamic_models.sh" 2>/dev/null; then
    pass_msg "bash -n lib/llm_dynamic_models.sh"
else
    fail_msg "bash -n lib/llm_dynamic_models.sh failed"
fi

note ""
note "Resultado: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 1
