# 🚀 Remnanode Production Installer (Debian 12/13)

Автоматический идемпотентный Bash-установщик ноды **Remnawave**: Nginx-камуфляж,
декои-сайт, продвинутая сетевая настройка и исходящий трафик через Cloudflare WARP.
Заточен под **Debian 12 (bookworm) и 13 (trixie)**.

При переданных флагах работает полностью без участия человека; повторный запуск
безопасен (обновляет и перепривязывает ноду на месте).

## 📋 Что делает скрипт

| Шаг | Что | Детали |
| --- | --- | ------ |
| 1  | Базовая система | Необходимые пакеты, синхронизация времени по NTP, `unattended-upgrades` (авто-обновления безопасности) |
| 2  | Тюнинг ядра и сети | **BBR + fq**, буферы TCP, backlog'и, conntrack, `nofile` до 1M (PAM + systemd), персистентный journald с лимитом |
| 3  | fail2ban | Защита SSH от брутфорса (бэкенд systemd journal), ваш текущий IP добавляется в whitelist автоматически |
| 4  | Docker | Официальный репозиторий Docker (с фолбэком на bookworm для новых Debian), Compose-плагин, ротация логов `json-file` + `live-restore` в `daemon.json` |
| 5  | Файрвол | UFW: SSH-порты определяются автоматически и **rate-limited**, открыты 80/443 и API-порт ноды |
| 6  | SSL | acme.sh **TLS-ALPN-01 на порту 443** (Let's Encrypt) или **Cloudflare DNS-01** (certbot, без открытых портов). Существующие сертификаты certbot/acme.sh подхватываются |
| 7  | Декои-сервис | Один из 12 веб-сервисов под камуфляжем (случайный или `--service`) |
| 8  | Nginx-прокси | TLS 1.2/1.3, unix-сокет + PROXY protocol (реальные IP клиентов через `$proxy_protocol_addr`), XHTTP-location |
| 9  | Remnanode | Ядро Xray, ulimit `nofile`, ротация логов |
| 10 | Продление | cron acme.sh или таймер certbot + deploy-hook; при продлении нода кратко останавливается, освобождая порт 443, затем сертификаты синкаются, стек перезапускается |
| 11 | WARP | Cloudflare WARP в режиме SOCKS5-прокси на `127.0.0.1:40000` (исходящий трафик пользователей) |

## 🆚 Отличия от старой версии

- ❌ **gRPC-транспорт удалён полностью** (остался только XHTTP)
- 🤖 **Полная автоматизация**: CLI-флаги + переменные окружения + `.env`, интерактивные вопросы не нужны
- 🐧 **Строгая поддержка Debian 12/13** (остальные ОС отклоняются; фолбэк репозиториев на bookworm)
- 🔧 **Production-настройки**: BBR+fq, буферы, conntrack, лимиты FD, лимиты journald, ротация логов Docker, авто-обновления, fail2ban, rate-limit UFW
- 🩹 **Исправлено**: челлендж TLS-ALPN перенесён с порта 8443 (ACME-серверы ходят только на 443 — продление было сломано) на 443 с хуками остановки/запуска ноды; вариант ZeroSSL убран (требует EAB и не работал); реальные IP клиентов теперь через `$proxy_protocol_addr`

## 🛠 Требования

- **ОС:** Debian 12 или 13 (amd64/arm64), желательно чистая установка
- **Домен:** A-запись, указывающая на IPv4 сервера
- **Доступ:** root (скрипт сам перезапустится через sudo)
- **Порты:** 22 (SSH), 80, 443 свободны; API-порт ноды (по умолчанию `2222`)

## 🚀 Установка

Интерактивно (спросит только недостающее):

```bash
git clone https://github.com/x1roko/node-setup.git && cd node-setup && sudo ./install.sh
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
`VALIDATION`, `CF_TOKEN`, `NODE_PORT`, `XHTTP_PATH`, `WARP_PORT`), и файл `.env`,
создаваемый рядом со скриптом при первом запуске. Приоритет: **флаги > окружение > .env > дефолты**.

## ⌨️ Параметры

| Флаг | Описание | По умолчанию |
| ---- | -------- | ------------ |
| `-d, --domain` | Домен ноды | *обязательный* |
| `-e, --email` | Email для регистрации сертификата | *обязательный* |
| `-s, --secret-key` | SECRET_KEY из панели Remnawave | *обязательный* |
| `-S, --service` | Имя декои-сервиса | случайный |
| `-p, --xhttp-path` | XHTTP location path | `/xhttppath/` |
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
- `/opt/remnanode/nginx/` — конфиг Nginx и SSL-ключи (`fullchain.pem`, `privkey.key`)
- `/opt/<service>/` — выбранный декои-сервис
- `/etc/sysctl.d/99-remnanode.conf` — сетевой тюнинг
- `/var/log/remnanode-install.log` — полный лог установки

## ⚠️ Используемые порты

| Порт | Сервис |
| ---- | ------ |
| 22   | SSH (rate-limited через UFW + fail2ban) |
| 80   | ACME / редирект на HTTPS |
| 443  | Xray (REALITY, камуфляж через nginx-сокет) |
| 2222 | API ноды Remnanode (панель → нода) |
| 40000 | Cloudflare WARP SOCKS5 — **только localhost, не открывать** |

## 📜 Лицензия

[MIT](../LICENSE)
