#!/usr/bin/env bash
# ==============================================================================
# MOSTECH GACS MANAGER v1.2
# Multi-instance GenieACS orchestration tool with auto port allocation,
# isolated databases, Nginx reverse proxy, wildcard SSL via Cloudflare,
# and L2TP VPN integration for ONU-to-ACS connectivity.
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
ROUTES_FILE="/etc/l2tp-onu-routes.conf"

# L2TP Configuration
L2TP_CONFIG="/etc/xl2tpd/xl2tpd.conf"
PPP_CONFIG="/etc/ppp/options.xl2tpd"
CHAP_SECRETS="/etc/ppp/chap-secrets"
L2TP_SUBNET="172.16.101.0/24"
L2TP_LOCAL_IP="172.16.101.1"
L2TP_IP_START=10
L2TP_IP_END=100
L2TP_IP_BASE="172.16.101"

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

# --- Firewall Abstraction (iptables vs nftables) ---
detect_firewall() {
  if command -v iptables &>/dev/null; then
    FW_CMD="iptables"
    FW_SAVE="iptables-save"
  elif command -v iptables-legacy &>/dev/null; then
    FW_CMD="iptables-legacy"
    FW_SAVE="iptables-legacy-save"
  else
    FW_CMD=""
    FW_SAVE=""
  fi
}
detect_firewall

fw_add() { [ -n "$FW_CMD" ] && $FW_CMD "$@" 2>/dev/null; }
fw_del() { [ -n "$FW_CMD" ] && $FW_CMD "$@" 2>/dev/null; }
fw_save() {
  [ -z "$FW_CMD" ] && return 0
  mkdir -p /etc/iptables 2>/dev/null
  $FW_SAVE > /etc/iptables/rules.v4 2>/dev/null
}

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
# ║      ONU ROUTE MANAGEMENT            ║
# ╚══════════════════════════════════════╝

add_onu_route() {
  local subnet="$1"
  local via_ip="$2"
  local instance="$3"

  # Try to add route immediately (may fail if MikroTik not connected yet — this is normal)
  if ip route show | grep -q "$subnet"; then
    warn "Route $subnet already exists, updating persistent config."
  else
    ip route add "$subnet" via "$via_ip" 2>/dev/null
    if [ $? -eq 0 ]; then
      ok "Route added: ${W}$subnet${N} via ${W}$via_ip${N}"
    else
      # Gateway unreachable = MikroTik belum connect, route akan otomatis aktif via PPP hooks
      ok "Route ${W}$subnet${N} via ${W}$via_ip${N} saved."
      info "Route akan otomatis aktif saat MikroTik connect via L2TP."
    fi
  fi

  # Remove existing entry for this instance to avoid duplicates
  [ -f "$ROUTES_FILE" ] && sed -i "/^$instance /d" "$ROUTES_FILE"

  # Save to persistent file
  echo "$instance $subnet $via_ip" >> "$ROUTES_FILE"
  # Save to instance dir
  echo "$subnet" > "$INSTANCES_DIR/$instance/.onu_subnet"

  # Ensure PPP hooks are installed for auto route on connect/disconnect
  install_ppp_route_hooks

  log_action "ROUTE" "Added: $subnet via $via_ip (instance: $instance)"
}

remove_onu_route() {
  local instance="$1"
  local subnet_file="$INSTANCES_DIR/$instance/.onu_subnet"

  if [ -f "$subnet_file" ]; then
    local subnet
    subnet=$(cat "$subnet_file")
    ip route del "$subnet" 2>/dev/null
    ok "Route removed: ${W}$subnet${N}"

    # Remove from persistent file
    [ -f "$ROUTES_FILE" ] && sed -i "/^$instance /d" "$ROUTES_FILE"
    rm -f "$subnet_file"
    log_action "ROUTE" "Removed: $subnet (instance: $instance)"
  fi
}

restore_onu_routes() {
  # Called on system boot to re-add all ONU routes
  if [ ! -f "$ROUTES_FILE" ]; then return; fi
  while IFS=' ' read -r inst subnet via_ip; do
    [[ -z "$inst" || "$inst" =~ ^# ]] && continue
    if ! ip route show | grep -q "$subnet"; then
      ip route add "$subnet" via "$via_ip" 2>/dev/null
    fi
  done < "$ROUTES_FILE"
}

install_ppp_route_hooks() {
  # Install PPP ip-up/ip-down hooks for automatic ONU route management
  # When MikroTik connects via L2TP → routes auto-added
  # When MikroTik disconnects → routes auto-removed
  local hook_up="/etc/ppp/ip-up.d/onu-routes"
  local hook_down="/etc/ppp/ip-down.d/onu-routes"

  mkdir -p /etc/ppp/ip-up.d /etc/ppp/ip-down.d

  cat > "$hook_up" <<'HOOKEOF'
#!/bin/bash
# GACS-Farm: Auto-add ONU routes when L2TP/PPP session comes up
# Called by pppd with args: interface tty speed local_ip remote_ip
REMOTE_IP="$5"
ROUTES_FILE="/etc/l2tp-onu-routes.conf"
[ ! -f "$ROUTES_FILE" ] && exit 0
while IFS=' ' read -r instance subnet via_ip; do
    [[ -z "$instance" || "$instance" =~ ^# ]] && continue
    if [ "$via_ip" == "$REMOTE_IP" ]; then
        ip route replace "$subnet" via "$via_ip" 2>/dev/null
        logger -t gacs-route "PPP up: added route $subnet via $via_ip (instance: $instance)"
    fi
done < "$ROUTES_FILE"
exit 0
HOOKEOF
  chmod +x "$hook_up"

  cat > "$hook_down" <<'HOOKEOF'
#!/bin/bash
# GACS-Farm: Auto-remove ONU routes when L2TP/PPP session goes down
# Called by pppd with args: interface tty speed local_ip remote_ip
REMOTE_IP="$5"
ROUTES_FILE="/etc/l2tp-onu-routes.conf"
[ ! -f "$ROUTES_FILE" ] && exit 0
while IFS=' ' read -r instance subnet via_ip; do
    [[ -z "$instance" || "$instance" =~ ^# ]] && continue
    if [ "$via_ip" == "$REMOTE_IP" ]; then
        ip route del "$subnet" via "$via_ip" 2>/dev/null
        logger -t gacs-route "PPP down: removed route $subnet via $via_ip (instance: $instance)"
    fi
done < "$ROUTES_FILE"
exit 0
HOOKEOF
  chmod +x "$hook_down"
}

setup_route_persistence() {
  # Install PPP hooks for automatic route management on connect/disconnect
  install_ppp_route_hooks

  # Add @reboot cron as fallback to restore routes after reboot
  local cron_cmd="@reboot sleep 30 && [ -f $ROUTES_FILE ] && while IFS=' ' read -r i s v; do ip route add \$s via \$v 2>/dev/null; done < $ROUTES_FILE"
  if ! crontab -l 2>/dev/null | grep -q "l2tp-onu-routes"; then
    (crontab -l 2>/dev/null; echo "$cron_cmd # l2tp-onu-routes") | crontab -
  fi
  ok "Route persistence enabled (PPP hooks + cron @reboot)."
}

# ╔══════════════════════════════════════╗
# ║         L2TP FUNCTIONS               ║
# ╚══════════════════════════════════════╝

check_l2tp_installed() {
  if dpkg -l xl2tpd 2>/dev/null | grep -q "^ii" && \
     [ -f "$L2TP_CONFIG" ] && \
     systemctl is-enabled xl2tpd >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

get_public_ip() {
  curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || \
  curl -s -4 --max-time 5 icanhazip.com 2>/dev/null || \
  echo "N/A"
}

get_default_interface() {
  ip route | grep default | awk '{print $5}' | head -n1
}

get_next_l2tp_ip() {
  local assigned_ips=()
  if [ -f "$CHAP_SECRETS" ]; then
    while IFS= read -r line; do
      [[ $line =~ ^#.*$ ]] || [[ -z $line ]] && continue
      local ip=$(echo "$line" | awk '{print $4}')
      [[ -n "$ip" ]] && assigned_ips+=("$ip")
    done < "$CHAP_SECRETS"
  fi

  for i in $(seq $L2TP_IP_START $L2TP_IP_END); do
    local test_ip="${L2TP_IP_BASE}.${i}"
    local found=0
    for aip in "${assigned_ips[@]}"; do
      [[ "$aip" == "$test_ip" ]] && { found=1; break; }
    done
    if [ $found -eq 0 ]; then
      echo "$test_ip"
      return 0
    fi
  done
  return 1
}

l2tp_user_exists() {
  grep -q "^$1\s" "$CHAP_SECRETS" 2>/dev/null
}

create_l2tp_user() {
  local username="$1"
  local password="$2"
  local ip_addr="$3"

  if ! check_l2tp_installed; then
    return 1
  fi

  if l2tp_user_exists "$username"; then
    warn "L2TP user '$username' sudah ada, skip."
    return 0
  fi

  printf "%-20s *       %-20s %s\n" "$username" "$password" "$ip_addr" >> "$CHAP_SECRETS"
  systemctl restart xl2tpd >/dev/null 2>&1
  log_action "L2TP" "User '$username' created (IP: $ip_addr)"
  return 0
}

delete_l2tp_user() {
  local username="$1"

  if ! [ -f "$CHAP_SECRETS" ]; then return 1; fi
  if ! l2tp_user_exists "$username"; then return 0; fi

  sed -i "/^$username\s/d" "$CHAP_SECRETS"
  systemctl restart xl2tpd >/dev/null 2>&1
  log_action "L2TP" "User '$username' deleted"
  return 0
}

install_l2tp_server() {
  header "INSTALL L2TP SERVER"

  if check_l2tp_installed; then
    ok "L2TP server sudah terinstall."
    return 0
  fi

  local PUBLIC_IP=$(get_public_ip)
  local DEFAULT_INTERFACE=$(get_default_interface)

  if [ -z "$DEFAULT_INTERFACE" ]; then
    err "Cannot detect default network interface!"
    return 1
  fi

  info "Public IP: ${W}$PUBLIC_IP${N}"
  info "Interface: ${W}$DEFAULT_INTERFACE${N}"

  # Step 1: Install packages
  step "[1/5] Installing packages..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
  # Core packages
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xl2tpd ppp socat curl >/dev/null 2>&1
  # Firewall persistence (may fail on some distros, non-fatal)
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent >/dev/null 2>&1 || \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq netfilter-persistent >/dev/null 2>&1 || \
    warn "iptables-persistent not available, firewall rules may not persist after reboot."
  # Ensure iptables command is available (for nftables-based distros)
  if ! command -v iptables &>/dev/null && ! command -v iptables-legacy &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables >/dev/null 2>&1
  fi
  detect_firewall
  if [ $? -ne 0 ] || ! dpkg -l xl2tpd 2>/dev/null | grep -q "^ii"; then
    err "Package installation failed!"; return 1
  fi
  ok "Packages installed."

  # Step 2: Configure xl2tpd
  step "[2/5] Configuring L2TP server..."
  [ -f "$L2TP_CONFIG" ] && cp "$L2TP_CONFIG" "${L2TP_CONFIG}.backup"
  cat > "$L2TP_CONFIG" <<EOF
[global]
port = 1701
access control = no

[lns default]
ip range = ${L2TP_IP_BASE}.${L2TP_IP_START}-${L2TP_IP_BASE}.${L2TP_IP_END}
local ip = ${L2TP_LOCAL_IP}
require chap = yes
refuse pap = yes
require authentication = yes
name = L2TPServer
ppp debug = yes
pppoptfile = $PPP_CONFIG
length bit = yes
EOF

  cat > "$PPP_CONFIG" <<EOF
ipcp-accept-local
ipcp-accept-remote
ms-dns 8.8.8.8
ms-dns 8.8.4.4
noccp
auth
mtu 1410
mru 1410
nodefaultroute
debug
proxyarp
require-chap
refuse-pap
EOF

  if [ ! -f "$CHAP_SECRETS" ]; then
    cat > "$CHAP_SECRETS" <<EOF
# Secrets for authentication using CHAP
# client        server  secret                  IP addresses
EOF
  fi
  ok "L2TP configured."

  # Step 3: Firewall
  step "[3/5] Configuring firewall..."
  grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
  sysctl -p >/dev/null 2>&1
  fw_add -t nat -A POSTROUTING -s $L2TP_SUBNET -o "$DEFAULT_INTERFACE" -j MASQUERADE
  fw_add -A FORWARD -s $L2TP_SUBNET -j ACCEPT
  fw_add -A FORWARD -d $L2TP_SUBNET -j ACCEPT
  fw_add -A INPUT -p udp --dport 1701 -j ACCEPT
  fw_save
  ok "Firewall configured."

  # Step 4: Start services
  step "[4/5] Starting L2TP service..."
  systemctl enable xl2tpd >/dev/null 2>&1
  systemctl start xl2tpd >/dev/null 2>&1
  sleep 2
  if systemctl is-active --quiet xl2tpd; then
    ok "xl2tpd running."
  else
    warn "xl2tpd may need manual check."
  fi

  # Step 5: Enable persistence
  step "[5/5] Enabling persistence..."
  systemctl enable netfilter-persistent >/dev/null 2>&1 || \
    systemctl enable iptables >/dev/null 2>&1 || true
  # Install PPP hooks for automatic ONU route management
  install_ppp_route_hooks
  ok "Done."

  log_action "L2TP" "L2TP server installed (IP: $PUBLIC_IP, IF: $DEFAULT_INTERFACE)"
  echo ""
  ok "L2TP Server installed! Listening on ${W}$PUBLIC_IP:1701${N}"
  info "VPN Subnet: ${W}$L2TP_SUBNET${N} | Local IP: ${W}$L2TP_LOCAL_IP${N}"
}

uninstall_l2tp_server() {
  header "UNINSTALL L2TP SERVER"

  if ! check_l2tp_installed; then
    info "L2TP server belum terinstall."
    return 0
  fi

  warn "Ini akan menghapus L2TP server dan semua user VPN!"
  read -p "$(echo -e "${R}✘${N} Ketik ${W}UNINSTALL${N} untuk konfirmasi: ")" CONFIRM
  if [ "$CONFIRM" != "UNINSTALL" ]; then
    warn "Cancelled."; return 0
  fi

  local DEFAULT_INTERFACE=$(get_default_interface)

  step "Stopping services..."
  systemctl stop xl2tpd 2>/dev/null
  systemctl disable xl2tpd 2>/dev/null

  step "Removing firewall rules..."
  fw_del -D INPUT -p udp --dport 1701 -j ACCEPT
  fw_del -D FORWARD -s $L2TP_SUBNET -j ACCEPT
  fw_del -D FORWARD -d $L2TP_SUBNET -j ACCEPT
  fw_del -t nat -D POSTROUTING -s $L2TP_SUBNET -o "$DEFAULT_INTERFACE" -j MASQUERADE
  fw_save

  step "Cleaning config files..."
  rm -f "$PPP_CONFIG"
  [ -f "$L2TP_CONFIG" ] && echo "" > "$L2TP_CONFIG"
  [ -f "$CHAP_SECRETS" ] && {
    echo "# Secrets for authentication using CHAP" > "$CHAP_SECRETS"
    echo "# client        server  secret                  IP addresses" >> "$CHAP_SECRETS"
  }

  read -p "$(echo -e "${Y}?${N} Hapus packages juga? (xl2tpd, ppp, socat) (y/n): ")" RM_PKG
  if [[ "$RM_PKG" == "y" || "$RM_PKG" == "Y" ]]; then
    step "Removing packages..."
    apt-get remove --purge -y xl2tpd ppp socat >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1
    ok "Packages removed."
  fi

  pkill -9 pppd 2>/dev/null
  for iface in $(ip link show 2>/dev/null | grep "ppp" | cut -d: -f2 | tr -d ' '); do
    ip link delete "$iface" 2>/dev/null
  done

  log_action "L2TP" "L2TP server uninstalled"
  ok "L2TP server removed."
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

services_install_menu() {
  header "INSTALL SERVICES"

  local l2tp_status nginx_status certbot_status

  check_l2tp_installed && l2tp_status="${G}Installed${N}" || l2tp_status="${D}Not installed${N}"

  docker ps -q -f name=mostech-nginx-proxy >/dev/null 2>&1 && \
    [ -n "$(docker ps -q -f name=mostech-nginx-proxy)" ] && \
    nginx_status="${G}Running${N}" || nginx_status="${D}Not running${N}"

  docker image inspect certbot/dns-cloudflare >/dev/null 2>&1 && \
    certbot_status="${G}Ready${N}" || certbot_status="${D}Not installed${N}"

  echo ""
  echo -e "  ${W}1.${N} L2TP Server      [$l2tp_status]"
  echo -e "  ${W}2.${N} Nginx Proxy      [$nginx_status]"
  echo -e "  ${W}3.${N} Certbot (SSL)    [$certbot_status]"
  echo -e "  ${W}4.${N} Install All"
  echo -e "  ${W}0.${N} Back"
  divider
  read -p "$(echo -e "${B}►${N} Pilihan: ")" SVC_CHOICE

  case $SVC_CHOICE in
    1) install_l2tp_server ;;
    2) install_nginx_service ;;
    3) install_certbot ;;
    4)
      install_l2tp_server
      install_nginx_service
      install_certbot
      echo ""
      ok "All services installed."
      ;;
    0) return ;;
    *) err "Invalid." ;;
  esac
}

services_uninstall_menu() {
  header "UNINSTALL SERVICES"

  local l2tp_status nginx_status certbot_status

  check_l2tp_installed && l2tp_status="${G}Installed${N}" || l2tp_status="${D}Not installed${N}"

  [ -n "$(docker ps -q -f name=mostech-nginx-proxy 2>/dev/null)" ] && \
    nginx_status="${G}Running${N}" || nginx_status="${D}Not running${N}"

  docker image inspect certbot/dns-cloudflare >/dev/null 2>&1 && \
    certbot_status="${G}Installed${N}" || certbot_status="${D}Not installed${N}"

  echo ""
  echo -e "  ${W}1.${N} L2TP Server      [$l2tp_status]"
  echo -e "  ${W}2.${N} Nginx Proxy      [$nginx_status]"
  echo -e "  ${W}3.${N} Certbot (SSL)    [$certbot_status]"
  echo -e "  ${W}4.${N} Uninstall All"
  echo -e "  ${W}0.${N} Back"
  divider
  read -p "$(echo -e "${B}►${N} Pilihan: ")" SVC_CHOICE

  case $SVC_CHOICE in
    1) uninstall_l2tp_server ;;
    2) uninstall_nginx_service ;;
    3) uninstall_certbot ;;
    4)
      uninstall_l2tp_server
      uninstall_nginx_service
      uninstall_certbot
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

  echo -e "\n${W}[ 2/3 ] Cloudflare API Token${N}"
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

  step "Allocating ports..."
  PORT_CWMP=$(get_random_free_port)
  PORT_NBI=$(get_random_free_port)
  PORT_FS=$(get_random_free_port)
  PORT_UI=$(get_random_free_port)
  ok "Ports: CWMP=${W}$PORT_CWMP${N} | NBI=${W}$PORT_NBI${N} | FS=${W}$PORT_FS${N} | UI=${W}$PORT_UI${N}"

  TARGET_DIR="$INSTANCES_DIR/$INSTANCE_NAME"
  mkdir -p "$TARGET_DIR"

  cat > "$TARGET_DIR/docker-compose.yml" <<EOF
services:
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
      - genieacs-net
    depends_on:
      - mongodb
    command: ./dist/bin/genieacs-cwmp

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
EOF

  step "Building & starting containers..."
  log_action "INSTALL" "START - '$INSTANCE_NAME' ver=$VERSION | CWMP=$PORT_CWMP NBI=$PORT_NBI FS=$PORT_FS UI=$PORT_UI"
  (cd "$TARGET_DIR" && $DOCKER_COMPOSE up -d --build)

  generate_nginx_conf "$INSTANCE_NAME" "$PORT_UI" "$PORT_CWMP" "$PORT_NBI" "$PORT_FS"

  # --- L2TP Auto User Creation ---
  local L2TP_USER_PASS="" L2TP_USER_IP="" ONU_SUBNET=""
  if check_l2tp_installed; then
    step "Creating L2TP user for this instance..."
    L2TP_USER_PASS=$(generate_random_password 12)
    L2TP_USER_IP=$(get_next_l2tp_ip)

    if [ -n "$L2TP_USER_IP" ]; then
      create_l2tp_user "$INSTANCE_NAME" "$L2TP_USER_PASS" "$L2TP_USER_IP"
      ok "L2TP user '${W}$INSTANCE_NAME${N}' created."

      # --- ONU Subnet Route ---
      echo ""
      info "Agar ACS bisa manage ONU (summon/push), perlu route ke subnet ONU."
      read -p "$(echo -e "${B}►${N} Subnet ONU di MikroTik ini (contoh: 10.50.0.0/16): ")" ONU_SUBNET
      if [[ -n "$ONU_SUBNET" && "$ONU_SUBNET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        add_onu_route "$ONU_SUBNET" "$L2TP_USER_IP" "$INSTANCE_NAME"
        setup_route_persistence
      elif [ -n "$ONU_SUBNET" ]; then
        err "Format subnet tidak valid! Contoh: 10.50.0.0/16"
        info "Anda bisa tambahkan manual nanti: ip route add <subnet> via $L2TP_USER_IP"
      else
        info "Skipped. Tambahkan manual nanti jika diperlukan."
      fi
    else
      warn "No available L2TP IPs. Skipped."
    fi
  fi

  # --- Parameter Restore ---
  local ACS_URL="http://${L2TP_LOCAL_IP}:${PORT_CWMP}"
  if [ -d "$PARAM_DIR" ]; then
    echo ""
    read -p "$(echo -e "${Y}?${N} Restore parameter preset (virtual params, UI config)? (y/n): ")" DO_RESTORE
    if [[ "$DO_RESTORE" == "y" || "$DO_RESTORE" == "Y" ]]; then
      restore_parameters "$INSTANCE_NAME" "$VERSION"
      # Auto-update ACS URL in provisions to match this instance
      update_provision_acs_url "$INSTANCE_NAME" "$ACS_URL"
    else
      info "Skipped parameter restore."
    fi
  fi

  log_action "INSTALL" "DONE - '$INSTANCE_NAME' deployed"

  divider
  echo -e "${G}  ✔ Instance '${W}$INSTANCE_NAME${G}' ready! (${VERSION})${N}"
  divider

  load_config
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

  # --- L2TP Info ---
  if [ -n "$L2TP_USER_PASS" ] && [ -n "$L2TP_USER_IP" ]; then
    local PUBLIC_IP=$(get_public_ip)
    echo ""
    divider
    echo -e "  ${C}L2TP VPN Connection:${N}"
    echo -e "  ${D}Server${N}   : ${W}$PUBLIC_IP${N}"
    echo -e "  ${D}Username${N} : ${W}$INSTANCE_NAME${N}"
    echo -e "  ${D}Password${N} : ${W}$L2TP_USER_PASS${N}"
    echo -e "  ${D}Client IP${N}: ${W}$L2TP_USER_IP${N}"
    [ -n "$ONU_SUBNET" ] && echo -e "  ${D}ONU Subnet${N}: ${W}$ONU_SUBNET${N}"
    echo ""
    echo -e "  ${Y}ACS URL (set di ONU):${N}"
    echo -e "  ${W}http://${L2TP_LOCAL_IP}:${PORT_CWMP}${N}"
    echo ""
    echo -e "  ${Y}Konfigurasi MikroTik:${N}"
    echo -e "  ${D}1.${N} Buat L2TP Client (server: $PUBLIC_IP, user: $INSTANCE_NAME, pass: $L2TP_USER_PASS)"
    echo -e "  ${D}2.${N} ${R}JANGAN${N} pakai masquerade di L2TP interface"
    echo -e "  ${D}3.${N} Pastikan IP forwarding aktif di MikroTik"
    echo ""
    echo -e "  ${Y}Script MikroTik (copy-paste ke terminal MikroTik):${N}"
    echo ""
    echo -e "  ${D}# 1. Buat L2TP Client${N}"
    echo -e "  ${W}/interface l2tp-client add name=Tunnel_GenieACS_Mostech connect-to=$PUBLIC_IP user=$INSTANCE_NAME password=$L2TP_USER_PASS disabled=no${N}"
    echo ""
    echo -e "  ${D}# 2. Firewall: Allow L2TP forward (POSISI PALING ATAS!)${N}"
    echo -e "  ${W}/ip firewall filter add chain=forward in-interface=Tunnel_GenieACS_Mostech action=accept comment=\"Allow L2TP to LAN - By Mostech\" place-before=0${N}"
    echo -e "  ${W}/ip firewall filter add chain=forward out-interface=Tunnel_GenieACS_Mostech action=accept comment=\"Allow LAN to L2TP - By Mostech\" place-before=1${N}"
  fi

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
    # Delete ONU route if exists
    if [ -f "$TARGET_DIR/.onu_subnet" ]; then
      step "Removing ONU route..."
      remove_onu_route "$INSTANCE_NAME"
    fi

    # Delete L2TP user if exists
    if check_l2tp_installed && l2tp_user_exists "$INSTANCE_NAME"; then
      step "Removing L2TP user '$INSTANCE_NAME'..."
      delete_l2tp_user "$INSTANCE_NAME"
      ok "L2TP user removed."
    fi

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
    echo -e "  ${C}▸${N} ${W}0${N}  ↩️   Back"
    divider
    read -p "$(echo -e "${B}►${N} Pilihan: ")" INST_MENU

    case $INST_MENU in
      1) install_instance ;;
      2) monitor_instance ;;
      3) pause_instance ;;
      4) uninstall_instance ;;
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

    local l2tp_status nginx_status certbot_status
    check_l2tp_installed && l2tp_status="${G}Active${N}" || l2tp_status="${D}Off${N}"
    [ -n "$(docker ps -q -f name=mostech-nginx-proxy 2>/dev/null)" ] && \
      nginx_status="${G}Active${N}" || nginx_status="${D}Off${N}"
    docker image inspect certbot/dns-cloudflare >/dev/null 2>&1 && \
      certbot_status="${G}Ready${N}" || certbot_status="${D}Off${N}"

    local stable_label latest_label
    [ -f "$SOURCE_DIR/stable/package.json" ] && stable_label="${G}Ready${N}" || stable_label="${R}Missing${N}"
    [ -f "$SOURCE_DIR/latest/package.json" ] && latest_label="${G}Ready${N}" || latest_label="${R}Missing${N}"

    load_config
    echo ""
    echo -e "  ${D}L2TP:${N} $l2tp_status  │  ${D}Nginx:${N} $nginx_status  │  ${D}Certbot:${N} $certbot_status"
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

  local l2tp_label docker_label ssl_label
  check_l2tp_installed && l2tp_label="${G}● Active${N}" || l2tp_label="${R}○ Off${N}"
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
  echo -e "${C}  │${N}  ${D}L2TP${N}       $l2tp_label"
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

# Restore ONU routes on start
restore_onu_routes

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
