#!/usr/bin/env bash
# =============================================================================
#  Cloudflare WARP in SOCKS5 proxy mode — install & configure (Debian 12/13)
#
#  Can be used two ways:
#    1. Sourced as a module by install.sh  (defines warp_setup, no side effects)
#    2. Run directly:  sudo ./warp.sh [port]      (default port: 40000)
#
#  The SOCKS5 proxy listens on 127.0.0.1 only — never open this port!
# =============================================================================
if [[ -n "${_WARP_MODULE_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_WARP_MODULE_LOADED=1

WARP_SOCKS_PORT="${WARP_SOCKS_PORT:-40000}"

# --- logging: reuse the caller's helpers when sourced, plain echo otherwise ---
_warp_info() { if declare -F info >/dev/null; then info "$*"; else echo "[INF] $*"; fi; }
_warp_ok()   { if declare -F ok   >/dev/null; then ok   "$*"; else echo "[OK ] $*"; fi; }
_warp_warn() { if declare -F warn >/dev/null; then warn "$*"; else echo "[WRN] $*"; fi; }
_warp_die()  { if declare -F die  >/dev/null; then die  "$*"; else echo "[ERR] $*" >&2; exit 1; fi; }

warp_cli() { warp-cli --accept-tos "$@"; }

_warp_root_check() {
    [[ $EUID -eq 0 ]] || _warp_die "warp.sh must be run as root."
}

_warp_os_check() {
    # Accepts Debian 12/13 only. When sourced, the installer has already checked,
    # but a direct run goes through here too.
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
    else
        _warp_die "Cannot read /etc/os-release"
    fi
    if [[ "${ID:-}" != "debian" ]] || [[ "${VERSION_ID:-}" != "12" && "${VERSION_ID:-}" != "13" ]]; then
        _warp_die "Unsupported OS: ${PRETTY_NAME:-unknown}. Only Debian 12/13 is supported."
    fi
}

_warp_repo_codename() {
    # Cloudflare's apt repo may lag behind new Debian releases; fall back to the
    # bookworm dist (fully compatible) when the current codename is absent.
    if curl -4 -fsSL -o /dev/null --max-time 10 \
        "https://pkg.cloudflareclient.com/dists/${VERSION_CODENAME}/Release" 2>/dev/null; then
        echo "$VERSION_CODENAME"
    else
        echo "bookworm"
    fi
}

warp_install() {
    if command -v warp-cli >/dev/null 2>&1; then
        _warp_ok "warp-cli already installed — skipping installation."
        return 0
    fi

    _warp_info "Installing dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -o DPkg::Lock::Timeout=300
    apt-get -y -o DPkg::Lock::Timeout=300 install gnupg curl ca-certificates

    _warp_info "Adding the Cloudflare WARP repository..."
    curl -4 -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    local cn
    cn="$(_warp_repo_codename)"
    [[ "$cn" != "$VERSION_CODENAME" ]] && \
        _warp_warn "Repo for ${VERSION_CODENAME} not published yet — using bookworm dist (compatible)."
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${cn} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list

    _warp_info "Installing cloudflare-warp..."
    apt-get update -o DPkg::Lock::Timeout=300
    apt-get -y -o DPkg::Lock::Timeout=300 install cloudflare-warp

    # warp-svc must be up before configuration
    systemctl enable --now warp-svc >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do
        systemctl is-active --quiet warp-svc && break
        sleep 2
    done
    systemctl is-active --quiet warp-svc || _warp_warn "warp-svc is not active yet — continuing anyway."
    _warp_ok "warp-cli installed"
}

warp_configure() {
    local port="${1:-$WARP_SOCKS_PORT}"

    # Fresh proxy state: disconnect first so mode/port changes apply cleanly
    warp_cli disconnect >/dev/null 2>&1 || true

    # Register unless already registered. Do NOT parse `registration show`
    # output to detect the unregistered state — its wording differs between
    # warp-cli versions, which silently skipped registration on new installs.
    # A redundant `registration new` just errors out harmlessly.
    warp_cli registration new >/dev/null 2>&1 || true
    if ! warp_cli registration show >/dev/null 2>&1; then
        _warp_die "WARP registration failed — run 'warp-cli --accept-tos registration new' manually and check 'journalctl -u warp-svc'."
    fi

    _warp_info "Setting mode to proxy..."
    warp_cli mode proxy
    _warp_info "Setting SOCKS5 port to ${port}..."
    warp_cli proxy port "$port"
    _warp_info "Connecting..."
    warp_cli connect

    # Wait for the tunnel to come up. NOTE: a plain grep for "Connected" would
    # also match "Disconnected" — compare the whole status instead.
    local i status
    for i in $(seq 1 12); do
        status="$(warp_cli status 2>/dev/null || true)"
        if [[ "$status" == *Connected* && "$status" != *Disconnected* && "$status" != *Disconnecting* ]]; then
            break
        fi
        (( i == 12 )) && _warp_warn "WARP did not report Connected within 60s — check 'warp-cli status'."
        sleep 5
    done
    _warp_ok "WARP configured: SOCKS5 on 127.0.0.1:${port} (do NOT open this port in the firewall)"
}

warp_verify() {
    local port="${1:-$WARP_SOCKS_PORT}" egress
    egress="$(curl -s --connect-timeout 5 --max-time 12 -x "socks5h://127.0.0.1:${port}" https://api.ipify.org 2>/dev/null || true)"
    if [[ "$egress" =~ ^[0-9a-fA-F:.]+$ && -n "$egress" ]]; then
        _warp_ok "Egress check via WARP: ${egress}"
    else
        _warp_warn "Egress check failed — verify with: curl -x socks5h://127.0.0.1:${port} https://api.ipify.org"
    fi
}

warp_setup() {
    local port="${1:-$WARP_SOCKS_PORT}"
    warp_install
    warp_configure "$port"
    warp_verify "$port"
}

# --- direct execution ---------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    _warp_root_check
    _warp_os_check
    warp_setup "${1:-$WARP_SOCKS_PORT}"
fi
