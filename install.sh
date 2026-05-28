#!/usr/bin/env bash
set -Eeuo pipefail

# Marzban + VLESS XHTTP TLS + Vercel relay auto installer
# This script is designed for Ubuntu 22.04/24.04 servers and must be run as root.

APP_NAME="marzban-xhttp-vercel"
STATE_DIR="/etc/${APP_NAME}"
WORK_DIR="/opt/${APP_NAME}"
OUTPUT_DIR="/root/${APP_NAME}-output"
LOG_FILE="/tmp/${APP_NAME}-install.log"
MARZBAN_ENV="/opt/marzban/.env"
MARZBAN_XRAY_JSON="/var/lib/marzban/xray_config.json"
CERT_DIR="/var/lib/marzban/certs"
VERCEL_WORKDIR="${WORK_DIR}/vercel-relay"
MARZBAN_INSTALL_TIMEOUT=1200
MARZBAN_RESTART_TIMEOUT=180
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec > >(tee -a "$LOG_FILE") 2>&1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}>>${NC} $*"; }
ok() { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✘${NC} $*"; exit 1; }

on_error() {
  local exit_code=$?
  echo
  fail "Installer failed at line ${BASH_LINENO[0]} with exit code ${exit_code}. Full log: ${LOG_FILE}"
}
trap on_error ERR

random_suffix() {
  tr -dc 'a-z0-9' </dev/urandom | head -c 8 || true
}

trim_slash() {
  local value="$1"
  value="${value#/}"
  value="${value%/}"
  printf '%s' "$value"
}

normalize_path() {
  local value="$1"
  [[ -z "$value" ]] && value="api"
  value="$(trim_slash "$value")"
  printf '/%s' "$value"
}

read_default() {
  local prompt="$1"
  local default="$2"
  local var
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " var
    printf '%s' "${var:-$default}"
  else
    read -r -p "${prompt}: " var
    printf '%s' "$var"
  fi
}

read_secret() {
  # Values are intentionally visible while typing because the operator asked
  # to see exactly what is being entered and avoid silent typos.
  local prompt="$1"
  local var
  read -r -p "${prompt}: " var
  printf '%s' "$var"
}

valid_email() {
  [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && [[ ! "$1" =~ \.\. ]] && [[ ! "$1" =~ ^- ]] && [[ ! "$1" =~ -$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 0 ))
}

valid_path() {
  local re='^/[A-Za-z0-9._~:/@-]*$'
  [[ "$1" =~ $re ]] && [[ ! "$1" =~ [[:space:]] ]]
}

valid_vercel_project() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,98}[a-z0-9])?$ ]]
}

valid_slug_or_blank() {
  [[ -z "$1" ]] || [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9_-]{0,98}[A-Za-z0-9])?$ ]]
}

valid_admin_username() {
  [[ "$1" =~ ^[A-Za-z0-9_.@-]{3,64}$ ]]
}

valid_admin_password() {
  # Keep it Docker-env-safe and sed-safe. No spaces, quotes, #, $, backslash, slash, or pipe.
  local re='^[A-Za-z0-9._@%+=:,;!?^-]+$'
  [[ ${#1} -ge 6 ]] && [[ "$1" =~ $re ]]
}

valid_client_address() {
  [[ -z "$1" ]] && return 0
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
  valid_domain "$1" && return 0
  return 1
}

ask_until_valid() {
  local prompt="$1" default="$2" validator="$3" error_msg="$4" value
  while true; do
    value="$(read_default "$prompt" "$default")"
    if "$validator" "$value"; then
      printf '%s' "$value"
      return 0
    fi
    echo "✘ ${error_msg}"
  done
}

ask_yes_no() {
  local prompt="$1" default="$2" value
  while true; do
    value="$(read_default "$prompt" "$default")"
    case "$value" in
      Y|y|YES|yes|Yes|"") printf 'Y'; return 0 ;;
      N|n|NO|no|No) printf 'N'; return 0 ;;
      *) echo "✘ Please enter Y or n." ;;
    esac
  done
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Please run as root. Example: sudo bash install.sh"
}

require_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then
    fail "Cannot detect OS. Ubuntu 22.04/24.04 is recommended."
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || warn "Detected ${PRETTY_NAME:-unknown}. Ubuntu 22.04/24.04 is recommended. Continuing anyway."
}

print_banner() {
  clear || true
  cat <<'EOF'

  ★ Marzban XHTTP Vercel Relay Installer ★
  ────────────────────────────────────────
  VLESS + XHTTP + TLS
  Marzban-ready Ubuntu Auto-Installer
  Relay: Vercel

  Before continuing:
  - Your origin domain DNS A-record must point to this server IP.
  - Keep your Vercel token private.
  - Deployment Protection on Vercel should be disabled for this relay project.

EOF
}


choose_inbound_tag() {
  echo "Choose Marzban inbound tag:" >&2
  echo "  1) VLESS XHTTP TLS - VERCEL  (recommended/default)" >&2
  echo "  2) VLESS XHTTP TLS - NODE 1  (good for multi-node setups)" >&2
  echo "  3) VLESS XHTTP TLS - ORIGIN 1" >&2
  echo "  4) Custom tag" >&2
  local choice
  choice="$(read_default "Select option" "1")"
  case "$choice" in
    1|"") printf '%s' "VLESS XHTTP TLS - VERCEL" ;;
    2) printf '%s' "VLESS XHTTP TLS - NODE 1" ;;
    3) printf '%s' "VLESS XHTTP TLS - ORIGIN 1" ;;
    4)
      local custom
      custom="$(read_default "Custom inbound tag" "VLESS XHTTP TLS - VERCEL")"
      printf '%s' "$custom"
      ;;
    *)
      warn "Unknown option. Using recommended default."
      printf '%s' "VLESS XHTTP TLS - VERCEL"
      ;;
  esac
}

collect_inputs() {
  mkdir -p "$STATE_DIR" "$WORK_DIR" "$OUTPUT_DIR"

  echo "[ Domain & SSL ]"
  ORIGIN_DOMAIN="$(ask_until_valid "Origin domain for Marzban/Xray inbound" "" valid_domain "Invalid domain. Example: origin.example.com")"
  PANEL_DOMAIN="$(ask_until_valid "Marzban panel/subscription domain" "$ORIGIN_DOMAIN" valid_domain "Invalid panel domain. Example: panel.example.com")"
  EMAIL="$(ask_until_valid "Email for Let's Encrypt" "" valid_email "Invalid email format. Example: yourname@example.com")"

  echo
  echo "[ Marzban ]"
  INSTALL_MARZBAN="$(ask_yes_no "Install/repair Marzban automatically? (Y/n)" "Y")"
  MARZBAN_PANEL_PORT="$(ask_until_valid "Marzban panel port" "8000" valid_port "Port must be a number from 1 to 65535.")"
  INBOUND_TAG="$(choose_inbound_tag)"
  while [[ -z "$INBOUND_TAG" || "$INBOUND_TAG" =~ [\$\`\|] ]]; do
    echo "✘ Inbound tag cannot be empty and cannot contain $, backtick, or pipe characters."
    INBOUND_TAG="$(choose_inbound_tag)"
  done
  ok "Inbound tag selected: ${INBOUND_TAG}"
  INBOUND_PORT="$(ask_until_valid "Inbound port on server" "443" valid_port "Inbound port must be a number from 1 to 65535.")"
  CREATE_ADMIN="$(ask_yes_no "Create/import Marzban sudo admin from env? (Y/n)" "Y")"
  if [[ "$CREATE_ADMIN" == "Y" ]]; then
    SUDO_USERNAME_INPUT="$(ask_until_valid "Marzban sudo username" "admin" valid_admin_username "Username must be 3-64 chars: letters, numbers, dot, underscore, @ or hyphen.")"
    while true; do
      SUDO_PASSWORD_INPUT="$(read_secret "Marzban sudo password (visible while typing)")"
      if valid_admin_password "$SUDO_PASSWORD_INPUT"; then
        break
      fi
      echo "✘ Password must be at least 6 chars and use only: letters, numbers, . _ @ % + = : , ; ! ? ^ ~ -"
      echo "  Avoid spaces, quotes, #, $, backslash, slash, and pipe to keep Docker env parsing safe."
    done
  fi

  echo
  echo "[ Relay paths ]"
  RELAY_PATH="$(normalize_path "$(read_default "RELAY_PATH on origin" "/api")")"
  while ! valid_path "$RELAY_PATH"; do
    echo "✘ RELAY_PATH is invalid. Use a simple path like /api or /edge-api with no spaces."
    RELAY_PATH="$(normalize_path "$(read_default "RELAY_PATH on origin" "/api")")"
  done
  PUBLIC_RELAY_PATH="$(normalize_path "$(read_default "PUBLIC_RELAY_PATH on Vercel" "$RELAY_PATH")")"
  while ! valid_path "$PUBLIC_RELAY_PATH"; do
    echo "✘ PUBLIC_RELAY_PATH is invalid. Use a simple path like /api or /edge-api with no spaces."
    PUBLIC_RELAY_PATH="$(normalize_path "$(read_default "PUBLIC_RELAY_PATH on Vercel" "$RELAY_PATH")")"
  done

  echo
  echo "[ Vercel ]"
  echo "The Vercel token is visible while typing so you can catch mistakes. It will not be printed in the final summary."
  VERCEL_TOKEN_INPUT="$(read_secret "Vercel API token")"
  while [[ -z "$VERCEL_TOKEN_INPUT" || ${#VERCEL_TOKEN_INPUT} -lt 20 ]]; do
    echo "✘ Vercel token looks too short or empty. Paste the full token again."
    VERCEL_TOKEN_INPUT="$(read_secret "Vercel API token")"
  done
  VERCEL_PROJECT="$(ask_until_valid "Vercel project name" "relay-$(random_suffix)" valid_vercel_project "Project name must be lowercase letters, numbers, and hyphens only; no leading/trailing hyphen.")"
  VERCEL_SCOPE="$(ask_until_valid "Vercel scope/team slug (blank for personal)" "" valid_slug_or_blank "Scope/team slug contains invalid characters.")"

  echo
  echo "[ Client / Marzban Host Settings ]"
  CLIENT_ADDRESS="$(ask_until_valid "Address to show in Marzban Host Settings (blank = Vercel domain after deploy)" "198.169.2.65" valid_client_address "Client address must be blank, an IPv4 address, or a domain.")"

  echo
  echo "[ Performance defaults ]"
  MAX_INFLIGHT="$(ask_until_valid "MAX_INFLIGHT" "128" valid_positive_int "Must be a non-negative integer.")"
  MAX_UP_BPS="$(ask_until_valid "MAX_UP_BPS" "2621440" valid_positive_int "Must be a non-negative integer.")"
  MAX_DOWN_BPS="$(ask_until_valid "MAX_DOWN_BPS" "2621440" valid_positive_int "Must be a non-negative integer.")"
  UPSTREAM_TIMEOUT_MS="$(ask_until_valid "UPSTREAM_TIMEOUT_MS" "50000" valid_positive_int "Must be a non-negative integer.")"
  SUCCESS_LOG_SAMPLE_RATE="$(ask_until_valid "SUCCESS_LOG_SAMPLE_RATE" "0" valid_positive_int "Must be a non-negative integer.")"
  SUCCESS_LOG_MIN_DURATION_MS="$(ask_until_valid "SUCCESS_LOG_MIN_DURATION_MS" "3000" valid_positive_int "Must be a non-negative integer.")"
  ERROR_LOG_MIN_INTERVAL_MS="$(ask_until_valid "ERROR_LOG_MIN_INTERVAL_MS" "5000" valid_positive_int "Must be a non-negative integer.")"

  TARGET_DOMAIN="https://${ORIGIN_DOMAIN}:${INBOUND_PORT}"

  cat <<EOF

────────────── SUMMARY ──────────────
Origin domain      : ${ORIGIN_DOMAIN}
Panel domain       : ${PANEL_DOMAIN}
Panel port         : ${MARZBAN_PANEL_PORT}
Inbound tag        : ${INBOUND_TAG}
Inbound port       : ${INBOUND_PORT}
RELAY_PATH         : ${RELAY_PATH}
PUBLIC_RELAY_PATH  : ${PUBLIC_RELAY_PATH}
TARGET_DOMAIN      : ${TARGET_DOMAIN}
Vercel project     : ${VERCEL_PROJECT}
Vercel scope       : ${VERCEL_SCOPE:-personal}
Client address     : ${CLIENT_ADDRESS:-Vercel domain after deploy}
MAX_INFLIGHT       : ${MAX_INFLIGHT}
MAX_UP_BPS         : ${MAX_UP_BPS}
MAX_DOWN_BPS       : ${MAX_DOWN_BPS}
TIMEOUT_MS         : ${UPSTREAM_TIMEOUT_MS}
─────────────────────────────────────
EOF

  local proceed
  proceed="$(ask_yes_no "Proceed with these settings? (Y/n)" "Y")"
  [[ "$proceed" == "Y" ]] || fail "Aborted by user."

  write_state_file
}

write_state_file() {
  {
    printf 'ORIGIN_DOMAIN=%q\n' "$ORIGIN_DOMAIN"
    printf 'PANEL_DOMAIN=%q\n' "$PANEL_DOMAIN"
    printf 'EMAIL=%q\n' "$EMAIL"
    printf 'MARZBAN_PANEL_PORT=%q\n' "$MARZBAN_PANEL_PORT"
    printf 'INBOUND_TAG=%q\n' "$INBOUND_TAG"
    printf 'INBOUND_PORT=%q\n' "$INBOUND_PORT"
    printf 'RELAY_PATH=%q\n' "$RELAY_PATH"
    printf 'PUBLIC_RELAY_PATH=%q\n' "$PUBLIC_RELAY_PATH"
    printf 'TARGET_DOMAIN=%q\n' "$TARGET_DOMAIN"
    printf 'VERCEL_PROJECT=%q\n' "$VERCEL_PROJECT"
    printf 'VERCEL_SCOPE=%q\n' "$VERCEL_SCOPE"
    printf 'CLIENT_ADDRESS=%q\n' "$CLIENT_ADDRESS"
    printf 'MAX_INFLIGHT=%q\n' "$MAX_INFLIGHT"
    printf 'MAX_UP_BPS=%q\n' "$MAX_UP_BPS"
    printf 'MAX_DOWN_BPS=%q\n' "$MAX_DOWN_BPS"
    printf 'UPSTREAM_TIMEOUT_MS=%q\n' "$UPSTREAM_TIMEOUT_MS"
    printf 'SUCCESS_LOG_SAMPLE_RATE=%q\n' "$SUCCESS_LOG_SAMPLE_RATE"
    printf 'SUCCESS_LOG_MIN_DURATION_MS=%q\n' "$SUCCESS_LOG_MIN_DURATION_MS"
    printf 'ERROR_LOG_MIN_INTERVAL_MS=%q\n' "$ERROR_LOG_MIN_INTERVAL_MS"
  } > "${STATE_DIR}/input.env"
}

install_base_dependencies() {
  info "PHASE 1 — System check & prerequisites"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget git unzip jq socat cron nano ufw dnsutils ca-certificates \
    lsb-release gnupg openssl tar coreutils python3
  ok "Base dependencies installed"
}

install_node_and_vercel() {
  info "PHASE 2 — Node.js and Vercel CLI"
  if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  fi
  ok "Node.js ready: $(node -v)"

  if ! command -v vercel >/dev/null 2>&1; then
    npm i -g vercel@latest
  else
    npm i -g vercel@latest >/dev/null 2>&1 || true
  fi
  ok "Vercel CLI ready: $(vercel --version | head -n 1)"
}

validate_vercel_credentials() {
  info "PHASE 2b — Validating Vercel token and scope"
  local args=()
  if [[ -n "$VERCEL_SCOPE" ]]; then
    args+=(--scope "$VERCEL_SCOPE")
  fi

  while true; do
    set +e
    local whoami_output
    whoami_output="$(VERCEL_TOKEN="$VERCEL_TOKEN_INPUT" vercel whoami "${args[@]}" 2>&1)"
    local status=$?
    set -e

    if [[ "$status" -eq 0 ]]; then
      ok "Vercel auth OK: $(echo "$whoami_output" | tail -n 1)"
      return 0
    fi

    warn "Vercel authentication failed. Message:"
    echo "$whoami_output"
    echo
    VERCEL_TOKEN_INPUT="$(read_secret "Enter Vercel API token again (visible while typing)")"
    while [[ -z "$VERCEL_TOKEN_INPUT" || ${#VERCEL_TOKEN_INPUT} -lt 20 ]]; do
      echo "✘ Vercel token looks too short or empty. Paste the full token again."
      VERCEL_TOKEN_INPUT="$(read_secret "Vercel API token")"
    done

    if [[ -n "$VERCEL_SCOPE" ]]; then
      local keep_scope
      keep_scope="$(ask_yes_no "Keep current Vercel scope '${VERCEL_SCOPE}'? (Y/n)" "Y")"
      if [[ "$keep_scope" == "N" ]]; then
        VERCEL_SCOPE="$(ask_until_valid "Vercel scope/team slug (blank for personal)" "" valid_slug_or_blank "Scope/team slug contains invalid characters.")"
        args=()
        [[ -n "$VERCEL_SCOPE" ]] && args+=(--scope "$VERCEL_SCOPE")
      fi
    fi
  done
}

install_acme() {
  info "PHASE 3 — acme.sh and SSL certificate"
  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    curl https://get.acme.sh | sh -s email="$EMAIL"
  fi
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
  ok "acme.sh ready"
}

check_dns() {
  info "Checking DNS for ${ORIGIN_DOMAIN}"
  local resolved
  resolved="$(dig +short "$ORIGIN_DOMAIN" A | tail -n 1 || true)"
  [[ -n "$resolved" ]] || fail "${ORIGIN_DOMAIN} does not resolve to an A record yet. Fix DNS and rerun."
  ok "DNS resolves: ${ORIGIN_DOMAIN} -> ${resolved}"
}

obtain_ssl() {
  mkdir -p "$CERT_DIR" "/etc/ssl/xhttp/${ORIGIN_DOMAIN}"

  # Ensure standalone ACME can bind port 80 when possible.
  systemctl stop nginx 2>/dev/null || true
  systemctl stop apache2 2>/dev/null || true

  local acme_cert="/root/.acme.sh/${ORIGIN_DOMAIN}_ecc/${ORIGIN_DOMAIN}.cer"
  if [[ -f "$acme_cert" ]] && openssl x509 -checkend 604800 -noout -in "$acme_cert" >/dev/null 2>&1; then
    ok "Existing valid EC certificate found. Reusing it."
  else
    if ! /root/.acme.sh/acme.sh --issue -d "$ORIGIN_DOMAIN" --standalone --keylength ec-256 --listen-v4; then
      warn "acme.sh issue failed. Trying with --force once."
      /root/.acme.sh/acme.sh --issue -d "$ORIGIN_DOMAIN" --standalone --keylength ec-256 --listen-v4 --force
    fi
  fi

  # Do NOT restart/start Marzban here. Restarting during certificate install can attach to
  # live logs and block the rest of the installer. The final Marzban start/recreate is
  # intentionally performed in the last phase only.
  /root/.acme.sh/acme.sh --install-cert -d "$ORIGIN_DOMAIN" --ecc \
    --fullchain-file "${CERT_DIR}/fullchain.pem" \
    --key-file "${CERT_DIR}/key.pem" \
    --reloadcmd "true"

  cp -f "${CERT_DIR}/fullchain.pem" "/etc/ssl/xhttp/${ORIGIN_DOMAIN}/fullchain.pem"
  cp -f "${CERT_DIR}/key.pem" "/etc/ssl/xhttp/${ORIGIN_DOMAIN}/privkey.pem"
  chmod 644 "${CERT_DIR}/fullchain.pem"
  chmod 600 "${CERT_DIR}/key.pem"
  ok "SSL installed: ${CERT_DIR}/fullchain.pem"
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker and Docker Compose are ready"
    return 0
  fi

  info "Installing Docker"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker.service 2>/dev/null || true
  docker version >/dev/null
  docker compose version >/dev/null
  ok "Docker installed and ready"
}

install_marzban_helper_command() {
  cat > /usr/local/bin/marzban <<'EOF'
#!/usr/bin/env bash
set -e
cd /opt/marzban
case "${1:-}" in
  start|up)
    shift || true
    docker compose up -d "$@"
    ;;
  restart)
    shift || true
    docker compose up -d --force-recreate --remove-orphans "$@"
    ;;
  stop|down)
    shift || true
    docker compose down "$@"
    ;;
  logs)
    shift || true
    docker compose logs "$@"
    ;;
  status|ps)
    shift || true
    docker compose ps "$@"
    ;;
  cli)
    shift || true
    docker compose exec -T marzban marzban cli "$@"
    ;;
  shell)
    shift || true
    docker compose exec marzban sh "$@"
    ;;
  *)
    echo "Usage: marzban {start|restart|stop|logs|status|cli|shell}"
    exit 1
    ;;
esac
EOF
  chmod +x /usr/local/bin/marzban
  ok "Marzban helper command installed: /usr/local/bin/marzban"
}

prepare_marzban_files_without_start() {
  info "Preparing Marzban files without starting/restarting it"
  install_docker_if_needed

  mkdir -p /opt/marzban /var/lib/marzban "$CERT_DIR"

  if [[ ! -f /opt/marzban/docker-compose.yml ]]; then
    cat > /opt/marzban/docker-compose.yml <<'EOF'
services:
  marzban:
    image: gozargah/marzban:latest
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - /var/lib/marzban:/var/lib/marzban
EOF
  fi

  touch "$MARZBAN_ENV"

  if [[ ! -f "$MARZBAN_XRAY_JSON" ]]; then
    cat > "$MARZBAN_XRAY_JSON" <<'EOF'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
  fi

  set_env_var "$MARZBAN_ENV" "UVICORN_HOST" "0.0.0.0"
  set_env_var "$MARZBAN_ENV" "UVICORN_PORT" "$MARZBAN_PANEL_PORT"
  set_env_var "$MARZBAN_ENV" "UVICORN_SSL_CERTFILE" "${CERT_DIR}/fullchain.pem"
  set_env_var "$MARZBAN_ENV" "UVICORN_SSL_KEYFILE" "${CERT_DIR}/key.pem"
  set_env_var "$MARZBAN_ENV" "XRAY_SUBSCRIPTION_URL_PREFIX" "https://${PANEL_DOMAIN}:${MARZBAN_PANEL_PORT}"
  set_env_var "$MARZBAN_ENV" "XRAY_JSON" "$MARZBAN_XRAY_JSON"

  if [[ "${CREATE_ADMIN:-Y}" =~ ^[Yy]$|^$ ]]; then
    set_env_var "$MARZBAN_ENV" "SUDO_USERNAME" "$SUDO_USERNAME_INPUT"
    set_env_var "$MARZBAN_ENV" "SUDO_PASSWORD" "$SUDO_PASSWORD_INPUT"
  fi

  install_marzban_helper_command
  ok "Marzban files prepared. No Marzban start/restart has been executed yet."
}

run_nonfatal() {
  # Run a command without allowing ERR trap / set -e to abort the installer.
  # This is used for optional post-start Marzban admin import commands that may
  # return non-zero when the admin already exists or the CLI version differs.
  local status
  local old_err_trap
  old_err_trap="$(trap -p ERR || true)"
  trap - ERR
  set +e
  "$@"
  status=$?
  set -e
  if [[ -n "$old_err_trap" ]]; then
    eval "$old_err_trap"
  else
    trap on_error ERR
  fi
  return "$status"
}

final_start_marzban() {
  info "FINAL PHASE — Starting/recreating Marzban only now"
  if [[ "$INSTALL_MARZBAN" =~ ^[Nn]$ ]]; then
    warn "Marzban install/repair was disabled. Skipping final Marzban start/recreate."
    return 0
  fi

  [[ -f /opt/marzban/docker-compose.yml ]] || fail "Marzban docker-compose.yml not found. Cannot start Marzban."

  local start_log="${OUTPUT_DIR}/marzban-final-start.log"
  mkdir -p "$OUTPUT_DIR"

  set +e
  (cd /opt/marzban && timeout "$MARZBAN_RESTART_TIMEOUT" docker compose up -d --force-recreate --remove-orphans) 2>&1 | tee "$start_log"
  local status=${PIPESTATUS[0]}
  set -e

  if [[ "$status" -eq 124 ]]; then
    warn "docker compose up timed out after ${MARZBAN_RESTART_TIMEOUT}s. Checking container status. Log: ${start_log}"
  elif [[ "$status" -ne 0 ]]; then
    warn "docker compose up returned status ${status}. Checking container status. Log: ${start_log}"
  else
    ok "Marzban docker compose started/recreated"
  fi

  wait_for_marzban_container
  wait_for_marzban_http

  if [[ "${CREATE_ADMIN:-Y}" =~ ^[Yy]$|^$ ]]; then
    info "Checking/importing Marzban sudo admin from env (non-fatal)"
    local admin_log="${OUTPUT_DIR}/marzban-admin-import.log"
    local elapsed=0
    local imported=0

    while (( elapsed < 90 )); do
      if run_nonfatal bash -lc "cd /opt/marzban && docker compose exec -T marzban marzban cli admin import-from-env --yes" >"$admin_log" 2>&1; then
        imported=1
        break
      fi
      if grep -qiE 'already|exist|duplicate|created|success' "$admin_log" 2>/dev/null; then
        imported=1
        break
      fi
      sleep 5
      elapsed=$((elapsed + 5))
    done

    if [[ "$imported" -eq 1 ]]; then
      ok "Marzban sudo admin import/check completed"
    else
      warn "Automatic admin import did not confirm success, but installer will continue because Marzban is running."
      warn "Admin import log: ${admin_log}"
      warn "If login does not work, run: cd /opt/marzban && docker compose exec -it marzban marzban cli admin create --sudo"
    fi
  fi
}

wait_for_marzban_http() {
  local elapsed=0
  local code=""
  while (( elapsed < 90 )); do
    code="$(curl -k -sS -o /dev/null -w '%{http_code}' --max-time 5 "https://${PANEL_DOMAIN}:${MARZBAN_PANEL_PORT}/dashboard/" || true)"
    if [[ "$code" =~ ^(200|301|302|307|308|401|403)$ ]]; then
      ok "Marzban HTTPS panel responds: HTTP ${code}"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  warn "Marzban HTTPS panel did not respond cleanly yet. Last HTTP code: ${code:-000}"
  warn "Check: docker compose -f /opt/marzban/docker-compose.yml logs --tail=100"
}
restart_marzban_safely() {
  # This function is intentionally kept for compatibility, but it must not be
  # called before final_start_marzban.
  warn "restart_marzban_safely was called. Skipping because Marzban start/restart is reserved for the final phase."
  return 0
}

wait_for_marzban_container() {
  local elapsed=0
  while (( elapsed < 180 )); do
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}} {{.Status}}' | grep -qi 'marzban'; then
      ok "Marzban container is running"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  warn "Could not confirm running Marzban container within 180 seconds."
}

install_marzban() {
  info "PHASE 4 — Preparing Marzban without final start"
  if [[ "$INSTALL_MARZBAN" =~ ^[Nn]$ ]]; then
    warn "Skipping Marzban install/repair by user request. Existing files will be used if present."
    if [[ ! -f "$MARZBAN_ENV" ]]; then
      warn "${MARZBAN_ENV} not found. Final Marzban start will also be skipped unless you enable install/repair."
    fi
    return 0
  fi

  prepare_marzban_files_without_start
  ok "Marzban prepared without starting/restarting"
}

set_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"
  touch "$file"
  python3 - "$file" "$key" "$value" <<'PY'
import re
import sys
from pathlib import Path

file_path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
path = Path(file_path)
lines = path.read_text(errors="ignore").splitlines() if path.exists() else []
pattern = re.compile(rf"^\s*#?\s*{re.escape(key)}=")
replacement = f"{key}={value}"
changed = False
out = []
for line in lines:
    if pattern.match(line):
        if not changed:
            out.append(replacement)
            changed = True
        # drop duplicate definitions silently
    else:
        out.append(line)
if not changed:
    out.append(replacement)
path.write_text("\n".join(out) + "\n")
PY
}

generate_marzban_inbound() {
  info "PHASE 5 — Generating Marzban VLESS XHTTP TLS inbound"
  mkdir -p "$OUTPUT_DIR" "$(dirname "$MARZBAN_XRAY_JSON")"

  jq -n \
    --arg tag "$INBOUND_TAG" \
    --argjson port "$INBOUND_PORT" \
    --arg domain "$ORIGIN_DOMAIN" \
    --arg path "$RELAY_PATH" \
    --arg cert "${CERT_DIR}/fullchain.pem" \
    --arg key "${CERT_DIR}/key.pem" \
    '{
      tag: $tag,
      listen: "0.0.0.0",
      port: $port,
      protocol: "vless",
      settings: {
        clients: [],
        decryption: "none"
      },
      streamSettings: {
        network: "xhttp",
        xhttpSettings: {
          path: $path,
          mode: "auto",
          extra: {
            xPaddingBytes: "100-1000"
          }
        },
        security: "tls",
        tlsSettings: {
          serverName: $domain,
          certificates: [
            {
              ocspStapling: 3600,
              certificateFile: $cert,
              keyFile: $key
            }
          ],
          minVersion: "1.2",
          alpn: ["h2", "http/1.1"]
        }
      },
      sniffing: {
        enabled: true,
        destOverride: ["http", "tls", "quic"]
      }
    }' > "${OUTPUT_DIR}/marzban-inbound.json"

  if [[ ! -f "$MARZBAN_XRAY_JSON" ]]; then
    cat > "$MARZBAN_XRAY_JSON" <<'EOF'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
  fi

  cp -f "$MARZBAN_XRAY_JSON" "${MARZBAN_XRAY_JSON}.bak.$(date +%Y%m%d%H%M%S)"
  local tmp
  tmp="$(mktemp)"
  jq --arg tag "$INBOUND_TAG" --slurpfile inbound "${OUTPUT_DIR}/marzban-inbound.json" '
    .inbounds = ((.inbounds // []) | map(select(.tag != $tag)) + [$inbound[0]]) |
    .outbounds = (if ((.outbounds // []) | length) == 0 then [{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}] else .outbounds end)
  ' "$MARZBAN_XRAY_JSON" > "$tmp"
  mv "$tmp" "$MARZBAN_XRAY_JSON"
  chmod 644 "$MARZBAN_XRAY_JSON"

  ok "Inbound inserted into ${MARZBAN_XRAY_JSON} and saved to ${OUTPUT_DIR}/marzban-inbound.json"
  warn "Marzban has NOT been restarted yet. Final start/recreate happens after Vercel deploy and final settings output."
}

prepare_vercel_project() {
  info "PHASE 6 — Preparing Vercel relay project"
  rm -rf "$VERCEL_WORKDIR"
  mkdir -p "${VERCEL_WORKDIR}/api" "${VERCEL_WORKDIR}/public"

  cat > "${VERCEL_WORKDIR}/package.json" <<EOF
{
  "name": "host-$(random_suffix)",
  "version": "1.0.$((RANDOM % 90 + 10))",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "node scripts/prepare-build.mjs"
  }
}
EOF

  mkdir -p "${VERCEL_WORKDIR}/scripts"
  cat > "${VERCEL_WORKDIR}/scripts/prepare-build.mjs" <<'EOF'
import { readFile, writeFile } from "node:fs/promises";

const tokens = {
  "{{BUILD_CODE}}": Math.random().toString(36).slice(2, 10).toUpperCase(),
  "{{PUBLIC_RELAY_PATH}}": process.env.PUBLIC_RELAY_PATH || "/api",
  "{{GENERATED_AT}}": new Date().toISOString()
};

for (const file of ["public/index.html", "public/styles.css", "public/app.js"]) {
  let content = await readFile(file, "utf8");
  for (const [key, value] of Object.entries(tokens)) {
    content = content.split(key).join(value);
  }
  await writeFile(file, content, "utf8");
}
console.log("Static landing page prepared.");
EOF

  cat > "${VERCEL_WORKDIR}/vercel.json" <<'EOF'
{
  "version": 2,
  "buildCommand": "npm run build",
  "functions": {
    "api/index.js": {
      "memory": 128,
      "maxDuration": 60
    }
  },
  "rewrites": [
    {
      "source": "/api",
      "destination": "/api/index"
    },
    {
      "source": "/api/:path*",
      "destination": "/api/index"
    }
  ],
  "trailingSlash": false
}
EOF

  cat > "${VERCEL_WORKDIR}/public/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Luma Bistro</title>
  <link rel="stylesheet" href="/styles.css" />
</head>
<body>
  <header class="site-header">
    <div class="brand">Luma Bistro</div>
    <nav>
      <a href="#menu">Menu</a>
      <a href="#visit">Visit</a>
    </nav>
  </header>

  <main>
    <section class="hero">
      <p class="eyebrow">Seasonal kitchen · Build {{BUILD_CODE}}</p>
      <h1>Fresh plates, calm evenings, and a small menu done well.</h1>
      <p class="lead">A lightweight restaurant landing page served from the relay project. Service endpoint: <code>{{PUBLIC_RELAY_PATH}}</code>.</p>
    </section>

    <section id="menu" class="cards">
      <article><span>01</span><h2>Garden Bowl</h2><p>Herbs, grains, roasted vegetables, citrus dressing.</p></article>
      <article><span>02</span><h2>Smoke Salmon</h2><p>Warm bread, dill cream, pickled cucumber.</p></article>
      <article><span>03</span><h2>Velvet Cake</h2><p>Dark cocoa, light cream, berry finish.</p></article>
    </section>
  </main>

  <footer id="visit">
    <p>Open daily · 18:00–23:00 · Generated {{GENERATED_AT}}</p>
  </footer>
  <script src="/app.js"></script>
</body>
</html>
EOF

  cat > "${VERCEL_WORKDIR}/public/styles.css" <<'EOF'
:root{font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#172018;background:#fbf7ef}*{box-sizing:border-box}body{margin:0;min-height:100vh;background:radial-gradient(circle at top left,#ffe4bd,transparent 32%),#fbf7ef;color:#172018}.site-header{display:flex;justify-content:space-between;align-items:center;padding:22px clamp(20px,6vw,70px);border-bottom:1px solid rgba(23,32,24,.08)}.brand{font-weight:900;letter-spacing:-.04em;font-size:24px}nav{display:flex;gap:18px}a{color:#172018;text-decoration:none;font-weight:700}.hero{padding:82px clamp(20px,8vw,110px) 48px;max-width:950px}.eyebrow{margin:0 0 16px;color:#9a5f21;font-weight:800;text-transform:uppercase;letter-spacing:.14em;font-size:12px}h1{margin:0;font-size:clamp(42px,7vw,86px);line-height:.92;letter-spacing:-.075em}.lead{max-width:660px;font-size:18px;line-height:1.8;color:#53614f}code{background:#fff;border:1px solid rgba(23,32,24,.1);padding:3px 7px;border-radius:8px}.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;padding:0 clamp(20px,8vw,110px) 72px}article{background:rgba(255,255,255,.72);border:1px solid rgba(23,32,24,.08);border-radius:24px;padding:24px;box-shadow:0 22px 50px rgba(80,55,22,.08)}article span{font-weight:900;color:#b7772a}h2{margin:18px 0 8px;font-size:24px}article p{margin:0;color:#5e6b58;line-height:1.65}footer{padding:24px clamp(20px,6vw,70px);border-top:1px solid rgba(23,32,24,.08);color:#687462}@media(max-width:760px){.site-header{align-items:flex-start;gap:12px;flex-direction:column}.cards{grid-template-columns:1fr}.hero{padding-top:56px}}
EOF

  cat > "${VERCEL_WORKDIR}/public/app.js" <<'EOF'
const header = document.querySelector('.site-header');
window.addEventListener('scroll', () => {
  header.style.background = window.scrollY > 10 ? 'rgba(251,247,239,.86)' : 'transparent';
  header.style.backdropFilter = window.scrollY > 10 ? 'blur(14px)' : 'none';
});
EOF

  cat > "${VERCEL_WORKDIR}/api/index.js" <<'EOF'
import { Readable, Transform, PassThrough } from "node:stream";
import { pipeline } from "node:stream/promises";
import { setDefaultResultOrder } from "node:dns";

export const config = {
  api: { bodyParser: false },
  supportsResponseStreaming: true,
  maxDuration: 60
};

const TARGET_BASE = String(process.env.TARGET_DOMAIN || "").replace(/\/$/, "");
const RELAY_PATH = normalizePath(process.env.RELAY_PATH || "/api");
const PUBLIC_RELAY_PATH = normalizePath(process.env.PUBLIC_RELAY_PATH || "/api");
const UPSTREAM_TIMEOUT_MS = numberEnv("UPSTREAM_TIMEOUT_MS", 50000, 1000);
const MAX_INFLIGHT = numberEnv("MAX_INFLIGHT", 128, 1);
const MAX_UP_BPS = numberEnv("MAX_UP_BPS", 2621440, 0);
const MAX_DOWN_BPS = numberEnv("MAX_DOWN_BPS", 2621440, 0);
const DNS_ORDER = String(process.env.UPSTREAM_DNS_ORDER || "ipv4first").trim();

try { if (DNS_ORDER === "ipv4first" || DNS_ORDER === "verbatim") setDefaultResultOrder(DNS_ORDER); } catch {}

const ALLOWED_METHODS = new Set(["GET", "HEAD", "POST"]);
const STRIP_HEADERS = new Set([
  "host", "connection", "proxy-connection", "keep-alive", "via", "te", "trailer",
  "transfer-encoding", "upgrade", "forwarded", "x-forwarded-host", "x-forwarded-proto",
  "x-forwarded-port", "x-vercel-id", "x-vercel-deployment-url"
]);
const FORWARD_HEADER_EXACT = new Set([
  "accept", "accept-encoding", "accept-language", "cache-control", "content-length",
  "content-type", "pragma", "range", "referer", "user-agent"
]);
const FORWARD_HEADER_PREFIXES = ["sec-ch-", "sec-fetch-"];
const uploadLimiter = createLimiter(MAX_UP_BPS);
const downloadLimiter = createLimiter(MAX_DOWN_BPS);
let inFlight = 0;

export default async function handler(req, res) {
  const started = Date.now();
  let acquired = false;

  try {
    if (!TARGET_BASE) return sendText(res, 500, "Misconfigured: TARGET_DOMAIN is not set");
    if (!ALLOWED_METHODS.has(req.method)) {
      res.setHeader("allow", "GET, HEAD, POST");
      return sendText(res, 405, "Method Not Allowed");
    }

    const incoming = new URL(req.url || "/", `https://${req.headers.host || "localhost"}`);
    const requestPath = normalizePath(incoming.pathname);
    if (!isRelayPath(requestPath, PUBLIC_RELAY_PATH)) return sendText(res, 404, "Not Found");

    if (!tryAcquire()) {
      res.setHeader("retry-after", "1");
      return sendText(res, 503, "Server Busy");
    }
    acquired = true;

    const upstreamPath = mapPath(requestPath, PUBLIC_RELAY_PATH, RELAY_PATH);
    const targetUrl = `${TARGET_BASE}${upstreamPath}${incoming.search || ""}`;
    const headers = buildHeaders(req);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(new Error("upstream_timeout")), UPSTREAM_TIMEOUT_MS);

    try {
      const opts = { method: req.method, headers, redirect: "manual", signal: controller.signal };
      if (req.method !== "GET" && req.method !== "HEAD") {
        const upload = uploadLimiter ? req.pipe(throttle(uploadLimiter)) : req;
        opts.body = Readable.toWeb(upload);
        opts.duplex = "half";
      }

      const upstream = await fetch(targetUrl, opts);
      res.statusCode = upstream.status;
      for (const [name, value] of upstream.headers) {
        const lower = name.toLowerCase();
        if (lower === "transfer-encoding" || lower === "connection") continue;
        try { res.setHeader(name, value); } catch {}
      }

      if (!upstream.body) return res.end();
      const body = Readable.fromWeb(upstream.body);
      const output = downloadLimiter ? body.pipe(throttle(downloadLimiter)) : body;
      await pipeline(output, res);
      if (upstream.status >= 400) console.warn("relay upstream status", { status: upstream.status, path: requestPath, ms: Date.now() - started });
    } finally {
      clearTimeout(timeout);
    }
  } catch (err) {
    console.error("relay error", { error: String(err), ms: Date.now() - started });
    if (!res.headersSent) sendText(res, isTimeout(err) ? 504 : 502, isTimeout(err) ? "Gateway Timeout" : "Bad Gateway");
  } finally {
    if (acquired) release();
  }
}

function buildHeaders(req) {
  const headers = {};
  for (const [key, value] of Object.entries(req.headers || {})) {
    const lower = key.toLowerCase();
    if (STRIP_HEADERS.has(lower) || lower.startsWith("x-vercel-")) continue;
    if (!FORWARD_HEADER_EXACT.has(lower) && !FORWARD_HEADER_PREFIXES.some((p) => lower.startsWith(p))) continue;
    const v = Array.isArray(value) ? value.join(", ") : String(value || "");
    if (v) headers[lower] = v;
  }
  return headers;
}
function sendText(res, status, text) { res.statusCode = status; res.setHeader("content-type", "text/plain; charset=utf-8"); res.end(text); }
function normalizePath(raw) { let p = String(raw || "/api").trim(); if (!p.startsWith("/")) p = `/${p}`; p = p.replace(/\/+/g, "/"); if (p.length > 1 && p.endsWith("/")) p = p.slice(0, -1); return p; }
function isRelayPath(path, base) { return path === base || path.startsWith(`${base}/`); }
function mapPath(path, publicBase, relayBase) { return path === publicBase ? relayBase : `${relayBase}${path.slice(publicBase.length)}`; }
function numberEnv(name, fallback, min) { const n = Number(process.env[name]); return Number.isFinite(n) && n >= min ? Math.trunc(n) : fallback; }
function isTimeout(err) { return err?.name === "AbortError" || err?.message === "upstream_timeout" || err?.cause?.message === "upstream_timeout"; }
function tryAcquire() { if (inFlight >= MAX_INFLIGHT) return false; inFlight += 1; return true; }
function release() { inFlight = Math.max(0, inFlight - 1); }
function createLimiter(bytesPerSecond) { if (!Number.isFinite(bytesPerSecond) || bytesPerSecond <= 0) return null; const burst = Math.max(bytesPerSecond, 262144); let tokens = burst; let last = Date.now(); return { async take(maxBytes) { refill(); if (tokens < 1) await sleep(4); refill(); const grant = Math.min(maxBytes, Math.max(1, Math.floor(tokens))); tokens -= grant; return grant; } }; function refill(){ const now=Date.now(); tokens=Math.min(burst,tokens+((now-last)*bytesPerSecond)/1000); last=now; } }
function throttle(limiter) { if (!limiter) return new PassThrough(); return new Transform({ transform(chunk, _enc, cb) { (async()=>{ let i=0; while(i<chunk.length){ const n=await limiter.take(chunk.length-i); this.push(chunk.subarray(i,i+n)); i+=n; } })().then(()=>cb()).catch(cb); } }); }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
EOF

  ok "Vercel relay project prepared at ${VERCEL_WORKDIR}"
}
vercel_args() {
  if [[ -n "$VERCEL_SCOPE" ]]; then
    printf '%s\n' "--scope" "$VERCEL_SCOPE"
  fi
}

set_vercel_env() {
  local key="$1"
  local value="$2"
  local args=()
  if [[ -n "$VERCEL_SCOPE" ]]; then
    args+=(--scope "$VERCEL_SCOPE")
  fi

  if ! printf '%s' "$value" | vercel env add "$key" production --force "${args[@]}" >/dev/null 2>&1; then
    vercel env rm "$key" production --yes "${args[@]}" >/dev/null 2>&1 || true
    printf '%s' "$value" | vercel env add "$key" production "${args[@]}" >/dev/null
  fi
}

deploy_vercel() {
  info "PHASE 7 — Deploying Vercel relay"
  export VERCEL_TOKEN="$VERCEL_TOKEN_INPUT"
  cd "$VERCEL_WORKDIR"

  local args=()
  if [[ -n "$VERCEL_SCOPE" ]]; then
    args+=(--scope "$VERCEL_SCOPE")
  fi

  vercel whoami "${args[@]}" >/dev/null
  ok "Vercel auth OK: $(vercel whoami "${args[@]}" | tail -n 1)"

  # Link creates the project when possible. If the project already exists, it links to it.
  vercel link --yes --project "$VERCEL_PROJECT" "${args[@]}" >/dev/null
  ok "Vercel project linked or created: ${VERCEL_PROJECT}"

  set_vercel_env "TARGET_DOMAIN" "$TARGET_DOMAIN"
  set_vercel_env "RELAY_PATH" "$RELAY_PATH"
  set_vercel_env "PUBLIC_RELAY_PATH" "$PUBLIC_RELAY_PATH"
  set_vercel_env "MAX_INFLIGHT" "$MAX_INFLIGHT"
  set_vercel_env "MAX_UP_BPS" "$MAX_UP_BPS"
  set_vercel_env "MAX_DOWN_BPS" "$MAX_DOWN_BPS"
  set_vercel_env "UPSTREAM_TIMEOUT_MS" "$UPSTREAM_TIMEOUT_MS"
  set_vercel_env "SUCCESS_LOG_SAMPLE_RATE" "$SUCCESS_LOG_SAMPLE_RATE"
  set_vercel_env "SUCCESS_LOG_MIN_DURATION_MS" "$SUCCESS_LOG_MIN_DURATION_MS"
  set_vercel_env "ERROR_LOG_MIN_INTERVAL_MS" "$ERROR_LOG_MIN_INTERVAL_MS"
  ok "Vercel ENV variables set"

  local deploy_output=""
  local attempt
  for attempt in 1 2 3; do
    info "Vercel deploy attempt ${attempt}/3"
    set +e
    deploy_output="$(vercel deploy --prod --yes "${args[@]}" 2>&1)"
    local status=$?
    set -e
    echo "$deploy_output"
    RELAY_URL="$(echo "$deploy_output" | grep -Eo 'https://[^[:space:]]+\.vercel\.app' | tail -n 1 || true)"
    if [[ "$status" -eq 0 && -n "$RELAY_URL" ]]; then
      break
    fi
    warn "Vercel deploy attempt ${attempt} failed or URL not detected. Retrying..."
    sleep 5
  done

  [[ -n "$RELAY_URL" ]] || fail "Could not detect Vercel production URL from deploy output."
  RELAY_DOMAIN="${RELAY_URL#https://}"
  ok "Production URL: ${RELAY_URL}"

  if [[ -z "$CLIENT_ADDRESS" ]]; then
    CLIENT_ADDRESS="$RELAY_DOMAIN"
  fi

  cat >> "${STATE_DIR}/input.env" <<EOF
RELAY_URL='${RELAY_URL}'
RELAY_DOMAIN='${RELAY_DOMAIN}'
EOF
}

health_checks() {
  info "PHASE 8 — Post-start health checks and diagnostics"
  mkdir -p "$OUTPUT_DIR"
  local upstream_code relay_code panel_code root_code

  panel_code="$(curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${PANEL_DOMAIN}:${MARZBAN_PANEL_PORT}/dashboard/" || true)"
  if [[ "$panel_code" =~ ^(200|301|302|307|308|401|403)$ ]]; then
    ok "Marzban panel reachable: HTTP ${panel_code}"
  else
    warn "Marzban panel check returned HTTP ${panel_code:-000}. Check ${OUTPUT_DIR}/marzban-final-start.log and docker logs."
  fi

  upstream_code="$(curl -k -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://${ORIGIN_DOMAIN}:${INBOUND_PORT}${RELAY_PATH}" || true)"
  if [[ "$upstream_code" =~ ^(200|204|301|302|400|401|403|404|405)$ ]]; then
    ok "Origin reachable: HTTP ${upstream_code} on ${ORIGIN_DOMAIN}:${INBOUND_PORT}${RELAY_PATH}"
  else
    warn "Origin check returned HTTP ${upstream_code:-000}. If v2rayNG shows EOF, check Xray inbound and port 443."
  fi

  root_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "${RELAY_URL}/" || true)"
  if [[ "$root_code" =~ ^(200|301|302)$ ]]; then
    ok "Vercel public landing page reachable: HTTP ${root_code}"
  else
    warn "Vercel landing page returned HTTP ${root_code:-000}. This does not always break XHTTP, but Vercel deployment should be checked."
  fi

  relay_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "${RELAY_URL}${PUBLIC_RELAY_PATH}" || true)"
  if [[ "$relay_code" =~ ^(200|204|301|302|400|401|403|404|405|502|504)$ ]]; then
    ok "Relay endpoint reachable: HTTP ${relay_code} on ${RELAY_URL}${PUBLIC_RELAY_PATH}"
    if [[ "$relay_code" == "401" ]]; then
      warn "HTTP 401 usually means Vercel Deployment Protection is enabled. Disable it in Vercel project settings."
    fi
  else
    warn "Relay endpoint returned HTTP ${relay_code:-000}. If it is 000, Vercel/Internet connectivity failed."
  fi

  cat > "${OUTPUT_DIR}/diagnostic-commands.txt" <<EOF
Diagnostic commands
===================

1) Marzban container status:
cd /opt/marzban && docker compose ps

2) Marzban logs:
cd /opt/marzban && docker compose logs --tail=150 marzban

3) Confirm panel HTTPS:
curl -kI https://${PANEL_DOMAIN}:${MARZBAN_PANEL_PORT}/dashboard/

4) Confirm origin XHTTP endpoint returns a normal HTTP code:
curl -kI https://${ORIGIN_DOMAIN}:${INBOUND_PORT}${RELAY_PATH}

5) Confirm Vercel public site:
curl -I ${RELAY_URL}/

6) Confirm Vercel relay endpoint:
curl -I ${RELAY_URL}${PUBLIC_RELAY_PATH}

7) Check generated Xray inbound tag inside Marzban core:
jq '.inbounds[] | select(.tag == "${INBOUND_TAG}")' ${MARZBAN_XRAY_JSON}

EOF
  ok "Diagnostic commands written to ${OUTPUT_DIR}/diagnostic-commands.txt"
}
generate_final_outputs() {
  info "PHASE 9 — Writing final Marzban settings"
  local host_txt="${OUTPUT_DIR}/marzban-host-settings.txt"
  local summary_txt="${OUTPUT_DIR}/summary.txt"

  cat > "$host_txt" <<EOF
Marzban Host Settings
=====================

Select inbound/tag:
${INBOUND_TAG}

Remark:
XHTTP Vercel - {USERNAME}

Address:
${CLIENT_ADDRESS}

Alternative Address for test:
${RELAY_DOMAIN}

Port:
443

SNI:
${RELAY_DOMAIN}

Host:
${RELAY_DOMAIN}

Path:
${PUBLIC_RELAY_PATH}

Security Layer:
TLS

ALPN:
h2,http/1.1

Fingerprint:
chrome

Allow Insecure:
false

Flow:
(empty)

Network:
xhttp

Mode:
auto

Extra:
{"xPaddingBytes":"100-1000"}
EOF

  cat > "$summary_txt" <<EOF
Installation Summary
====================

Origin domain:       ${ORIGIN_DOMAIN}
Target domain:       ${TARGET_DOMAIN}
Marzban panel:       https://${PANEL_DOMAIN}:${MARZBAN_PANEL_PORT}/dashboard/
Marzban subscription prefix: https://${PANEL_DOMAIN}:${MARZBAN_PANEL_PORT}
Inbound tag:         ${INBOUND_TAG}
Inbound port:        ${INBOUND_PORT}
Relay URL:           ${RELAY_URL}
Relay domain:        ${RELAY_DOMAIN}
RELAY_PATH:          ${RELAY_PATH}
PUBLIC_RELAY_PATH:   ${PUBLIC_RELAY_PATH}
Client address:      ${CLIENT_ADDRESS}
Cert fullchain:      ${CERT_DIR}/fullchain.pem
Cert key:            ${CERT_DIR}/key.pem
Marzban Xray JSON:   ${MARZBAN_XRAY_JSON}
Generated inbound:   ${OUTPUT_DIR}/marzban-inbound.json
Host settings file:  ${host_txt}
Install log:         ${LOG_FILE}

Next steps:
1. Open Marzban dashboard.
2. Check Settings > Core Settings and confirm inbound tag exists: ${INBOUND_TAG}
3. Open Settings > Host Settings and enter values from ${host_txt}
4. Create a user and enable this inbound.
5. Import/update the user's subscription in v2rayNG.
EOF

  cat > "${OUTPUT_DIR}/vercel-env.txt" <<EOF
TARGET_DOMAIN=${TARGET_DOMAIN}
RELAY_PATH=${RELAY_PATH}
PUBLIC_RELAY_PATH=${PUBLIC_RELAY_PATH}
MAX_INFLIGHT=${MAX_INFLIGHT}
MAX_UP_BPS=${MAX_UP_BPS}
MAX_DOWN_BPS=${MAX_DOWN_BPS}
UPSTREAM_TIMEOUT_MS=${UPSTREAM_TIMEOUT_MS}
SUCCESS_LOG_SAMPLE_RATE=${SUCCESS_LOG_SAMPLE_RATE}
SUCCESS_LOG_MIN_DURATION_MS=${SUCCESS_LOG_MIN_DURATION_MS}
ERROR_LOG_MIN_INTERVAL_MS=${ERROR_LOG_MIN_INTERVAL_MS}
EOF

  ok "Final output written to ${OUTPUT_DIR}"

  cat <<EOF

╔══════════════════════════════════════════════════════════╗
║      MAIN SETUP COMPLETE — MARZBAN START IS NEXT        ║
╚══════════════════════════════════════════════════════════╝

The Vercel project has been deployed and all Marzban settings have been written.
The installer will now start/recreate Marzban as the FINAL step only.

Origin Domain      : ${ORIGIN_DOMAIN}
Target Domain      : ${TARGET_DOMAIN}
Marzban Panel      : https://${PANEL_DOMAIN}:${MARZBAN_PANEL_PORT}/dashboard/
Relay URL          : ${RELAY_URL}
Relay Domain       : ${RELAY_DOMAIN}
Inbound Tag        : ${INBOUND_TAG}
RELAY_PATH         : ${RELAY_PATH}
PUBLIC_PATH        : ${PUBLIC_RELAY_PATH}
Client Address     : ${CLIENT_ADDRESS}
Alternative Address: ${RELAY_DOMAIN}

── Marzban Host Settings ──
Address           : ${CLIENT_ADDRESS}
Port              : 443
SNI               : ${RELAY_DOMAIN}
Host              : ${RELAY_DOMAIN}
Path              : ${PUBLIC_RELAY_PATH}
Security          : TLS
ALPN              : h2,http/1.1
Fingerprint       : chrome
Network           : xhttp
Mode              : auto
Extra             : {"xPaddingBytes":"100-1000"}

If v2rayNG shows EOF, first test Address=${RELAY_DOMAIN} instead of the pinned IP.

Files:
- ${OUTPUT_DIR}/marzban-inbound.json
- ${OUTPUT_DIR}/marzban-host-settings.txt
- ${OUTPUT_DIR}/summary.txt
- ${LOG_FILE}

EOF
}

main() {
  print_banner
  require_root
  require_ubuntu
  collect_inputs
  install_base_dependencies
  install_node_and_vercel
  validate_vercel_credentials
  install_acme
  check_dns
  obtain_ssl
  install_marzban
  generate_marzban_inbound
  prepare_vercel_project
  deploy_vercel
  generate_final_outputs
  final_start_marzban
  health_checks
  echo
  ok "All done. Marzban final start/recreate phase has completed."
}

main "$@"
