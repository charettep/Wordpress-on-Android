#!/bin/bash
set -euo pipefail

log() {
  printf '%s\n' "$*"
}

die() {
  log "Error: $*"
  exit 1
}

run_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

APT_UPDATED=0
apt_update_once() {
  if [ "$APT_UPDATED" -eq 0 ]; then
    run_sudo apt-get update
    APT_UPDATED=1
  fi
}

apt_update_force() {
  APT_UPDATED=0
  apt_update_once
}

install_pkg() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    apt_update_once
    run_sudo apt-get install -y "$pkg"
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

read_os_release() {
  [ -r /etc/os-release ] || die "/etc/os-release not found (unsupported distro)"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
  OS_PRETTY_NAME="${PRETTY_NAME:-}"

  if [ -z "$OS_ID" ]; then
    die "Could not determine distro ID from /etc/os-release"
  fi

  if [ -z "$OS_VERSION_CODENAME" ]; then
    die "Could not determine VERSION_CODENAME from /etc/os-release"
  fi

  case "$OS_ID" in
    debian) DOCKER_LINUX="debian" ;;
    ubuntu) DOCKER_LINUX="ubuntu" ;;
    *) die "Unsupported distro '$OS_ID' (supported: debian, ubuntu)" ;;
  esac
}

get_target_user() {
  TARGET_USER="${SUDO_USER:-${USER:-}}"
  if [ -z "$TARGET_USER" ]; then
    die "Could not determine target user (SUDO_USER/USER unset)"
  fi

  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    die "Could not determine home directory for user '$TARGET_USER'"
  fi
}

gen_hex() {
  local bytes="$1"
  openssl rand -hex "$bytes"
}

write_env_file() {
  local env_file="$1"

  umask 077
  cat >"$env_file" <<EOF
WP_DB_NAME=$WP_DB_NAME
WP_DB_USER=$WP_DB_USER
WP_DB_PASSWORD=$WP_DB_PASSWORD
WP_DB_ROOT_PASSWORD=$WP_DB_ROOT_PASSWORD
WP_PORT=$WP_PORT
EOF
  chmod 600 "$env_file" 2>/dev/null || true
  run_sudo chown "$TARGET_USER":"$TARGET_USER" "$env_file" 2>/dev/null || true
}

load_env_file() {
  local env_file="$1"

  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      WP_DB_NAME|WP_DB_USER|WP_DB_PASSWORD|WP_DB_ROOT_PASSWORD|WP_PORT) ;;
      ""|\#*) continue ;;
      *) continue ;;
    esac

    # Backwards-compatibility: older versions wrote values in double-quotes.
    if [ "${value#\"}" != "$value" ] && [ "${value%\"}" != "$value" ]; then
      value="${value#\"}"
      value="${value%\"}"
    fi
    value="${value%$'\r'}"

    if [ -z "$value" ]; then
      die "Invalid empty value for '$key' in $env_file"
    fi

    case "$value" in
      *[!A-Za-z0-9_]*)
        die "Invalid characters in '$key' in $env_file (expected [A-Za-z0-9_])"
        ;;
    esac

    printf -v "$key" '%s' "$value"
  done <"$env_file"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    return
  fi

  # Docker docs (Debian/Ubuntu): https://docs.docker.com/engine/install/
  CONFLICTING_DOCKER_PKGS=(docker.io docker-compose docker-doc podman-docker containerd runc)
  INSTALLED_CONFLICTS="$(dpkg --get-selections "${CONFLICTING_DOCKER_PKGS[@]}" 2>/dev/null | awk '$2 == "install" {print $1}' | tr '\n' ' ')"
  if [ -n "${INSTALLED_CONFLICTS// }" ]; then
    run_sudo apt-get remove -y $INSTALLED_CONFLICTS
  fi

  apt_update_once
  run_sudo apt-get install -y ca-certificates curl
  run_sudo install -m 0755 -d /etc/apt/keyrings
  run_sudo curl -fsSL "https://download.docker.com/linux/${DOCKER_LINUX}/gpg" -o /etc/apt/keyrings/docker.asc
  run_sudo chmod a+r /etc/apt/keyrings/docker.asc

  run_sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/${DOCKER_LINUX}
Suites: ${OS_VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt_update_force
  run_sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

ensure_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    return
  fi

  # Cloudflare packages docs (recommended "any"): https://pkg.cloudflare.com/
  apt_update_once
  run_sudo apt-get install -y ca-certificates curl
  run_sudo mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | run_sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | run_sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
  apt_update_force
  run_sudo apt-get install -y cloudflared
}

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    run_sudo docker "$@"
  fi
}

#----------------------------
# interactive Cloudflare input (the part humans always forget)
#----------------------------
printf "Cloudflare API token (must have: Cloudflare Tunnel Edit + DNS Edit): "
IFS= read -rs CF_API_TOKEN
printf "\n"
if [ -z "$CF_API_TOKEN" ]; then
  echo "Cloudflare API token is required. Try again when you remember it."
  exit 1
fi

read -rp "Public hostname to expose (FQDN, e.g. lde123.example.com): " CF_HOSTNAME
if [ -z "$CF_HOSTNAME" ]; then
  echo "Hostname is required. You said you wanted it wired. This is the wire."
  exit 1
fi

export CF_API_TOKEN CF_HOSTNAME

#----------------------------
# preflight
#----------------------------
require_cmd dpkg
require_cmd getent
require_cmd apt-get
if [ "$(id -u)" -ne 0 ]; then
  require_cmd sudo
fi
read_os_release
get_target_user

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) ;;
  *)
    log "Warning: architecture '$ARCH' is not explicitly supported by upstream Docker packages."
    ;;
esac

log "Detected OS: ${OS_PRETTY_NAME:-$OS_ID} (${OS_ID}/${OS_VERSION_CODENAME}), arch: $ARCH"

# ensure core tools for secure credential generation + API parsing
install_pkg openssl
install_pkg jq

#=====================================================================
# WordPress-on-Docker
#=====================================================================
#----------------------------
# 0. basic dirs
#----------------------------
PROJECT_DIR="${TARGET_HOME}/wordpress-docker"
run_sudo mkdir -p "$PROJECT_DIR"
run_sudo chown "$TARGET_USER":"$TARGET_USER" "$PROJECT_DIR" 2>/dev/null || true
cd "$PROJECT_DIR"

#----------------------------
# 1. install Docker (per official docs) + start daemon
#----------------------------
ensure_docker
run_sudo systemctl enable --now docker 2>/dev/null || run_sudo service docker start 2>/dev/null || true

#----------------------------
# 2. .env credentials (generate securely, persist to disk)
#----------------------------
ENV_FILE="$PROJECT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  load_env_file "$ENV_FILE"
else
  WP_DB_NAME="wordpress_$(gen_hex 3)"
  WP_DB_USER="wpuser_$(gen_hex 2)"
  WP_DB_PASSWORD="$(gen_hex 16)"
  WP_DB_ROOT_PASSWORD="$(gen_hex 24)"
  WP_PORT=8080
  write_env_file "$ENV_FILE"
fi

#----------------------------
# 3. docker network & volumes
#----------------------------
if ! docker_cmd network inspect wp-net >/dev/null 2>&1; then
  docker_cmd network create wp-net
fi

#----------------------------
# 4. start MariaDB container (idempotent)
#----------------------------
if docker_cmd container inspect wp-mariadb >/dev/null 2>&1; then
  if ! docker_cmd ps --format '{{.Names}}' | grep -qx 'wp-mariadb'; then
    docker_cmd start wp-mariadb >/dev/null
  fi
else
  docker_cmd volume inspect wp-mariadb-data >/dev/null 2>&1 || docker_cmd volume create wp-mariadb-data >/dev/null
  docker_cmd run -d \
    --name wp-mariadb \
    --network wp-net \
    -v wp-mariadb-data:/var/lib/mysql \
    -e MARIADB_DATABASE="$WP_DB_NAME" \
    -e MARIADB_USER="$WP_DB_USER" \
    -e MARIADB_PASSWORD="$WP_DB_PASSWORD" \
    -e MARIADB_ROOT_PASSWORD="$WP_DB_ROOT_PASSWORD" \
    --restart unless-stopped \
    mariadb:11
fi

#----------------------------
# 5. pick HTTP port (persisted in .env)
#----------------------------
if [ -z "${WP_PORT:-}" ]; then
  WP_PORT=8080
fi

# If wordpress container already exists, reuse its port mapping.
if docker_cmd container inspect wordpress >/dev/null 2>&1; then
  mapped_port="$(docker_cmd port wordpress 80/tcp 2>/dev/null | head -n 1 | sed 's/.*://')"
  if [ -n "${mapped_port:-}" ]; then
    WP_PORT="$mapped_port"
    write_env_file "$ENV_FILE"
  fi
else
  # Avoid clobbering a local service on the chosen port.
  if command -v ss >/dev/null 2>&1 && ss -ltnH "( sport = :$WP_PORT )" | grep -q .; then
    if [ "$WP_PORT" -eq 8080 ]; then
      WP_PORT=8081
    fi
  fi
  write_env_file "$ENV_FILE"
fi

#----------------------------
# 6. start WordPress container (idempotent, binds localhost-only)
#----------------------------
if docker_cmd container inspect wordpress >/dev/null 2>&1; then
  if ! docker_cmd ps --format '{{.Names}}' | grep -qx 'wordpress'; then
    docker_cmd start wordpress >/dev/null
  fi
else
  docker_cmd volume inspect wp-wordpress-data >/dev/null 2>&1 || docker_cmd volume create wp-wordpress-data >/dev/null
  docker_cmd run -d \
    --name wordpress \
    --network wp-net \
    -e WORDPRESS_DB_HOST=wp-mariadb:3306 \
    -e WORDPRESS_DB_NAME="$WP_DB_NAME" \
    -e WORDPRESS_DB_USER="$WP_DB_USER" \
    -e WORDPRESS_DB_PASSWORD="$WP_DB_PASSWORD" \
    -v wp-wordpress-data:/var/www/html \
    -p "127.0.0.1:${WP_PORT}:80" \
    --restart unless-stopped \
    wordpress:latest
fi

#----------------------------
# 7. final local status (no secrets)
#----------------------------
log
log "------------------------------------------------------------"
log "WordPress Docker stack is up."
log "Project dir: $PROJECT_DIR"
log "Local URL:   http://localhost:${WP_PORT}"
log "Env file:    $ENV_FILE"
log "------------------------------------------------------------"

#=====================================================================
# Cloudflare Tunnel + DNS automation
#=====================================================================

ensure_cloudflared

echo "[cf] discovering Cloudflare account..."
ACCOUNTS_JSON=$(curl -sS -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" https://api.cloudflare.com/client/v4/accounts)
if [ "$(echo "$ACCOUNTS_JSON" | jq -r '.success')" != "true" ]; then
  echo "Failed to fetch Cloudflare accounts. Raw:"
  echo "$ACCOUNTS_JSON"
  exit 1
fi

CF_ACCOUNT_ID=$(echo "$ACCOUNTS_JSON" | jq -r '.result[0].id')
CF_ACCOUNT_NAME=$(echo "$ACCOUNTS_JSON" | jq -r '.result[0].name')
if [ -z "$CF_ACCOUNT_ID" ] || [ "$CF_ACCOUNT_ID" = "null" ]; then
  echo "Could not determine Cloudflare account id."
  exit 1
fi
echo "[cf] using account: $CF_ACCOUNT_NAME ($CF_ACCOUNT_ID)"

echo "[cf] determining zone for hostname $CF_HOSTNAME ..."
ZONES_JSON=$(curl -sS -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "https://api.cloudflare.com/client/v4/zones?per_page=200")
if [ "$(echo "$ZONES_JSON" | jq -r '.success')" != "true" ]; then
  echo "Failed to list zones."
  echo "$ZONES_JSON"
  exit 1
fi

CF_ZONE_ID=""
CF_ZONE_NAME=""
BEST_LEN=0

while IFS= read -r zline; do
  zname=$(echo "$zline" | cut -d'|' -f1)
  zid=$(echo "$zline" | cut -d'|' -f2)
  case "$CF_HOSTNAME" in
    "$zname"|*".${zname}")
      if [ "${#zname}" -gt "$BEST_LEN" ]; then
        CF_ZONE_ID="$zid"
        CF_ZONE_NAME="$zname"
        BEST_LEN="${#zname}"
      fi
      ;;
  esac
done < <(echo "$ZONES_JSON" | jq -r '.result[] | "\(.name)|\(.id)"')

if [ -z "$CF_ZONE_ID" ]; then
  echo "Could not match hostname '$CF_HOSTNAME' to any zone in your account."
  exit 1
fi
echo "[cf] using zone: $CF_ZONE_NAME ($CF_ZONE_ID)"

# tunnel name (stable per-hostname)
TUNNEL_NAME="wp-${CF_HOSTNAME//./-}"

echo "[cf] looking for existing tunnel named $TUNNEL_NAME ..."
LIST_TUNNELS_JSON=$(curl -sS -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel")
if [ "$(echo "$LIST_TUNNELS_JSON" | jq -r '.success')" != "true" ]; then
  echo "Failed to list tunnels."
  echo "$LIST_TUNNELS_JSON"
  exit 1
fi

TUNNEL_ID=$(echo "$LIST_TUNNELS_JSON" | jq -r --arg n "$TUNNEL_NAME" '.result[] | select(.name == $n) | .id' | head -n 1)

if [ -n "$TUNNEL_ID" ] && [ "$TUNNEL_ID" != "null" ]; then
  echo "[cf] reusing tunnel id: $TUNNEL_ID"
  GET_TOKEN_JSON=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json")
  if [ "$(echo "$GET_TOKEN_JSON" | jq -r '.success')" != "true" ]; then
    echo "Failed to fetch tunnel token."
    echo "$GET_TOKEN_JSON"
    exit 1
  fi
  TUNNEL_TOKEN=$(echo "$GET_TOKEN_JSON" | jq -r '.result')
else
  echo "[cf] creating tunnel $TUNNEL_NAME ..."
  CREATE_TUNNEL_JSON=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data '{"name":"'"$TUNNEL_NAME"'","config_src":"cloudflare"}')

  if [ "$(echo "$CREATE_TUNNEL_JSON" | jq -r '.success')" != "true" ]; then
    echo "Failed to create tunnel."
    echo "$CREATE_TUNNEL_JSON"
    exit 1
  fi

  TUNNEL_ID=$(echo "$CREATE_TUNNEL_JSON" | jq -r '.result.id')
  TUNNEL_TOKEN=$(echo "$CREATE_TUNNEL_JSON" | jq -r '.result.token')
fi

if [ -z "$TUNNEL_ID" ] || [ -z "$TUNNEL_TOKEN" ] || [ "$TUNNEL_ID" = "null" ]; then
  echo "Tunnel creation response incomplete."
  exit 1
fi
echo "[cf] tunnel id: $TUNNEL_ID"

echo "[cf] pushing remote tunnel configuration (hostname -> http://localhost:$WP_PORT) ..."
PUT_CFG_JSON=$(curl -sS -X PUT "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "config": {
      "ingress": [
        {
          "hostname": "'"$CF_HOSTNAME"'",
          "service": "http://localhost:'"$WP_PORT"'"
        },
        {
          "service": "http_status:404"
        }
      ]
    }
  }')

if [ "$(echo "$PUT_CFG_JSON" | jq -r '.success')" != "true" ]; then
  echo "Failed to set tunnel configuration."
  echo "$PUT_CFG_JSON"
  exit 1
fi

echo "[cf] ensuring DNS CNAME $CF_HOSTNAME -> $TUNNEL_ID.cfargotunnel.com ..."
CF_DNS_TARGET="${TUNNEL_ID}.cfargotunnel.com"

EXIST_JSON=$(curl -sS -G "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -d "type=CNAME" \
  -d "name=$CF_HOSTNAME")

REC_ID=$(echo "$EXIST_JSON" | jq -r '.result[0].id // empty')

if [ -n "$REC_ID" ]; then
  echo "[cf] updating existing DNS record $REC_ID ..."
  UPDATE_JSON=$(curl -sS -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$REC_ID" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data '{"type":"CNAME","name":"'"$CF_HOSTNAME"'","content":"'"$CF_DNS_TARGET"'","proxied":true}')
  if [ "$(echo "$UPDATE_JSON" | jq -r '.success')" != "true" ]; then
    echo "Failed to update DNS record."
    echo "$UPDATE_JSON"
    exit 1
  fi
else
  echo "[cf] creating DNS record ..."
  CREATE_DNS_JSON=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data '{"type":"CNAME","name":"'"$CF_HOSTNAME"'","content":"'"$CF_DNS_TARGET"'","proxied":true}')
  if [ "$(echo "$CREATE_DNS_JSON" | jq -r '.success')" != "true" ]; then
    echo "Failed to create DNS record."
    echo "$CREATE_DNS_JSON"
    exit 1
  fi
fi

echo "[cf] installing cloudflared systemd service ..."
run_sudo cloudflared service install "$TUNNEL_TOKEN"
run_sudo systemctl restart cloudflared || true
run_sudo systemctl enable cloudflared || true

echo
echo "============================================================"
echo "Local WordPress:        http://localhost:${WP_PORT}"
echo "Public (Cloudflare):    https://$CF_HOSTNAME"
echo "Cloudflare Tunnel ID:   $TUNNEL_ID"
echo "Cloudflare Account:     $CF_ACCOUNT_NAME"
echo "Project dir:            $PROJECT_DIR"
echo "Env file:               $ENV_FILE"
echo "============================================================"
echo "If you're reading this, the script actually did its job. Miracles happen."
