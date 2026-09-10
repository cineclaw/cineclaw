# CineClaw (v1) — Agent Guide (`AGENTS.md`)

> **Note for AI Agents**: This file is your operational entry point. Keep it token-efficient (~150 lines). For subsystem-specific deep dives, refer to the documents linked in the [Documentation Map](#6-documentation-map) below instead of loading everything at once.

---

## 1. Project Vision & Mental Model
**CineClaw** is an evolving, extensible self-hosted home cinema and media platform. It bridges metadata discovery, torrent indexing, transparent de-duplication, and on-demand streaming.
- **Current Core**: Fast IMDb Tantivy search, multi-tracker aggregator (RuTracker, RuTor, NNM-Club), intelligent cross-tracker deduplication, modern React cinema UI, and **instant one-click streaming** via Tiramisu FUSE torrent mounting directly into Jellyfin.
- **Active Roadmap**: Intelligent cache retention/cleanup, subtitle synchronization, and web-player deep linking.

---

## 2. Microservice & Port Topology

| Service | Stack | Port | Execution Mode | Role |
| :--- | :--- | :--- | :--- | :--- |
| **`imdb-indexer`** | Rust 2021 (Axum, Tantivy, redb) | `8090` | Docker / GHCR (`ghcr.io/cineclaw/imdb-indexer`) | IMDb title search, TMDB seasons, poster proxy |
| **`tracker-proxy`** | Go 1.25 (bbolt, modernc.org/sqlite, goquery) | `9118` | Docker / GHCR (`ghcr.io/cineclaw/tracker-proxy`) | Multi-tracker scraper, dedup, TorrServer orchestrator, SQLite playback store |
| **`flaresolverr`** | Node/Chromium | `8191` | Docker Container (`v3.5.0`) | Cloudflare Turnstile clearance for RuTracker |
| **`frontend`** | React 19, Vite 8, RTK Query, Tailwind | `3000` | Docker / GHCR (`ghcr.io/cineclaw/frontend`) | Dark cinema UI, client-side filters, 1-click playback, external player launcher |
| **`lodestarr`** | Rust | `3420` | Docker Container (`master`) | Torrent downloader daemon |
| **`torrserver`** | Go (MatriX, GStreamer remuxing) | `8092` | Docker Container (`yourok/torrserver:latest`) | On-demand BitTorrent streaming engine, HLS remuxing, subtitle delivery |
| **`cineclaw-ai`** | Go 1.25 (Genkit, bbolt, OpenRouter) | `9120` | Docker / GHCR (`ghcr.io/cineclaw/cineclaw-ai`) | Critic aggregation (RT, Metacritic, IMDb), AI consensus summarizer |

---

## 3. Operations Cheatsheet

### Multi-Arch Building & GHCR Publishing (`Makefile`)
```bash
# Build and publish all 3 microservices to GHCR (amd64 + arm64)
make publish-all VERSION=1.0.0

# Build and publish individual service
make publish-indexer VERSION=1.0.0
make publish-tracker VERSION=1.0.0
make publish-frontend VERSION=1.0.0

# Fast local builds for host architecture
make build-local
```

### Local Dev Overrides
```bash
# Start with local source builds
docker compose -f docker-compose.yml -f docker-compose.dev.yml up --build
```

### Frontend (`frontend` - Vite / React 19)
```bash
cd frontend
# Start local dev server (port 3000)
npm run dev

# Check TypeScript & production build
npm run build
```

### Torrent Streaming Engine (`torrserver`)
```bash
# Restart TorrServer container
docker compose restart torrserver

# View streaming & transcode logs
docker compose logs -f torrserver
```

### Universal Linux / NAS Installer (`install.sh`)
```bash
# Interactive deployment on Linux / NAS (Synology, TrueNAS, unRAID, Ubuntu/Debian)
./install.sh

# Unattended mode (using .env or smart defaults)
./install.sh --non-interactive

# System diagnostics & health check
./install.sh --status

# Restart stack & refresh webhooks
./install.sh --restart
```

---

## 4. Critical Invariants & Rules (Strictly Enforced)

1. **NEVER delete `./data/`**:
   - `data/tracker-proxy/cache/cache.db` stores bbolt caches (`imdb_cache`, `topic_hashes`).
   - `data/tracker-proxy/config.yaml` contains tracker credentials.
   - `data/fdb/` contains the IMDb Tantivy search index.
   - `data/media/` contains source JSON stubs and FUSE virtual mount points.
2. **Trackers Rate Limiting**:
   - NNM-Club throws Cloudflare `503` if hit with $>2$ concurrent requests. Always enforce semaphores and $\ge 75$ms pacing.
   - RuTracker requires FlareSolverr session tokens (`bb_session`).
3. **Cross-Tracker Deduplication**:
   - Size clustering tolerance is strictly $\pm 0.105\text{ GB}$ ($\pm 0.1\text{ GB}$ rounded to 1 decimal place).
   - Only merge when verified by InfoHash comparison.
   - Combined releases must merge seeds ($\sum \text{seeds}$) and inject all official announce URLs into the synthesized magnet.
4. **TorrServer & Media Database Invariants**:
   - Media playback state is persisted in pure-Go SQLite (`data/tracker-proxy/cineclaw.db`).
   - External player stream links direct to port `8092` (`http://<host>:8092/stream?link=<hash>&index=<idx>&play`).
   - Browser HLS streaming utilizes GStreamer zero-transcode remuxing (`/torr/gst/<hash>/master.m3u8?index=<idx>&audio=<audio>`).
5. **Context Window Hygiene**:
   - Do not dump hundreds of lines of code or raw HTML into user messages. Keep responses concise and focused.
6. **Documentation Maintenance (Strict Requirement)**:
   - Any agent modifying architecture, adding services/ports, changing scraper logic, updating endpoints, or altering UI features **MUST** immediately update `AGENTS.md` and the corresponding documents in `docs/`. Never leave documentation stale or out of sync with the codebase.

---

## 5. Architectural Roadmap
- **Phase 1 (Complete)**: Discovery (IMDb indexer + TMDB seasons), multi-tracker aggregation, cross-tracker dedup, multi-tracker magnet injection, client-side filtering.
- **Phase 3 (Complete)**: **Multi-Version Video & Media Retention**: Multi-source video versioning (Jellyfin movie version grouping `<Folder> - <Version>.mkv`, episode version merging via `POST /Videos/MergeVersions`), conflict resolution dialog (Replace vs Add as Version), clean dual-sync unmount pipeline (`/api/stream/unmount`, `/torrents/unmount`), Jellyfin `ItemDeleted` webhook handler, background orphaned stubs reconciler/GC, UI mount status indicator with versions & seasons.
- **Phase 4 (Complete)**: **Mobile-First Cinema Redesign, Rich Metadata, TMDB Shelves, Pagination, PWA & TV Series Creators**: Ergonomic thumb-zone bottom search dock (`fixed bottom-0`, safe-area insets), 400ms typing debounce + instant Enter, bottom-up search results (`flex-col-reverse` with Rank 1 nearest thumb), fluid Framer-Motion animations (top-down card cascade, clean results replacement with `AnimatePresence`, and mobile screen push/slide transitions), dedicated full-screen mobile screen view for movie details with sticky `< Назад` bar and browser back-gesture handling, unified single-scroll layout, rich TMDB metadata (synopsis, crew badges, swipeable cast avatars, in-app YouTube trailer player), **TV Series Creators & Showrunner Extraction** (`created_by` array, `aggregate_credits` episodic directors and writers sorted by episode count, deduplicating creators from executive producers to surface key stars like Jon Hamm, and dynamic TV vs Movie crew priorities), mobile bottom-sheet filter drawer, **In-App Person Card & Filmography** (`/api/person/:id`, `/api/tmdb/:type/:id/movie`, sort by «Новые»/«Лучшие», cast/crew tabs, and 1-click drill-down into Cine-Claw movie screens), **Curated TMDB Home Shelves with Shelf Pagination & Full View** (`/api/feeds`, `GET /api/feeds/:shelf_id?page=N`, «Ещё →» buttons, dedicated `ShelfModal` screen with multi-page grid and «Загрузить ещё (+20)», seamless browser history stack navigation, and removal of redundant static quick-search chips), and **Full PWA Experience & Unified Cinema Theme** (`manifest.webmanifest`, standalone mode, precision-bypass Service Worker `sw.js`, custom vector CineClaw brand icon suite [512x512, 192x192, maskable, apple-touch-icon 180x180], `viewport-fit=cover`, notch/Dynamic Island safe-area integration `env(safe-area-inset-top)`, and strictly unified `#07090e` obsidian cinema background eliminating all seams and overscroll flashes).
- **Phase 5 (Complete)**: **Universal Interactive Linux / NAS Installer & Full Containerization**: Universal, battle-tested interactive installer script (`install.sh`) supporting Synology DSM, TrueNAS, unRAID, QNAP, and standard Linux distributions. Interactive strictly where user input is required (TMDB API key, NAS IP with multi-NIC auto-detection, persistent data directory, optional tracker credentials). Automatic pre-flight diagnostics (OS detection, Docker daemon, compose v1/v2 compatibility, kernel `/dev/fuse` and module loader `insmod /lib/modules/fuse.ko`), directory scaffolding with UID-safe `chmod 777` permissions, multi-stage production Docker containers for `frontend` (Nginx reverse proxy + PWA) and `imdb-indexer` (Rust release runtime), unified Compose orchestration on `cineclaw-net`, automatic Jellyfin webhook provisioning (`setup-jellyfin-webhook.sh`), and unified management CLI (`--status`, `--restart`, `--stop`, `--update`, `--uninstall`).
- **Phase 6 (Complete)**: **Edge Gateway Security & Persistent Web UI Authentication**: Reverse-proxy edge authorization on port 3000 (`auth_request /api/auth/verify`), timing-safe HMAC-SHA256 session token generation and verification (`tracker-proxy/pkg/auth`), 3-way credential parsing (HttpOnly Cookie `cineclaw_session`, `Authorization: Bearer <token>`, `Authorization: Basic <base64>`), sleek Obsidian cinema login modal with 30-day "Remember me" persistence, profile status & logout in header, and automated credentials provisioning via installer & `.env` (`AUTH_ENABLED`, `AUTH_USERNAME`, `AUTH_PASSWORD`, `AUTH_SECRET`).
- **Phase 8 (Active Roadmap / Complete in Core)**: **AI Critics Aggregator & Cinema Consultant Agent**: Dedicated microservice `cineclaw-ai` (`:9120`) powered by Go 1.25, Genkit, and OpenRouter (`google/gemini-2.5-flash`). Aggregates Rotten Tomatoes %, Metascore, IMDb user rating/votes, and awards via OMDb and TMDB. Generates structured AI consensus (verdict, tone, pros/cons, target audience) with instant bbolt persistent caching. Seamless Nginx reverse-proxy on port 3000 (`/api/ai/`) and mobile-first Obsidian cinema cards in movie view.
- **Phase 9 (Complete)**: **Catalog Discovery Hub, Tracker Swarm Hotlist, 4K UHD, Specialized Hubs & Clean Video Search**: High-performance home discovery hub replacing eager loading of multiple shelves with on-demand interactive catalog launcher (`CatalogTilesGrid.tsx`). Proactive BitTorrent swarm hotlist aggregation (`tracker-proxy/pkg/hotlist`, `GET /torrents/hotlist?type=movie|tv|anime|doc&quality=4k`) scraping RuTor/RuTracker seed-sorted swarms across 10 pages per category with strict $\le 2$ parallel request semaphores, matching against Tantivy index (<1ms) and displaying live seed counts (`🌱 {seeds} сидов`) with instant 1-click playback. Dedicated **«4K UHD Кинозал»** hub with pure 2160p HDR/DV filters and quality toggle pill `[ Все качества | ✨ Только 4K UHD ]`. Specialized **«Аниме & Мультипликация»** and **«Документальное кино»** hubs. Strict video-only category whitelists on RuTracker & NNM-Club with non-video noise purge on RuTor (eliminating audiobooks, music/FLAC, PC games, cracks), and explicit exclusion of Asian doramas and Turkish series. Curated streaming network hubs (Apple TV+ `with_networks=2552`, HBO Max `49`, Netflix `213`, Amazon Prime `1024`) with strict soap-opera/news filtering (`without_genres=10763,10764,10766,10767` and `vote_count.gte=50`). Universal multi-criteria discovery engine (`GET /api/catalog/discover`) supporting interactive Year, Genre, Country, and Rating chip filters, plus explicit, zero-leakage `[ 🎬 Фильмы | 📺 Сериалы ]` toggle across all views.
- **Phase 10 (Complete)**: **Embedded Cinema Video Player & Streaming**: Native custom cinema player (`CinemaPlayerModal.tsx`) directly inside CineClaw dark obsidian interface using `Hls.js` and Apple native HLS. Dynamic audio track switching (Russian dub, line, original AC3/DTS/AAC), WebVTT subtitle track selector, TV series episodes playlist drawer with auto-countdown next episode banner (`[ Следующая серия ▶ ]`), speed controller (0.5x-2x), PiP, fullscreen, mobile double-tap seek gestures (±10s) and desktop cinema keyboard shortcuts.
- **Phase 11 (Complete)**: **Standalone Cinema Interface, 1-Click Quality Streaming, TV Series Episodes Browser & Resume Shelf**: Replaced raw torrent lists with two primary action buttons on titles: **«Смотреть»** and **«Добавить»** with an instant quality selector (`4K UHD`, `1080p FHD`, `720p HD`, `SD`) and live library mount status (`● В медиатеке`). Automatic intelligent release selection via seed-dominant scoring heuristic (`scoreTorrent` prioritizing seeds, penalizing dead swarms, with dubbing as a minor tiebreaker, and complete season packs). Top home shelf **«Продолжить просмотр» (Continue Watching)** with accurate runtime percentage calculation, series episode deduplication (single latest episode per show), «Далее» Next Up badge and filter tabs (`[ Все | В процессе | Далее ]`). Interactive Obsidian cinema resume prompt modal upon playback («Продолжить просмотр? Остановлено на: XX:XX» with `[ ▶ Продолжить с XX:XX ]` and `[ С начала ]`). TV Series experience with interactive seasons selector, 16:9 episode cards with TMDB still backdrops, Russian plot synopses, air dates, progress bars, and 1-click episode play. Granular torrent list preserved under collapsible `<details>` accordion at the bottom for power users.
- **Phase 12 (Complete)**: **Native TorrServer MatriX Streaming & Pure-Go SQLite Playback Engine**: Complete migration away from Jellyfin and Tiramisu FUSE. Native BitTorrent streaming via TorrServer MatriX (`yourok/torrserver:latest` on port `8092`) with GStreamer zero-transcode remuxing (H.264/H.265 passthrough + AAC audio transcoding). Embedded cinema web player with Hls.js, dynamic audio track switching, WebVTT subtitles, and external player launcher (VLC `vlc://`, IINA `iina://`, Infuse `infuse://`, and direct stream link copy). Pure-Go SQLite (`modernc.org/sqlite`) media database storing watch progress, duration, percentage, series episode tracking, Next Up recommendations, and deduplicated «Продолжить просмотр» home shelf.
- **Phase 7 (Active Roadmap)**: Subtitle synchronization, intelligent cache retention.

---

## 6. Documentation Map

When working on a specific subsystem, load only the relevant document:

- [docs/architecture.md](docs/architecture.md) — System data flow, microservices sequence, and extension slots.
- [docs/roadmap.md](docs/roadmap.md) — Detailed plans for Jellyfin, Tiramisu FUSE torrent mounting, and streaming pipelines.
- [docs/tracker-proxy.md](docs/tracker-proxy.md) — Scraping protocols, CP1251, FlareSolverr, bbolt cache, dedup algorithm, FUSE mounter.
- [docs/imdb-indexer.md](docs/imdb-indexer.md) — Tantivy indexing, redb streaming, TMDB seasons endpoint, poster proxy.
- [docs/frontend.md](docs/frontend.md) — React 19 + RTK Query, client-side season/resolution parsing, cache invalidation, UI components.
- [docs/cineclaw-ai.md](docs/cineclaw-ai.md) — Critic scores aggregation (RT, Metascore), bbolt cache, and OpenRouter LLM consensus.
