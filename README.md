# 🚀 Remnanode Production Installer (Debian 12/13)

An automated, idempotent Bash installer that deploys a **Remnawave node** with an Nginx
camouflage proxy, a decoy web service, hardened networking and Cloudflare WARP egress —
targeting **Debian 12 (bookworm) and 13 (trixie)** only.

Runs fully unattended when flags are provided; re-running it is safe (it upgrades/re-pairs
in place).

## 📋 What It Does

| Step | What | Details |
| ---- | ---- | ------- |
| 1  | Base system | Essential packages, NTP time sync, `unattended-upgrades` (auto security patches) |
| 2  | Kernel & network tuning | **BBR + fq**, TCP buffer/backlog tuning, conntrack headroom, `nofile` up to 1M (PAM + systemd), persistent capped journald |
| 3  | fail2ban | SSH brute-force protection with the systemd journal backend; your current IP is whitelisted automatically |
| 4  | Docker | Official Docker repo (with a bookworm fallback for newer Debian), Compose plugin, `json-file` log rotation + `live-restore` in `daemon.json` |
| 5  | Firewall | UFW: SSH ports auto-detected and **rate-limited** (`limit`, not `allow`), 80/443 + node API port open |
| 6  | SSL | acme.sh **TLS-ALPN-01 on port 443** (Let's Encrypt) or **Cloudflare DNS-01** (certbot, no open ports needed). Existing certbot/acme.sh certs are detected and reused |
| 7  | Decoy service | One of 12 web services behind the camouflage (random or `--service`) |
| 8  | Nginx proxy | TLS 1.2/1.3 hardening, unix-socket + PROXY protocol (real client IPs via `$proxy_protocol_addr`), XHTTP location |
| 9  | Remnanode | Xray core, `nofile` ulimit, log rotation |
| 10 | Renewal | acme.sh cron or certbot timer + deploy hook; renewal briefly stops/starts the node to free port 443, then syncs certs and restarts the stack |
| 11 | WARP | Cloudflare WARP in SOCKS5 proxy mode on `127.0.0.1:40000` (egress for user traffic) |

## 🆚 What Changed vs. the Old Script

- ❌ **gRPC location/transport removed entirely** (XHTTP only)
- 🤖 **Fully scriptable**: CLI flags + env vars + `.env`, no interactive prompts required
- 🐧 **Strict Debian 12/13 support** (other releases are rejected; repo fallback to bookworm where vendors lag)
- 🔧 **Production tuning**: BBR+fq, buffers, conntrack, fd limits, journald caps, Docker log rotation, unattended upgrades, fail2ban, UFW rate-limiting
- 🩹 **Fixed**: TLS-ALPN challenge moved from port 8443 (ACME servers only ever connect to 443 — renewals were broken) to 443 with stop/start hooks; ZeroSSL option dropped (it requires EAB and never worked); real client IPs now use `$proxy_protocol_addr`

## 🛠 Prerequisites

- **OS:** Debian 12 or 13 (amd64/arm64), fresh install recommended
- **Domain:** an A-record pointing to the server's IPv4
- **Access:** root (the script re-executes itself via sudo if needed)
- **Ports:** 22 (SSH), 80, 443 free; the node API port (default `2222`)

## 🚀 Installation

Interactive (prompts only for what's missing):

```bash
git clone https://github.com/x1roko/node-setup.git && cd node-setup && sudo ./install.sh
```

Fully non-interactive:

```bash
sudo ./install.sh \
  --domain node.example.com \
  --email me@example.com \
  --secret-key <SECRET_FROM_PANEL> \
  --validation cloudflare --cf-token <CLOUDFLARE_API_TOKEN> \
  --service gitea --yes
```

Environment variables work too (`DOMAIN`, `EMAIL`, `SECRET_KEY`, `SERVICE_NAME`,
`VALIDATION`, `CF_TOKEN`, `NODE_PORT`, `XHTTP_PATH`, `WARP_PORT`), as does the `.env`
file created next to the script on first run. Precedence: **flags > environment > .env > defaults**.

## ⌨️ Options

| Flag | Description | Default |
| ---- | ----------- | ------- |
| `-d, --domain` | Node domain | *required* |
| `-e, --email` | Email for certificate registration | *required* |
| `-s, --secret-key` | SECRET_KEY from the Remnawave panel | *required* |
| `-S, --service` | Decoy service name | random |
| `-p, --xhttp-path` | XHTTP location path | `/xhttppath/` |
| `-n, --node-port` | Remnanode API port | `2222` |
| `-V, --validation` | `standalone` (TLS-ALPN-01) or `cloudflare` (DNS-01) | `standalone` |
| `-T, --cf-token` | Cloudflare API token (Zone:DNS:Edit) | — |
| `-w, --warp-port` | WARP SOCKS5 port | `40000` |
| `--no-tune` | Skip kernel/network sysctl tuning | tuning ON |
| `--no-fail2ban` | Skip fail2ban | fail2ban ON |
| `--no-warp` | Skip WARP installation | WARP ON |
| `-y, --yes` | Never prompt | — |
| `-f, --force` | Skip the Debian 12/13 check | — |
| `-h, --help` | Show help | — |

## 📂 Project Structure

- `/opt/remnanode/` — node compose + config
- `/opt/remnanode/nginx/` — Nginx config and SSL keys (`fullchain.pem`, `privkey.key`)
- `/opt/<service>/` — selected decoy service
- `/etc/sysctl.d/99-remnanode.conf` — network tuning
- `/var/log/remnanode-install.log` — full install log

## ⚠️ Used Ports

| Port | Service |
| ---- | ------- |
| 22   | SSH (rate-limited by UFW + fail2ban) |
| 80   | ACME / HTTP redirect |
| 443  | Xray (REALITY, camouflage via nginx socket) |
| 2222 | Remnanode API (panel → node) |
| 40000 | Cloudflare WARP SOCKS5 — **localhost only, do not open** |

## 🌍 Other Languages

- [Русский](docs/README_RU.md)
- [中文](docs/README_CN.md) *(may be outdated)*

## 📜 License

[MIT](LICENSE)
