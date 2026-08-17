#!/usr/bin/env bash
# ── Hiveflow authentication ───────────────────────────────────
# Two paths:
#   1) API token    — you paste an hf_... token and it is validated against the API
#   2) Subscription — browser login (device flow) at hiveflow.ai
#
# The endpoint is configurable (HIVEFLOW_API_URL). While the auth backend
# is not deployed, remote validation is skipped with a warning and the
# token is stored locally (offline mode).

HIVEFLOW_API_URL="${HIVEFLOW_API_URL:-https://api.hiveflow.ai}"

hf_auth_token()  { hf_config_get '.auth.token'; }
hf_auth_method() { hf_config_get '.auth.method'; }
hf_auth_email()  { hf_config_get '.auth.email'; }

# Asks the backend for the token's identity and stores it (.auth.email/.auth.name).
# Silent: if the backend does not respond, nothing breaks.
hf_auth_fetch_identity() {
  local token="${1:-$(hf_auth_token)}" body email name
  [ -z "$token" ] && return 1
  body=$(curl -s -m 6 -H "Authorization: Bearer $token" \
    "$HIVEFLOW_API_URL/api/auth/cli/verify" 2>/dev/null)
  email=$(printf '%s' "$body" | jq -r '.email // empty' 2>/dev/null)
  name=$(printf '%s' "$body" | jq -r '.name // empty' 2>/dev/null)
  [ -n "$email" ] && hf_config_set '.auth.email' "$email"
  [ -n "$name" ] && hf_config_set '.auth.name' "$name"
  [ -n "$email" ]
}

hf_auth_ok() {
  [ -n "$(hf_auth_token)" ]
}

# Validates the token against the API when there is connectivity; if the
# backend does not respond, accepts in offline mode (revalidated on use).
hf_auth_validate() {
  local token="$1"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 6 \
    -H "Authorization: Bearer $token" \
    "$HIVEFLOW_API_URL/api/auth/cli/verify" 2>/dev/null)"
  case "$code" in
    200) return 0 ;;
    401|403) return 1 ;;
    *)  hf_warn "$(hf_t "Could not reach $HIVEFLOW_API_URL (HTTP ${code:-no response}). Token saved in offline mode." "No se pudo contactar $HIVEFLOW_API_URL (HTTP ${code:-sin respuesta}). Token guardado en modo offline.")"
        return 0 ;;
  esac
}

hf_login() {
  echo ""
  echo -e "  ${HF_C_BOLD}$(hf_t "Connect your Hiveflow account" "Conecta tu cuenta de Hiveflow")${HF_C_RESET}"
  [ "$HF_LANG" = "es" ] || hf_dim "¿Español? Ejecuta: HIVEFLOW_LANG=es hiveflow — o /lang es dentro del REPL"
  echo ""
  echo "  $(hf_t "1) API token       — generate one at https://app.hiveflow.ai/cli-login and paste it" "1) API token       — genera uno en https://app.hiveflow.ai/cli-login y pégalo")"
  echo "  $(hf_t "2) Subscription    — sign in with your browser" "2) Suscripción     — inicia sesión con tu navegador")"
  echo ""
  local choice
  read -r -p "  $(hf_t "Method" "Método") [1/2]: " choice

  case "$choice" in
    1)
      local token
      read -r -s -p "  Token (hf_...): " token; echo ""
      if [ -z "$token" ]; then
        hf_err "$(hf_t "Empty token." "Token vacío.")"
        return 1
      fi
      if ! hf_auth_validate "$token"; then
        hf_err "$(hf_t "Token rejected by the API." "Token rechazado por la API.")"
        return 1
      fi
      hf_config_set '.auth.token'  "$token"
      hf_config_set '.auth.method' "api"
      hf_auth_fetch_identity "$token" >/dev/null 2>&1 || true
      local _email; _email="$(hf_auth_email)"
      hf_ok "$(hf_t "Authenticated via API token${_email:+ as $_email}." "Autenticado por API token${_email:+ como $_email}.")"
      ;;
    2)
      hf_auth_device_flow
      ;;
    *)
      hf_err "$(hf_t "Invalid option." "Opción inválida.")"
      return 1
      ;;
  esac
}

# Claude Code-style device flow:
#   1. POST /device/start → device_code (secret) + user_code (XXXX-XXXX)
#   2. Opens the browser at app.hiveflow.ai/cli-login?code=<user_code>
#      (no browser: prints the URL and the code to do it by hand)
#   3. Polls until the user approves → the backend issues an hf_ API key
#      and it arrives in the poll. Stored as the CLI credential.
hf_auth_device_flow() {
  local start_url="$HIVEFLOW_API_URL/api/auth/cli/device/start"
  local poll_url="$HIVEFLOW_API_URL/api/auth/cli/device/poll"
  local device_name
  device_name="$(hostname -s 2>/dev/null || echo terminal)"

  local resp http_code
  resp="$(curl -s -m 10 -w '\n%{http_code}' -X POST "$start_url" \
    -H 'Content-Type: application/json' \
    -d "{\"device_name\":\"$device_name\"}" 2>/dev/null)"
  http_code="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"

  local device_code user_code verification_url interval expires_in
  device_code="$(echo "$resp" | jq -r '.device_code // empty' 2>/dev/null)"
  user_code="$(echo "$resp" | jq -r '.user_code // empty' 2>/dev/null)"
  verification_url="$(echo "$resp" | jq -r '.verification_url // empty' 2>/dev/null)"
  interval="$(echo "$resp" | jq -r '.interval // 3' 2>/dev/null)"
  expires_in="$(echo "$resp" | jq -r '.expires_in // 600' 2>/dev/null)"

  if [ -z "$device_code" ] || [ -z "$user_code" ]; then
    case "$http_code" in
      404)
        hf_err "$(hf_t "The backend at $HIVEFLOW_API_URL does not expose the CLI login yet (HTTP 404 — deploy pending?). Use option 1 (API token)." "El backend en $HIVEFLOW_API_URL aún no expone el login del CLI (HTTP 404 — ¿deploy pendiente?). Usa la opción 1 (API token).")" ;;
      000|"")
        hf_err "$(hf_t "Could not reach $HIVEFLOW_API_URL (no response). Check your connection or use option 1 (API token)." "No se pudo contactar $HIVEFLOW_API_URL (sin respuesta). Revisa tu conexión o usa la opción 1 (API token).")" ;;
      *)
        hf_err "$(hf_t "Could not start the login (HTTP $http_code from $HIVEFLOW_API_URL). Use option 1 (API token)." "No se pudo iniciar el login (HTTP $http_code de $HIVEFLOW_API_URL). Usa la opción 1 (API token).")" ;;
    esac
    return 1
  fi

  echo ""
  echo -e "  $(hf_t "Your pairing code:" "Tu código de vinculación:")  ${HF_C_BOLD}${user_code}${HF_C_RESET}"
  echo ""
  if (command -v open >/dev/null 2>&1 && open "$verification_url" >/dev/null 2>&1) ||
     (command -v xdg-open >/dev/null 2>&1 && xdg-open "$verification_url" >/dev/null 2>&1); then
    hf_info "$(hf_t "Browser opened. Check that the code matches and press Authorize." "Se abrió el navegador. Verifica que el código coincida y pulsa Autorizar.")"
  else
    echo "  $(hf_t "No browser available. Open this URL on any device:" "No hay navegador disponible. Abre esta URL en cualquier dispositivo:")"
    echo ""
    echo -e "    ${HF_C_BOLD}${verification_url}${HF_C_RESET}"
    echo ""
    echo "  $(hf_t "and enter the code above." "e introduce el código de arriba.")"
  fi
  hf_dim "$(hf_t "Waiting for authorization (Ctrl+C to cancel)..." "Esperando autorización (Ctrl+C para cancelar)...")"

  local waited=0 status token
  while [ "$waited" -lt "$expires_in" ]; do
    sleep "$interval"
    waited=$((waited + interval))
    resp="$(curl -s -m 10 -X POST "$poll_url" \
      -H 'Content-Type: application/json' \
      -d "{\"device_code\":\"$device_code\"}" 2>/dev/null)"
    status="$(echo "$resp" | jq -r '.status // empty' 2>/dev/null)"
    case "$status" in
      approved)
        token="$(echo "$resp" | jq -r '.token // empty')"
        if [ -z "$token" ]; then
          hf_err "$(hf_t "The backend approved but returned no token. Try again." "El backend aprobó pero no entregó token. Reintenta.")"
          return 1
        fi
        hf_config_set '.auth.token'  "$token"
        hf_config_set '.auth.method' "subscription"
        hf_auth_fetch_identity "$token" >/dev/null 2>&1 || true
        local _email; _email="$(hf_auth_email)"
        hf_ok "$(hf_t "CLI authorized${_email:+ as $_email} — connected as this device ($device_name)." "CLI autorizado${_email:+ como $_email} — conectado como este dispositivo ($device_name).")"
        return 0
        ;;
      denied)
        hf_err "$(hf_t "Request denied from the web." "Solicitud rechazada desde la web.")"
        return 1
        ;;
      expired)
        hf_err "$(hf_t "The code expired. Try logging in again." "El código expiró. Vuelve a intentar el login.")"
        return 1
        ;;
      pending|"")
        : ;;  # keep waiting (or a transient network hiccup)
    esac
  done
  hf_err "$(hf_t "Timed out waiting. Try logging in again." "Tiempo de espera agotado. Vuelve a intentar el login.")"
  return 1
}

hf_logout() {
  hf_config_del '.auth'
  hf_ok "$(hf_t "Logged out." "Sesión cerrada.")"
}

# Guarantees auth before entering the REPL
hf_auth_ensure() {
  if hf_auth_ok; then
    local method email
    method="$(hf_auth_method)"
    email="$(hf_auth_email)"
    # Identity backfill for sessions logged in before this feature existed
    if [ -z "$email" ]; then
      hf_auth_fetch_identity >/dev/null 2>&1 || true
      email="$(hf_auth_email)"
    fi
    hf_dim "$(hf_t "Signed in${email:+ as $email} (${method:-api}) · /logout to switch accounts" "Sesión${email:+ de $email} (${method:-api}) · /logout para cambiar de cuenta")"
    return 0
  fi
  hf_login
}
