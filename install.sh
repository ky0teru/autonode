#!/usr/bin/env bash
# =============================================================================
#  Remnawave node (remnanode) — production installer for Debian 12/13
#
#  What it does (fully unattended when flags are provided):
#    [1/11] Base packages, time sync, unattended security upgrades
#    [2/11] Kernel/network tuning (BBR+fq, buffers, conntrack), fd limits,
#           journald persistence + caps
#    [3/11] fail2ban SSH protection (systemd journal backend)
#    [4/11] Docker Engine + Compose plugin (official repo), log rotation,
#           live-restore
#    [5/11] UFW firewall: SSH rate-limited, 80/443 + node API port
#    [6/11] SSL certificate: acme.sh TLS-ALPN on 443 or Cloudflare DNS-01
#    [7/11] Decoy web service (camouflage site)
#    [8/11] Nginx camouflage proxy (unix socket + PROXY protocol)
#    [9/11] Remnanode (Xray core)
#    [10/11] Certificate auto-renewal wiring + node log rotation
#    [11/11] Cloudflare WARP SOCKS5 egress proxy
#
#  Usage:  ./install.sh --help
# =============================================================================
set -Eeuo pipefail
umask 022

export DEBIAN_FRONTEND=noninteractive
export DEBIAN_PRIORITY=critical

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly LOG_FILE="/var/log/remnanode-install.log"
readonly NODE_DIR="/opt/remnanode"
readonly NOFILE_LIMIT=1048576

# --- config (filled by arg parsing / env / .env / prompts) -------------------
# NOTE: TCP (VLESS/REALITY) only — no XHTTP/gRPC transport locations.
# "${VAR:=}" keeps an inherited environment value and defaults to empty,
# so DOMAIN=... ./install.sh works alongside flags and the .env file.
: "${DOMAIN:=}" "${EMAIL:=}" "${SECRET_KEY:=}" "${SERVICE_NAME:=}" \
  "${SERVICE_IMAGE:=}" "${SERVICE_PORT:=}" "${NODE_PORT:=}" \
  "${VALIDATION:=}" "${CF_TOKEN:=}" "${WARP_PORT:=}"
ENABLE_TUNE=true ENABLE_FAIL2BAN=true ENABLE_WARP=true ASSUME_YES=false FORCE_OS=false
CERT_SOURCE=""

# --- output helpers ----------------------------------------------------------
# Terminal detection MUST happen before stdout/stderr are redirected into the
# log file below — afterwards isatty() is always false.
INTERACTIVE_TTY=false
if [[ -t 0 && -t 1 ]]; then
    INTERACTIVE_TTY=true
fi

if [[ -t 1 ]]; then
    readonly C_RED='\033[0;31m' C_GREEN='\033[0;32m' C_YELLOW='\033[0;33m' C_BLUE='\033[0;34m' C_OFF='\033[0m'
else
    readonly C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_OFF=''
fi
info()  { echo -e "${C_BLUE}[INF]${C_OFF} $*"; }
ok()    { echo -e "${C_GREEN}[OK ]${C_OFF} $*"; }
warn()  { echo -e "${C_YELLOW}[WRN]${C_OFF} $*"; }
err()   { echo -e "${C_RED}[ERR]${C_OFF} $*"; }
die()   { err "$*"; exit 1; }
step()  { echo ""; echo -e "${C_BLUE}=== $* ===${C_OFF}"; }

trap 'err "Installation failed at line $LINENO (command: ${BASH_COMMAND}). Log: ${LOG_FILE}"' ERR

apt_install() {
    apt-get -y -o DPkg::Lock::Timeout=300 install "$@"
}

# =============================================================================
#  Usage (--help must work without root)
# =============================================================================
usage() {
    cat <<USAGE
Usage: sudo ./install.sh [options]

Required (prompted interactively if omitted and run from a terminal):
  -d, --domain DOMAIN         Node domain (A-record must point to this server)
  -e, --email EMAIL           Email for certificate registration
  -s, --secret-key KEY        SECRET_KEY from the Remnawave panel

Optional:
  -S, --service NAME          Decoy service: filebrowser, memos, pingvin-share,
                              excalidraw, searxng, sharry, audiobookshelf,
                              kavita, kodbox, navidrome, gitea, fluffy-web
                              (default: random)
  -n, --node-port PORT        Remnanode API port (default: 2222)
  -V, --validation METHOD     Certificate method: standalone | cloudflare
                              (default: standalone, TLS-ALPN-01 on port 443)
  -T, --cf-token TOKEN        Cloudflare API token (required for cloudflare)
  -w, --warp-port PORT        WARP SOCKS5 port (default: 40000)

Toggles (production defaults are ON, use --no-* to disable):
  --no-tune                   Skip kernel/network sysctl tuning and fd limits
  --no-fail2ban               Skip fail2ban SSH protection
  --no-warp                   Skip Cloudflare WARP installation

  -y, --yes                   Accept defaults, never prompt
  -f, --force                 Skip the Debian 12/13 version check
  -h, --help                  Show this help

Non-interactive example:
  sudo ./install.sh --domain node.example.com --email me@example.com \\
       --secret-key <SECRET> --service gitea --validation cloudflare \\
       --cf-token <TOKEN> --yes

Environment variables (DOMAIN, EMAIL, SECRET_KEY, ...) and .env saved next to
the script are also honored. Re-running the script is safe (idempotent).
USAGE
}

for _arg in "$@"; do
    [[ "$_arg" == "-h" || "$_arg" == "--help" ]] && { usage; exit 0; }
done
unset _arg

# =============================================================================
#  Root check + env fix (before anything else)
# =============================================================================
if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" "$@"
    fi
    echo "ERROR: must be run as root" >&2
    exit 1
fi
# sudo -E keeps the calling user's HOME; everything below must live in /root
export HOME="$(getent passwd root | cut -d: -f6)"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Remnawave node installer — $(date -u '+%Y-%m-%d %H:%M:%S UTC') — log: ${LOG_FILE}"

# =============================================================================
#  CLI arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--domain)       DOMAIN="${2:?}"; shift 2 ;;
        --domain=*)        DOMAIN="${1#*=}"; shift ;;
        -e|--email)        EMAIL="${2:?}"; shift 2 ;;
        --email=*)         EMAIL="${1#*=}"; shift ;;
        -s|--secret-key)   SECRET_KEY="${2:?}"; shift 2 ;;
        --secret-key=*)    SECRET_KEY="${1#*=}"; shift ;;
        -S|--service)      SERVICE_NAME="${2:?}"; shift 2 ;;
        --service=*)       SERVICE_NAME="${1#*=}"; shift ;;
        -n|--node-port)    NODE_PORT="${2:?}"; shift 2 ;;
        --node-port=*)     NODE_PORT="${1#*=}"; shift ;;
        -V|--validation)   VALIDATION="${2:?}"; shift 2 ;;
        --validation=*)    VALIDATION="${1#*=}"; shift ;;
        -T|--cf-token)     CF_TOKEN="${2:?}"; shift 2 ;;
        --cf-token=*)      CF_TOKEN="${1#*=}"; shift ;;
        -w|--warp-port)    WARP_PORT="${2:?}"; shift 2 ;;
        --warp-port=*)     WARP_PORT="${1#*=}"; shift ;;
        --no-tune)         ENABLE_TUNE=false; shift ;;
        --no-fail2ban)     ENABLE_FAIL2BAN=false; shift ;;
        --no-warp)         ENABLE_WARP=false; shift ;;
        -y|--yes)          ASSUME_YES=true; shift ;;
        -f|--force)        FORCE_OS=true; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 err "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# =============================================================================
#  .env persistence (lowest priority: does not override args or environment)
# =============================================================================
if [[ -f "$ENV_FILE" ]]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        if [[ -z "${!key:-}" ]]; then
            export "$key=$value"
        fi
    done < "$ENV_FILE"
fi

# =============================================================================
#  Decoy service catalog
# =============================================================================
# Format: "Name|Image|Internal_Port"
SERVICES=(
    "filebrowser|filebrowser/filebrowser|80"
    "memos|neosmemo/memos:stable|5230"
    "pingvin-share|stonith404/pingvin-share|3000"
    "excalidraw|excalidraw/excalidraw|80"
    "searxng|searxng/searxng|8080"
    "sharry|jlesage/sharry|9090"
    "audiobookshelf|advplyr/audiobookshelf|80"
    "kavita|jvmilazz0/kavita|5000"
    "kodbox|kodcloud/kodbox|80"
    "navidrome|deluan/navidrome|4533"
    "gitea|gitea/gitea|3000"
    "fluffy-web|aceberg/fluffychat|80"
)

# =============================================================================
#  Validation helpers
# =============================================================================
# NOTE: no {N,M} interval quantifiers here — support for them varies between
# regex implementations shipped with bash; `*`/`+` plus explicit length checks
# behave identically everywhere.
is_domain() {
    local lbl
    [[ "$1" =~ ^[a-zA-Z0-9.-]+$ ]] || return 1
    [[ "$1" == *.* && "$1" != *.*. && "$1" != .* ]] || return 1
    (( ${#1} <= 253 )) || return 1
    local -a labels
    IFS='.' read -ra labels <<< "$1"
    for lbl in "${labels[@]}"; do
        [[ "$lbl" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
        (( ${#lbl} <= 63 )) || return 1
    done
    return 0
}
is_email()  { [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; }
is_secret() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#1} >= 16 && ${#1} <= 256 )); }
is_port()   { [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1024 && "$1" <= 65535 )); }

interactive() { [[ "$INTERACTIVE_TTY" == true ]]; }

require_value() { # $1 var name, $2 prompt, $3 validator name, $4 hidden?
    local __name="$1" __prompt="$2" __validator="$3" __hidden="${4:-}" __val="${!1}"
    if [[ -n "$__val" ]]; then return 0; fi
    if ! interactive; then
        die "$__name is not set. Pass --$(echo "$__name" | tr '_' '-' | tr 'A-Z' 'a-z') or run from a terminal."
    fi
    while true; do
        if [[ "$__hidden" == "hidden" ]]; then
            read -rs -p "$__prompt (input hidden): " __val; echo
        else
            read -r -p "$__prompt: " __val
        fi
        [[ -z "$__val" ]] && continue
        if "$__validator" "$__val"; then break; fi
        err "Invalid value, try again."
    done
    printf -v "$__name" '%s' "$__val"
}

# =============================================================================
#  OS / hardware preflight
# =============================================================================
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
else
    die "Cannot read /etc/os-release"
fi
OS_ID="${ID:-}"
OS_VER="${VERSION_ID:-}"
OS_CODENAME="${VERSION_CODENAME:-unknown}"

if [[ "$FORCE_OS" != true ]]; then
    if [[ "$OS_ID" != "debian" || "$OS_VER" != "12" && "$OS_VER" != "13" ]]; then
        die "Unsupported OS: ${PRETTY_NAME:-$OS_ID $OS_VER}. This installer targets Debian 12 (bookworm) / 13 (trixie) only. Use --force to override."
    fi
fi

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  DPKG_ARCH="amd64" ;;
    aarch64) DPKG_ARCH="arm64" ;;
    *) die "Unsupported architecture: $ARCH (need amd64 or arm64)" ;;
esac

DISK_FREE_MB="$(df -Pm / | awk 'NR==2{print $4}')"
if (( DISK_FREE_MB < 2048 )); then
    die "Not enough disk space: ${DISK_FREE_MB}MB free (need at least 2GB)."
fi
RAM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
if (( RAM_MB < 480 )); then
    die "Not enough RAM: ${RAM_MB}MB (need at least 512MB)."
elif (( RAM_MB < 1024 )); then
    warn "Only ${RAM_MB}MB RAM — a lightweight decoy service is recommended."
fi

# Returns the closest codename for which a repo has dists (falls back to bookworm)
repo_codename() { # $1 = repo base url
    if curl -4 -fsSL -o /dev/null --max-time 10 "$1/dists/${OS_CODENAME}/Release" 2>/dev/null; then
        echo "$OS_CODENAME"
    else
        echo "bookworm"
    fi
}

detect_public_ip() {
    local src ip
    for src in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        if ip="$(curl -4 -fsSL --max-time 6 "$src" 2>/dev/null | tr -d '[:space:]')" && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"; return 0
        fi
    done
    return 1
}

# =============================================================================
#  Configuration resolution
# =============================================================================
echo ""
info "Detected: ${PRETTY_NAME:-Debian} (${DPKG_ARCH}), ${RAM_MB}MB RAM, ${DISK_FREE_MB}MB free disk"

require_value DOMAIN     "Enter domain (e.g. node.example.com)" is_domain
require_value EMAIL      "Enter email (for SSL)"                is_email
require_value SECRET_KEY "Enter SECRET_KEY (from panel)"        is_secret hidden

if ! is_domain "$DOMAIN"; then die "Invalid domain: $DOMAIN"; fi
if ! is_email "$EMAIL";  then die "Invalid email: $EMAIL"; fi
if ! is_secret "$SECRET_KEY"; then
    die "SECRET_KEY must be 16-256 chars of [A-Za-z0-9_-] (the value from the Remnawave panel)."
fi

# --- decoy service selection --------------------------------------------------
resolve_service() {
    local s
    for s in "${SERVICES[@]}"; do
        [[ "${s%%|*}" == "$SERVICE_NAME" ]] && { echo "$s"; return 0; }
    done
    return 1
}

SELECTED_SERVICE=""
if [[ -n "$SERVICE_NAME" ]]; then
    SELECTED_SERVICE="$(resolve_service)" || true
    if [[ -z "$SELECTED_SERVICE" ]]; then
        err "Unknown service '$SERVICE_NAME'. Available: ${SERVICES[*]%%|*}"
        exit 1
    fi
elif interactive && [[ "$ASSUME_YES" != true ]]; then
    echo "------------------------------------------------"
    echo "Select the decoy service to install:"
    for i in "${!SERVICES[@]}"; do
        echo "  [$((i+1))] ${SERVICES[$i]%%|*}"
    done
    read -r -p "Service number (Enter for random): " CHOICE
    if [[ -z "$CHOICE" ]]; then
        SELECTED_SERVICE="${SERVICES[$((RANDOM % ${#SERVICES[@]}))]}"
    elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#SERVICES[@]} )); then
        SELECTED_SERVICE="${SERVICES[$((CHOICE-1))]}"
    else
        die "Invalid selection: $CHOICE"
    fi
else
    SELECTED_SERVICE="${SERVICES[$((RANDOM % ${#SERVICES[@]}))]}"
fi
SERVICE_NAME="${SELECTED_SERVICE%%|*}"
SERVICE_IMAGE="$(echo "$SELECTED_SERVICE" | cut -d'|' -f2)"
SERVICE_PORT="$(echo "$SELECTED_SERVICE" | cut -d'|' -f3)"

# --- remaining options ---------------------------------------------------------
case "$VALIDATION" in
    standalone|cloudflare) : ;;
    "") if interactive && [[ "$ASSUME_YES" != true ]]; then
            echo "SSL validation method:"
            echo "  1) standalone  — TLS-ALPN-01 on port 443 (needs the domain to point here)"
            echo "  2) cloudflare  — DNS-01 via Cloudflare API token (no inbound port needed)"
            read -r -p "Choose [1-2, default 1]: " VALIDATION
            [[ "$VALIDATION" == "2" ]] && VALIDATION="cloudflare" || VALIDATION="standalone"
        else
            VALIDATION="standalone"
        fi ;;
    *) die "Invalid --validation '$VALIDATION' (standalone|cloudflare)" ;;
esac
if [[ "$VALIDATION" == "cloudflare" ]]; then
    if [[ -z "$CF_TOKEN" ]]; then
        if interactive && [[ "$ASSUME_YES" != true ]]; then
            read -rs -p "Cloudflare API Token (Zone:DNS:Edit, input hidden): " CF_TOKEN; echo
        else
            die "cloudflare validation requires --cf-token"
        fi
    fi
fi

NODE_PORT="${NODE_PORT:-2222}"
WARP_PORT="${WARP_PORT:-40000}"
is_port "$NODE_PORT" || die "Invalid --node-port '$NODE_PORT' (1024-65535)"
is_port "$WARP_PORT" || die "Invalid --warp-port '$WARP_PORT' (1024-65535)"
# NOTE: Hysteria2 (QUIC) runs inside the node's Xray-core with its inbound
# pushed by the panel — no server binary is installed here. UDP buffers and
# the 443/udp firewall rule below are what the node needs for it.

# --- preflight DNS sanity (non-fatal) ------------------------------------------
PUBLIC_IP="$(detect_public_ip || true)"
RESOLVED_IPS="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)"
if [[ -z "$RESOLVED_IPS" ]]; then
    warn "Domain $DOMAIN does not resolve — certificate issuance will fail if this stays broken."
elif [[ -n "$PUBLIC_IP" ]] && ! grep -qx "$PUBLIC_IP" <<<"$RESOLVED_IPS"; then
    warn "$DOMAIN resolves to: $(echo "$RESOLVED_IPS" | tr '\n' ' ') — but this server's IP is $PUBLIC_IP."
    warn "If the domain is behind a CDN/proxy, standalone certificate issuance will fail (use --validation cloudflare)."
fi

# --- persist configuration -------------------------------------------------------
cat > "$ENV_FILE" <<EOF
EMAIL=$EMAIL
DOMAIN=$DOMAIN
SECRET_KEY=$SECRET_KEY
SERVICE_NAME=$SERVICE_NAME
NODE_PORT=$NODE_PORT
WARP_PORT=$WARP_PORT
VALIDATION=$VALIDATION
EOF
[[ -n "$CF_TOKEN" ]] && echo "CF_TOKEN=$CF_TOKEN" >> "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo ""
info "Configuration:"
info "  domain       : $DOMAIN"
info "  email        : $EMAIL"
info "  decoy service: $SERVICE_NAME ($SERVICE_IMAGE)"
info "  node port    : $NODE_PORT"
info "  validation   : $VALIDATION"
info "  tune/f2b/warp: $ENABLE_TUNE / $ENABLE_FAIL2BAN / $ENABLE_WARP"

# =============================================================================
step "[1/11] Base system: packages, time sync, unattended upgrades"
# =============================================================================
apt-get update -o DPkg::Lock::Timeout=300
apt_install ca-certificates curl gnupg socat cron ufw logrotate python3 openssl

# Time sync (skip failures inside LXC where the host controls the clock)
timedatectl set-ntp true 2>/dev/null || true
for _ in $(seq 1 6); do
    [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]] && break
    sleep 2
done
if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
    ok "Clock synchronized via NTP"
else
    warn "NTP not synchronized yet (common in LXC containers — the host manages the clock)."
fi

# Automatic security updates
apt_install unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
ok "Unattended security upgrades enabled"

# =============================================================================
step "[2/11] Kernel & network tuning, file descriptor limits, journald"
# =============================================================================
if [[ "$ENABLE_TUNE" == true ]]; then
    # nf_conntrack must be loaded before its sysctls can be set
    modprobe nf_conntrack 2>/dev/null || true
    echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf

    cat > /etc/sysctl.d/99-remnanode.conf <<'EOF'
# --- Remnawave VPN node production tuning ---
# Congestion control: BBR with fair queueing
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Socket buffers for high-BDP links and QUIC/UDP traffic
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432

# Listen backlogs / connection handling
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1

# TCP behavior tuned for proxying long-lived connections
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1

# Conntrack headroom for many concurrent proxied connections
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 7440
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# File descriptors and inotify
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288

# VM behavior
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# Auto-reboot 10s after a kernel panic
kernel.panic = 10
EOF
    if sysctl -p /etc/sysctl.d/99-remnanode.conf >/dev/null 2>&1; then
        ok "Sysctl tuning applied ($(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'bbr') congestion control)"
    else
        # Some keys are read-only in LXC/OpenVZ — not fatal
        warn "Some sysctls could not be applied (restricted container?). Continuing."
    fi

    # File descriptor limits: PAM + systemd-wide
    cat > /etc/security/limits.d/99-remnanode.conf <<EOF
*     soft nofile ${NOFILE_LIMIT}
*     hard nofile ${NOFILE_LIMIT}
root  soft nofile ${NOFILE_LIMIT}
root  hard nofile ${NOFILE_LIMIT}
EOF
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-remnanode-limits.conf <<EOF
[Manager]
DefaultLimitNOFILE=${NOFILE_LIMIT}:${NOFILE_LIMIT}
EOF
    systemctl daemon-reexec 2>/dev/null || true
    ok "File descriptor limits raised to ${NOFILE_LIMIT}"
else
    info "Kernel/network tuning skipped (--no-tune)"
fi

# journald: persistent, capped logs (protects small disks)
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-remnanode.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=200M
MaxRetentionSec=2week
EOF
systemctl restart systemd-journald 2>/dev/null || true
ok "journald: persistent storage capped at 200M / 2 weeks"

# =============================================================================
step "[3/11] fail2ban: SSH brute-force protection"
# =============================================================================
if [[ "$ENABLE_FAIL2BAN" == true ]]; then
    apt_install fail2ban python3-systemd
    CLIENT_IP=""
    [[ -n "${SSH_CLIENT:-}" ]] && CLIENT_IP="$(echo "$SSH_CLIENT" | awk '{print $1}')"
    IGNOREIP="127.0.0.1/8 ::1"
    [[ -n "$CLIENT_IP" ]] && IGNOREIP="$IGNOREIP $CLIENT_IP"
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
backend = systemd
ignoreip = ${IGNOREIP}
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd
EOF
    systemctl enable --now fail2ban >/dev/null 2>&1 || true
    if fail2ban-client ping >/dev/null 2>&1; then
        ok "fail2ban active (sshd jail, your IP whitelisted: ${CLIENT_IP:-none})"
    else
        warn "fail2ban installed but not responding yet — check 'systemctl status fail2ban'."
    fi
else
    info "fail2ban skipped (--no-fail2ban)"
fi

# =============================================================================
step "[4/11] Docker Engine + Compose plugin, log rotation"
# =============================================================================
ensure_docker_repo() {
    install -d -m 0755 /etc/apt/keyrings
    curl -4 -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    local cn
    cn="$(repo_codename https://download.docker.com/linux/debian)"
    echo "deb [arch=${DPKG_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${cn} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -o DPkg::Lock::Timeout=300
}

if command -v docker >/dev/null 2>&1; then
    ok "Docker already installed ($(docker --version | head -n1))"
    if ! docker compose version >/dev/null 2>&1; then
        info "Compose plugin missing — installing from Docker repository..."
        ensure_docker_repo
        apt_install docker-compose-plugin
    fi
else
    info "Installing Docker Engine from the official repository..."
    ensure_docker_repo
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is not available after installation."
systemctl enable --now docker >/dev/null 2>&1 || true

# daemon.json: rotate container logs, keep containers alive during daemon restarts
DAEMON_JSON="/etc/docker/daemon.json"
DAEMON_CHANGED="$(python3 - "$DAEMON_JSON" <<'PYEOF'
import json, os, shutil, sys
path = sys.argv[1]
cfg = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            cfg = json.load(f)
    except Exception as exc:
        shutil.copy(path, path + ".bak")
        print(f"existing config invalid ({exc}), backed up and replaced")
        cfg = {}
changed = False
def put(key, value):
    global cfg, changed
    if cfg.get(key) != value:
        cfg[key] = value
        changed = True
put("log-driver", "json-file")
lo = cfg.get("log-opts") or {}
if lo.get("max-size") != "10m": lo["max-size"] = "10m"; changed = True
if lo.get("max-file") != "3":   lo["max-file"] = "3";   changed = True
cfg["log-opts"] = lo
put("live-restore", True)
if changed:
    if os.path.exists(path):
        shutil.copy(path, path + ".bak")
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2, sort_keys=True)
    print("updated")
else:
    print("unchanged")
PYEOF
)"
if [[ "$DAEMON_CHANGED" == *"updated"* ]]; then
    systemctl restart docker
    ok "Docker: json-file log rotation (10M x 3) + live-restore enabled"
else
    ok "Docker daemon.json already configured"
fi

# =============================================================================
step "[5/11] Firewall (UFW)"
# =============================================================================
# Rate-limit every port sshd actually listens on (default 22)
SSH_PORTS="$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | awk 'tolower($1)=="port"{print $2}' | sort -u || true)"
if [[ -z "$SSH_PORTS" ]]; then
    SSH_PORTS="$(grep -hE '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | sort -u || true)"
fi
[[ -z "$SSH_PORTS" ]] && SSH_PORTS="22"

ufw default deny incoming
ufw default allow outgoing
for p in $SSH_PORTS; do
    ufw limit "${p}/tcp" >/dev/null
done
ufw allow 80/tcp  comment 'ACME http-01'  >/dev/null
ufw allow 443/tcp comment 'Xray TLS'      >/dev/null
ufw allow "${NODE_PORT}/tcp" comment 'remnanode API' >/dev/null
# 443/udp is needed by QUIC-based inbounds (e.g. Hysteria2) pushed by the panel
ufw allow 443/udp comment 'QUIC / Hysteria2 (Xray)' >/dev/null
ufw --force enable >/dev/null

# =============================================================================
step "[6/11] SSL certificate for ${DOMAIN}"
# =============================================================================
CERT_KEY="${NODE_DIR}/nginx/privkey.key"
CERT_PEM="${NODE_DIR}/nginx/fullchain.pem"
ACME_BIN="${HOME}/.acme.sh/acme.sh"
ACME_ECC_DIR="${HOME}/.acme.sh/${DOMAIN}_ecc"
ACME_RSA_DIR="${HOME}/.acme.sh/${DOMAIN}"
LE_LIVE_DIR="/etc/letsencrypt/live/${DOMAIN}"

# Renewal hooks: free port 443 by briefly stopping the node, then bring it back.
ACME_PRE_HOOK='if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qx remnanode; then docker stop remnanode >/dev/null 2>&1 || true; fi; true'
ACME_POST_HOOK='if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qx remnanode; then docker start remnanode >/dev/null 2>&1 || true; fi; true'
ACME_RELOADCMD='docker compose -f "/opt/remnanode/nginx/docker-compose.yml" restart >/dev/null 2>&1; docker compose -f "/opt/remnanode/docker-compose.yml" restart >/dev/null 2>&1; true'

install -d -m 755 "${NODE_DIR}/nginx"

if [[ ! -f "$ACME_BIN" ]]; then
    info "Installing acme.sh..."
    curl -4 -fsSL https://get.acme.sh | sh -s email="$EMAIL"
fi
export LE_WORKING_DIR="${HOME}/.acme.sh"
"$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null

CERT_SOURCE=""
if [ -f "$LE_LIVE_DIR/fullchain.pem" ] && [ -f "$LE_LIVE_DIR/privkey.pem" ]; then
    echo "Found an existing certbot/Let's Encrypt certificate for $DOMAIN — using it."
    cp -L "$LE_LIVE_DIR/fullchain.pem" "$CERT_PEM"
    cp -L "$LE_LIVE_DIR/privkey.pem"   "$CERT_KEY"
    chmod 600 "$CERT_KEY"
    CERT_SOURCE="letsencrypt_live"

elif [ -f "$CERT_PEM" ] && [ -f "$CERT_KEY" ]; then
    echo "Certificates already present at $CERT_PEM — reusing them."
    CERT_SOURCE="existing"

elif [ -f "$ACME_ECC_DIR/fullchain.cer" ] && [ -f "$ACME_ECC_DIR/${DOMAIN}.key" ]; then
    echo "Certificate found in the acme.sh cache (ECC) — installing."
    "$ACME_BIN" --install-cert -d "$DOMAIN" --ecc \
        --key-file "$CERT_KEY" --fullchain-file "$CERT_PEM" \
        --pre-hook "$ACME_PRE_HOOK" --post-hook "$ACME_POST_HOOK" \
        --reloadcmd "$ACME_RELOADCMD"
    CERT_SOURCE="acme_ecc"

elif [ -f "$ACME_RSA_DIR/fullchain.cer" ] && [ -f "$ACME_RSA_DIR/${DOMAIN}.key" ]; then
    echo "Certificate found in the acme.sh cache (RSA) — installing."
    "$ACME_BIN" --install-cert -d "$DOMAIN" \
        --key-file "$CERT_KEY" --fullchain-file "$CERT_PEM" \
        --pre-hook "$ACME_PRE_HOOK" --post-hook "$ACME_POST_HOOK" \
        --reloadcmd "$ACME_RELOADCMD"
    CERT_SOURCE="acme_rsa"

else
    if [[ "$VALIDATION" == "cloudflare" ]]; then
        echo "--- Cloudflare DNS-01 challenge (certbot) ---"
        apt_install certbot python3-certbot-dns-cloudflare
        CF_INI="${NODE_DIR}/cloudflare.ini"
        install -m 600 /dev/null "$CF_INI"
        echo "dns_cloudflare_api_token = $CF_TOKEN" > "$CF_INI"
        chmod 600 "$CF_INI"
        if certbot certonly \
            --dns-cloudflare \
            --dns-cloudflare-credentials "$CF_INI" \
            -d "$DOMAIN" \
            --non-interactive --agree-tos -m "$EMAIL"; then
            cp -L "$LE_LIVE_DIR/fullchain.pem" "$CERT_PEM"
            cp -L "$LE_LIVE_DIR/privkey.pem"   "$CERT_KEY"
            chmod 600 "$CERT_KEY"
            CERT_SOURCE="letsencrypt_live"
        else
            die "Cloudflare DNS-01 issuance failed. Check that the token has Zone:DNS:Edit for $DOMAIN."
        fi
    else
        echo "--- TLS-ALPN-01 challenge on port 443 (acme.sh standalone) ---"
        # The pre-hook frees 443 if the node is already running (re-issuance case).
        if "$ACME_BIN" --issue --standalone -d "$DOMAIN" --alpn --keylength ec-256 \
                --server letsencrypt \
                --pre-hook "$ACME_PRE_HOOK" --post-hook "$ACME_POST_HOOK" \
                --key-file "$CERT_KEY" --fullchain-file "$CERT_PEM" \
                --reloadcmd "$ACME_RELOADCMD"; then
            CERT_SOURCE="acme_ecc"
        elif [ -f "$ACME_ECC_DIR/fullchain.cer" ]; then
            warn "Issuance reported an error but certificate files exist — installing from cache."
            "$ACME_BIN" --install-cert -d "$DOMAIN" --ecc \
                --key-file "$CERT_KEY" --fullchain-file "$CERT_PEM" \
                --pre-hook "$ACME_PRE_HOOK" --post-hook "$ACME_POST_HOOK" \
                --reloadcmd "$ACME_RELOADCMD"
            CERT_SOURCE="acme_ecc"
        else
            die "Certificate issuance failed. Check DNS ($DOMAIN -> $PUBLIC_IP) and that port 443 is reachable."
        fi
    fi
fi
chmod 600 "$CERT_KEY"
ok "Certificate ready (source: $CERT_SOURCE)"

# =============================================================================
step "[7/11] Decoy service: ${SERVICE_NAME}"
# =============================================================================
install -d -m 755 "/opt/${SERVICE_NAME}"
cat > "/opt/${SERVICE_NAME}/docker-compose.yml" <<EOF
services:
  ${SERVICE_NAME}:
    container_name: ${SERVICE_NAME}
    image: ${SERVICE_IMAGE}
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:${SERVICE_PORT}"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
docker compose -f "/opt/${SERVICE_NAME}/docker-compose.yml" up -d

# =============================================================================
step "[8/11] Nginx camouflage proxy"
# =============================================================================
cat > "${NODE_DIR}/nginx/nginx.conf" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name ${DOMAIN};
    server_tokens off;
    return 301 https://\$host\$request_uri;
}

# Xray terminates TLS on :443 (REALITY) and forwards decoy traffic here over
# a unix socket with PROXY protocol — nginx never touches the public internet.
server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    server_name ${DOMAIN};
    http2 on;
    server_tokens off;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # Camouflage: the decoy web service
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
EOF

cat > "${NODE_DIR}/nginx/docker-compose.yml" <<EOF
services:
  nginx:
    image: nginx:stable
    container_name: remnanode-proxy
    restart: always
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/certs/fullchain.pem:ro
      - ./privkey.key:/etc/nginx/certs/privkey.key:ro
      - /dev/shm:/dev/shm:rw
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'
EOF
docker compose -f "${NODE_DIR}/nginx/docker-compose.yml" up -d

# =============================================================================
step "[9/11] Remnanode (Xray core)"
# =============================================================================
install -d -m 755 /var/log/remnanode
cat > "${NODE_DIR}/docker-compose.yml" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    volumes:
      - ${NODE_DIR}/nginx/fullchain.pem:/etc/nginx/certs/fullchain.pem:ro
      - ${NODE_DIR}/nginx/privkey.key:/etc/nginx/certs/privkey.key:ro
      - /dev/shm:/dev/shm:rw
      - /var/log/remnanode:/var/log/remnanode
    ulimits:
      nofile:
        soft: ${NOFILE_LIMIT}
        hard: ${NOFILE_LIMIT}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    environment:
      NODE_PORT: "${NODE_PORT}"
      SECRET_KEY: "${SECRET_KEY}"
EOF
docker compose -f "${NODE_DIR}/docker-compose.yml" up -d

# =============================================================================
step "[10/11] Certificate renewal wiring, node log rotation"
# =============================================================================
if [[ "$CERT_SOURCE" == "letsencrypt_live" ]]; then
    echo "Certificate is managed by certbot — installing a deploy hook."
    install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/remnanode-sync.sh <<HOOKEOF
#!/bin/bash
# Auto-generated by the remnanode install script.
# Syncs the renewed certificate and restarts the stack when the domain matches.
case ",\${RENEWED_DOMAINS// /,}," in
  *",${DOMAIN},"*)
    cp -L "${LE_LIVE_DIR}/fullchain.pem" "${CERT_PEM}"
    cp -L "${LE_LIVE_DIR}/privkey.pem" "${CERT_KEY}"
    chmod 600 "${CERT_KEY}"
    docker compose -f ${NODE_DIR}/nginx/docker-compose.yml restart
    docker compose -f ${NODE_DIR}/docker-compose.yml restart
    ;;
esac
HOOKEOF
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/remnanode-sync.sh
    # certbot's package ships certbot.timer — verify it is active
    systemctl is-active --quiet certbot.timer 2>/dev/null \
        || systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    ok "certbot deploy hook + renewal timer configured"

elif [[ "$CERT_SOURCE" == "existing" || "$CERT_SOURCE" == "" ]]; then
    warn "Certificates were not issued by this script — automatic renewal is NOT configured."
    warn "Set up renewal manually or re-run the script with --validation cloudflare."

else
    # acme.sh manages renewal; it registers its own cron at install time
    if ! crontab -l 2>/dev/null | grep -q "acme.sh --cron"; then
        (crontab -l 2>/dev/null; echo "0 0 * * * \"${HOME}/.acme.sh\"/acme.sh --cron --home \"${HOME}/.acme.sh\" > /dev/null") | crontab -
    fi
    ok "acme.sh auto-renewal configured (pre/post hooks toggle port 443, reloadcmd restarts the stack)"
fi

cat > /etc/logrotate.d/remnanode <<'EOF'
/var/log/remnanode/*.log {
    daily
    rotate 7
    maxsize 50M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
ok "logrotate configured for /var/log/remnanode"

# =============================================================================
step "[11/11] Cloudflare WARP (SOCKS5 egress, 127.0.0.1:${WARP_PORT})"
# =============================================================================
if [[ "$ENABLE_WARP" == true ]]; then
    if [[ -f "${SCRIPT_DIR}/warp.sh" ]]; then
        # shellcheck source=warp.sh
        source "${SCRIPT_DIR}/warp.sh"
        WARP_SOCKS_PORT="$WARP_PORT" warp_setup
    else
        warn "warp.sh not found next to install.sh — skipping WARP installation."
    fi
else
    info "WARP skipped (--no-warp)"
fi

# =============================================================================
#  Final verification & summary
# =============================================================================
echo ""
step "Verification"
FAIL=0
for svc_name in "${SERVICE_NAME}" remnanode-proxy remnanode; do
    STATE="$(docker inspect -f '{{.State.Status}}' "$svc_name" 2>/dev/null || echo missing)"
    if [[ "$STATE" == "running" ]]; then
        ok "container ${svc_name}: running"
    else
        err "container ${svc_name}: ${STATE}"
        FAIL=1
    fi
done
if docker exec remnanode xray version >/dev/null 2>&1; then
    ok "Xray inside remnanode: $(docker exec remnanode xray version | head -n1 | awk '{print $2}')"
else
    err "Cannot execute xray inside remnanode"
    FAIL=1
fi

echo ""
echo "================================================"
if (( FAIL )); then
    err "INSTALLATION FINISHED WITH ERRORS — see ${LOG_FILE}"
    docker compose -f "${NODE_DIR}/docker-compose.yml" logs --tail 20 2>/dev/null || true
    exit 1
fi
echo " INSTALLATION COMPLETE"
echo "------------------------------------------------"
echo " Domain           : ${DOMAIN}"
echo " Decoy service    : ${SERVICE_NAME} (masked site on 443)"
echo " Node API         : ${DOMAIN}:${NODE_PORT} (panel -> nodes, add this node)"
echo " Certificate      : ${CERT_SOURCE}"
echo " WARP SOCKS5      : 127.0.0.1:${WARP_PORT} (do NOT open this port!)"
echo " Install log      : ${LOG_FILE}"
echo "================================================"
echo ""
echo " Next steps:"
echo "   1. In the Remnawave panel add this node: host ${DOMAIN}, port ${NODE_PORT},"
echo "      the same SECRET_KEY."
echo "   2. Real users' traffic exits via WARP; decoy visitors see ${SERVICE_NAME}."
echo "   3. Re-running this script is safe (idempotent upgrade)."
