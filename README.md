# CineClaw

[![Docker Images](https://img.shields.io/badge/docker-GHCR-blue.svg?logo=docker)](https://github.com/orgs/cineclaw/packages)
[![Version](https://img.shields.io/badge/version-1.0.0-emerald.svg)](https://github.com/cineclaw/cineclaw/releases)
[![Organization](https://img.shields.io/badge/github-cineclaw-black.svg?logo=github)](https://github.com/cineclaw)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**CineClaw** — автономная self-hosted экосистема для домашнего кинотеатра. Объединяет быстрый полнотекстовый поиск по 11+ миллионам фильмов и сериалов (<5 мс), агрегацию крупнейших торрент-трекеров (RuTracker, RuTor, NNM-Club) с дедупликацией раздач и **мгновенное воспроизведение в 1 клик** через виртуальное FUSE-монтирование прямо в Jellyfin.

Все компоненты поставляются в виде готовых multi-arch контейнеров (`linux/amd64`, `linux/arm64`) на GitHub Container Registry. **Сборка из исходников не требуется.**

---

## ⚡ Быстрая установка (1 команда)

Для установки на любой **Linux-сервер или домашний NAS** (Synology DSM 7+, TrueNAS SCALE, unRAID, QNAP, Ubuntu, Debian и др.) **не требуется `git`, не требуется клонирование репозиториев и не требуются инструменты разработки**.

Запустите универсальный интерактивный установщик одной командой:

```bash
curl -fsSL https://raw.githubusercontent.com/cineclaw/cineclaw/main/install.sh | bash
```

*Либо пошагово в отдельной папке:*
```bash
mkdir -p cineclaw && cd cineclaw
curl -fsSL https://raw.githubusercontent.com/cineclaw/cineclaw/main/install.sh -o install.sh
chmod +x install.sh && ./install.sh
```

### Что делает установщик:
1. **Диагностика окружения**: проверяет наличие Docker и модуля ядра `/dev/fuse` (на Synology DSM автоматически активирует `fuse.ko`).
2. **Определение сети**: автоматически определяет локальный IP-адрес NAS в вашей домашней сети для корректного воспроизведения на ТВ и смартфонах.
3. **Минимальный опрос**: запрашивает только ключ [TMDB API](https://www.themoviedb.org/settings/api) (для постеров и метаданных) и путь к медиатеке.
4. **Готовые контейнеры**: скачивает официальные Docker-образы из `ghcr.io/cineclaw/*` без компиляции на хосте.
5. **Интеграция с Jellyfin**: запускает стек и автоматически настраивает вебхуки приоритетного FUSE-стриминга.

### Бесшумная (неинтерактивная) установка из короткого конфига

Для автоматического развёртывания (например, в скриптах автоматизации, Ansible или без ручного ввода) достаточно создать минимальный файл `cineclaw.env` всего с одной обязательной строкой:

```bash
# 1. Создать минимальный конфиг
cat << 'EOF' > cineclaw.env
TMDB_API_KEY=your_tmdb_api_key_here
DATA_DIR=/volume1/media/cineclaw
EOF

# 2. Запустить тихую установку (без диалогов и вопросов):
./install.sh -c cineclaw.env
```

*Либо в одну команду через curl с инлайн-ключом:*
```bash
curl -fsSL https://raw.githubusercontent.com/cineclaw/cineclaw/main/install.sh | TMDB_API_KEY="your_api_key" bash -s -- -y
```

#### Параметры короткого конфига (`cineclaw.env`):
| Переменная | Описание | Значение по умолчанию |
| :--- | :--- | :--- |
| `TMDB_API_KEY` | Ключ TMDB API ([получить бесплатно](https://www.themoviedb.org/settings/api)) | *рекомендуется для постеров и сезонов* |
| `DATA_DIR` | Каталог хранения индексов, постеров и FUSE-заглушек | `./data` |
| `NAS_IP` | Локальный IP-адрес или домен хоста | *авто-определение шлюза сети* |
| `TZ` | Часовой пояс контейнеров | `Europe/Moscow` |
| `RUTRACKER_USERNAME` / `PASSWORD` | Учётная запись RuTracker (опционально) | *RuTor работает без аккаунта* |
| `NNMCLUB_USERNAME` / `PASSWORD` | Учётная запись NNM-Club (опционально) | - |

---

## 🛠 Управление системой

Скрипт `install.sh` работает автономно (без `git`) и предоставляет команды управления:

```bash
./install.sh --status       # Проверка статуса здоровья всех 7 микросервисов и пинга
./install.sh --restart      # Перезапуск стека и обновление привязок вебхуков
./install.sh --update       # Обновление compose-файла, скриптов и образов до актуальных версий
./install.sh --stop         # Остановка всех контейнеров
./install.sh --uninstall    # Остановка контейнеров и удаление сети (данные в ./data сохраняются)
```

Также доступны стандартные команды Docker Compose:
```bash
docker compose ps
docker compose logs -f [service]
```

---

## 🩺 Диагностика и встроенный мониторинг

В веб-интерфейсе CineClaw доступен экран живой диагностики:
- **Клик по бейджу версии** `v1.0.0` в правом верхнем углу шапки или переход по адресу: `http://<NAS_IP>:3000/#diagnostic`.
- Экран в реальном времени параллельно опрашивает все микросервисы, выводя:
  - Версию каждого компонента (`SemVer`).
  - Время сетевого отклика (пинг в миллисекундах).
  - Статус индекса фильмов, кэша постеров и bbolt хранилища.
  - Кнопку «Скопировать отчёт» для быстрой отправки логов диагностики.

---

## 🏗 Архитектура системы

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

## 📦 Микросервисы экосистемы

| Репозиторий / Сервис | Стек | Порт | Роль в системе |
| :--- | :--- | :--- | :--- |
| [**`cineclaw/frontend`**](https://github.com/cineclaw/frontend) | React 19, Vite, PWA, Nginx | `3000` | Мобильный cinema-интерфейс, кураторские полки, PWA и диагностика |
| [**`cineclaw/imdb-indexer`**](https://github.com/cineclaw/imdb-indexer) | Rust 2021, Axum, Tantivy, redb | `8090` | Локальный поиск по 11M фильмов (<5мс), кэш постеров и метаданные TMDB |
| [**`cineclaw/tracker-proxy`**](https://github.com/cineclaw/tracker-proxy) | Go 1.25, bbolt, goquery | `9118` | Агрегация RuTracker, RuTor, NNM-Club, дедупликация и монтирование |
| **`jellyfin`** | .NET 8 / C# (официальный `10.11.11`) | `8096` | Транскодирование, каталог библиотеки и медиаплеер |
| **`tiramisu`** | Go FUSE / GoStorm (официальный `v1.9.59`) | `9080`, `8092` | Виртуальная файловая система FUSE для мгновенного sequential-стриминга |
| **`flaresolverr`** | Node.js / Chromium (`v3.5.0`) | `8191` | Автоматический обход Cloudflare Turnstile для RuTracker |
| **`lodestarr`** | Rust (`master`) | `3420` | Фоновый торрент-загрузчик |

---

## 💾 Требования к FUSE на NAS

Для стриминга торрентов без предварительного скачивания сервис `tiramisu` использует модуль ядра Linux `/dev/fuse`.
- Установщик `install.sh` автоматически проверяет наличие `/dev/fuse`.
- На **Synology DSM 7+** скрипт автоматически выполняет `insmod /lib/modules/fuse.ko`.
- На обычных дистрибутивах Linux выполняется `modprobe fuse`.
- Каталог `$DATA_DIR/media/virtual` монтируется с параметром `rshared`/`rslave`, что обеспечивает мгновенную видимость виртуальных файлов в контейнере Jellyfin.

---

## 💻 Для разработчиков (`Makefile` и сборка из исходников)

Если вы хотите модифицировать код микросервисов или собрать образы локально с постоянным кешированием BuildKit:

```bash
# Клонирование репозитория со всеми подмодулями
git clone --recursive https://github.com/cineclaw/cineclaw.git
cd cineclaw

# Просмотр доступных команд автоматизации
make help

# Быстрая локальная сборка с BuildKit-кешем компиляции:
make build-local

# Multi-arch сборка и публикация в GHCR (amd64 + arm64):
make publish-all VERSION=1.0.0

# Локальный запуск стека с hot-reload разработкой:
docker compose -f docker-compose.yml -f docker-compose.dev.yml up --build
```

---

## Лицензия
Проект распространяется под лицензией [MIT](LICENSE).
