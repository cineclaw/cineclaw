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
| **`tracker-proxy`** | Go 1.25 (bbolt, goquery) | `9118` | Docker / GHCR (`ghcr.io/cineclaw/tracker-proxy`) | Multi-tracker scraper, dedup, FUSE mount orchestrator |
| **`flaresolverr`** | Node/Chromium | `8191` | Docker Container (`v3.5.0`) | Cloudflare Turnstile clearance for RuTracker |
| **`frontend`** | React 19, Vite 8, RTK Query, Tailwind | `3000` | Docker / GHCR (`ghcr.io/cineclaw/frontend`) | Dark cinema UI, client-side filters, 1-click playback |
| **`lodestarr`** | Rust | `3420` | Docker Container (`master`) | Torrent downloader daemon |
| **`jellyfin`** | C# / .NET | `8096` | Docker Container (`10.11.11`) | Media server & playback target |
| **`tiramisu`** | Go FUSE / GoStorm | `9080`, `8092` | Docker Container (`v1.9.59`) | FUSE virtual torrent streaming engine |

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

### Media Server & FUSE Streaming (`jellyfin` & `tiramisu`)
```bash
# Restart streaming stack
docker compose restart tiramisu jellyfin

# View streaming & mount logs
docker compose logs -f tiramisu
docker compose logs -f jellyfin

# Auto-install and configure Jellyfin -> Tiramisu Priority Mode Webhook
./scripts/setup-jellyfin-webhook.sh
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
4. **Tiramisu FUSE Invariants**:
   - The `.mkv` JSON stub URL parameter **MUST** include `link=<40-char-hash>&index=<file-id>` for Tiramisu's VFS parser.
   - If `tiramisu` container is restarted, `jellyfin` **MUST** also be restarted (`docker compose restart jellyfin`) to reconnect the shared mount.
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
- **Phase 6 (Active Roadmap)**: Subtitle synchronization, web-player deep linking, intelligent cache retention.

---

## 6. Documentation Map

When working on a specific subsystem, load only the relevant document:

- [docs/architecture.md](docs/architecture.md) — System data flow, microservices sequence, and extension slots.
- [docs/roadmap.md](docs/roadmap.md) — Detailed plans for Jellyfin, Tiramisu FUSE torrent mounting, and streaming pipelines.
- [docs/tracker-proxy.md](docs/tracker-proxy.md) — Scraping protocols, CP1251, FlareSolverr, bbolt cache, dedup algorithm, FUSE mounter.
- [docs/imdb-indexer.md](docs/imdb-indexer.md) — Tantivy indexing, redb streaming, TMDB seasons endpoint, poster proxy.
- [docs/frontend.md](docs/frontend.md) — React 19 + RTK Query, client-side season/resolution parsing, cache invalidation, UI components.
