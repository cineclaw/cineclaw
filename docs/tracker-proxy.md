# Tracker Proxy — Subsystem Documentation

## 1. Overview
`tracker-proxy` is a high-performance Go microservice running inside Docker (port `9118`). It concurrently scrapes Russian BitTorrent trackers, resolves Cloudflare Turnstile challenges, caches metadata in bbolt, and performs cross-tracker deduplication with multi-tracker magnet synthesis.

---

## 2. Directory & Package Structure

```
tracker-proxy/
├── cmd/
│   └── server/
│       └── main.go           # Entry point, HTTP routes, graceful shutdown
├── pkg/
│   ├── aggregator/
│   │   ├── aggregator.go     # Concurrent scraper coordinator & cache dispatcher
│   │   └── dedup.go          # Size clustering, InfoHash resolution, magnet synthesis
│   ├── cache/
│   │   └── cache.go          # bbolt database wrapper (imdb_cache & topic_hashes buckets)
│   ├── config/
│   │   └── config.go         # YAML configuration loader
│   ├── db/
│   │   └── sqlite.go         # Pure-Go SQLite database wrapper (modernc.org/sqlite, WAL mode)
│   ├── flaresolverr/
│   │   └── client.go         # FlareSolverr v1 JSON API client
│   ├── playback/
│   │   ├── store.go          # Watch progress CRUD, resume shelf & favorites
│   │   └── nextup.go         # Next Up episode calculator against TMDB
│   ├── stream/
│   │   ├── service.go        # TorrStreamService orchestrator
│   │   └── torrclient.go     # TorrServer MatriX JSON API & GStreamer client
│   └── trackers/
│       ├── nnmclub/          # NNM-Club scraper (Windows-1251, semaphore rate-limiting)
│       ├── rutor/            # RuTor scraper (direct HTML parsing, inline magnet/hash)
│       └── rutracker/        # RuTracker scraper (FlareSolverr session, topic parsing)
├── config.example.yaml
├── Dockerfile
└── go.mod
```

---

## 3. Tracker Scraper Invariants

### RuTor (`pkg/trackers/rutor`)
- **Direct HTTP**: Does not require authentication or FlareSolverr.
- **Encoding**: UTF-8.
- **InfoHash**: Extracted directly from the magnet URI found in search result rows.
- **Search Query & Sorting**: Uses `/search/0/0/0/2/<query>` to strictly sort search results by seed count descending (`sort=2`), ensuring the healthiest swarms are prioritized over low-seeded recent repacks (`sort=0`).
- **Non-Video Clean Filtering**: Strips out non-video noise via regex pattern: `(?i)(\b(flac|lossless|alac|ape|soundtrack|ost|audiobook|аудиокнига|repack by|gog|pc game|crack|patch|pdf|fb2|epub|djvu)\b|\[(flac|mp3|lossless|pc|iso|android|ios)\])`.

### RuTracker (`pkg/trackers/rutracker`)
- **Protection**: Protected by Cloudflare Turnstile.
- **Authentication**: Uses FlareSolverr (`http://flaresolverr:8191/v1`) with `request.post` to solve Turnstile and authenticate with RuTracker login/password.
- **Session**: Caches and reuses the `bb_session` cookie across requests until expired.
- **InfoHash Resolution**: Search results contain Topic IDs but no InfoHash. The scraper fetches the topic page to extract the InfoHash, caching the result in bbolt's `topic_hashes` bucket.
- **Strict Video Forum Whitelist**: Filters searches by video-only subforums based on media type:
  - **Movies**: 1457 (UHD HDR), 1940 (UHD SDR), 271 (UHD Remux), 313 (HD), 312, 2339, 252, 1950, 2200, 941, 1666, 124, 352, 4, 1105, 1936, 314, 46.
  - **TV Series**: 119 (UHD), 1171 (UHD), 2366 (HD), 1803, 842, 812 (UHD), 81 (HD), 920, 921, 1106, 315.
  - Eliminates all music, audiobooks, software, and PC games.

### NNM-Club (`pkg/trackers/nnmclub`)
- **Encoding**: **Windows-1251 (CP1251)**. All outgoing queries must be encoded to CP1251 and HTML responses decoded via `golang.org/x/text/encoding/charmap.Windows1251`.
- **Strict Rate Limiting**: Sending $>2$ parallel requests triggers Cloudflare `503`.
  - Enforced by `nnmSemaphore = make(chan struct{}, 2)`.
  - Inter-request pacing: Minimum $75\text{ms} - 100\text{ms}$ delay between topic page fetches.
- **Strict Video Forum Whitelist**: Replaces broad `f[]=-1` with dedicated video subforums based on media type:
  - **Movies**: 954, 219, 1296 (UHD), 227 (HD), 882, 225, 221, 1177, 912, 909, 884, 1150, 1345, 1346, 891, 889, 682, 694, 1299, 1313, 1312, 1330, 1332, 1337, 1339, 620, 624, 628.
  - **TV Series**: 768, 769, 1219, 1221, 1220, 1344, 1265, 784, 774, 770, 780, 781, 1300, 1322, 658, 232, 620, 624, 628.
  - Guarantees search results contain zero audiobooks, software, or soundtracks.

---

## 4. Cross-Tracker Deduplication Engine (`pkg/aggregator/dedup.go`)

### The Problem
The same release (e.g. `The Gentlemen S02 1080p WEB-DL`) is frequently posted to RuTracker, RuTor, and NNM-Club by the same author. Each tracker has a separate swarm with separate seeders, fragmenting the download speed.

### Deduplication Algorithm
1. **Size-Based Clustering**:
   - Compares releases within a tolerant margin: $\Delta \text{size} \le 0.105\text{ GB}$ (equivalent to $\pm 0.1\text{ GB}$ rounding tolerance).
2. **Top Candidate Prioritization**:
   - Releases within each cluster are sorted descending by seeder count.
   - For items missing an InfoHash, up to 10 candidates are resolved concurrently (NNM is throttled by semaphore).
3. **Exact InfoHash Verification**:
   - Torrents are **only** merged if their calculated or fetched BitTorrent InfoHash (`40-char hex`) matches identically.
4. **Card Merging**:
   - Seeds are summed: $\sum \text{seeds}$.
   - All participating tracker tags are attached to `Trackers: []string`.
   - Links to each tracker's individual topic are retained for user inspection.

### Multi-Tracker Magnet Synthesis
When multiple trackers share the same InfoHash, `buildMultiTrackerMagnet` creates an augmented magnet URI with all tier-1 trackers:
```
magnet:?xt=urn:btih:<INFOHASH>&dn=<NAME>
  &tr=http://bt.t-ru.org/ann?magnet
  &tr=http://bt2.t-ru.org/ann?magnet
  &tr=http://bt.searchtor.to/announce
  &tr=http://bt02.searchtor.to:2710/announce
  &tr=udp://opentor.net:6969
  &tr=udp://tracker.openbittorrent.com:6969/announce
```
This forces the user's BitTorrent client to connect to peers across all three swarms simultaneously.

---

## 5. Caching & Persistence (`pkg/cache/cache.go`)

Database: `data/tracker-proxy/cache/cache.db` (bbolt embedded key-value store).
- **`imdb_cache` Bucket**: Key: IMDb `tconst`. Value: JSON payload of aggregated torrents + timestamp (default TTL: 24h).
- **`topic_hashes` Bucket**: Key: Tracker topic URL. Value: BitTorrent InfoHash (persists indefinitely).

---

## 6. Instant FUSE Streaming & Dual-Directory Architecture (`pkg/stream/mounter.go`)

### Dual-Directory Symlink Architecture
To ensure maximum speed, clean metadata indexing, and avoid Jellyfin scanning stalls:
1. **Source (`/media/source`)**: Virtual torrent JSON stubs consumed by Tiramisu VFS.
2. **Virtual (`/media/virtual`)**: Tiramisu FUSE mount (`mrrobotogit/tiramisu:latest`) with `:rshared` (host) and `:rslave` (jellyfin container).
3. **Library (`/media/library`)**: Real local writable directory mounted as `/media` in Jellyfin. Contains real symlinks pointing into `/media/virtual`, pre-downloaded local `poster.jpg`, `tvshow.nfo` with `<tmdbid>`, and per-episode `<Episode>.nfo` with full Russian titles, overviews, and air dates.

### Mount Flow
1. **On-Demand Magnet Resolution**:
   If `magnet` is not supplied, `ResolveInfoHash(ctx, tracker, torrentID)` dynamically resolves the BitTorrent InfoHash from bbolt's `topic_hashes` cache or live tracker topic scraping, synthesizing a multi-tracker magnet link on the fly.
2. **Torrent Registration**:
   Submits the magnet link to Tiramisu's internal GoStorm daemon (`POST http://tiramisu:8090/torrents`).
3. **Metadata Polling**:
   Polls `POST http://tiramisu:8090/torrents` (`action: "get"`) with backoff until `file_stats` contains the swarm file tree and byte lengths.
4. **Metadata Pre-Generation & Parallel Image Download**:
   - Fetches show metadata and per-season episode details from `imdb-indexer` (`/series/{tconst}/seasons`, `/series/{tconst}/episodes`, or `/movie/{tconst}/metadata`).
   - Downloads main `poster.jpg`, hero `backdrop.jpg` (with `fanart.jpg` symlink), and high-res clear `logo.png` (with `clearlogo.png` symlink) directly to the root library directory.
   - For TV shows:
     - Downloads localized Russian season covers into `Season XX/poster.jpg` and creates root `seasonXX-poster.jpg` symlinks for both Jellyfin lookup patterns.
     - Writes `Season XX/season.nfo` with localized season titles.
     - Downloads episode video stills (`Season XX/<Show> - SXXEYY-thumb.jpg`).
     - Image downloads run concurrently via a 10-worker pool directly against TMDb CDN.
   - Writes enriched `tvshow.nfo` / `movie.nfo` with `<title>`, `<originaltitle>`, `<year>`, `<imdbid>`, `<tmdbid>`, `<plot>`, `<rating>`, `<premiered>`, `<studio>`, `<status>`, and `<genre>` tags.
5. **Multi-Season & Single-Season Stub & Symlink Creation**:
   - **Movies**: Creates `/media/source/movies/<Title> (<Year>) [imdbid-<tconst>]/<Title> (<Year>).mkv` JSON stub, symlink in `/media/library/movies/...`, and `<Title>.nfo` / `movie.nfo`.
   - **Series**: `parseSeasonEpisode` categorizes video files into discrete season folders (`Season 01/`, `Season 02/`). Generates JSON stubs in `/media/source`, symlinks in `/media/library`, accompanied `<Title> - SXXEYY.nfo` with Russian episode titles, overview, air date, and `<thumb>`, plus local `-thumb.jpg`.
6. **Instant Targeted Refresh & Image Binding**:
   - Queries `GET /Library/VirtualFolders` to resolve the exact parent `ItemId` for `shows` or `movies`.
   - Triggers `POST /Items/{folderId}/Refresh` for immediate directory detection without waiting for any debounce.
   - Polls for the created item ID and fires `POST /Items/{itemId}/Refresh?MetadataRefreshMode=FullRefresh&ReplaceAllMetadata=true&ImageRefreshMode=FullRefresh&ReplaceAllImages=true&Recursive=true`.
   - Because all NFOs and images are already pre-downloaded to disk, Jellyfin's `LocalImageProvider` and `NfoReader` instantly attach posters, backdrops, logos, season covers, and episode stills in $<1$ second with zero remote scraping.
7. **ffprobe Interception & Caching**:
   - Jellyfin uses a custom `ffprobe` wrapper (`jellyfin/wrapper/main.go`).
   - Probes files via `pipe:0` on first 4MB of header bytes to avoid full-file seeking over FUSE.
   - Result profiles are cached in `/cache/ffprobe` (persisted on host at `./data/jellyfin/cache/ffprobe`), making subsequent probes take $<5\text{ms}$.
8. **Canonical Folder Detection & Language Invariance**:
   - Whenever mounting (`add`, `add_version`, or `replace`), `tracker-proxy` inspects `/media/library/` and `/media/source/` for an existing directory containing `[imdbid-<tconst>]`.
   - If found, that canonical directory name is reused (e.g. `The Sopranos (1999) [imdbid-tt0141842]`), and episode prefixes are extracted from it even if the incoming request specifies a localized title (e.g. `Сопрано`).
   - Prevents duplicate directory splits, keeps all versions grouped under a single Jellyfin show/movie item, and guarantees reliable episode version merging via `POST /Videos/MergeVersions`.

---

## 7. API Endpoints

- `GET /api/torrents?imdb_id=tt...&q=...&season=...&refresh_cache=true&limit=100`  
  Fetches aggregated and deduped torrents. Returns cached results from bbolt if fresh.
- `POST /api/stream/mount` (aliases: `/torrents/mount`, `/stream/mount`)  
  Mounts the requested torrent into Tiramisu FUSE and notifies Jellyfin.  
  Payload:
  ```json
  {
    "tconst": "tt0141842",
    "title": "The Sopranos",
    "year": "1999",
    "type": "tvSeries",
    "season": 0,
    "magnet": "magnet:?xt=urn:btih:...",
    "tracker": "nnmclub",
    "torrent_id": "1872861",
    "details_url": "https://nnmclub.to/forum/viewtopic.php?t=1872861",
    "mode": "add_version",
    "version_name": "4K UHD",
    "resolution": "4k"
  }
  ```
  **Modes**:
  - `"add"`: Standard addition.
  - `"add_version"`: Adds release as a secondary video source alongside existing files. For movies, files are named `<FolderName> - <VersionName>.mkv` (Jellyfin Core merges them natively). For series, files are named `<Show> - SXXEYY - <VersionName>.mkv`, and `tracker-proxy` invokes `POST /Videos/MergeVersions?ids=id1,id2` to attach secondary MediaSources to the primary episode.
  - `"replace"`: Removes existing video files/symlinks for that movie or season, unmounts old torrent hashes from GoStorm, and mounts the new release in place.

- `POST /api/stream/unmount` (aliases: `/torrents/unmount`, `/stream/unmount`)  
  Completely unmounts and deletes a media item across all layers:
  1. Purges symbolic links and local metadata in `/media/library/{movies,shows}/...`
  2. Parses info hashes from JSON stubs in `/media/source/{movies,shows}/...`
  3. Sends `action: "rem"` to GoStorm (`http://tiramisu:8090/torrents`) to close cache and terminate the swarm.
  4. Deletes `/media/source/{movies,shows}/...`
  5. Triggers `POST /Library/Refresh` on Jellyfin.  
  Payload:
  ```json
  {
    "tconst": "tt0141842",
    "type": "shows"
  }
  ```
- `GET /api/stream/status?tconst=tt...` (aliases: `/torrents/status`, `/stream/status`)  
  Returns the live mounting status, mounted season numbers, and existing version labels:
  ```json
  {
    "mounted": true,
    "tconst": "tt0116282",
    "type": "movies",
    "folder_name": "Фарго (1996) [imdbid-tt0116282]",
    "library_path": "/media/library/movies/Фарго (1996) [imdbid-tt0116282]",
    "source_path": "/media/source/movies/Фарго (1996) [imdbid-tt0116282]",
    "file_count": 2,
    "mounted_files": [
      "Фарго (1996) [imdbid-tt0116282] - 4K UHD.mkv",
      "Фарго (1996) [imdbid-tt0116282] - SD.mkv"
    ],
    "seasons": [],
    "versions": ["4K UHD", "SD"]
  }
  ```
- `POST /api/stream/webhook/deleted` (alias: `/webhook/deleted`)  
  Webhook receiver for Jellyfin's Webhook plugin (`NotificationType: ItemDeleted`). Receives deleted item payloads and automatically unmounts the corresponding item and reconciles leftover stubs.
- `GET /api/stream/resume` (alias: `/stream/resume`)  
  Queries Jellyfin `/UserItems/Resume` to extract movies and episodes currently in-progress for the user. Automatically resolves parent series `tconst` if episode items lack direct IMDb IDs, calculates duration and resume percentage, and provides image URLs for the home "Continue Watching" shelf:
  ```json
  [
    {
      "item_id": "cdbb4fbba2a1c99efef3062a840ce59c",
      "tconst": "tt14688458",
      "title": "Укрытие",
      "series_name": "Укрытие",
      "episode_title": "Сын уборщика",
      "media_type": "Episode",
      "season_number": 1,
      "episode_number": 5,
      "duration_seconds": 3563.782,
      "resume_seconds": 13.485938,
      "played_percentage": 0.3784164687963517,
      "image_url": "/jellyfin/Items/cdbb4fbba2a1c99efef3062a840ce59c/Images/Primary"
    }
  ]
  ```
- `GET /api/stream/player/info?tconst=...&season=N&episode=M` (alias: `/stream/player/info`)  
  Fetches comprehensive playback metadata for the embedded cinema player (`CinemaPlayerModal`). Formats Russian natural titles (`Сезон N, серия M — Название`), surfaces all audio tracks (Dolby Digital Plus, Atmos, EAC3, AC3, AAC) and subtitles (VTT delivery URLs), resolves next episodes, and constructs the HLS master playlist URL using fMP4 fragmented MP4 segments (`SegmentContainer=mp4&MinSegments=2&BreakOnNonKeyFrames=True&VideoCodec=h264&AudioCodec=aac`) without `EnableAutoStreamCopy=true`, ensuring fast transcode/remux on any browser even for 4K HEVC HDR/DV content.

---

## 8. Automated Deletion & Orphaned Stubs Reconciler

Because Jellyfin library files are symbolic links pointing to `/media/virtual/`, deleting media inside the Jellyfin UI only deletes the symlinks in `/media/library/` without reaching FUSE or the underlying GoStorm daemon. Cine-Claw implements two complementary systems to guarantee 100% clean deletion:

1. **Jellyfin `ItemDeleted` Webhook**:
   When an item is deleted in Jellyfin, the Jellyfin Webhook plugin sends an HTTP POST notification to `http://tracker-proxy:9118/api/stream/webhook/deleted`. `tracker-proxy` resolves the path and IMDb ID, extracts the active hashes, instructs GoStorm to remove the swarms, and deletes the source stubs.
2. **Background Orphaned Stubs Reconciler / Garbage Collector**:
   Every 5 minutes (and immediately on container startup), `tracker-proxy` scans `/media/source/` against `/media/library/`. Any source folder or empty folder whose symlinks were deleted is automatically identified as orphaned, stripped of its torrent swarms in GoStorm, and purged from disk.

---

## 9. Authentication & Edge Gateway Security

`tracker-proxy` includes a built-in, lightweight authentication service (`pkg/auth`) protecting all media and scraping endpoints when exposed to the Internet:

### Endpoints
- `POST /api/auth/login`: Accepts `{"username":"...", "password":"...", "remember_me": true/false}`. Validates credentials with `subtle.ConstantTimeCompare`, sets an `HttpOnly`, `SameSite=Lax` cookie (`cineclaw_session`), and returns `{ "success": true, "token": "...", "username": "...", "expires_at": "..." }`.
- `GET /api/auth/verify`: Auth verification endpoint used by Nginx's `auth_request` subrequest directive. Returns `200 OK` (with `X-User` header) if authenticated, or `401 Unauthorized` if not.
- `POST /api/auth/logout`: Clears the session cookie (`Max-Age=0`) and logs out.
- `GET /api/auth/me`: Returns `{ "authenticated": true, "username": "..." }` or `401`.

### Supported Authentication Methods
`tracker-proxy` validates incoming requests in priority order:
1. **Session Cookie**: `cineclaw_session=<token>` (used by web browser for poster `<img>` tags and web requests).
2. **Bearer Token**: `Authorization: Bearer <token>` (used by frontend API client via RTK Query).
3. **Basic Auth**: `Authorization: Basic <base64(user:pass)>` (used by curl, scripts, and external tools).

### Token Security
- Tokens are signed with HMAC-SHA256: `<base64_user>.<expiry_unix>.<random_salt>.<signature>`.
- Token expiration is 30 days when "Remember Me" is checked, or 24 hours for standard sessions.
- Secret key is configured via `AUTH_SECRET` in `.env` (or automatically generated on initialization).

---

## 10. Tracker Swarm Hotlist Aggregator (`pkg/hotlist`)

`tracker-proxy` proactively scrapes top-seeded releases from Russian trackers and correlates them with local IMDb metadata:

### Architecture
- **`scraper.go`**:
  - Scrapes 10 pages (`page 0..9`) per category via RuTor category browsing (`/browse/{page}/{cat}/0/2`, sorted descending by seeders).
  - Movies cover categories `1` (Зарубежные фильмы), `5` (Наши фильмы), and `7` (Мультипликация) — total 30 pages (~3,000 raw releases).
  - TV series cover categories `4` (Зарубежные сериалы) and `16` (Наши сериалы) — total 20 pages (~2,000 raw releases).
  - Anime covers category `10` (Аниме) — 10 pages (~1,000 raw releases).
  - Documentaries cover category `12` (Документальное кино и юмор) — 10 pages (~1,000 raw releases).
  - 4K UHD Scraping (`ScrapeUHD`): Queries high-seed `2160p` and `UHD` across movie and TV categories.
  - Exclusions: Asian doramas and Turkish series subcategories are explicitly omitted.
  - Enforces a strict concurrency limit of 2 parallel HTTP requests via `sem: make(chan struct{}, 2)` with a 50ms anti-ban pacing delay.
- **`parser.go`**: Robust regex parsing extracting Russian title, English/original title, year, season, resolution (4K/1080p), and quality tags (WEB-DL, HDR10, BDRip, etc.).
- **`matcher.go`**:
  - Correlates releases against `imdb-indexer`'s Tantivy search index (`GET /search?q=...&limit=3`) using an in-run memoization cache (`lookupCache`), minimizing HTTP requests down from 3,000+ to ~250 unique titles.
  - Clusters all release variants (4K Remux, 1080p WEB-DL, DUB, 720p), sums swarm seeds ($\sum \text{seeds}$) and leeches across all variants, determines precise resolution (`4k`, `1080p`, `720p`, `lq`), and enriches items with verified IMDb `tconst`, genres, ratings, and poster URLs.
- **`service.go`**: Background fetcher and persistent bbolt disk cache (`bucket: tracker_hotlist`) with a 2-hour TTL:
  - Supports separate cache keys: `hotlist_movie`, `hotlist_tv`, `hotlist_anime`, `hotlist_doc`.
  - Supports on-the-fly resolution filtering: when `quality=4k`, returns only titles offering verified 4K UHD torrents.
- **Endpoints**:
  - `GET /torrents/hotlist?type=movie|tv|anime|doc&quality=4k&page=1&limit=20` (alias: `GET /api/stream/hotlist`)
  - Supports query parameter `?refresh=true` (or `?refresh_cache=true`) to force an immediate background re-scrape.
  - Returns `{ "id": "tracker_hotlist", "title": "Популярно на трекерах", "media_type": "...", "page": 1, "total_pages": ..., "total_results": ..., "items": [...] }`.

---

## 11. Native BitTorrent Streaming & SQLite Playback Engine (`pkg/stream`, `pkg/playback`)

- **TorrServer MatriX Orchestrator (`pkg/stream/torrclient.go`)**:
  - Adds torrents directly to TorrServer via `POST /torrents` (`action: "add"`, `link: magnet`, `save_to_db: true`).
  - Fetches torrent file stats, file lists, and swarm health via `POST /torrents` (`action: "get"`).
  - Robust season and episode file parsing (`ParseSeasonEpisode`) mapping regex filenames (`S01E02`, `1x02`, `Сезон 1/02.mkv`) directly to TorrServer file indices.
  - Probes audio and subtitle streams via TorrServer probe API (`POST /probe`).
  - GStreamer remuxing delivers HLS master playlist on `/torr/gst/<hash>/master.m3u8?index=<file-id>&audio=<audio-idx>` with zero-transcode video passthrough and AAC stereo audio transcoding.
  - Subtitles served dynamically as WebVTT on `/torr/gst/<hash>/subs/<idx>.m3u8`.
- **Pure-Go SQLite Media Database (`pkg/db/sqlite.go`, `pkg/playback/store.go`)**:
  - Managed using `modernc.org/sqlite` (pure Go, zero CGo requirement).
  - WAL mode enabled for high-concurrency read/write operations without locking.
  - `watch_progress`: Stores watch time (`position_seconds`), runtime (`duration_seconds`), completion percentage (`playback_percent`), watched state (`is_completed`), torrent hash, link, and file index.
  - Conflict-safe updates preserving existing durations and calculating real-time percentages.
  - Deduplicated Resume shelf (`GetResumeList`) returning currently in-progress titles with accurate elapsed times.
- **Next Up Episode Engine (`pkg/playback/nextup.go`)**:
  - Compares user's watched episodes in SQLite with series season episode manifests from `imdb-indexer` (`/api/series/:tconst/episodes`).
  - Automatically identifies the next sequential episode (e.g. S01E04 when S01E03 finishes) or first episode of the next season.
  - Emits `ResumeItem` with `is_next_up: true` for immediate 1-click continuation on the home shelf.
- **External Player Launchers**:
  - Direct streams to TorrServer port `8092` (`http://<host>:8092/stream?link=<hash>&index=<idx>&play`).
  - Deep linking protocol schemes supported: VLC (`vlc://`), IINA (`iina://weblink?url=...`), Infuse (`infuse://x-callback-url/play?url=...`), and clipboard stream link copy.


