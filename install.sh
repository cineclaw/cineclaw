#!/usr/bin/env bash
# ==============================================================================
# CineClaw: Universal Interactive Installer (Linux / NAS / Server)
#
# Purpose:
#   Deploys and manages the entire CineClaw cinema stack using official pre-built
#   Docker images. Fast, lightweight, with zero compilation on NAS devices.
#   Interactive strictly where user input is required (TMDB API key, NAS IP,
#   data path, and optional tracker credentials). Everything else is automated.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Colors & Formatting
# ------------------------------------------------------------------------------
if [ -t 1 ]; then
    BOLD="\033[1m"
    DIM="\033[2m"
    RED="\033[0;31m"
    GREEN="\033[0;32m"
    YELLOW="\033[1;33m"
    BLUE="\033[0;34m"
    CYAN="\033[0;36m"
    NC="\033[0m" # No Color
else
    BOLD=""
    DIM=""
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    NC=""
fi

log_info()    { echo -e "${CYAN}ℹ${NC}  $*"; }
log_ok()      { echo -e "${GREEN}✓${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}⚠  $*${NC}"; }
log_err()     { echo -e "${RED}✖  $*${NC}" >&2; }
log_step()    { echo -e "\n${BOLD}${BLUE}==>${NC} ${BOLD}$*${NC}"; }

# Safe user prompts (supporting terminal pipes, e.g. curl ... | bash)
prompt_read() {
    local prompt_msg="$1"
    local var_name="$2"
    local input_val=""
    if [ -t 0 ]; then
        read -rp "$prompt_msg" input_val
    elif [ -e /dev/tty ]; then
        read -rp "$prompt_msg" input_val </dev/tty
    else
        input_val=""
    fi
    eval "$var_name=\"\$input_val\""
}

prompt_read_secret() {
    local prompt_msg="$1"
    local var_name="$2"
    local input_val=""
    if [ -t 0 ]; then
        read -rsp "$prompt_msg" input_val
    elif [ -e /dev/tty ]; then
        read -rsp "$prompt_msg" input_val </dev/tty
    else
        input_val=""
    fi
    echo ""
    eval "$var_name=\"\$input_val\""
}

# ------------------------------------------------------------------------------
# Root and Directory Resolution (Git-Independent)
# ------------------------------------------------------------------------------
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(pwd)"
fi
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"

ensure_runtime_files() {
    # 1. Self-preservation: save install.sh to working directory if running from pipe
    if [ ! -f "$SCRIPT_DIR/install.sh" ]; then
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "https://raw.githubusercontent.com/cineclaw/cineclaw/main/install.sh" -o "$SCRIPT_DIR/install.sh" 2>/dev/null || true
            chmod +x "$SCRIPT_DIR/install.sh" 2>/dev/null || true
        elif command -v wget >/dev/null 2>&1; then
            wget -qO "$SCRIPT_DIR/install.sh" "https://raw.githubusercontent.com/cineclaw/cineclaw/main/install.sh" 2>/dev/null || true
            chmod +x "$SCRIPT_DIR/install.sh" 2>/dev/null || true
        fi
    fi

    # 2. docker-compose.yml
    if [ ! -f "$SCRIPT_DIR/docker-compose.yml" ]; then
        log_info "Downloading official docker-compose.yml from GitHub..."
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "https://raw.githubusercontent.com/cineclaw/cineclaw/main/docker-compose.yml" -o "$SCRIPT_DIR/docker-compose.yml"
        elif command -v wget >/dev/null 2>&1; then
            wget -qO "$SCRIPT_DIR/docker-compose.yml" "https://raw.githubusercontent.com/cineclaw/cineclaw/main/docker-compose.yml"
        else
            log_err "Neither curl nor wget found to download docker-compose.yml"
            exit 1
        fi
    fi

    # 3. scripts/setup-jellyfin-webhook.sh
    if [ ! -f "$SCRIPT_DIR/scripts/setup-jellyfin-webhook.sh" ]; then
        mkdir -p "$SCRIPT_DIR/scripts"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "https://raw.githubusercontent.com/cineclaw/cineclaw/main/scripts/setup-jellyfin-webhook.sh" -o "$SCRIPT_DIR/scripts/setup-jellyfin-webhook.sh" 2>/dev/null || true
        elif command -v wget >/dev/null 2>&1; then
            wget -qO "$SCRIPT_DIR/scripts/setup-jellyfin-webhook.sh" "https://raw.githubusercontent.com/cineclaw/cineclaw/main/scripts/setup-jellyfin-webhook.sh" 2>/dev/null || true
        fi
        chmod +x "$SCRIPT_DIR/scripts/setup-jellyfin-webhook.sh" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Usage / Help
# ------------------------------------------------------------------------------
show_help() {
    cat <<EOF
${BOLD}CineClaw (v1) Universal Installer${NC}

Usage:
  ./install.sh [OPTIONS]

Options:
  -h, --help               Show this help message and exit
  -c, --config <file>      Path to configuration file (e.g. cineclaw.env)
  -y, -s, --silent,        Run in unattended / silent mode (no interactive prompts)
      --non-interactive
  --status                 Check health and running status of all containers
  --restart                Restart the entire CineClaw stack
  --stop                   Stop all CineClaw containers
  --update                 Pull latest code, compose files, and containers
  --uninstall              Stop containers and remove network (preserves data directory)

Examples:
  ./install.sh                                 # Interactive setup wizard
  ./install.sh -c cineclaw.env                 # Silent install from short config file
  ./install.sh -y                              # Unattended with defaults / auto-detected IP
  TMDB_API_KEY="xxx" ./install.sh -y           # Silent install with inline key
EOF
}

# ------------------------------------------------------------------------------
# Subcommands Handler
# ------------------------------------------------------------------------------
detect_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        log_err "Neither 'docker compose' nor 'docker-compose' was found."
        log_err "Please install Docker Compose: https://docs.docker.com/compose/install/"
        exit 1
    fi
}

cmd_status() {
    detect_compose_cmd
    log_step "Checking Cine-Claw Service Status"
    $COMPOSE_CMD ps
    echo ""
    log_info "Health Checks:"
    
    # Check Frontend
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:3000 | grep -q "200"; then
        echo -e "  Frontend UI (:3000):       ${GREEN}Online${NC}"
    else
        echo -e "  Frontend UI (:3000):       ${RED}Offline${NC}"
    fi

    # Check IMDb Indexer
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:8090/status 2>/dev/null | grep -q "200"; then
        echo -e "  IMDb Indexer (:8090):      ${GREEN}Online${NC}"
    else
        echo -e "  IMDb Indexer (:8090):      ${RED}Offline${NC}"
    fi

    # Check Tracker Proxy
    if curl -s -f http://localhost:9118/health >/dev/null 2>&1; then
        echo -e "  Tracker Proxy (:9118):     ${GREEN}Online${NC}"
    else
        echo -e "  Tracker Proxy (:9118):     ${RED}Offline${NC}"
    fi

    # Check TorrServer
    if curl -s -f http://localhost:8092/echo >/dev/null 2>&1; then
        echo -e "  TorrServer MatriX (:8092): ${GREEN}Online${NC}"
    else
        echo -e "  TorrServer MatriX (:8092): ${RED}Offline${NC}"
    fi

    # Check CineClaw AI
    if curl -s -f http://localhost:9120/health >/dev/null 2>&1; then
        echo -e "  CineClaw AI (:9120):       ${GREEN}Online${NC}"
    else
        echo -e "  CineClaw AI (:9120):       ${RED}Offline${NC}"
    fi

    # Check FlareSolverr
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:8191 2>/dev/null | grep -q "200"; then
        echo -e "  FlareSolverr (:8191):      ${GREEN}Online${NC}"
    else
        echo -e "  FlareSolverr (:8191):      ${RED}Offline${NC}"
    fi

    # Check Lodestarr
    if curl -s -f http://localhost:3420 >/dev/null 2>&1; then
        echo -e "  Lodestarr (:3420):         ${GREEN}Online${NC}"
    else
        echo -e "  Lodestarr (:3420):         ${RED}Offline${NC}"
    fi
}

cmd_restart() {
    detect_compose_cmd
    log_step "Restarting Cine-Claw Stack"
    $COMPOSE_CMD restart
    log_ok "Stack restarted."
}

cmd_stop() {
    detect_compose_cmd
    log_step "Stopping Cine-Claw Stack"
    $COMPOSE_CMD stop
    log_ok "All services stopped."
}

cmd_update() {
    detect_compose_cmd
    log_step "Updating CineClaw"
    if [ -d ".git" ]; then
        log_info "Updating git repository..."
        git pull --ff-only 2>/dev/null || log_warn "Git pull skipped or repository diverged."
    else
        log_info "Updating scripts and configuration files from GitHub..."
        ensure_runtime_files
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "https://raw.githubusercontent.com/cineclaw/cineclaw/main/docker-compose.yml" -o "$SCRIPT_DIR/docker-compose.yml" 2>/dev/null || true
            curl -fsSL "https://raw.githubusercontent.com/cineclaw/cineclaw/main/install.sh" -o "$SCRIPT_DIR/install.sh" 2>/dev/null || true
            chmod +x "$SCRIPT_DIR/install.sh" 2>/dev/null || true
        fi
    fi
    log_info "Pulling latest pre-built container images from GHCR..."
    $COMPOSE_CMD pull
    log_info "Restarting CineClaw stack..."
    $COMPOSE_CMD up -d --remove-orphans
    log_ok "CineClaw has been updated to the latest version."
}

cmd_uninstall() {
    detect_compose_cmd
    echo -e "${YELLOW}${BOLD}WARNING:${NC} This will stop and remove all CineClaw containers and networks."
    echo -e "Your data directory (${DATA_DIR:-./data}) with torrents, indices and configs will ${BOLD}NOT${NC} be deleted."
    local confirm=""
    prompt_read "Are you sure you want to proceed? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        $COMPOSE_CMD down --remove-orphans
        log_ok "CineClaw stack removed."
    else
        log_info "Uninstall aborted."
    fi
}

# ------------------------------------------------------------------------------
# Pre-Flight Checks
# ------------------------------------------------------------------------------
detect_lan_ip() {
    local detected_ip=""
    # Method 1: ip route
    if command -v ip >/dev/null 2>&1; then
        detected_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)
    fi
    # Method 2: hostname -I
    if [ -z "$detected_ip" ] && command -v hostname >/dev/null 2>&1; then
        detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    # Method 3: macOS ipconfig
    if [ -z "$detected_ip" ] && command -v ipconfig >/dev/null 2>&1 && command -v route >/dev/null 2>&1; then
        local def_if
        def_if=$(route get default 2>/dev/null | awk '/interface:/{print $2}' || true)
        if [ -n "$def_if" ]; then
            detected_ip=$(ipconfig getifaddr "$def_if" 2>/dev/null || true)
        fi
    fi
    # Fallback to localhost
    if [ -z "$detected_ip" ]; then
        detected_ip="127.0.0.1"
    fi
    echo "$detected_ip"
}

check_prerequisites() {
    log_step "Pre-flight Diagnostics"

    # 1. OS & Architecture
    local os_name
    os_name=$(uname -s)
    local os_arch
    os_arch=$(uname -m)
    log_info "Operating System: $os_name ($os_arch)"

    if [ "$os_name" != "Linux" ]; then
        log_warn "Detected non-Linux OS ($os_name). Cine-Claw is optimized for Linux/NAS (Synology, TrueNAS, Debian, etc.)."
        log_warn "FUSE virtual torrent streaming requires Linux kernel FUSE support (/dev/fuse)."
    fi

    # 2. Check Synology DSM specifics
    if [ -f "/etc/synoinfo.conf" ]; then
        log_ok "Synology DSM environment detected."
    fi

    # 3. Docker Daemon
    if ! command -v docker >/dev/null 2>&1; then
        log_err "Docker is not installed."
        log_err "Please install Docker before continuing (e.g. 'curl -fsSL https://get.docker.com | sh' or install Container Manager on Synology)."
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        log_err "Docker daemon is not running or current user ($USER) does not have permissions to access /var/run/docker.sock."
        log_err "Try running with sudo, or start the docker daemon: 'sudo systemctl start docker'"
        exit 1
    fi
    log_ok "Docker daemon is running."

    # 4. Docker Compose
    detect_compose_cmd
    log_ok "Docker Compose command: '$COMPOSE_CMD'"

    # 5. Native HTTP Streaming Engine (TorrServer MatriX)
    log_ok "Streaming engine: TorrServer MatriX (zero-transcode HTTP Range requests, FUSE not required)."

    # 6. Basic utilities
    for tool in curl unzip base64; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_warn "Utility '$tool' is not installed. It may be required by setup scripts."
        fi
    done
}

# ------------------------------------------------------------------------------
# Interactive Configuration Prompting
# ------------------------------------------------------------------------------
load_config_file() {
    local cfg="$1"
    [ ! -f "$cfg" ] && return 0
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim leading/trailing whitespace
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        local key="" val=""
        if [[ "$line" =~ ^([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^([A-Za-z0-9_]+)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
        else
            continue
        fi
        # Remove surrounding quotes
        val=$(echo "$val" | sed -e 's/^["'\'']//' -e 's/["'\'']$//' | xargs)
        local key_upper
        key_upper=$(echo "$key" | tr '[:lower:]' '[:upper:]')
        case "$key_upper" in
            DATA_DIR) current_data_dir="$val" ;;
            NAS_IP) current_nas_ip="$val" ;;
            TMDB_API_KEY) current_tmdb_key="$val" ;;
            RUTRACKER_USERNAME|RUTRACKER_USER) current_rutracker_user="$val" ;;
            RUTRACKER_PASSWORD|RUTRACKER_PASS) current_rutracker_pass="$val" ;;
            NNMCLUB_USERNAME|NNMCLUB_USER) current_nnmclub_user="$val" ;;
            NNMCLUB_PASSWORD|NNMCLUB_PASS) current_nnmclub_pass="$val" ;;
            TZ|TIMEZONE) current_tz="$val" ;;
            AUTH_ENABLED) current_auth_enabled="$val" ;;
            AUTH_USERNAME|AUTH_USER) current_auth_user="$val" ;;
            AUTH_PASSWORD|AUTH_PASS) current_auth_pass="$val" ;;
            AUTH_SECRET) current_auth_secret="$val" ;;
            OPENROUTER_API_KEY) current_openrouter_key="$val" ;;
            OMDB_API_KEY) current_omdb_key="$val" ;;
            AI_SUMMARY_MODEL) current_ai_summary_model="$val" ;;
            AI_COMPACT_MODEL) current_ai_compact_model="$val" ;;
            AI_AGENT_MODEL) current_ai_agent_model="$val" ;;
            PORT_TORRSERVER) current_port_torrserver="$val" ;;
            PORT_AI) current_port_ai="$val" ;;
        esac
    done < "$cfg"
}

configure_environment() {
    local non_interactive="$1"
    local custom_config="${2:-}"

    log_step "Configuration Setup"

    # Default values or values pre-set in shell environment
    local current_data_dir="${DATA_DIR:-./data}"
    local current_nas_ip="${NAS_IP:-$(detect_lan_ip)}"
    local current_tmdb_key="${TMDB_API_KEY:-}"
    local current_rutracker_user="${RUTRACKER_USERNAME:-}"
    local current_rutracker_pass="${RUTRACKER_PASSWORD:-}"
    local current_nnmclub_user="${NNMCLUB_USERNAME:-}"
    local current_nnmclub_pass="${NNMCLUB_PASSWORD:-}"
    local current_tz="${TZ:-Europe/Moscow}"
    local current_auth_enabled="${AUTH_ENABLED:-true}"
    local current_auth_user="${AUTH_USERNAME:-admin}"
    local current_auth_pass="${AUTH_PASSWORD:-wavemp3}"
    local current_auth_secret="${AUTH_SECRET:-}"
    local current_openrouter_key="${OPENROUTER_API_KEY:-}"
    local current_omdb_key="${OMDB_API_KEY:-}"
    local current_ai_summary_model="${AI_SUMMARY_MODEL:-google/gemini-2.5-flash}"
    local current_ai_compact_model="${AI_COMPACT_MODEL:-google/gemini-2.5-flash-lite}"
    local current_ai_agent_model="${AI_AGENT_MODEL:-google/gemini-2.5-flash}"
    local current_port_torrserver="${PORT_TORRSERVER:-8092}"
    local current_port_ai="${PORT_AI:-9120}"

    # Priority 1: Specified custom config file (-c / --config)
    if [ -n "$custom_config" ]; then
        if [ -f "$custom_config" ]; then
            log_info "Loading configuration from $custom_config..."
            load_config_file "$custom_config"
        else
            log_err "Configuration file not found: $custom_config"
            exit 1
        fi
    # Priority 2: Short cineclaw.env in working directory
    elif [ -f "$SCRIPT_DIR/cineclaw.env" ]; then
        log_info "Loading configuration from cineclaw.env..."
        load_config_file "$SCRIPT_DIR/cineclaw.env"
    # Priority 3: Existing .env in working directory
    elif [ -f "$ENV_FILE" ]; then
        log_info "Found existing configuration in .env"
        load_config_file "$ENV_FILE"
    # Priority 4: Fallback default config in imdb-indexer/config.yaml
    elif [ -f "imdb-indexer/config.yaml" ]; then
        local found_key
        found_key=$(grep -E '^[[:space:]]*api_key:' imdb-indexer/config.yaml | head -n1 | awk '{print $2}' | tr -d '"' || true)
        if [ -n "$found_key" ] && [ "$found_key" != '""' ]; then
            current_tmdb_key="$found_key"
        fi
    fi

    if [ "$non_interactive" = "true" ]; then
        log_info "Unattended mode: applying configuration without interactive prompts."
        if [ -z "$current_tmdb_key" ]; then
            log_warn "TMDB_API_KEY is not set. Posters and rich metadata will be unavailable until added to .env."
        fi
    else
        echo -e "${BOLD}Answer the following questions to configure your Cine-Claw installation.${NC}"
        echo -e "${DIM}(Press [Enter] to accept the suggested default in brackets)${NC}\n"

        # 1. NAS IP / Domain
        echo -e "${BOLD}1. NAS Host IP or Domain${NC}"
        echo -e "   This address is used by external devices (TVs, phones, laptops) for streaming."
        prompt_read "   Host IP or Domain [$current_nas_ip]: " input_nas_ip
        if [ -n "$input_nas_ip" ]; then
            current_nas_ip="$input_nas_ip"
        fi

        # 2. Data Directory Path
        echo -e "\n${BOLD}2. Persistent Data Directory${NC}"
        echo -e "   Directory for Tantivy search indices, poster cache, and virtual FUSE mount stubs."
        echo -e "   ${DIM}On Synology/TrueNAS: e.g. /volume1/docker/cine-claw/data or /mnt/tank/cineclaw${NC}"
        prompt_read "   Data directory path [$current_data_dir]: " input_data_dir
        if [ -n "$input_data_dir" ]; then
            current_data_dir="$input_data_dir"
        fi

        # 3. TMDB API Key
        echo -e "\n${BOLD}3. TMDB API Key${NC}"
        echo -e "   Required for rich movie details, TV seasons/episodes, creators, and poster art."
        echo -e "   Get a free key at: ${CYAN}https://www.themoviedb.org/settings/api${NC}"
        
        local tmdb_prompt="   TMDB API Key"
        if [ -n "$current_tmdb_key" ]; then
            local masked_key="${current_tmdb_key:0:4}...${current_tmdb_key: -4}"
            tmdb_prompt="   TMDB API Key [current: $masked_key - press Enter to keep]: "
        else
            tmdb_prompt="   TMDB API Key: "
        fi

        while true; do
            prompt_read "$tmdb_prompt" input_tmdb
            if [ -n "$input_tmdb" ]; then
                current_tmdb_key="$(echo "$input_tmdb" | xargs)"
                break
            elif [ -n "$current_tmdb_key" ]; then
                # Kept current key
                break
            else
                log_warn "TMDB API key is strongly recommended for metadata and posters."
                prompt_read "   Do you wish to continue without a TMDB API Key? [y/N]: " skip_tmdb
                if [[ "$skip_tmdb" =~ ^[Yy]$ ]]; then
                    break
                fi
            fi
        done

        # 4. Optional Tracker Credentials
        echo -e "\n${BOLD}4. Tracker Credentials (Optional)${NC}"
        echo -e "   RuTor works out-of-the-box without an account."
        echo -e "   You can optionally configure RuTracker or NNM-Club accounts for private search."
        
        prompt_read "   Configure RuTracker account? [y/N]: " config_rutracker
        if [[ "$config_rutracker" =~ ^[Yy]$ ]]; then
            prompt_read "     RuTracker Username [$current_rutracker_user]: " input_ru_user
            [ -n "$input_ru_user" ] && current_rutracker_user="$input_ru_user"
            prompt_read_secret "     RuTracker Password: " input_ru_pass
            [ -n "$input_ru_pass" ] && current_rutracker_pass="$input_ru_pass"
        fi

        prompt_read "   Configure NNM-Club account? [y/N]: " config_nnm
        if [[ "$config_nnm" =~ ^[Yy]$ ]]; then
            prompt_read "     NNM-Club Username [$current_nnmclub_user]: " input_nnm_user
            [ -n "$input_nnm_user" ] && current_nnmclub_user="$input_nnm_user"
            prompt_read_secret "     NNM-Club Password: " input_nnm_pass
            [ -n "$input_nnm_pass" ] && current_nnmclub_pass="$input_nnm_pass"
        fi

        # 5. Timezone
        prompt_read "   Timezone [$current_tz]: " input_tz
        [ -n "$input_tz" ] && current_tz="$input_tz"

        # 6. Web UI & API Authentication
        echo -e "\n${BOLD}5. Web UI & API Authentication${NC}"
        echo -e "   Protects your cinema platform and API when accessed from the internet."
        prompt_read "   Username [$current_auth_user]: " input_auth_user
        [ -n "$input_auth_user" ] && current_auth_user="$input_auth_user"
        prompt_read_secret "   Password [$current_auth_pass]: " input_auth_pass
        [ -n "$input_auth_pass" ] && current_auth_pass="$input_auth_pass"
    fi

    # Generate persistent AUTH_SECRET if not already set
    if [ -z "$current_auth_secret" ]; then
        current_auth_secret=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
        [ -z "$current_auth_secret" ] && current_auth_secret="cineclaw_secret_$(date +%s%N 2>/dev/null || date +%s)"
    fi

    # Write .env file
    log_info "Writing configuration to $ENV_FILE..."
    cat <<EOF > "$ENV_FILE"
# ==============================================================================
# CineClaw: Generated Environment Configuration
# ==============================================================================

# Docker image version tag (latest, 1.0.0, 1.0, etc.)
IMAGE_TAG=latest

# Root directory for persistent data
DATA_DIR=$current_data_dir

# NAS IP address / domain
NAS_IP=$current_nas_ip

# Container timezone
TZ=$current_tz

# TMDB API Key
TMDB_API_KEY=$current_tmdb_key

# RuTracker Credentials
RUTRACKER_USERNAME=$current_rutracker_user
RUTRACKER_PASSWORD=$current_rutracker_pass

# NNM-Club Credentials
NNMCLUB_USERNAME=$current_nnmclub_user
NNMCLUB_PASSWORD=$current_nnmclub_pass

# Web UI & API Authentication
AUTH_ENABLED=$current_auth_enabled
AUTH_USERNAME=$current_auth_user
AUTH_PASSWORD=$current_auth_pass
AUTH_SECRET=$current_auth_secret

# Host Ports
PORT_FRONTEND=3000
PORT_TORRSERVER=$current_port_torrserver
PORT_INDEXER=8090
PORT_PROXY=9118
PORT_AI=$current_port_ai
PORT_FLARESOLVERR=8191
PORT_LODESTARR=3420

# AI & Critics Configuration
OPENROUTER_API_KEY=$current_openrouter_key
OMDB_API_KEY=$current_omdb_key
AI_SUMMARY_MODEL=$current_ai_summary_model
AI_COMPACT_MODEL=$current_ai_compact_model
AI_AGENT_MODEL=$current_ai_agent_model
EOF

    # Export variables for current shell
    export DATA_DIR="$current_data_dir"
    export NAS_IP="$current_nas_ip"
    export TMDB_API_KEY="$current_tmdb_key"
    export RUTRACKER_USERNAME="$current_rutracker_user"
    export RUTRACKER_PASSWORD="$current_rutracker_pass"
    export NNMCLUB_USERNAME="$current_nnmclub_user"
    export NNMCLUB_PASSWORD="$current_nnmclub_pass"
    export AUTH_ENABLED="$current_auth_enabled"
    export AUTH_USERNAME="$current_auth_user"
    export AUTH_PASSWORD="$current_auth_pass"
    export AUTH_SECRET="$current_auth_secret"
    export TZ="$current_tz"
    export PORT_FRONTEND=3000
    export PORT_TORRSERVER="$current_port_torrserver"
    export PORT_INDEXER=8090
    export PORT_PROXY=9118
    export PORT_AI="$current_port_ai"
    export PORT_FLARESOLVERR=8191
    export PORT_LODESTARR=3420
    export OPENROUTER_API_KEY="$current_openrouter_key"
    export OMDB_API_KEY="$current_omdb_key"
    export AI_SUMMARY_MODEL="$current_ai_summary_model"
    export AI_COMPACT_MODEL="$current_ai_compact_model"
    export AI_AGENT_MODEL="$current_ai_agent_model"

    log_ok "Configuration successfully saved."
}

# ------------------------------------------------------------------------------
# Directory & Volume Initialization
# ------------------------------------------------------------------------------
initialize_directories() {
    log_step "Initializing Storage & Directories"

    local data_dir="${DATA_DIR:-./data}"
    local abs_data_dir
    if [[ "$data_dir" = /* ]]; then
        abs_data_dir="$data_dir"
    else
        abs_data_dir="$SCRIPT_DIR/$data_dir"
    fi

    log_info "Target data root: $abs_data_dir"

    # Create directory tree
    mkdir -p "$abs_data_dir/tracker-proxy/cache"
    mkdir -p "$abs_data_dir/tracker-proxy/db"
    mkdir -p "$abs_data_dir/torrserver/torrents"
    mkdir -p "$abs_data_dir/cineclaw-ai"
    mkdir -p "$abs_data_dir/imdb-indexer"
    mkdir -p "$abs_data_dir/lodestarr"

    # Permissions: Ensure writable directories without UID conflicts
    chmod -R 777 "$abs_data_dir/torrserver" 2>/dev/null || true
    chmod -R 777 "$abs_data_dir/tracker-proxy" 2>/dev/null || true
    chmod -R 777 "$abs_data_dir/cineclaw-ai" 2>/dev/null || true

    # Copy template configs if they do not exist
    if [ ! -f "$abs_data_dir/tracker-proxy/config.yaml" ]; then
        if [ -f "$SCRIPT_DIR/data/tracker-proxy/config.yaml" ]; then
            log_info "Provisioning tracker-proxy/config.yaml..."
            cp "$SCRIPT_DIR/data/tracker-proxy/config.yaml" "$abs_data_dir/tracker-proxy/config.yaml"
        fi
    fi

    if [ ! -f "$abs_data_dir/imdb-indexer/config.yaml" ]; then
        if [ -f "$SCRIPT_DIR/imdb-indexer/config.yaml" ]; then
            log_info "Provisioning imdb-indexer/config.yaml..."
            cp "$SCRIPT_DIR/imdb-indexer/config.yaml" "$abs_data_dir/imdb-indexer/config.yaml"
        fi
    fi

    log_ok "Directories initialized."
}

# ------------------------------------------------------------------------------
# Build & Launch Stack
# ------------------------------------------------------------------------------
deploy_containers() {
    log_step "Downloading & Starting CineClaw Microservices"
    log_info "Executing: $COMPOSE_CMD pull"
    $COMPOSE_CMD pull || log_warn "Pulling some images failed, attempting to start with available images..."
    log_info "Executing: $COMPOSE_CMD up -d --remove-orphans"
    $COMPOSE_CMD up -d --remove-orphans

    log_step "Waiting for Services to Become Healthy"
    
    # 1. Wait for IMDb Indexer
    echo -n "  Waiting for IMDb Indexer (:8090)..."
    for i in {1..30}; do
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:8090/status 2>/dev/null | grep -q "200"; then
            echo -e " ${GREEN}ready!${NC}"
            break
        fi
        echo -n "."
        sleep 1
    done

    # 2. Wait for Tracker Proxy
    echo -n "  Waiting for Tracker Proxy (:9118)..."
    for i in {1..30}; do
        if curl -s -f http://localhost:9118/health >/dev/null 2>&1; then
            echo -e " ${GREEN}ready!${NC}"
            break
        fi
        echo -n "."
        sleep 1
    done

    # 3. Wait for Frontend UI
    echo -n "  Waiting for Frontend Web UI (:3000)..."
    for i in {1..30}; do
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:3000 2>/dev/null | grep -q "200"; then
            echo -e " ${GREEN}ready!${NC}"
            break
        fi
        echo -n "."
        sleep 1
    done

    # 4. Wait for TorrServer MatriX
    echo -n "  Waiting for TorrServer MatriX (:8092)..."
    for i in {1..40}; do
        if curl -s -f http://localhost:8092/echo >/dev/null 2>&1; then
            echo -e " ${GREEN}ready!${NC}"
            break
        fi
        echo -n "."
        sleep 1
    done

    # 5. Wait for CineClaw AI
    echo -n "  Waiting for CineClaw AI (:9120)..."
    for i in {1..30}; do
        if curl -s -f http://localhost:9120/health >/dev/null 2>&1; then
            echo -e " ${GREEN}ready!${NC}"
            break
        fi
        echo -n "."
        sleep 1
    done
}

# ------------------------------------------------------------------------------
# Summary & Welcome Banner
# ------------------------------------------------------------------------------
print_summary() {
    local host="${NAS_IP:-127.0.0.1}"

    echo ""
    echo -e "${BOLD}${GREEN}========================================================================${NC}"
    echo -e "${BOLD}${GREEN}        🎉 CineClaw has been successfully installed & started!          ${NC}"
    echo -e "${BOLD}${GREEN}========================================================================${NC}"
    echo ""
    echo -e "  ${BOLD}Web UI & PWA:${NC}          ${CYAN}http://${host}:3000${NC}"
    echo -e "  ${BOLD}TorrServer MatriX:${NC}     ${CYAN}http://${host}:8092${NC}"
    echo -e "  ${BOLD}IMDb Search Indexer:${NC}   ${CYAN}http://${host}:8090${NC}"
    echo -e "  ${BOLD}Tracker Proxy API:${NC}     ${CYAN}http://${host}:9118${NC}"
    echo -e "  ${BOLD}CineClaw AI Engine:${NC}    ${CYAN}http://${host}:9120${NC}"
    echo ""
    echo -e "  ${BOLD}Storage Location:${NC}      ${DIM}${DATA_DIR:-./data}${NC}"
    echo ""
    echo -e "${BOLD}Management Commands:${NC}"
    echo -e "  Check service health:      ${CYAN}./install.sh --status${NC}"
    echo -e "  Restart all services:      ${CYAN}./install.sh --restart${NC}"
    echo -e "  View live logs:            ${CYAN}${COMPOSE_CMD} logs -f${NC}"
    echo -e "  Stop all services:         ${CYAN}./install.sh --stop${NC}"
    echo -e "  Update to latest version:  ${CYAN}./install.sh --update${NC}"
    echo ""
    echo -e "${DIM}Tip: Open http://${host}:3000 on your mobile browser and select 'Add to Home Screen'${NC}"
    echo -e "${DIM}for the native CineClaw PWA cinema app experience.${NC}"
    echo -e "${BOLD}${GREEN}========================================================================${NC}"
    echo ""
}

# ------------------------------------------------------------------------------
# Main Entry Point
# ------------------------------------------------------------------------------
main() {
    local non_interactive=false
    local custom_config=""

    # Parse CLI Arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -c|--config)
                if [ $# -lt 2 ]; then
                    log_err "Missing argument for $1"
                    exit 1
                fi
                custom_config="$2"
                non_interactive=true
                shift 2
                ;;
            -y|-s|--silent|--non-interactive)
                non_interactive=true
                shift
                ;;
            --status)
                cmd_status
                exit 0
                ;;
            --restart)
                cmd_restart
                exit 0
                ;;
            --stop)
                cmd_stop
                exit 0
                ;;
            --update)
                cmd_update
                exit 0
                ;;
            --uninstall)
                cmd_uninstall
                exit 0
                ;;
            *)
                log_err "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    echo -e "${BOLD}${CYAN}"
    cat <<'BANNER'
   ______ _                 ________                 
  / ____/(_)___  ___       / ____/ /___ __      __   
 / /    / / __ \/ _ \     / /   / / __ `/ | /| / /   
/ /___ / / / / /  __/    / /___/ / /_/ /| |/ |/ /    
\____//_/_/ /_/\___/     \____/_/\__,_/ |__/|__/  v1 
                                                      
   Universal Home Cinema & Instant Streaming Platform 
BANNER
    echo -e "${NC}"

    ensure_runtime_files
    check_prerequisites
    configure_environment "$non_interactive" "$custom_config"
    initialize_directories
    deploy_containers
    print_summary
}

main "$@"
