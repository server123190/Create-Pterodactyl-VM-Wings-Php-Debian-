#!/usr/bin/env bash
# ===========================================================================================
#  bootstrap-vps.sh
#  A verbose, development-friendly bootstrap script for Codesandbox "Docker-container".
#  - Creates a pseudo "VM" workspace named vps#~ under Vm/
#  - Installs base tools, PHP, and ROOTLESS Docker (no systemd needed)
#  - Prepares docker-compose files for PHP/Apache, MySQL, phpMyAdmin (optional)
#  - Adds helper commands and aliases (vmctl) for managing rootless Docker daemon
#  - Sets username/password for MySQL services to root/root (dev only)
#  - DOES NOT install Pterodactyl Wings (placeholder provided for you to run manually)
#
#  Usage:
#     chmod +x bootstrap-vps.sh && ./bootstrap-vps.sh
#
#  Notes:
#  * Designed for Codesandbox containers (Debian/Ubuntu-ish). Tested without systemd.
#  * Idempotent where possible; re-running is safe.
#  * Meant for development, not production (uses root/root creds, relaxed configs).
# ===========================================================================================

set -Eeuo pipefail

# ---------------------------------------
# Global Constants / Defaults
# ---------------------------------------
VM_NAME_DEFAULT="vps#~"
VM_DIR_DEFAULT="Vm"
MYSQL_ROOT_PASSWORD_DEFAULT="root"
MYSQL_DATABASE_DEFAULT="testdb"
MYSQL_USER_DEFAULT="root"
MYSQL_PASSWORD_DEFAULT="root"
PHP_HTTP_PORT_DEFAULT="8080"
PHPMYADMIN_HTTP_PORT_DEFAULT="8081"
MYSQL_TCP_PORT_DEFAULT="3306"
DOCKER_DATA_ROOT_DEFAULT="${HOME}/.local/share/docker-rootless"
SLEEP_AFTER_DAEMON_START="5"

# ---------------------------------------
# Styling / Colors (fallback if tput missing)
# ---------------------------------------
if command -v tput >/dev/null 2>&1; then
  BOLD="$(tput bold || true)"
  DIM="$(tput dim || true)"
  RED="$(tput setaf 1 || true)"
  GREEN="$(tput setaf 2 || true)"
  YELLOW="$(tput setaf 3 || true)"
  BLUE="$(tput setaf 4 || true)"
  RESET="$(tput sgr0 || true)"
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

# ---------------------------------------
# Logger helpers
# ---------------------------------------
log()   { echo -e "${DIM}[$(date +'%H:%M:%S')]${RESET} $*"; }
info()  { echo -e "${BLUE}${BOLD}➤${RESET} $*"; }
ok()    { echo -e "${GREEN}${BOLD}✔${RESET} $*"; }
warn()  { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
err()   { echo -e "${RED}${BOLD}✖${RESET} $*" >&2; }
die()   { err "$*"; exit 1; }

# ---------------------------------------
# Trap for diagnostics
# ---------------------------------------
on_exit() {
  local code=$?
  if [[ $code -ne 0 ]]; then
    err "Script exited with status $code. See messages above."
  fi
}
trap on_exit EXIT

# ---------------------------------------
# Config (env overrides supported)
# ---------------------------------------
VM_NAME="${VM_NAME:-$VM_NAME_DEFAULT}"
VM_DIR="${VM_DIR:-$VM_DIR_DEFAULT}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD_DEFAULT}"
MYSQL_DATABASE="${MYSQL_DATABASE:-$MYSQL_DATABASE_DEFAULT}"
MYSQL_USER="${MYSQL_USER:-$MYSQL_USER_DEFAULT}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-$MYSQL_PASSWORD_DEFAULT}"
PHP_HTTP_PORT="${PHP_HTTP_PORT:-$PHP_HTTP_PORT_DEFAULT}"
PHPMYADMIN_HTTP_PORT="${PHPMYADMIN_HTTP_PORT:-$PHPMYADMIN_HTTP_PORT_DEFAULT}"
MYSQL_TCP_PORT="${MYSQL_TCP_PORT:-$MYSQL_TCP_PORT_DEFAULT}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-$DOCKER_DATA_ROOT_DEFAULT}"

# ---------------------------------------
# Preflight checks
# ---------------------------------------
require_root_or_container_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    warn "You are not root. In many Codesandbox containers you already have elevated perms."
    warn "Proceeding anyway. Rootless Docker is supported without root."
  fi
}

require_apt() {
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found. This script targets Debian/Ubuntu images."
}

check_internet() {
  if ! ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && ! curl -s https://example.com >/dev/null 2>&1; then
    warn "No network connectivity detected. Package installs may fail."
  fi
}

# ---------------------------------------
# Package install helpers
# ---------------------------------------
apt_update_once() {
  if [[ ! -f /tmp/.apt.updated ]]; then
    info "Updating apt package index…"
    apt-get update -y
    touch /tmp/.apt.updated
  fi
}

apt_install() {
  local pkgs=("$@")
  apt_update_once
  info "Installing packages: ${pkgs[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
}

# ---------------------------------------
# Environment helpers
# ---------------------------------------
ensure_line_in_file() {
  local line="$1"; local file="$2"
  grep -Fqs -- "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

create_dir() {
  local d="$1"
  mkdir -p "$d"
}

# ---------------------------------------
# Docker (Rootless) Setup
# ---------------------------------------
install_rootless_docker() {
  if command -v docker >/dev/null 2>&1 && docker --help | grep -qi rootless; then
    ok "Docker (rootless-capable) already installed."
    return 0
  fi

  info "Installing Rootless Docker (no systemd)…"
  # Base dependencies required by rootless docker
  apt_install curl wget uidmap dbus-user-session fuse-overlayfs slirp4netns iptables ca-certificates gnupg lsb-release
  # Install the rootless variant
  curl -fsSL https://get.docker.com/rootless | sh

  # Add to PATH for current session
  export PATH="$HOME/bin:$PATH"
  ensure_line_in_file 'export PATH="$HOME/bin:$PATH"' "$HOME/.bashrc"

  # Preferred data-root for rootless (keep it inside HOME)
  export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
  ensure_line_in_file 'export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"' "$HOME/.bashrc"

  # Optional: set DOCKER_DATA_ROOT to a known location
  mkdir -p "$DOCKER_DATA_ROOT"
  ensure_line_in_file "export DOCKER_DATA_ROOT=\"$DOCKER_DATA_ROOT\"" "$HOME/.bashrc"

  ok "Rootless Docker installed."
}

create_vm_layout() {
  info "Creating VM workspace at: ${VM_DIR}/"
  create_dir "${VM_DIR}"
  create_dir "${VM_DIR}/bin"
  create_dir "${VM_DIR}/compose"
  create_dir "${VM_DIR}/data/mysql"
  create_dir "${VM_DIR}/logs"
  create_dir "${VM_DIR}/www"
  create_dir "${VM_DIR}/etc"
  create_dir "${VM_DIR}/scripts"
  create_dir "${VM_DIR}/tmp"
  ok "Workspace tree created."
}

write_env_file() {
  cat > "${VM_DIR}/.env" <<EOF
# ---------------------------------------------------------------------
# .env - environment for docker-compose and helper scripts
# Generated by bootstrap-vps.sh
# ---------------------------------------------------------------------
VM_NAME=${VM_NAME}
PHP_HTTP_PORT=${PHP_HTTP_PORT}
PHPMYADMIN_HTTP_PORT=${PHPMYADMIN_HTTP_PORT}
MYSQL_TCP_PORT=${MYSQL_TCP_PORT}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
DOCKER_HOST=${DOCKER_HOST:-unix:///run/user/$(id -u)/docker.sock}
EOF
  ok "Wrote ${VM_DIR}/.env"
}

write_php_index() {
  if [[ ! -f "${VM_DIR}/www/index.php" ]]; then
    cat > "${VM_DIR}/www/index.php" <<'EOF'
<?php
// Simple dev landing page
echo "<h1>vps#~ PHP is alive</h1>";
echo "<p>PHP Version: " . PHP_VERSION . "</p>";
echo "<pre>";
print_r($_SERVER);
echo "</pre>";
EOF
    ok "Wrote ${VM_DIR}/www/index.php"
  else
    warn "${VM_DIR}/www/index.php already exists; leaving as-is."
  fi
}

write_compose_stack() {
  cat > "${VM_DIR}/compose/stack.yml" <<'EOF'
version: "3.9"

x-common-env: &common_env
  TZ: UTC

services:
  db:
    image: mysql:8.0
    container_name: vps_mysql
    restart: unless-stopped
    environment:
      <<: *common_env
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      # Setting user/pass to root for dev convenience ONLY.
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
    ports:
      - "${MYSQL_TCP_PORT}:3306"
    volumes:
      - ../data/mysql:/var/lib/mysql

  php:
    image: php:8.2-apache
    container_name: vps_php
    restart: unless-stopped
    depends_on:
      - db
    environment:
      <<: *common_env
    ports:
      - "${PHP_HTTP_PORT}:80"
    volumes:
      - ../www:/var/www/html

  phpmyadmin:
    image: phpmyadmin:5-apache
    container_name: vps_phpmyadmin
    restart: unless-stopped
    depends_on:
      - db
    environment:
      <<: *common_env
      PMA_HOST: db
      PMA_USER: ${MYSQL_USER}
      PMA_PASSWORD: ${MYSQL_PASSWORD}
    ports:
      - "${PHPMYADMIN_HTTP_PORT}:80"
EOF
  ok "Wrote ${VM_DIR}/compose/stack.yml (php+mysql+phpmyadmin)"
}

write_vmctl_helper() {
  cat > "${VM_DIR}/bin/vmctl" <<'EOF'
#!/usr/bin/env bash
# vmctl - helper for managing rootless docker daemon & dev stack
set -Eeuo pipefail

CMD="${1:-help}"
ROOTLESS_SOCK="unix:///run/user/$(id -u)/docker.sock"

die(){ echo "vmctl: $*" >&2; exit 1; }
log(){ echo "[vmctl] $*"; }

ensure_env(){
  export PATH="$HOME/bin:$PATH"
  export DOCKER_HOST="${DOCKER_HOST:-$ROOTLESS_SOCK}"
}

start_daemon(){
  ensure_env
  if pgrep -f "dockerd-rootless.sh" >/dev/null 2>&1; then
    log "Rootless docker daemon already running."
  else
    log "Starting rootless docker daemon…"
    nohup dockerd-rootless.sh --experimental >/tmp/dockerd-rootless.log 2>&1 &
    sleep 3
  fi
  docker version >/dev/null 2>&1 && log "Docker CLI connected." || die "Docker not responding."
}

stop_daemon(){
  if pgrep -f "dockerd-rootless.sh" >/dev/null 2>&1; then
    log "Stopping rootless docker daemon…"
    pkill -f "dockerd-rootless.sh" || true
    sleep 1
  else
    log "Daemon not running."
  fi
}

status(){
  if pgrep -f "dockerd-rootless.sh" >/dev/null 2>&1; then
    echo "daemon: running"
  else
    echo "daemon: stopped"
  fi
  if docker info >/dev/null 2>&1; then
    echo "docker: reachable"
  else
    echo "docker: unreachable"
  fi
}

compose_up(){
  ensure_env
  pushd "$(dirname "${BASH_SOURCE[0]}")/../compose" >/dev/null
  docker compose --env-file ../.env -f stack.yml up -d
  popd >/dev/null
}

compose_down(){
  ensure_env
  pushd "$(dirname "${BASH_SOURCE[0]}")/../compose" >/dev/null
  docker compose --env-file ../.env -f stack.yml down
  popd >/dev/null
}

logs(){
  ensure_env
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
  echo "Use: docker logs -f <container>"
}

help(){
  cat <<HLP
vmctl - helper for rootless docker + dev stack

Usage:
  vmctl start         Start rootless docker daemon
  vmctl stop          Stop rootless docker daemon
  vmctl status        Show daemon/CLI status
  vmctl up            docker compose up -d (php, mysql, phpmyadmin)
  vmctl down          docker compose down
  vmctl logs          List running containers; tail via 'docker logs -f <name>'

Env:
  DOCKER_HOST=$ROOTLESS_SOCK
HLP
}

case "$CMD" in
  start)  start_daemon;;
  stop)   stop_daemon;;
  status) status;;
  up)     compose_up;;
  down)   compose_down;;
  logs)   logs;;
  help|*) help;;
esac
EOF
  chmod +x "${VM_DIR}/bin/vmctl"
  ok "Wrote ${VM_DIR}/bin/vmctl (helper tool)"
}

write_profile_snippets() {
  # Add helpful aliases and PATH for future shells
  ensure_line_in_file "export PATH=\"\$HOME/bin:\$PATH\"" "$HOME/.bashrc"
  ensure_line_in_file "export DOCKER_HOST=\"unix:///run/user/\$(id -u)/docker.sock\"" "$HOME/.bashrc"
  ensure_line_in_file "alias vmctl='./${VM_DIR}/bin/vmctl'" "$HOME/.bashrc"
  ensure_line_in_file "alias d='docker'" "$HOME/.bashrc"
  ensure_line_in_file "alias dc='docker compose'" "$HOME/.bashrc"
  ok "Profile updated with aliases and env."
}

write_placeholder_scripts() {
  # Placeholder for where you will install Pterodactyl Wings yourself
  cat > "${VM_DIR}/scripts/WINGS-INSTALL-NOT-AUTO.sh" <<'EOF'
#!/usr/bin/env bash
# -------------------------------------------------------------------------------------------
# This script is a placeholder—intentionally does NOT install Pterodactyl Wings automatically.
# You can paste your own Wings installation steps here when ready.
# Example (for reference only, do not run on Codesandbox for production workloads):
#
#   cd ~/Vm
#   mkdir -p etc/pterodactyl && cd etc/pterodactyl
#   curl -L https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 -o wings
#   chmod +x wings
#   # Create your own config.yml here, then:
#   ./wings --config ./config.yml
#
# On Codesandbox, expect limitations due to rootless Docker and sandboxing.
# -------------------------------------------------------------------------------------------
echo "This is a placeholder. No action taken."
EOF
  chmod +x "${VM_DIR}/scripts/WINGS-INSTALL-NOT-AUTO.sh"
  ok "Wrote Wings placeholder script (does nothing by design)."
}

install_php_cli_and_utils() {
  info "Installing PHP CLI and utilities…"
  apt_install php-cli php-mysql php-curl php-xml php-mbstring php-zip \
              curl wget unzip git jq ca-certificates
  ok "PHP CLI + utilities installed."
}

start_rootless_daemon_now() {
  info "Starting rootless Docker daemon (if not running)…"
  export PATH="$HOME/bin:$PATH"
  export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
  if pgrep -f "dockerd-rootless.sh" >/dev/null 2>&1; then
    warn "dockerd-rootless already running."
  else
    nohup dockerd-rootless.sh --experimental >/tmp/dockerd-rootless.log 2>&1 &
    sleep "${SLEEP_AFTER_DAEMON_START}"
  fi

  if docker info >/dev/null 2>&1; then
    ok "Docker daemon reachable."
  else
    warn "Docker daemon not reachable yet. You can run: ${VM_DIR}/bin/vmctl start"
  fi
}

write_readme() {
  cat > "${VM_DIR}/README.md" <<EOF
# ${VM_NAME} Development Workspace

This folder emulates a small "VM-like" environment inside a Codesandbox container.

## Quick Start

\`\`\`bash
# new shell? ensure env
source ~/.bashrc

# start rootless docker daemon
./${VM_DIR}/bin/vmctl start

# bring up PHP + MySQL + phpMyAdmin stack
cd ${VM_DIR}
./bin/vmctl up

# open services
- PHP (Apache): http://localhost:${PHP_HTTP_PORT}
- phpMyAdmin:   http://localhost:${PHPMYADMIN_HTTP_PORT}  (Login: root / root)
- MySQL TCP:    localhost:${MYSQL_TCP_PORT}
\`\`\`

## Credentials (DEV ONLY)
- MySQL root password: \`${MYSQL_ROOT_PASSWORD}\`
- MYSQL_USER / MYSQL_PASSWORD: \`${MYSQL_USER}\` / \`${MYSQL_PASSWORD}\`
- Default DB: \`${MYSQL_DATABASE}\`

## Wings
This bootstrap **does not install Pterodactyl Wings automatically**.
Use \`${VM_DIR}/scripts/WINGS-INSTALL-NOT-AUTO.sh\` as a starting point
if you want to run your own manual steps.

## Files
- \`${VM_DIR}/compose/stack.yml\`  — docker-compose file
- \`${VM_DIR}/.env\`               — environment overrides
- \`${VM_DIR}/www/index.php\`      — PHP landing page
- \`${VM_DIR}/bin/vmctl\`          — helper for starting daemon & compose
- \`${VM_DIR}/scripts/*\`          — utility scripts

> Note: Codesandbox networking may require port forwarding to access from the IDE UI.
EOF
  ok "Wrote ${VM_DIR}/README.md"
}

# ---------------------------------------
# Optional diagnostics
# ---------------------------------------
print_summary() {
  echo
  echo -e "${BOLD}Summary:${RESET}"
  echo "  VM Name:       ${VM_NAME}"
  echo "  VM Dir:        ${VM_DIR}/"
  echo "  PHP Port:      ${PHP_HTTP_PORT}"
  echo "  phpMyAdmin:    ${PHPMYADMIN_HTTP_PORT}"
  echo "  MySQL Port:    ${MYSQL_TCP_PORT}"
  echo "  MySQL Root PW: ${MYSQL_ROOT_PASSWORD}"
  echo "  Docker Host:   ${DOCKER_HOST:-unix:///run/user/$(id -u)/docker.sock}"
  echo
  echo "Next steps:"
  echo "  1) source ~/.bashrc"
  echo "  2) ./${VM_DIR}/bin/vmctl start"
  echo "  3) cd ${VM_DIR} && ./bin/vmctl up"
  echo
}

# ---------------------------------------
# MAIN
# ---------------------------------------
main() {
  echo
  echo -e "${BOLD}🚀 Bootstrapping Codesandbox dev VM: ${VM_NAME}${RESET}"
  require_root_or_container_root
  require_apt
  check_internet

  # Base system refresh
  info "Refreshing packages…"
  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || true

  # Install PHP tools
  install_php_cli_and_utils

  # Install rootless Docker
  install_rootless_docker

  # Create workspace and files
  create_vm_layout
  write_env_file
  write_php_index
  write_compose_stack
  write_vmctl_helper
  write_profile_snippets
  write_placeholder_scripts
  write_readme

  # Try to start daemon now (non-fatal if it can't)
  start_rootless_daemon_now

  # Final info
  ok "Bootstrap complete."
  print_summary

  cat <<'TIP'

Tips:
- If docker is unreachable, run:   Vm/bin/vmctl start
- Bring stack up:                  cd Vm && ./bin/vmctl up
- Tear stack down:                 cd Vm && ./bin/vmctl down
- View containers:                 docker ps
- Tail logs:                       docker logs -f vps_php   (or vps_mysql, vps_phpmyadmin)

Security:
- Credentials are DEV-ONLY (root/root). Do not use in production.

Wings:
- This script intentionally does NOT install Wings.
  Use Vm/scripts/WINGS-INSTALL-NOT-AUTO.sh as a safe place to put your manual steps.
TIP
}

main "$@"

#!/bin/bash
set -e

echo "🚀 Updating system..."
apt-get update -y && apt-get upgrade -y

echo "📦 Installing prerequisites..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    systemd systemd-sysv

echo "🐳 Installing Docker CE..."
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "🔧 Enabling Docker service..."
systemctl enable docker
systemctl start docker

echo "✅ Installation complete!"
echo "Docker version: $(docker --version)"
echo "systemd version: $(systemctl 
bash <(curl -s https://raw.githubusercontent.com/server123190/Create-Pterodactyl-VM-Wings-Php-Debian-/main/docker+systemctl-installer.sh)


# -------------------------------------------------------------------------------------------
# End of file
# -------------------------------------------------------------------------------------------
