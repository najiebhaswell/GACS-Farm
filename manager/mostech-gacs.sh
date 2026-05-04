#!/usr/bin/env bash
# ==============================================================================
# MOSTECH GACS MANAGER v1.2
# Multi-instance GenieACS orchestration tool with auto port allocation,
# isolated databases, Nginx reverse proxy, wildcard SSL via Cloudflare,
# and OpenVPN per instance (Docker) for site-to-ACS connectivity.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIN_DIR="$(dirname "$SCRIPT_DIR")"
INSTANCES_DIR="${MAIN_DIR}/instances"
SOURCE_DIR="${MAIN_DIR}/source"
MANAGER_DIR="${MAIN_DIR}/manager"
LOG_FILE="${MANAGER_DIR}/log.txt"
CONFIG_FILE="${MANAGER_DIR}/config.conf"
NGINX_DIR="${MANAGER_DIR}/nginx"
NGINX_CONF_DIR="${NGINX_DIR}/conf.d"
SSL_DIR="${NGINX_DIR}/ssl"
VERSION_TAG="v1.2"
PARAM_DIR="${SOURCE_DIR}/GACS-Ubuntu-22.04/parameter"

mkdir -p "$INSTANCES_DIR" "$NGINX_CONF_DIR" "$SSL_DIR"

# --- Root Check ---
if [ "$(id -u)" -ne 0 ]; then
  echo -e "\033[0;31m✘ Script ini harus dijalankan sebagai root!\033[0m"
  echo "  Gunakan: sudo $0"
  exit 1
fi

# --- Dependency Check ---
check_dependencies() {
  local missing=()
  command -v docker &>/dev/null || missing+=("docker")
  command -v curl &>/dev/null || missing+=("curl")
  command -v git &>/dev/null || missing+=("git")

  # Docker Compose v2 (plugin) or v1 (standalone)
  if docker compose version &>/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
  elif command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE="docker-compose"
  else
    missing+=("docker-compose")
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "\033[0;31m✘ Dependencies belum terinstall: ${missing[*]}\033[0m"
    echo "  Install dulu sebelum menjalankan manager."
    echo "  Docker: https://docs.docker.com/engine/install/ubuntu/"
    exit 1
  fi
}
check_dependencies

# --- Colors ---
R='\033[0;31m'
G='\033[0;32m'
Y='\033[0;33m'
B='\033[0;34m'
C='\033[0;36m'
W='\033[1;37m'
D='\033[0;90m'
N='\033[0m'

# --- Helpers ---
info()    { echo -e "${C}ℹ ${N}$1"; }
ok()      { echo -e "${G}✔ ${N}$1"; }
warn()    { echo -e "${Y}⚠ ${N}$1"; }
err()     { echo -e "${R}✘ ${N}$1"; }
step()    { echo -e "${B}► ${N}$1"; }
header()  { echo -e "\n${W}═══ $1 ═══${N}"; }
divider() { echo -e "${D}──────────────────────────────────────────${N}"; }

log_action() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" >> "$LOG_FILE"
}

# --- Config ---
load_config() {
  BASE_DOMAIN="" CF_API_TOKEN="" CF_EMAIL="" SSL_ENABLED=""
  [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
BASE_DOMAIN="$BASE_DOMAIN"
CF_API_TOKEN="$CF_API_TOKEN"
CF_EMAIL="$CF_EMAIL"
SSL_ENABLED="$SSL_ENABLED"
EOF
}

# --- Port Allocator ---
get_random_free_port() {
  local port
  while true; do
    port=$(shuf -i 1000-9999 -n 1)
    if ! ss -tuln | grep -q ":${port} "; then
      echo "$port"
      return
    fi
  done
}

# --- Counters ---
count_instances() {
  shopt -s nullglob
  local DIRS=("$INSTANCES_DIR"/*/)
  shopt -u nullglob
  echo "${#DIRS[@]}"
}

generate_random_password() {
  local length=${1:-12}
  local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  local password=""
  for ((i=0; i<length; i++)); do
    password+=${chars:$((RANDOM % ${#chars})):1}
  done
  echo "$password"
}

# ╔══════════════════════════════════════╗
# ║         NETWORK HELPERS              ║
# ╚══════════════════════════════════════╝

get_public_ip() {
  curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || \
  curl -s -4 --max-time 5 icanhazip.com 2>/dev/null || \
  echo "N/A"
}

# Unique 172.27.x.0/24 per instance (OpenVPN tun pool) for RADIUS / NAS allowlists.
# Isolated from DOCKER_SUBNET (10.x.y.0/24) and from customer ONU LANs.
allocate_vpn_tun_pool() {
  local used=() n collision try f line
  shopt -s nullglob
  for f in "$INSTANCES_DIR"/*/.vpn_tun_pool; do
    [ ! -f "$f" ] && continue
    line=$(head -1 "$f" 2>/dev/null)
    if [[ "$line" =~ ^172\.27\.([0-9]+)\.0/24$ ]]; then
      used+=("${BASH_REMATCH[1]}")
    fi
  done
  shopt -u nullglob
  for ((try = 0; try < 400; try++)); do
    n=$((RANDOM % 254 + 1))
    collision=0
    for u in "${used[@]}"; do
      [[ "$u" == "$n" ]] && { collision=1; break; }
    done
    [[ $collision -eq 1 ]] && continue
    echo "172.27.${n}.0"
    return 0
  done
  err "Tidak bisa alokasi subnet tun OpenVPN unik (172.27.x.0/24 penuh?)."
  return 1
}

# ╔══════════════════════════════════════╗
# ║    SERVICES INSTALL / UNINSTALL      ║
# ╚══════════════════════════════════════╝

install_certbot() {
  header "INSTALL CERTBOT"
  step "Pulling certbot/dns-cloudflare image..."
  docker pull certbot/dns-cloudflare
  if [ $? -eq 0 ]; then
    ok "Certbot ready."
    log_action "SERVICE" "Certbot image pulled"
  else
    err "Failed to pull certbot image."
  fi
}

uninstall_certbot() {
  header "UNINSTALL CERTBOT"
  warn "Ini akan menghapus certbot image dan sertifikat SSL!"
  read -p "$(echo -e "${Y}?${N} Lanjutkan? (y/n): ")" CONFIRM
  [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { warn "Cancelled."; return; }

  step "Removing certbot image..."
  docker rmi certbot/dns-cloudflare 2>/dev/null
  ok "Certbot image removed."

  if [ -d "$SSL_DIR/live" ]; then
    step "Removing SSL certificates..."
    rm -rf "$SSL_DIR/live" "$SSL_DIR/archive" "$SSL_DIR/renewal" "$SSL_DIR/accounts"
    SSL_ENABLED=""
    load_config
    SSL_ENABLED=""
    save_config
    ok "SSL certificates removed."
  fi

  # Remove cron job
  crontab -l 2>/dev/null | grep -v "certbot/dns-cloudflare renew" | crontab - 2>/dev/null

  log_action "SERVICE" "Certbot uninstalled"
  ok "Certbot removed."
}

install_nginx_service() {
  header "INSTALL NGINX PROXY"
  setup_nginx
  log_action "SERVICE" "Nginx proxy installed"
}

uninstall_nginx_service() {
  header "UNINSTALL NGINX PROXY"

  local nginx_running
  nginx_running=$(docker ps -q -f name=mostech-nginx-proxy)

  if [ -z "$nginx_running" ] && [ ! -f "$NGINX_DIR/docker-compose.yml" ]; then
    info "Nginx proxy belum terinstall."
    return 0
  fi

  warn "Ini akan menghapus Nginx proxy dan semua konfigurasi subdomain!"
  read -p "$(echo -e "${Y}?${N} Lanjutkan? (y/n): ")" CONFIRM
  [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { warn "Cancelled."; return; }

  step "Stopping Nginx container..."
  (cd "$NGINX_DIR" && $DOCKER_COMPOSE down 2>/dev/null)

  step "Removing config files..."
  rm -f "$NGINX_DIR/docker-compose.yml"
  rm -f "$NGINX_DIR/nginx.conf"
  rm -rf "$NGINX_CONF_DIR"
  mkdir -p "$NGINX_CONF_DIR"

  log_action "SERVICE" "Nginx proxy uninstalled"
  ok "Nginx proxy removed."
}
install_radius_service() {
  header "INSTALL CENTRAL RADIUS (daloRADIUS Official)"
  local RADIUS_DIR="/home/well/GACS-Farm/radius"
  
  if [ ! -d "$RADIUS_DIR" ]; then
    step "Cloning official daloRADIUS repository..."
    git clone https://github.com/lirantal/daloradius.git "$RADIUS_DIR" >/dev/null 2>&1
  fi
  
  if ! docker network ls | grep -qw 'gacs-radius-net'; then
    docker network create gacs-radius-net >/dev/null 2>&1
    info "Created global network 'gacs-radius-net'."
  fi

  # Mencegah bentrok port 80 dengan Nginx Proxy Host
  sed -i "s/- '80:80'/- '8080:80'/g" "$RADIUS_DIR/docker-compose.yml"

  cat > "$RADIUS_DIR/docker-compose.override.yml" <<EOF
services:
  radius-mysql:
    networks:
      - default
      - gacs-radius-net
  radius:
    networks:
      - default
      - gacs-radius-net
  radius-web:
    networks:
      - default
      - gacs-radius-net

networks:
  gacs-radius-net:
    external: true
EOF

  step "Building and starting daloRADIUS containers..."
  (cd "$RADIUS_DIR" && $DOCKER_COMPOSE up -d --build) || { err "Failed to start RADIUS."; return; }
  
  echo ""
  ok "Central RADIUS (Official daloRADIUS) is now running!"
  echo -e "  ${D}RADIUS Auth:${N} ${W}Port 1812 UDP${N}"
  echo -e "  ${D}RADIUS Acct:${N} ${W}Port 1813 UDP${N}"
  echo -e "  ${D}Web UI (daloRADIUS):${N} ${W}http://<IP_SERVER>:8080${N}"
  echo -e "  ${D}Login UI:${N} ${W}administrator${N} / ${W}radius${N}"
  echo ""
}

uninstall_radius_service() {
  header "UNINSTALL CENTRAL RADIUS"
  local RADIUS_DIR="/home/well/GACS-Farm/radius"
  if [ -d "$RADIUS_DIR" ]; then
    (cd "$RADIUS_DIR" && $DOCKER_COMPOSE down -v)
    rm -rf "$RADIUS_DIR"
    ok "Central RADIUS uninstalled."
  else
    warn "Central RADIUS is not installed."
  fi
}
services_install_menu() {
  header "INSTALL SERVICES"

  local nginx_status certbot_status radius_status

  docker ps -q -f name=mostech-nginx-proxy >/dev/null 2>&1 && \
    [ -n "$(docker ps -q -f name=mostech-nginx-proxy)" ] && \
    nginx_status="${G}Running${N}" || nginx_status="${D}Not running${N}"

  docker image inspect certbot/dns-cloudflare >/dev/null 2>&1 && \
    certbot_status="${G}Ready${N}" || certbot_status="${D}Not installed${N}"

  docker ps -q -f name=gacs-central-radius >/dev/null 2>&1 && \
    [ -n "$(docker ps -q -f name=gacs-central-radius)" ] && \
    radius_status="${G}Running${N}" || radius_status="${D}Not running${N}"

  echo ""
  echo -e "  ${W}1.${N} Nginx Proxy      [$nginx_status]"
  echo -e "  ${W}2.${N} Certbot (SSL)    [$certbot_status]"
  echo -e "  ${W}3.${N} Central RADIUS   [$radius_status]"
  echo -e "  ${W}4.${N} Install All"
  echo -e "  ${W}0.${N} Back"
  divider
  read -p "$(echo -e "${B}►${N} Pilihan: ")" SVC_CHOICE

  case $SVC_CHOICE in
    1) install_nginx_service ;;
    2) install_certbot ;;
    3) install_radius_service ;;
    4)
      install_nginx_service
      install_certbot
      install_radius_service
      echo ""
      ok "All services installed."
      ;;
    0) return ;;
    *) err "Invalid." ;;
  esac
}

services_uninstall_menu() {
  header "UNINSTALL SERVICES"

  local nginx_status certbot_status radius_status

  [ -n "$(docker ps -q -f name=mostech-nginx-proxy 2>/dev/null)" ] && \
    nginx_status="${G}Running${N}" || nginx_status="${D}Not running${N}"

  docker image inspect certbot/dns-cloudflare >/dev/null 2>&1 && \
    certbot_status="${G}Installed${N}" || certbot_status="${D}Not installed${N}"

  [ -n "$(docker ps -q -f name=gacs-central-radius 2>/dev/null)" ] && \
    radius_status="${G}Installed${N}" || radius_status="${D}Not installed${N}"

  echo ""
  echo -e "  ${W}1.${N} Nginx Proxy      [$nginx_status]"
  echo -e "  ${W}2.${N} Certbot (SSL)    [$certbot_status]"
  echo -e "  ${W}3.${N} Central RADIUS   [$radius_status]"
  echo -e "  ${W}4.${N} Uninstall All"
  echo -e "  ${W}0.${N} Back"
  divider
  read -p "$(echo -e "${B}►${N} Pilihan: ")" SVC_CHOICE

  case $SVC_CHOICE in
    1) uninstall_nginx_service ;;
    2) uninstall_certbot ;;
    3) uninstall_radius_service ;;
    4)
      uninstall_nginx_service
      uninstall_certbot
      uninstall_radius_service
      echo ""
      ok "All services removed."
      ;;
    0) return ;;
    *) err "Invalid." ;;
  esac
}

# ╔══════════════════════════════════════╗
# ║     DOMAIN, CLOUDFLARE & SSL         ║
# ╚══════════════════════════════════════╝

setup_domain() {
  header "SETUP DOMAIN & SSL"
  load_config

  echo -e "\n${W}[ 1/3 ] Domain${N}"
  if [ -n "$BASE_DOMAIN" ]; then
    info "Domain aktif: ${W}$BASE_DOMAIN${N}"
    read -p "$(echo -e "${Y}?${N} Ganti domain? (y/n): ")" CHANGE_DOMAIN
  else
    CHANGE_DOMAIN="y"
  fi

  if [[ "$CHANGE_DOMAIN" == "y" || "$CHANGE_DOMAIN" == "Y" ]]; then
    read -p "$(echo -e "${B}►${N} Masukkan domain (contoh: domain.id): ")" NEW_DOMAIN
    if [[ ! "$NEW_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
      err "Format domain tidak valid!"; return
    fi
    BASE_DOMAIN="$NEW_DOMAIN"
    ok "Domain: $BASE_DOMAIN"
    echo ""
    warn "Pastikan wildcard DNS aktif: ${W}*.${BASE_DOMAIN} → A → <IP SERVER>${N}"
  fi

  echo -e "\n${W}[ 2/3 ] Setup SSL Wildcard Otomatis${N}"
  info "GACS-Farm mendukung auto-SSL (HTTPS) menggunakan Let's Encrypt Wildcard dengan verifikasi Cloudflare DNS."
  read -p "$(echo -e "${Y}?${N} Gunakan Cloudflare SSL otomatis? (y/n - ketik 'n' jika ingin HTTP / proxy manual): ")" USE_CF_SSL

  if [[ "$USE_CF_SSL" == "y" || "$USE_CF_SSL" == "Y" ]]; then
    if [ -n "$CF_API_TOKEN" ]; then
      local masked="${CF_API_TOKEN:0:6}...${CF_API_TOKEN: -4}"
      info "Token: ${D}$masked${N}"
      read -p "$(echo -e "${Y}?${N} Ganti token? (y/n): ")" CHANGE_TOKEN
    else
      CHANGE_TOKEN="y"
    fi

    if [[ "$CHANGE_TOKEN" == "y" || "$CHANGE_TOKEN" == "Y" ]]; then
      read -p "$(echo -e "${B}►${N} Cloudflare API Token: ")" NEW_TOKEN
      [ -z "$NEW_TOKEN" ] && { err "Token kosong!"; return; }

      step "Validating token..."
      local verify_result
      verify_result=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
        -H "Authorization: Bearer $NEW_TOKEN" -H "Content-Type: application/json")
      local token_status
      token_status=$(echo "$verify_result" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
      if [ "$token_status" != "active" ]; then
        err "Token tidak valid!"; return
      fi
      ok "Token valid."

      step "Checking zone access for '$BASE_DOMAIN'..."
      local zone_result
      zone_result=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$BASE_DOMAIN" \
        -H "Authorization: Bearer $NEW_TOKEN" -H "Content-Type: application/json")
      local zone_count
      zone_count=$(echo "$zone_result" | grep -o '"count":[0-9]*' | head -1 | cut -d':' -f2)
      if [ "$zone_count" == "0" ] || [ -z "$zone_count" ]; then
        err "Token tidak punya akses ke zone '$BASE_DOMAIN'!"; return
      fi
      ok "Zone access confirmed."
      CF_API_TOKEN="$NEW_TOKEN"
    fi

    echo -e "\n${W}[ 3/3 ] SSL Certificate${N}"
    if [ -z "$CF_EMAIL" ]; then
      read -p "$(echo -e "${B}►${N} Email untuk Let's Encrypt: ")" CF_EMAIL
    else
      info "Email: $CF_EMAIL"
      read -p "$(echo -e "${Y}?${N} Ganti email? (y/n): ")" CHANGE_EMAIL
      [[ "$CHANGE_EMAIL" == "y" || "$CHANGE_EMAIL" == "Y" ]] && \
        read -p "$(echo -e "${B}►${N} Email baru: ")" CF_EMAIL
    fi

    save_config
    log_action "SETUP" "Domain=$BASE_DOMAIN | CF Token configured | Email=$CF_EMAIL"
    setup_nginx

    echo ""
    read -p "$(echo -e "${Y}?${N} Issue Wildcard SSL Certificate sekarang? (y/n): ")" DO_SSL
    [[ "$DO_SSL" == "y" || "$DO_SSL" == "Y" ]] && issue_ssl_cert
  else
    info "Cloudflare SSL dilewati. GACS-Farm akan menggunakan HTTP polos (atau Anda bisa setup reverse proxy di sisi lain)."
    CF_API_TOKEN=""
    CF_EMAIL=""
    SSL_ENABLED=""
    save_config
    log_action "SETUP" "Domain=$BASE_DOMAIN | No SSL Configured"
    setup_nginx
    ok "Setup domain (HTTP) selesai."
  fi
}

issue_ssl_cert() {
  load_config
  if [ -z "$BASE_DOMAIN" ] || [ -z "$CF_API_TOKEN" ] || [ -z "$CF_EMAIL" ]; then
    err "Domain/Token/Email belum dikonfigurasi."; return
  fi

  header "ISSUING WILDCARD SSL"
  info "Domain: ${W}*.${BASE_DOMAIN}${N}"

  cat > "$SSL_DIR/cloudflare.ini" <<EOF
dns_cloudflare_api_token = $CF_API_TOKEN
EOF
  chmod 600 "$SSL_DIR/cloudflare.ini"

  step "Running certbot DNS-01 challenge..."
  docker run --rm \
    -v "$SSL_DIR:/etc/letsencrypt" \
    -v "$SSL_DIR/cloudflare.ini:/cloudflare.ini:ro" \
    certbot/dns-cloudflare certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /cloudflare.ini \
    --dns-cloudflare-propagation-seconds 30 \
    -d "*.${BASE_DOMAIN}" -d "${BASE_DOMAIN}" \
    --agree-tos --no-eff-email --email "$CF_EMAIL" -n

  if [ -f "$SSL_DIR/live/${BASE_DOMAIN}/fullchain.pem" ]; then
    ok "Wildcard SSL certificate issued!"
    SSL_ENABLED="true"
    save_config
    log_action "SSL" "Wildcard cert for *.${BASE_DOMAIN} issued"
    update_nginx_ssl
    reload_nginx
    setup_ssl_renewal
    ok "SSL/HTTPS aktif."
  else
    err "Certificate issuance failed."
    log_action "SSL" "FAILED - cert for *.${BASE_DOMAIN}"
  fi
}

update_nginx_ssl() {
  load_config
  cat > "$NGINX_DIR/nginx.conf" <<'NGINXCONF'
worker_processes auto;
events { worker_connections 1024; }
http {
    sendfile on;
    keepalive_timeout 65;
    client_max_body_size 100M;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    server {
        listen 80 default_server;
        server_name _;
        return 444;
    }
    server {
        listen 443 ssl default_server;
        server_name _;
        ssl_certificate /etc/letsencrypt/live/SSL_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/SSL_DOMAIN/privkey.pem;
        return 444;
    }
    include /etc/nginx/conf.d/*.conf;
}
NGINXCONF
  sed -i "s|SSL_DOMAIN|${BASE_DOMAIN}|g" "$NGINX_DIR/nginx.conf"

  cat > "$NGINX_DIR/docker-compose.yml" <<'DCOMPOSE'
services:
  nginx-proxy:
    image: nginx:alpine
    container_name: mostech-nginx-proxy
    restart: always
    ports:
      - "80:80"
      - "443:443"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf.d:/etc/nginx/conf.d:ro
      - ./ssl:/etc/letsencrypt:ro
DCOMPOSE

  ok "Nginx reconfigured with SSL."
  (cd "$NGINX_DIR" && $DOCKER_COMPOSE down && $DOCKER_COMPOSE up -d)
  log_action "NGINX" "Restarted with SSL"
  regenerate_all_nginx_confs
}

setup_ssl_renewal() {
  local cron_cmd="0 3 * * * docker run --rm -v $SSL_DIR:/etc/letsencrypt -v $SSL_DIR/cloudflare.ini:/cloudflare.ini:ro certbot/dns-cloudflare renew --dns-cloudflare --dns-cloudflare-credentials /cloudflare.ini --quiet && docker exec mostech-nginx-proxy nginx -s reload"
  if ! crontab -l 2>/dev/null | grep -q "certbot/dns-cloudflare renew"; then
    (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab -
    ok "Auto-renewal scheduled (daily 03:00)."
  else
    ok "Auto-renewal already scheduled."
  fi
}

# ╔══════════════════════════════════════╗
# ║          NGINX MANAGEMENT            ║
# ╚══════════════════════════════════════╝

setup_nginx() {
  step "Checking Nginx reverse proxy..."
  load_config

  if [ ! -f "$NGINX_DIR/nginx.conf" ]; then
    cat > "$NGINX_DIR/nginx.conf" <<'NGINXCONF'
worker_processes auto;
events { worker_connections 1024; }
http {
    sendfile on;
    keepalive_timeout 65;
    client_max_body_size 100M;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    server {
        listen 80 default_server;
        server_name _;
        return 444;
    }
    include /etc/nginx/conf.d/*.conf;
}
NGINXCONF
    ok "Nginx config created."
  fi

  if [ ! -f "$NGINX_DIR/docker-compose.yml" ]; then
    if [ "$SSL_ENABLED" == "true" ]; then
      cat > "$NGINX_DIR/docker-compose.yml" <<'DCOMPOSE'
services:
  nginx-proxy:
    image: nginx:alpine
    container_name: mostech-nginx-proxy
    restart: always
    ports:
      - "80:80"
      - "443:443"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf.d:/etc/nginx/conf.d:ro
      - ./ssl:/etc/letsencrypt:ro
DCOMPOSE
    else
      cat > "$NGINX_DIR/docker-compose.yml" <<'DCOMPOSE'
services:
  nginx-proxy:
    image: nginx:alpine
    container_name: mostech-nginx-proxy
    restart: always
    ports:
      - "80:80"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf.d:/etc/nginx/conf.d:ro
DCOMPOSE
    fi
    ok "Nginx compose created."
  fi

  local nginx_running
  nginx_running=$(docker ps -q -f name=mostech-nginx-proxy)
  if [ -z "$nginx_running" ]; then
    step "Starting Nginx..."
    (cd "$NGINX_DIR" && $DOCKER_COMPOSE up -d)
    log_action "NGINX" "Nginx started"
    ok "Nginx running."
  else
    ok "Nginx already running."
  fi
}

reload_nginx() {
  local nginx_running
  nginx_running=$(docker ps -q -f name=mostech-nginx-proxy)
  [ -n "$nginx_running" ] && docker exec mostech-nginx-proxy nginx -s reload 2>/dev/null
}

generate_nginx_conf() {
  local instance_name="$1" port_ui="$2" port_cwmp="$3" port_nbi="$4" port_fs="$5"
  load_config
  [ -z "$BASE_DOMAIN" ] && return

  if [ "$SSL_ENABLED" == "true" ]; then
    cat > "$NGINX_CONF_DIR/${instance_name}.conf" <<EOF
server {
    listen 80;
    server_name acs-${instance_name}.${BASE_DOMAIN};
    return 301 https://\$server_name\$request_uri;
}
server {
    listen 443 ssl;
    server_name acs-${instance_name}.${BASE_DOMAIN};
    ssl_certificate /etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${BASE_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    location / {
        proxy_pass http://host.docker.internal:${port_ui};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
server {
    listen 80;
    server_name cwmp-${instance_name}.${BASE_DOMAIN};
    location / {
        proxy_pass http://host.docker.internal:${port_cwmp};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
server {
    listen 80;
    server_name nbi-${instance_name}.${BASE_DOMAIN};
    location / {
        proxy_pass http://host.docker.internal:${port_nbi};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
server {
    listen 80;
    server_name fs-${instance_name}.${BASE_DOMAIN};
    location / {
        proxy_pass http://host.docker.internal:${port_fs};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  else
    cat > "$NGINX_CONF_DIR/${instance_name}.conf" <<EOF
server {
    listen 80;
    server_name acs-${instance_name}.${BASE_DOMAIN};
    location / {
        proxy_pass http://host.docker.internal:${port_ui};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
server {
    listen 80;
    server_name cwmp-${instance_name}.${BASE_DOMAIN};
    location / {
        proxy_pass http://host.docker.internal:${port_cwmp};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
server {
    listen 80;
    server_name nbi-${instance_name}.${BASE_DOMAIN};
    location / {
        proxy_pass http://host.docker.internal:${port_nbi};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
server {
    listen 80;
    server_name fs-${instance_name}.${BASE_DOMAIN};
    location / {
        proxy_pass http://host.docker.internal:${port_fs};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  fi
  reload_nginx
  log_action "NGINX" "Proxy config for '$instance_name' created"
}

remove_nginx_conf() {
  local instance_name="$1"
  [ -f "$NGINX_CONF_DIR/${instance_name}.conf" ] && {
    rm -f "$NGINX_CONF_DIR/${instance_name}.conf"
    reload_nginx
    log_action "NGINX" "Proxy config for '$instance_name' removed"
  }
}

regenerate_all_nginx_confs() {
  step "Regenerating proxy configs..."
  shopt -s nullglob
  local DIRS=("$INSTANCES_DIR"/*/)
  shopt -u nullglob
  for dir in "${DIRS[@]}"; do
    local name=$(basename "$dir")
    local cf="$dir/docker-compose.yml"
    if [ -f "$cf" ]; then
      local p_cwmp p_nbi p_fs p_ui
      p_cwmp=$(grep -A1 'genieacs-cwmp' "$cf" | grep -oP '\d+(?=:7547)' | head -1)
      p_nbi=$(grep -A1 'genieacs-nbi' "$cf" | grep -oP '\d+(?=:7557)' | head -1)
      p_fs=$(grep -A1 'genieacs-fs' "$cf" | grep -oP '\d+(?=:7567)' | head -1)
      p_ui=$(grep -A1 'genieacs-ui' "$cf" | grep -oP '\d+(?=:3000)' | head -1)
      [ -n "$p_ui" ] && generate_nginx_conf "$name" "$p_ui" "$p_cwmp" "$p_nbi" "$p_fs" && ok "$name"
    fi
  done
}

# ╔══════════════════════════════════════╗
# ║       PARAMETER RESTORE              ║
# ╚══════════════════════════════════════╝

restore_parameters() {
  local instance_name="$1"
  local version="$2"
  local mongo_container="${instance_name}-mongodb-1"

  if [ ! -d "$PARAM_DIR" ]; then
    warn "Parameter directory not found: $PARAM_DIR"
    return 1
  fi

  # Latest (v1.3) has rewritten UI — config.bson UI entries are incompatible
  local collections=()
  local bson_files=()

  if [ "$version" == "stable" ]; then
    collections=("config" "virtualParameters" "presets" "provisions")
    bson_files=("config.bson" "virtualParameters.bson" "presets.bson" "provisions.bson")
    info "Stable detected → restoring all 4 collections (termasuk UI config)."
  else
    collections=("virtualParameters" "presets" "provisions")
    bson_files=("virtualParameters.bson" "presets.bson" "provisions.bson")
    warn "Latest detected → skip config.bson (UI v1.3 tidak kompatibel dengan v1.2 config)."
    info "Restoring 3 collections (virtualParams, presets, provisions)."
  fi

  step "Copying parameter files to MongoDB container..."
  docker cp "$PARAM_DIR" "${mongo_container}:/tmp/parameter" 2>/dev/null
  if [ $? -ne 0 ]; then
    err "Failed to copy files to container."
    return 1
  fi

  local i=0
  local success=0
  for col in "${collections[@]}"; do
    local bson="${bson_files[$i]}"
    step "Restoring $col..."
    docker exec "${mongo_container}" mongorestore \
      --db genieacs --collection "$col" --drop \
      "/tmp/parameter/$bson" 2>/dev/null
    if [ $? -eq 0 ]; then
      ok "$col"
      ((success++))
    else
      err "Failed: $col"
    fi
    ((i++))
  done

  # Cleanup
  docker exec "${mongo_container}" rm -rf /tmp/parameter 2>/dev/null

  if [ $success -eq ${#collections[@]} ]; then
    log_action "RESTORE" "Parameters restored for '$instance_name' ver=$version ($success/${#collections[@]} collections)"
    ok "Parameters restored (${W}${success}/${#collections[@]} collections${N})."
  else
    warn "Partial restore: $success/${#collections[@]} collections."
    log_action "RESTORE" "PARTIAL restore for '$instance_name' ($success/${#collections[@]})"
  fi
}

update_provision_acs_url() {
  local instance_name="$1"
  local acs_url="$2"
  local mongo_container="${instance_name}-mongodb-1"

  step "Updating ACS URL in provisions to ${W}$acs_url${N}..."

  # Write temp JS file for MongoDB
  local tmp_js="${MANAGER_DIR}/.tmp_update_url.js"
  cat > "$tmp_js" <<JSEOF
var newUrl = "${acs_url}";
db.provisions.find().forEach(function(doc) {
  if (doc.script && doc.script.indexOf('const url = "http://') !== -1) {
    var newScript = doc.script.replace(/const url = "http:\/\/[^"]+";/, 'const url = "' + newUrl + '";');
    db.provisions.updateOne({_id: doc._id}, {\$set: {script: newScript}});
    print("Updated: " + doc._id);
  }
});
JSEOF

  docker cp "$tmp_js" "${mongo_container}:/tmp/update_url.js" 2>/dev/null
  local result
  result=$(docker exec "${mongo_container}" mongo --quiet genieacs /tmp/update_url.js 2>/dev/null)
  local exit_code=$?

  # Cleanup
  docker exec "${mongo_container}" rm -f /tmp/update_url.js 2>/dev/null
  rm -f "$tmp_js"

  if [ $exit_code -eq 0 ] && [ -n "$result" ]; then
    ok "ACS URL updated: ${W}$acs_url${N}"
    echo -e "  ${D}$result${N}"
    log_action "PROVISION" "ACS URL updated to $acs_url (instance: $instance_name)"
  else
    warn "Gagal update ACS URL otomatis. Update manual via GenieACS UI."
  fi
}

# ╔══════════════════════════════════════╗
# ║         INSTALL INSTANCE             ║
# ╚══════════════════════════════════════╝

install_instance() {
  header "INSTALL NEW INSTANCE"
  read -p "$(echo -e "${B}►${N} Nama instance (alfabet/angka/strip): ")" INSTANCE_NAME

  if [[ ! "$INSTANCE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    err "Nama tidak valid!"; return
  fi
  if [ -d "$INSTANCES_DIR/$INSTANCE_NAME" ]; then
    err "Instance '$INSTANCE_NAME' sudah ada!"; return
  fi

  echo -e "\n${W}Pilih versi GenieACS:${N}"
  echo "  1. Stable (v1.2) — Production ready"
  echo "  2. Latest (v1.3.0-dev) — Experimental"
  read -p "$(echo -e "${B}►${N} Pilihan (1/2): ")" VERSION_CHOICE

  case "$VERSION_CHOICE" in
    1) VERSION="stable" ;;
    2) VERSION="latest" ;;
    *) err "Pilihan tidak valid!"; return ;;
  esac

  # Check source exists
  if [ ! -f "$SOURCE_DIR/$VERSION/package.json" ]; then
    err "Source GenieACS '$VERSION' belum tersedia!"
    info "Jalankan: ${W}Services & Settings → Setup GenieACS Source${N}"
    return
  fi

  echo -e "\n${W}Pilih tipe VPN untuk Site-to-ACS:${N}"
  echo "  1. OpenVPN (Default, port tunggal)"
  echo "  2. L2TP/IPsec (hwdsl2/docker-ipsec-vpn-server)"
  read -p "$(echo -e "${B}►${N} Pilihan (1/2): ")" VPN_CHOICE
  [[ "$VPN_CHOICE" != "2" ]] && VPN_CHOICE=1

  step "Allocating ports..."
  PORT_CWMP=$(get_random_free_port)
  PORT_NBI=$(get_random_free_port)
  PORT_FS=$(get_random_free_port)
  PORT_UI=$(get_random_free_port)
  DOCKER_SUBNET="10.$((RANDOM % 200 + 10)).$((RANDOM % 250))"

  if [ "$VPN_CHOICE" == "2" ]; then
    PORT_IPSEC_500=$(get_random_free_port)
    PORT_IPSEC_4500=$(get_random_free_port)
    VPN_IPSEC_PSK=$(generate_random_password 16)
    VPN_USER="gacs-${INSTANCE_NAME}"
    VPN_PASSWORD=$(generate_random_password 12)
    ok "Ports: CWMP=${W}$PORT_CWMP${N} | NBI=${W}$PORT_NBI${N} | FS=${W}$PORT_FS${N} | UI=${W}$PORT_UI${N} | IPsec=500:${W}$PORT_IPSEC_500${N}, 4500:${W}$PORT_IPSEC_4500${N}"
  else
    PORT_OPENVPN=$(get_random_free_port)
    ok "Ports: CWMP=${W}$PORT_CWMP${N} | NBI=${W}$PORT_NBI${N} | FS=${W}$PORT_FS${N} | UI=${W}$PORT_UI${N} | VPN=${W}$PORT_OPENVPN${N}"
  fi

  TARGET_DIR="$INSTANCES_DIR/$INSTANCE_NAME"
  mkdir -p "$TARGET_DIR"

  if ! docker network ls | grep -qw 'gacs-radius-net'; then
    docker network create gacs-radius-net >/dev/null 2>&1
    info "Created global network 'gacs-radius-net' untuk integrasi RADIUS."
  fi

  # --- ONU Subnet Route ---
  echo ""
  info "Agar ACS bisa manage ONU (summon/push), perlu route ke subnet ONU."
  read -p "$(echo -e "${B}►${N} Subnet ONU di MikroTik ini (contoh: 10.50.0.0/16): ")" ONU_SUBNET
  if [[ ! "$ONU_SUBNET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    err "Format subnet tidak valid! Contoh: 10.50.0.0/16"
    return
  fi

  local VPN_POOL_BASE
  VPN_POOL_BASE=$(allocate_vpn_tun_pool) || return
  echo "${VPN_POOL_BASE}/24" > "$TARGET_DIR/.vpn_tun_pool"
  info "OpenVPN tun pool (RADIUS/NAS allow): ${W}${VPN_POOL_BASE}/24${N}"
  log_action "VPN" "tun pool ${VPN_POOL_BASE}/24 instance=$INSTANCE_NAME"

  PUBLIC_IP=$(get_public_ip)
  load_config
  if [ "$VPN_CHOICE" == "2" ]; then
    cat > "$TARGET_DIR/vpn.env" <<EOF
VPN_IPSEC_PSK=${VPN_IPSEC_PSK}
VPN_USER=${VPN_USER}
VPN_PASSWORD=${VPN_PASSWORD}
VPN_L2TP_NET=${VPN_POOL_BASE}.0/24
VPN_L2TP_LOCAL=${VPN_POOL_BASE}.1
VPN_L2TP_POOL=${VPN_POOL_BASE}.10-${VPN_POOL_BASE}.250
EOF
  else
    if [ -n "$BASE_DOMAIN" ]; then
      cat > "$TARGET_DIR/vpn.env" <<EOF
VPN_DNS_NAME=acs-${INSTANCE_NAME}.${BASE_DOMAIN}
VPN_PORT=${PORT_OPENVPN}
VPN_PROTO=udp
EOF
    else
      cat > "$TARGET_DIR/vpn.env" <<EOF
VPN_PORT=${PORT_OPENVPN}
VPN_PROTO=udp
EOF
    fi
  fi

  cat > "$TARGET_DIR/docker-compose.yml" <<EOF
services:
EOF

  if [ "$VPN_CHOICE" == "2" ]; then
    cat >> "$TARGET_DIR/docker-compose.yml" <<EOF
  ipsec-vpn:
    image: hwdsl2/ipsec-vpn-server
    container_name: ipsec-${INSTANCE_NAME}
    restart: always
    env_file:
      - ./vpn.env
    ports:
      - "${PORT_IPSEC_500}:500/udp"
      - "${PORT_IPSEC_4500}:4500/udp"
    cap_add:
      - NET_ADMIN
    privileged: true
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv6.conf.all.forwarding=1
    networks:
      genieacs-net:
        ipv4_address: ${DOCKER_SUBNET}.254
      gacs-radius-net:
EOF
  else
    cat >> "$TARGET_DIR/docker-compose.yml" <<EOF
  openvpn:
    image: hwdsl2/openvpn-server
    container_name: ovpn-${INSTANCE_NAME}
    restart: always
    ports:
      - "${PORT_OPENVPN}:${PORT_OPENVPN}/udp"
    volumes:
      - ./ovpn-data:/etc/openvpn
      - ./vpn.env:/vpn.env:ro
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv6.conf.all.forwarding=1
    networks:
      genieacs-net:
        ipv4_address: ${DOCKER_SUBNET}.254
      gacs-radius-net:
EOF
  fi

  cat >> "$TARGET_DIR/docker-compose.yml" <<EOF

  mongodb:
    image: mongo:4.4
    restart: always
    volumes:
      - mongo-data:/data/db
    networks:
      - genieacs-net

  genieacs-cwmp:
    build:
      context: ../../source/${VERSION}
      dockerfile: ../deploy/${VERSION}/Dockerfile
    restart: always
    environment:
      - GENIEACS_MONGODB_CONNECTION_URL=mongodb://mongodb:27017/genieacs
    ports:
      - "${PORT_CWMP}:7547"
    networks:
      genieacs-net:
        ipv4_address: ${DOCKER_SUBNET}.100
    depends_on:
      - mongodb
    cap_add:
      - NET_ADMIN
    command: sh -c "ip route add ${ONU_SUBNET} via ${DOCKER_SUBNET}.254 && ./dist/bin/genieacs-cwmp"

  genieacs-nbi:
    build:
      context: ../../source/${VERSION}
      dockerfile: ../deploy/${VERSION}/Dockerfile
    restart: always
    environment:
      - GENIEACS_MONGODB_CONNECTION_URL=mongodb://mongodb:27017/genieacs
    ports:
      - "${PORT_NBI}:7557"
    networks:
      - genieacs-net
    depends_on:
      - mongodb
    command: ./dist/bin/genieacs-nbi

  genieacs-fs:
    build:
      context: ../../source/${VERSION}
      dockerfile: ../deploy/${VERSION}/Dockerfile
    restart: always
    environment:
      - GENIEACS_MONGODB_CONNECTION_URL=mongodb://mongodb:27017/genieacs
    ports:
      - "${PORT_FS}:7567"
    networks:
      - genieacs-net
    depends_on:
      - mongodb
    command: ./dist/bin/genieacs-fs

  genieacs-ui:
    build:
      context: ../../source/${VERSION}
      dockerfile: ../deploy/${VERSION}/Dockerfile
    restart: always
    environment:
      - GENIEACS_MONGODB_CONNECTION_URL=mongodb://mongodb:27017/genieacs
      - GENIEACS_UI_JWT_SECRET=super_secret_${INSTANCE_NAME}
    ports:
      - "${PORT_UI}:3000"
    networks:
      - genieacs-net
    depends_on:
      - mongodb
    command: ./dist/bin/genieacs-ui

volumes:
  mongo-data:

networks:
  genieacs-net:
    ipam:
      config:
        - subnet: ${DOCKER_SUBNET}.0/24
  gacs-radius-net:
    external: true
EOF

  step "Building & starting containers..."
  if [ "$VPN_CHOICE" == "2" ]; then
    log_action "INSTALL" "START - '$INSTANCE_NAME' ver=$VERSION | CWMP=$PORT_CWMP NBI=$PORT_NBI FS=$PORT_FS UI=$PORT_UI IPsec=$PORT_IPSEC_500,$PORT_IPSEC_4500"
  else
    log_action "INSTALL" "START - '$INSTANCE_NAME' ver=$VERSION | CWMP=$PORT_CWMP NBI=$PORT_NBI FS=$PORT_FS UI=$PORT_UI OVPN=$PORT_OPENVPN"
  fi
  (cd "$TARGET_DIR" && $DOCKER_COMPOSE up -d --build)
  
  step "Menunggu layanan siap (sleep 15s)..."
  sleep 15

  generate_nginx_conf "$INSTANCE_NAME" "$PORT_UI" "$PORT_CWMP" "$PORT_NBI" "$PORT_FS"

  if [ "$VPN_CHOICE" == "1" ]; then
    step "Configuring OpenVPN Client routing (iroute)..."
    local CIDR=$(echo "$ONU_SUBNET" | cut -d/ -f2)
    local SUBNET_IP=$(echo "$ONU_SUBNET" | cut -d/ -f1)
    
    local full_octets=$((CIDR/8))
    local partial_octet=$((CIDR%8))
    local NETMASK=""
    for ((i=0;i<4;i+=1)); do
      if [ $i -lt $full_octets ]; then
        NETMASK+="255"
      elif [ $i -eq $full_octets ]; then
        NETMASK+=$((256 - 2**(8-partial_octet)))
      else
        NETMASK+="0"
      fi
      test $i -lt 3 && NETMASK+="."
    done

    docker exec ovpn-${INSTANCE_NAME} sh -c "mkdir -p /etc/openvpn/ccd" 2>/dev/null
    docker exec ovpn-${INSTANCE_NAME} sh -c "echo 'iroute $SUBNET_IP $NETMASK' > /etc/openvpn/ccd/client" 2>/dev/null
    docker exec ovpn-${INSTANCE_NAME} sh -c "grep -q 'client-config-dir' /etc/openvpn/server/server.conf || echo 'client-config-dir /etc/openvpn/ccd' >> /etc/openvpn/server/server.conf" 2>/dev/null
    docker exec ovpn-${INSTANCE_NAME} sh -c "grep -q 'route $SUBNET_IP' /etc/openvpn/server/server.conf || echo 'route $SUBNET_IP $NETMASK' >> /etc/openvpn/server/server.conf" 2>/dev/null
    
    # Fix MikroTik compatibility: disable tls-crypt entirely to prevent auth digest errors
    docker exec ovpn-${INSTANCE_NAME} sed -i '/tls-crypt tc.key/d' /etc/openvpn/server/server.conf 2>/dev/null
    docker exec ovpn-${INSTANCE_NAME} sed -i -e '/<tls-crypt>/,/<\/tls-crypt>/d' /etc/openvpn/clients/client.ovpn 2>/dev/null
    docker exec ovpn-${INSTANCE_NAME} sed -i '/ignore-unknown-option/d' /etc/openvpn/clients/client.ovpn 2>/dev/null
    
    # Fix MikroTik null-digest error by switching AEAD cipher (GCM) to CBC
    docker exec ovpn-${INSTANCE_NAME} sed -i 's/cipher AES-128-GCM/cipher AES-256-CBC\ndata-ciphers AES-256-CBC/g' /etc/openvpn/server/server.conf 2>/dev/null
    docker exec ovpn-${INSTANCE_NAME} sed -i 's/cipher AES-128-GCM/cipher AES-256-CBC/g' /etc/openvpn/clients/client.ovpn 2>/dev/null
    
    # Remove unsupported push options that cause MikroTik to fail getting IP
    docker exec ovpn-${INSTANCE_NAME} sed -i '/push "redirect-gateway/d' /etc/openvpn/server/server.conf 2>/dev/null
    docker exec ovpn-${INSTANCE_NAME} sed -i '/push "block-ipv6/d' /etc/openvpn/server/server.conf 2>/dev/null
    docker exec ovpn-${INSTANCE_NAME} sed -i '/push "ifconfig-ipv6/d' /etc/openvpn/server/server.conf 2>/dev/null
    docker exec ovpn-${INSTANCE_NAME} sed -i '/push "dhcp-option/d' /etc/openvpn/server/server.conf 2>/dev/null
    docker exec ovpn-${INSTANCE_NAME} sed -i '/push "block-outside-dns/d' /etc/openvpn/server/server.conf 2>/dev/null
    
    # Unique tun /24 per instance (default image uses 10.8.0.0 — replace for RADIUS per-customer allow)
    docker exec ovpn-${INSTANCE_NAME} sed -i "s|^server[[:space:]].*|server ${VPN_POOL_BASE} 255.255.255.0|" /etc/openvpn/server/server.conf 2>/dev/null
    docker exec ovpn-${INSTANCE_NAME} sh -c ': > /etc/openvpn/server/ipp.txt' 2>/dev/null

    # Push docker subnet route to MikroTik so it can reach the CWMP container
    docker exec ovpn-${INSTANCE_NAME} sh -c "echo 'push \"route ${DOCKER_SUBNET}.0 255.255.255.0\"' >> /etc/openvpn/server/server.conf" 2>/dev/null

    docker restart ovpn-${INSTANCE_NAME} >/dev/null
  else
    step "L2TP/IPsec selected. Pastikan MikroTik Anda mengkonfigurasi IPsec port forwarding yang benar jika diperlukan."
  fi

  # --- Parameter Restore ---
  # For parameter restore, ACS URL that the ONU reaches is the CWMP Docker Container IP in its network, 
  # or simply the public domain if NGINX is used. But Mikrotik via OpenVPN will likely reach the CWMP via DOCKER_SUBNET.x
  # Let's set it to the CWMP container's internal IP or just the NGINX domain if domain is set.
  load_config
  local ACS_URL="http://${DOCKER_SUBNET}.100:7547"
  if [ -n "$BASE_DOMAIN" ]; then
    ACS_URL="http://cwmp-${INSTANCE_NAME}.${BASE_DOMAIN}"
  fi

  if [ -d "$PARAM_DIR" ]; then
    echo ""
    read -p "$(echo -e "${Y}?${N} Restore parameter preset (virtual params, UI config)? (y/n): ")" DO_RESTORE
    if [[ "$DO_RESTORE" == "y" || "$DO_RESTORE" == "Y" ]]; then
      restore_parameters "$INSTANCE_NAME" "$VERSION"
      update_provision_acs_url "$INSTANCE_NAME" "$ACS_URL"
    else
      info "Skipped parameter restore."
    fi
  fi

  log_action "INSTALL" "DONE - '$INSTANCE_NAME' deployed"

  divider
  echo -e "${G}  ✔ Instance '${W}$INSTANCE_NAME${G}' ready! (${VERSION})${N}"
  divider

  if [ -n "$BASE_DOMAIN" ]; then
    echo ""
    if [ "$SSL_ENABLED" == "true" ]; then
      echo -e "  ${C}Web UI${N}  : ${W}https://acs-${INSTANCE_NAME}.${BASE_DOMAIN}${N}"
    else
      echo -e "  ${C}Web UI${N}  : ${W}http://acs-${INSTANCE_NAME}.${BASE_DOMAIN}${N}"
    fi
    echo -e "  ${C}CWMP${N}    : http://cwmp-${INSTANCE_NAME}.${BASE_DOMAIN}"
    echo -e "  ${C}NBI${N}     : http://nbi-${INSTANCE_NAME}.${BASE_DOMAIN}"
    echo -e "  ${C}FS${N}      : http://fs-${INSTANCE_NAME}.${BASE_DOMAIN}"
  fi

  echo -e "\n  ${D}Direct access:${N}"
  echo -e "  ${D}UI=:$PORT_UI | CWMP=:$PORT_CWMP | NBI=:$PORT_NBI | FS=:$PORT_FS${N}"

  echo ""
  divider
  if [ "$VPN_CHOICE" == "2" ]; then
    echo -e "  ${C}L2TP/IPsec Connection (Isolasi Cluster):${N}"
    echo -e "  ${D}Server IP${N}   : ${W}$PUBLIC_IP${N}"
    echo -e "  ${D}Ports UDP${N}   : ${W}500->${PORT_IPSEC_500}, 4500->${PORT_IPSEC_4500}${N}"
    echo -e "  ${D}IPsec PSK${N}   : ${W}${VPN_IPSEC_PSK}${N}"
    echo -e "  ${D}Username${N}    : ${W}${VPN_USER}${N}"
    echo -e "  ${D}Password${N}    : ${W}${VPN_PASSWORD}${N}"
    echo -e "  ${D}Client IP${N}   : ${W}${VPN_POOL_BASE}.10 - .250${N} ${D}(Server L2TP: ${VPN_POOL_BASE}.1)${N}"
    echo -e "  ${D}ONU Subnet${N}  : ${W}$ONU_SUBNET${N} ${D}(tambahkan static route di MikroTik Anda ke ${DOCKER_SUBNET}.0/24 via interface L2TP)${N}"
  else
    echo -e "  ${C}OpenVPN Connection (Isolasi Cluster):${N}"
    echo -e "  ${D}Server IP${N} : ${W}$PUBLIC_IP${N}"
    echo -e "  ${D}Port${N}      : ${W}$PORT_OPENVPN (UDP)${N}"
    echo -e "  ${D}Tun pool${N}   : ${W}${VPN_POOL_BASE}/24${N} ${D}(allow di RADIUS dari rentang ini; client MikroTik umumnya .2)${N}"
    echo -e "  ${D}ONU Subnet${N}: ${W}$ONU_SUBNET${N} ${D}(bukan IP VPN)${N}"
    echo ""
    echo -e "  ${Y}Download Profile VPN (.ovpn) untuk MikroTik:${N}"
    echo -e "  ${W}$TARGET_DIR/ovpn-data/client.ovpn${N}"
    echo -e "  ${D}(Copy file tersebut dan import ke router MikroTik/Client Anda)${N}"
  fi
  echo ""
  echo -e "  ${Y}ACS URL (Set di ONU):${N}"
  echo -e "  ${W}$ACS_URL${N}"
  divider
}

# ╔══════════════════════════════════════╗
# ║     LIST, SELECT & OPERATIONS        ║
# ╚══════════════════════════════════════╝

INSTANCE_LIST=()

list_instances() {
  shopt -s nullglob
  local DIRS=("$INSTANCES_DIR"/*/)
  shopt -u nullglob
  INSTANCE_LIST=()

  if [ ${#DIRS[@]} -eq 0 ]; then
    info "Belum ada instance terpasang."; return 1
  fi

  echo -e "${W}Instances:${N}"
  local i=1
  for dir in "${DIRS[@]}"; do
    local name=$(basename "$dir")
    local running=$(cd "$dir" 2>/dev/null && $DOCKER_COMPOSE ps --status running -q 2>/dev/null | wc -l)
    if [ "$running" -gt 0 ]; then
      echo -e "  ${W}$i.${N} $name ${G}(${running} containers running)${N}"
    else
      echo -e "  ${W}$i.${N} $name ${D}(stopped)${N}"
    fi
    INSTANCE_LIST+=("$name")
    ((i++))
  done
  return 0
}

select_instance() {
  local prompt="$1"
  read -p "$(echo -e "${B}►${N} $prompt ")" SELECTION
  if [[ ! "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt ${#INSTANCE_LIST[@]} ]; then
    err "Nomor tidak valid."; return 1
  fi
  SELECTED_INSTANCE="${INSTANCE_LIST[$((SELECTION-1))]}"
  return 0
}

monitor_instance() {
  header "MONITOR RESOURCES"
  if ! list_instances; then return; fi
  if ! select_instance "Pilih nomor instance:"; then return; fi

  local INSTANCE_NAME="$SELECTED_INSTANCE"
  local containers=$(docker ps --filter "label=com.docker.compose.project=${INSTANCE_NAME}" -q)
  if [ -z "$containers" ]; then
    warn "Instance '$INSTANCE_NAME' tidak punya container aktif."; return
  fi
  info "Monitoring ${W}$INSTANCE_NAME${N} — press ${W}Ctrl+C${N} to exit"
  docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" $containers
}

pause_instance() {
  header "PAUSE / UNPAUSE"
  if ! list_instances; then return; fi
  if ! select_instance "Pilih nomor instance:"; then return; fi

  local INSTANCE_NAME="$SELECTED_INSTANCE"
  local TARGET_DIR="$INSTANCES_DIR/$INSTANCE_NAME"

  echo -e "  1. ${Y}Pause${N}  (freeze)"
  echo -e "  2. ${G}Unpause${N} (resume)"
  read -p "$(echo -e "${B}►${N} Action (1/2): ")" ACTION

  cd "$TARGET_DIR" || return
  if [ "$ACTION" == "1" ]; then
    $DOCKER_COMPOSE pause
    log_action "PAUSE" "'$INSTANCE_NAME' paused"
    ok "$INSTANCE_NAME paused."
  elif [ "$ACTION" == "2" ]; then
    $DOCKER_COMPOSE unpause
    log_action "UNPAUSE" "'$INSTANCE_NAME' resumed"
    ok "$INSTANCE_NAME resumed."
  else
    warn "Cancelled."
  fi
}

update_onu_subnet() {
  header "UPDATE ONU SUBNET (ON-THE-FLY)"
  if ! list_instances; then return; fi
  if ! select_instance "Pilih nomor instance:"; then return; fi

  local INSTANCE_NAME="$SELECTED_INSTANCE"
  local TARGET_DIR="$INSTANCES_DIR/$INSTANCE_NAME"
  local COMPOSE_FILE="$TARGET_DIR/docker-compose.yml"
  local OVPN_CONTAINER="ovpn-${INSTANCE_NAME}"
  local CWMP_CONTAINER="${INSTANCE_NAME}-genieacs-cwmp-1"

  if [ ! -f "$COMPOSE_FILE" ]; then
    err "File compose tidak ditemukan: $COMPOSE_FILE"; return
  fi

  local DOCKER_SUBNET_CIDR DOCKER_BASE DOCKER_GATEWAY
  DOCKER_SUBNET_CIDR=$(grep -oP '(?<=subnet:\s)[0-9]+\.[0-9]+\.[0-9]+\.0/24' "$COMPOSE_FILE" | head -1)
  if [ -z "$DOCKER_SUBNET_CIDR" ]; then
    err "Tidak bisa membaca subnet Docker instance."; return
  fi
  DOCKER_BASE=$(echo "$DOCKER_SUBNET_CIDR" | cut -d'.' -f1-3)
  DOCKER_GATEWAY="${DOCKER_BASE}.254"

  local CURRENT_SUBNET=""
  if [ -f "$TARGET_DIR/.onu_subnet" ]; then
    CURRENT_SUBNET=$(cat "$TARGET_DIR/.onu_subnet")
  else
    CURRENT_SUBNET=$(grep -oP 'ip route add \K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' "$COMPOSE_FILE" | head -1)
  fi

  [ -n "$CURRENT_SUBNET" ] && info "Subnet saat ini: ${W}$CURRENT_SUBNET${N}"
  read -p "$(echo -e "${B}►${N} Subnet ONU baru (contoh: 192.168.20.0/24): ")" NEW_ONU_SUBNET
  if [[ ! "$NEW_ONU_SUBNET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    err "Format subnet tidak valid!"; return
  fi
  if [ "$NEW_ONU_SUBNET" == "$CURRENT_SUBNET" ]; then
    warn "Subnet baru sama dengan subnet saat ini."; return
  fi

  local CIDR SUBNET_IP NETMASK
  CIDR=$(echo "$NEW_ONU_SUBNET" | cut -d/ -f2)
  SUBNET_IP=$(echo "$NEW_ONU_SUBNET" | cut -d/ -f1)

  local full_octets partial_octet i
  full_octets=$((CIDR / 8))
  partial_octet=$((CIDR % 8))
  NETMASK=""
  for ((i=0; i<4; i+=1)); do
    if [ "$i" -lt "$full_octets" ]; then
      NETMASK+="255"
    elif [ "$i" -eq "$full_octets" ] && [ "$partial_octet" -ne 0 ]; then
      NETMASK+=$((256 - 2**(8-partial_octet)))
    else
      NETMASK+="0"
    fi
    [ "$i" -lt 3 ] && NETMASK+="."
  done

  step "Updating OpenVPN route..."
  if ! docker ps --format '{{.Names}}' | grep -q "^${OVPN_CONTAINER}$"; then
    err "Container OpenVPN tidak berjalan: $OVPN_CONTAINER"; return
  fi
  docker exec "$OVPN_CONTAINER" sh -c "mkdir -p /etc/openvpn/ccd" 2>/dev/null
  docker exec "$OVPN_CONTAINER" sh -c "echo 'iroute $SUBNET_IP $NETMASK' > /etc/openvpn/ccd/client" 2>/dev/null
  docker exec "$OVPN_CONTAINER" sed -i '/^route [0-9]/d' /etc/openvpn/server/server.conf 2>/dev/null
  docker exec "$OVPN_CONTAINER" sh -c "echo 'route $SUBNET_IP $NETMASK' >> /etc/openvpn/server/server.conf" 2>/dev/null
  docker restart "$OVPN_CONTAINER" >/dev/null 2>&1
  ok "OpenVPN route updated (${NEW_ONU_SUBNET})."

  step "Updating CWMP startup route..."
  sed -i -E "s|ip route add [0-9.]+/[0-9]+ via ${DOCKER_GATEWAY} && \./dist/bin/genieacs-cwmp|ip route add ${NEW_ONU_SUBNET} via ${DOCKER_GATEWAY} \&\& ./dist/bin/genieacs-cwmp|g" "$COMPOSE_FILE"

  # Apply immediately in running container (best effort) before recreate.
  if docker ps --format '{{.Names}}' | grep -q "^${CWMP_CONTAINER}$"; then
    [ -n "$CURRENT_SUBNET" ] && docker exec "$CWMP_CONTAINER" ip route del "$CURRENT_SUBNET" 2>/dev/null || true
    docker exec "$CWMP_CONTAINER" ip route replace "$NEW_ONU_SUBNET" via "$DOCKER_GATEWAY" 2>/dev/null || true
  fi

  (cd "$TARGET_DIR" && $DOCKER_COMPOSE up -d --no-deps genieacs-cwmp >/dev/null 2>&1)
  echo "$NEW_ONU_SUBNET" > "$TARGET_DIR/.onu_subnet"
  log_action "ROUTE" "Updated ONU subnet for '$INSTANCE_NAME': ${CURRENT_SUBNET:-unknown} -> $NEW_ONU_SUBNET"

  ok "ONU subnet instance '${INSTANCE_NAME}' berhasil diupdate."
  info "OpenVPN dan CWMP telah disinkronkan ke subnet baru."
}

# ╔══════════════════════════════════════╗
# ║            UNINSTALL                 ║
# ╚══════════════════════════════════════╝

uninstall_instance() {
  header "UNINSTALL INSTANCE"
  if ! list_instances; then return; fi
  if ! select_instance "Pilih nomor instance untuk dihapus:"; then return; fi

  local INSTANCE_NAME="$SELECTED_INSTANCE"
  local TARGET_DIR="$INSTANCES_DIR/$INSTANCE_NAME"

  echo ""
  warn "Ini akan menghapus ${W}$INSTANCE_NAME${N} beserta seluruh database-nya!"
  read -p "$(echo -e "${R}✘${N} Ketik ${W}$INSTANCE_NAME${N} untuk konfirmasi: ")" CONFIRM

  if [ "$CONFIRM" == "$INSTANCE_NAME" ]; then
    step "Removing containers, images, volumes..."
    cd "$TARGET_DIR" || return
    $DOCKER_COMPOSE down -v --rmi all
    cd /
    remove_nginx_conf "$INSTANCE_NAME"
    rm -rf "$TARGET_DIR"
    log_action "UNINSTALL" "'$INSTANCE_NAME' fully removed"
    ok "$INSTANCE_NAME deleted."
  else
    warn "Cancelled. Input tidak cocok."
  fi
}

# ╔══════════════════════════════════════╗
# ║             VIEW LOGS                ║
# ╚══════════════════════════════════════╝

view_logs() {
  header "ACTIVITY LOG"
  if [ ! -f "$LOG_FILE" ]; then
    info "Belum ada log."; return
  fi

  local total_lines
  total_lines=$(wc -l < "$LOG_FILE")
  info "Total: ${W}$total_lines${N} entries"
  echo ""
  echo "  1. Last 20 entries"
  echo "  2. Last 50 entries"
  echo "  3. All entries"
  echo "  4. Search by keyword"
  read -p "$(echo -e "${B}►${N} Pilihan (1-4): ")" LOG_CHOICE

  case $LOG_CHOICE in
    1) divider; tail -n 20 "$LOG_FILE" ;;
    2) divider; tail -n 50 "$LOG_FILE" ;;
    3) divider; cat "$LOG_FILE" ;;
    4)
      read -p "$(echo -e "${B}►${N} Keyword: ")" KEYWORD
      divider
      grep -i --color=always "$KEYWORD" "$LOG_FILE" || info "No results."
      ;;
    *) warn "Invalid." ;;
  esac
}

# ╔══════════════════════════════════════╗
# ║       INSTANCE MANAGEMENT MENU       ║
# ╚══════════════════════════════════════╝

manage_instance_menu() {
  while true; do
    clear
    header "MANAGE INSTANCES"

    local instance_count
    instance_count=$(count_instances)
    echo -e "  ${D}Total instances:${N} ${W}$instance_count${N}"
    divider

    echo -e "  ${C}▸${N} ${W}1${N}  🆕  Install New Instance"
    echo -e "  ${C}▸${N} ${W}2${N}  📊  Monitor Resources"
    echo -e "  ${C}▸${N} ${W}3${N}  ⏸️   Pause / Unpause"
    echo -e "  ${C}▸${N} ${W}4${N}  🗑️   Uninstall Instance"
    echo -e "  ${C}▸${N} ${W}5${N}  🔁  Update ONU Subnet"
    echo -e "  ${C}▸${N} ${W}0${N}  ↩️   Back"
    divider
    read -p "$(echo -e "${B}►${N} Pilihan: ")" INST_MENU

    case $INST_MENU in
      1) install_instance ;;
      2) monitor_instance ;;
      3) pause_instance ;;
      4) uninstall_instance ;;
      5) update_onu_subnet ;;
      0) return ;;
      *) err "Invalid option." ;;
    esac

    [ "$INST_MENU" != "2" ] && { echo ""; read -p "$(echo -e "${D}Press Enter to continue...${N}")"; }
  done
}

# ╔══════════════════════════════════════╗
# ║          SERVICES MENU               ║
# ╚══════════════════════════════════════╝

# --- Setup GenieACS Source ---
setup_genieacs_source() {
  header "SETUP GENIEACS SOURCE"

  local stable_ok="${R}Missing${N}"
  local latest_ok="${R}Missing${N}"
  [ -f "$SOURCE_DIR/stable/package.json" ] && stable_ok="${G}Ready${N}"
  [ -f "$SOURCE_DIR/latest/package.json" ] && latest_ok="${G}Ready${N}"

  echo ""
  echo -e "  ${D}Stable (v1.2):${N} $stable_ok"
  echo -e "  ${D}Latest (v1.3):${N} $latest_ok"
  divider

  echo -e "  ${W}1.${N} Clone Stable (v1.2)"
  echo -e "  ${W}2.${N} Clone Latest (v1.3-dev)"
  echo -e "  ${W}3.${N} Clone Both"
  echo -e "  ${W}0.${N} Back"
  divider
  read -p "$(echo -e "${B}►${N} Pilihan: ")" SRC_CHOICE

  case $SRC_CHOICE in
    1|3)
      if [ -f "$SOURCE_DIR/stable/package.json" ]; then
        info "Stable sudah ada, skip."
      else
        step "Cloning GenieACS stable (v1.2)..."
        git clone --depth 1 -b v1.2 https://github.com/genieacs/genieacs.git "$SOURCE_DIR/stable" 2>&1 | tail -1
        [ -f "$SOURCE_DIR/stable/package.json" ] && ok "Stable cloned!" || err "Clone failed!"
      fi
      ;;&
    2|3)
      if [ -f "$SOURCE_DIR/latest/package.json" ]; then
        info "Latest sudah ada, skip."
      else
        step "Cloning GenieACS latest..."
        git clone --depth 1 https://github.com/genieacs/genieacs.git "$SOURCE_DIR/latest" 2>&1 | tail -1
        [ -f "$SOURCE_DIR/latest/package.json" ] && ok "Latest cloned!" || err "Clone failed!"
      fi
      ;;
    0) return ;;
    *) err "Invalid." ;;
  esac
}

services_menu() {
  while true; do
    clear
    header "SERVICES & SETTINGS"

    local nginx_status certbot_status radius_status
    [ -n "$(docker ps -q -f name=mostech-nginx-proxy 2>/dev/null)" ] && \
      nginx_status="${G}Active${N}" || nginx_status="${D}Off${N}"
    docker image inspect certbot/dns-cloudflare >/dev/null 2>&1 && \
      certbot_status="${G}Ready${N}" || certbot_status="${D}Off${N}"
    [ -n "$(docker ps -q -f name=gacs-central-radius 2>/dev/null)" ] && \
      radius_status="${G}Active${N}" || radius_status="${D}Off${N}"

    local stable_label latest_label
    [ -f "$SOURCE_DIR/stable/package.json" ] && stable_label="${G}Ready${N}" || stable_label="${R}Missing${N}"
    [ -f "$SOURCE_DIR/latest/package.json" ] && latest_label="${G}Ready${N}" || latest_label="${R}Missing${N}"

    load_config
    echo ""
    echo -e "  ${D}Nginx:${N} $nginx_status  │  ${D}Certbot:${N} $certbot_status  │  ${D}RADIUS:${N} $radius_status"
    echo -e "  ${D}Domain:${N} ${W}${BASE_DOMAIN:-none}${N}  │  ${D}SSL:${N} $([ "$SSL_ENABLED" == "true" ] && echo -e "${G}Active${N}" || echo -e "${D}Off${N}")"
    echo -e "  ${D}Source Stable:${N} $stable_label  │  ${D}Source Latest:${N} $latest_label"
    divider

    echo -e "  ${C}▸${N} ${W}1${N}  🌐  Setup Domain & SSL"
    echo -e "  ${C}▸${N} ${W}2${N}  📥  Install Services"
    echo -e "  ${C}▸${N} ${W}3${N}  📤  Uninstall Services"
    echo -e "  ${C}▸${N} ${W}4${N}  📦  Setup GenieACS Source"
    echo -e "  ${C}▸${N} ${W}0${N}  ↩️   Back"
    divider
    read -p "$(echo -e "${B}►${N} Pilihan: ")" SVC_MENU

    case $SVC_MENU in
      1) setup_domain ;;
      2) services_install_menu ;;
      3) services_uninstall_menu ;;
      4) setup_genieacs_source ;;
      0) return ;;
      *) err "Invalid option." ;;
    esac

    echo ""; read -p "$(echo -e "${D}Press Enter to continue...${N}")"
  done
}

# ╔══════════════════════════════════════╗
# ║            MAIN MENU                 ║
# ╚══════════════════════════════════════╝

show_menu() {
  clear
  load_config

  local instance_count
  instance_count=$(count_instances)

  local docker_label ssl_label
  command -v docker &>/dev/null && docker info &>/dev/null 2>&1 && docker_label="${G}● Active${N}" || docker_label="${R}○ Off${N}"
  [ "$SSL_ENABLED" == "true" ] && ssl_label="${G}● Active${N}" || ssl_label="${D}○ Off${N}"

  echo ""
  echo -e "${C}   ██████╗  █████╗  ██████╗███████╗${N}"
  echo -e "${C}  ██╔════╝ ██╔══██╗██╔════╝██╔════╝${N}"
  echo -e "${C}  ██║  ███╗███████║██║     ███████╗${N}"
  echo -e "${C}  ██║   ██║██╔══██║██║     ╚════██║${N}"
  echo -e "${C}  ╚██████╔╝██║  ██║╚██████╗███████║${N}"
  echo -e "${C}   ╚═════╝ ╚═╝  ╚═╝ ╚═════╝╚══════╝${N}"
  echo -e "${D}  GenieACS Multi-Instance Orchestrator ${VERSION_TAG}${N}"
  echo -e "${D}  By Mostech — github.com/safrinnetwork${N}"
  echo ""
  echo -e "${C}  ┌──────────────────────────────────┐${N}"
  echo -e "${C}  │${N}  ${D}Domain${N}     ${W}${BASE_DOMAIN:-none}${N}"
  echo -e "${C}  │${N}  ${D}SSL${N}        $ssl_label"
  echo -e "${C}  │${N}  ${D}Docker${N}     $docker_label"
  echo -e "${C}  │${N}  ${D}Instances${N}  ${W}$instance_count${N}"
  echo -e "${C}  └──────────────────────────────────┘${N}"
  echo ""
  echo -e "  ${C}▸${N} ${W}1${N}  📦  Manage Instance"
  echo -e "  ${C}▸${N} ${W}2${N}  📋  View Activity Log"
  echo -e "  ${C}▸${N} ${W}3${N}  ⚙️   Services & Settings"
  echo -e "  ${C}▸${N} ${W}0${N}  🚪  Exit"
  echo ""
  divider
}

log_action "SYSTEM" "Manager started"
while true; do
  show_menu
  read -p "$(echo -e "${B}►${N} Menu: ")" MENU

  case $MENU in
    1) manage_instance_menu ;;
    2) view_logs ;;
    3) services_menu ;;
    0) log_action "SYSTEM" "Manager closed"; echo -e "\n${G}Goodbye!${N}"; exit 0 ;;
    *) err "Invalid option." ;;
  esac

  [ "$MENU" == "2" ] && { echo ""; read -p "$(echo -e "${D}Press Enter to continue...${N}")"; }
done
