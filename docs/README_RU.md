# 🚀 Remnawave Node Installer (Debian 12/13)

Production-установщик одной командой превращает чистый сервер на **Debian 12/13** в ноду
**Remnawave**: Xray поверх TCP (VLESS/REALITY) и QUIC (Hysteria2-inbound — панель сама
заворачивает его в Xray-core ноды), сайт-камуфляж на Nginx и исходящий трафик через Cloudflare WARP.

## 📋 Что разворачивает скрипт

| Шаг | Компонент | Результат |
| --- | --------- | --------- |
| 1  | Базовая система | Необходимые пакеты, синхронизация времени NTP, авто-обновления безопасности |
| 2  | Тюнинг ядра и сети | Sysctl-профиль под проксирование долгоживущих TCP-соединений |
| 3  | fail2ban | Защита SSH от брутфорса, ваш IP в whitelist автоматически |
| 4  | Docker | Официальный репозиторий (amd64/arm64), Compose-плагин, настроенный `daemon.json` |
| 5  | Файрвол | UFW: default-deny на вход, SSH-порты определяются автоматически и rate-limited, открыты только нужные ноде порты |
| 6  | SSL | Let's Encrypt через acme.sh TLS-ALPN-01 на 443 или Cloudflare DNS-01 (без открытых портов). Автопродление настроено целиком |
| 7  | Декои-сайт | Настоящее веб-приложение (12 на выбор) — его видит любой, кто открывает домен |
| 8  | Nginx-камуфляж | TLS 1.2/1.3 терминатор на unix-сокете за REALITY-fallback'ом Xray, реальные IP клиентов через PROXY protocol |
| 9  | Remnanode | Ядро Xray под управлением панели Remnawave, высокие лимиты FD |
| 10 | Продление и логи | При продлении сертификата нода останавливается/запускается вокруг ACME-челленджа; логи ноды ротируются |
| 11 | Cloudflare WARP | SOCKS5-прокси для исходящего трафика на `127.0.0.1:40000` |
| 12 | Готовность к Hysteria2 | UDP 443 открыт в файрволе, QUIC-буферы затюningы; сам Hysteria2-inbound разворачивается панелью в Xray-core ноды |

## ⚙️ Production-настройки

**Сеть / ядро** (`/etc/sysctl.d/99-remnanode.conf`)
- BBR congestion control + fair-queue qdisc
- Буферы сокетов 64 МБ, тюнинг `tcp_rmem`/`tcp_wmem` под high-BDP-каналы — в 4 раза выше
  требуемых Hysteria2/QUIC 16 МБ UDP-буферов
- Поднятые `somaxconn` / `netdev_max_backlog` / SYN backlog под пиковую нагрузку
- Таблица conntrack на тысячи одновременных проксированных соединений
- TCP fast open, MTU probing, отказ от slow start после простоя, keepalive под NAT
- Авто-перезагрузка через 10 с после kernel panic

**Лимиты ресурсов**
- `nofile` = 1 048 576 на каждом уровне: PAM `limits.d`, systemd `DefaultLimitNOFILE`, ulimit контейнера
- Поднятые `fs.file-max` и inotify-лимиты
- `vm.swappiness = 10`, `vm.vfs_cache_pressure = 50`

**Безопасность**
- UFW default-deny на вход; SSH-порты берутся из `sshd -T` и **rate-limited**, а не просто открыты
- fail2ban с бэкендом systemd journal (работает на минимальных сборках без rsyslog)
- `unattended-upgrades` для автоматических патчей безопасности
- Строгая валидация входных данных; `.env` и сертификаты — `chmod 600`
- Только TLS 1.2/1.3, современные шифры ECDHE/CHACHA20, session tickets выключены

**Эксплуатация**
- Полностью без участия человека: CLI-флаги, env-переменные или сохранённый `.env` — приоритет `флаги > env > .env > дефолты`
- Идемпотентность: повторный запуск безопасен (обновление/перепривязка ноды)
- journald персистентный, но с лимитом (200 МБ / 2 недели) — маленькие диски в безопасности
- Ротация логов Docker `json-file` (10 МБ × 3) + `live-restore`, плюс лимиты на каждый сервис
- logrotate для логов ноды; полный лог установки в `/var/log/remnanode-install.log`
- Preflight-проверки: версия ОС, архитектура, диск, RAM, DNS — понятные ошибки вместо поломанных установок

## 🛠 Требования

- **ОС:** Debian 12 или 13 (amd64/arm64), желательно чистая установка
- **Домен:** A-запись на IPv4 сервера
- **Доступ:** root (скрипт сам перезапустится через sudo)
- **Порты:** 22 (SSH), 80, 443 (TCP и UDP) свободны; API-порт ноды (по умолчанию `2222`)

## 🚀 Установка

Интерактивно (спросит только недостающее):

```bash
git clone https://github.com/ky0teru/autonode.git && cd autonode && sudo bash install.sh
```

Полностью без вопросов:

```bash
sudo ./install.sh \
  --domain node.example.com \
  --email me@example.com \
  --secret-key <SECRET_ИЗ_ПАНЕЛИ> \
  --validation cloudflare --cf-token <CLOUDFLARE_API_TOKEN> \
  --service gitea --yes
```

Работают и переменные окружения (`DOMAIN`, `EMAIL`, `SECRET_KEY`, `SERVICE_NAME`,
`VALIDATION`, `CF_TOKEN`, `NODE_PORT`, `WARP_PORT`), и файл `.env`, создаваемый при первом запуске.

## ⌨️ Параметры

| Флаг | Описание | По умолчанию |
| ---- | -------- | ------------ |
| `-d, --domain` | Домен ноды | *обязательный* |
| `-e, --email` | Email для регистрации сертификата | *обязательный* |
| `-s, --secret-key` | SECRET_KEY из панели Remnawave | *обязательный* |
| `-S, --service` | Имя декои-сервиса | случайный |
| `-n, --node-port` | API-порт ноды | `2222` |
| `-V, --validation` | `standalone` (TLS-ALPN-01) или `cloudflare` (DNS-01) | `standalone` |
| `-T, --cf-token` | Cloudflare API token (Zone:DNS:Edit) | — |
| `-w, --warp-port` | Порт WARP SOCKS5 | `40000` |
| `--no-tune` | Пропустить тюнинг ядра/сети | тюнинг включён |
| `--no-fail2ban` | Пропустить fail2ban | fail2ban включён |
| `--no-warp` | Не устанавливать WARP | WARP включён |
| `-y, --yes` | Ничего не спрашивать | — |
| `-f, --force` | Пропустить проверку Debian 12/13 | — |
| `-h, --help` | Справка | — |

## 📂 Структура

- `/opt/remnanode/` — compose и конфиг ноды
- `/opt/remnanode/nginx/` — конфиг Nginx и SSL-ключи
- `/opt/<service>/` — выбранный декои-сервис
- `/etc/sysctl.d/99-remnanode.conf` — сетевой тюнинг
- `/var/log/remnanode-install.log` — полный лог установки

## ⚠️ Используемые порты

| Порт | Сервис |
| ---- | ------ |
| 22   | SSH (rate-limited через UFW + fail2ban) |
| 80   | ACME / редирект на HTTPS |
| 443/tcp | Xray TCP (REALITY, камуфляж через nginx-сокет) |
| 443/udp | QUIC-inbounds через Xray (Hysteria2, управляется панелью) |
| 2222 | API ноды Remnanode (панель → нода) |
| 40000 | Cloudflare WARP SOCKS5 — **только localhost, не открывать** |

## 🌍 Другие языки

- [English](../README.md)
- [中文](README_CN.md) *(может быть устаревшим)*

## 📜 Лицензия

[MIT](../LICENSE)
