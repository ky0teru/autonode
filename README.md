# 🚀 Remnawave Node Installer (Debian 12/13)

A production-grade, fully unattended Bash installer that turns a fresh **Debian 12/13**
server into a **Remnawave VPN node**: Xray over TCP (VLESS/REALITY), an Nginx camouflage
site, and Cloudflare WARP as the traffic egress.

## 📋 What the Script Deploys

| Step | Component | What you get |
| ---- | --------- | ------------ |
| 1  | Base system | Required packages, NTP time sync, automatic security updates |
| 2  | Kernel & network tuning | Sysctl profile built for proxying long-lived TCP connections |
| 3  | fail2ban | SSH brute-force protection, your IP whitelisted automatically |
| 4  | Docker | Official repo (amd64/arm64), Compose plugin, tuned `daemon.json` |
| 5  | Firewall | UFW: default-deny inbound, SSH auto-detected and rate-limited, only the ports the node needs |
| 6  | SSL | Let's Encrypt via acme.sh TLS-ALPN-01 on 443, or Cloudflare DNS-01 (no open ports). Auto-renewal wired end-to-end |
| 7  | Decoy site | A real web app (12 to choose from) served to anyone probing the domain |
| 8  | Nginx camouflage | TLS 1.2/1.3 terminator on a unix socket behind Xray's REALITY fallback, real client IPs via PROXY protocol |
| 9  | Remnanode | Xray core managed by the Remnawave panel, high fd limits |
| 10 | Renewal & logs | Cert renewals stop/start the node around the ACME challenge; node logs rotated |
| 11 | Cloudflare WARP | SOCKS5 egress proxy on `127.0.0.1:40000` for user traffic |

## ⚙️ Production-Level Settings

**Network / kernel** (`/etc/sysctl.d/99-remnanode.conf`)
- BBR congestion control + fair-queue qdisc
- 64 MB socket buffers, tuned `tcp_rmem`/`tcp_wmem` for high-BDP links
- `somaxconn` / `netdev_max_backlog` / SYN backlog raised for burst load
- conntrack table sized for thousands of concurrent proxied connections
- TCP fast open, MTU probing, no slow-start after idle, keepalives tuned for NAT
- auto-reboot 10 s after a kernel panic

**Resource limits**
- `nofile` = 1 048 576 at every layer: PAM `limits.d`, systemd `DefaultLimitNOFILE`, container `ulimits`
- `fs.file-max`, inotify limits raised
- `vm.swappiness = 10`, `vm.vfs_cache_pressure = 50`

**Security**
- UFW default-deny inbound; SSH ports detected from `sshd -T` and **rate-limited**, not just opened
- fail2ban with the systemd journal backend (works on minimal installs without rsyslog)
- `unattended-upgrades` enabled for automatic security patches
- Strict input validation; `.env` and certificates `chmod 600`
- TLS 1.2/1.3 only, modern ECDHE/CHACHA20 ciphers, session tickets off

**Operability**
- Fully unattended: CLI flags, env vars, or a saved `.env` — precedence `flags > env > .env > defaults`
- Idempotent: safe to re-run for upgrades/re-pairing
- journald persistent but capped (200 MB / 2 weeks) — small disks stay safe
- Docker `json-file` log rotation (10 MB × 3) + `live-restore`, plus per-service limits
- logrotate for node logs; full install log at `/var/log/remnanode-install.log`
- Preflight checks: OS version, arch, disk, RAM, DNS → clear errors instead of half-broken installs

## 🛠 Requirements

- **OS:** Debian 12 or 13 (amd64/arm64), fresh install recommended
- **Domain:** an A-record pointing to the server's IPv4
- **Access:** root (the script re-executes itself via sudo)
- **Ports:** 22 (SSH), 80, 443 free; node API port (default `2222`)

## 🚀 Installation

Interactive (prompts only for what's missing):

```bash
git clone https://github.com/ky0teru/autonode.git && cd autonode && sudo ./install.sh
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

Environment variables (`DOMAIN`, `EMAIL`, `SECRET_KEY`, `SERVICE_NAME`, `VALIDATION`,
`CF_TOKEN`, `NODE_PORT`, `WARP_PORT`) and the `.env` file created on first run work too.

## ⌨️ Options

| Flag | Description | Default |
| ---- | ----------- | ------- |
| `-d, --domain` | Node domain | *required* |
| `-e, --email` | Email for certificate registration | *required* |
| `-s, --secret-key` | SECRET_KEY from the Remnawave panel | *required* |
| `-S, --service` | Decoy service name | random |
| `-n, --node-port` | Remnanode API port | `2222` |
| `-V, --validation` | `standalone` (TLS-ALPN-01) or `cloudflare` (DNS-01) | `standalone` |
| `-T, --cf-token` | Cloudflare API token (Zone:DNS:Edit) | — |
| `-w, --warp-port` | WARP SOCKS5 port | `40000` |
| `--no-tune` | Skip kernel/network tuning | tuning ON |
| `--no-fail2ban` | Skip fail2ban | fail2ban ON |
| `--no-warp` | Skip WARP installation | WARP ON |
| `-y, --yes` | Never prompt | — |
| `-f, --force` | Skip the Debian 12/13 check | — |
| `-h, --help` | Show help | — |

## 📂 Project Structure

- `/opt/remnanode/` — node compose + config
- `/opt/remnanode/nginx/` — Nginx config and SSL keys
- `/opt/<service>/` — selected decoy service
- `/etc/sysctl.d/99-remnanode.conf` — network tuning
- `/var/log/remnanode-install.log` — full install log

## ⚠️ Used Ports

| Port | Service |
| ---- | ------- |
| 22   | SSH (rate-limited by UFW + fail2ban) |
| 80   | ACME / HTTP redirect |
| 443  | Xray TCP (REALITY, camouflage via nginx socket) |
| 2222 | Remnanode API (panel → node) |
| 40000 | Cloudflare WARP SOCKS5 — **localhost only, do not open** |

## 🌍 Other Languages

- [Русский](docs/README_RU.md)
- [中文](docs/README_CN.md) *(may be outdated)*

## 📜 License

[MIT](LICENSE)
