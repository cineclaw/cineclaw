# CineClaw

[![Docker Images](https://img.shields.io/badge/docker-GHCR-blue.svg?logo=docker)](https://github.com/orgs/cineclaw/packages)
[![Version](https://img.shields.io/badge/version-1.0.0-emerald.svg)](https://github.com/cineclaw/cineclaw/releases)
[![Organization](https://img.shields.io/badge/github-cineclaw-black.svg?logo=github)](https://github.com/cineclaw)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**CineClaw** — автономная self-hosted экосистема для домашнего кинотеатра. Объединяет быстрый полнотекстовый поиск по 11+ миллионам фильмов и сериалов, агрегацию крупнейших торрент-трекеров с дедупликацией раздач и **мгновенное воспроизведение в 1 клик** через виртуальное FUSE-монтирование прямо в Jellyfin.

Все компоненты поставляются в виде готовых многоплатформенных Docker-контейнеров (`linux/amd64`, `linux/arm64`), не требуя локальной компиляции на серверах и NAS.

---

## Архитектура системы

```mermaid
graph TD
    Client["Клиент (Браузер, ТВ, Смартфон PWA)"]
    
    subgraph CineClaw_Stack ["CineClaw Docker Bridge Network (cineclaw-net)"]
        FE["frontend (:3000)<br/>React 19 PWA & Nginx Gateway"]
        Idx["imdb-indexer (:8090)<br/>Tantivy Search, TMDB Cache & Feeds"]
        Prx["tracker-proxy (:9118)<br/>Агрегатор трекеров & FUSE-оркестратор"]
        Flare["flaresolverr (:8191)<br/>Обход Cloudflare Turnstile"]
        Trm["tiramisu (:9080, :8092)<br/>Виртуальный торрент-стриминг FUSE"]
        Jlf["jellyfin (:8096)<br/>Транскодирование и медиасервер"]
        Lds["lodestarr (:3420)<br/>Торрент-клиент демон"]
    end

    Client -->|Web UI / PWA :3000| FE
    Client -->|Воспроизведение :8096| Jlf
    
    FE -->|/search, /poster, /feeds, /person| Idx
    FE -->|/torrents, /stream| Prx
    Prx -->|RuTracker| Flare
    Prx -->|VFS JSON stubs| Trm
    Trm -->|/media/virtual (rshared)| Jlf
    Jlf -->|Priority Mode Webhook| Trm
    Jlf -->|ItemDeleted Webhook| Prx
```

---

## Микросервисы экосистемы

| Репозиторий / Сервис | Стек | Порт | Роль в системе |
| :--- | :--- | :--- | :--- |
| [**`cineclaw/frontend`**](https://github.com/cineclaw/frontend) | React 19, Vite, PWA, Nginx | `3000` | Мобильный cinema-интерфейс, кураторские полки, PWA и диагностика |
| [**`cineclaw/imdb-indexer`**](https://github.com/cineclaw/imdb-indexer) | Rust 2021, Axum, Tantivy, redb | `8090` | Локальный поиск по 11M фильмов (<5мс), кэш постеров и метаданные TMDB |
| [**`cineclaw/tracker-proxy`**](https://github.com/cineclaw/tracker-proxy) | Go 1.25, bbolt, goquery | `9118` | Агрегация RuTracker, RuTor, NNM-Club, дедупликация и монтирование |
| **`jellyfin`** | .NET 8 / C# (с ffprobe-патчем) | `8096` | Транскодирование, каталог библиотеки и медиаплеер |
| **`tiramisu`** | Go FUSE / GoStorm | `9080`, `8092` | Виртуальная файловая система FUSE для мгновенного sequential-стриминга |
| **`flaresolverr`** | Node.js / Chromium | `8191` | Автоматический обход Cloudflare Turnstile для RuTracker |
| **`lodestarr`** | Rust | `3420` | Фоновый торрент-загрузчик |

---

## Быстрый старт на Linux и NAS

Универсальный интерактивный установщик автоматически диагностирует систему, запрашивает только минимально необходимые данные (TMDB API-ключ и путь к хранилищу), скачивает официальные готовые образы и настраивает вебхуки.

Поддерживаются: **Synology DSM 7+**, **TrueNAS SCALE**, **unRAID**, **QNAP**, **Ubuntu / Debian**, **Arch**, **RHEL / Rocky**.

```bash
# 1. Клонировать репозиторий с подмодулями
git clone --recursive https://github.com/cineclaw/cineclaw.git
cd cineclaw

# 2. Запустить интерактивный установщик
./install.sh
```

### Автоматический (unattended) запуск
Если файл `.env` уже заполнен или требуются настройки по умолчанию:
```bash
./install.sh --non-interactive
```

---

## Управление системой

Скрипт `install.sh` предоставляет быстрый интерфейс управления стеком:

```bash
./install.sh --status       # Проверка статуса здоровья всех 7 микросервисов
./install.sh --restart      # Перезапуск стека и обновление привязок вебхуков
./install.sh --update       # Обновление git-кода и скачивание свежих образов
./install.sh --stop         # Остановка всех контейнеров
./install.sh --uninstall    # Остановка контейнеров и удаление сети (данные в ./data сохраняются)
```

Также доступны стандартные команды Docker Compose:
```bash
docker compose ps
docker compose logs -f [service]
```

---

## Диагностика и встроенный мониторинг

В веб-интерфейсе CineClaw доступен экран диагностики:
- **Клик по бейджу версии** `v1.0.0` в правом верхнем углу шапки или переход по адресу: `http://<NAS_IP>:3000/#diagnostic`.
- Экран в реальном времени параллельно опрашивает все микросервисы, выводя:
  - Версию каждого компонента (`SemVer`).
  - Время сетевого отклика (пинг в миллисекундах).
  - Статус индекса фильмов, кэша постеров и bbolt хранилища.
  - Кнопку «Скопировать отчёт» для отправки логов диагностики.

---

## Требования к FUSE на NAS

Для стриминга торрентов без предварительного скачивания сервис `tiramisu` использует модуль ядра Linux `/dev/fuse`.
- Установщик `install.sh` автоматически проверяет наличие `/dev/fuse`.
- На **Synology DSM 7+** скрипт автоматически выполняет `insmod /lib/modules/fuse.ko`.
- На обычных дистрибутивах Linux выполняется `modprobe fuse`.
- Каталог `$DATA_DIR/media/virtual` монтируется с параметром `rshared`/`rslave`, что обеспечивает видимость виртуальных файлов в контейнере Jellyfin без задержек.

---

## Разработка из исходников (Local Dev)

Если вы хотите вносить изменения в исходный код микросервисов:

```bash
# Сборка из локальных исходников через dev-оверлей
docker compose -f docker-compose.yml -f docker-compose.dev.yml up --build

# Локальный запуск фронтенда с HMR:
cd frontend && npm run dev

# Локальный запуск поискового индексатора:
cd imdb-indexer && cargo run --release

# Локальный запуск прокси трекеров:
cd tracker-proxy && go run ./cmd/server
```

---

## Лицензия
Проект распространяется под лицензией [MIT](LICENSE).
