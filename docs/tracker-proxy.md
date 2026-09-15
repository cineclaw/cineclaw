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
│   │   ├── watchlist_store.go# Watchlist CRUD (media_watchlist table)
│   │   └── nextup.go         # Next Up episode calculator against TMDB
│   ├── hotlist/
│   │   ├── service.go        # Hotlist & fresh releases manager with bbolt caching
│   │   ├── scraper.go        # RuTor/RuTracker swarm & fresh release scrapers
│   │   ├── matcher.go        # Concurrent Tantivy metadata resolution & grouping
│   │   └── models.go         # Data models for hotlist and fresh items
│   ├── stream/
│   │   ├── service.go        # TorrStreamService orchestrator (Range requests & TorrServer stream)
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

### RuTracker (`pkg/tracker/rutracker`)
- **Protection**: Protected by Cloudflare Turnstile.
- **Authentication**: Uses FlareSolverr (`http://flaresolverr:8191/v1`) with `request.post` to solve Turnstile and authenticate with RuTracker login/password.
- **Session**: Caches and reuses the `bb_session` cookie across requests until expired.
- **InfoHash Resolution**: Search results contain Topic IDs but no InfoHash. The scraper fetches the topic page to extract the InfoHash, caching the result in bbolt's `topic_hashes` bucket.
- **Sorting & Multi-Page Pagination**: Searches using `tracker.php?nm=<query>&o=10&s=2` (seeders DESC) iterating up to 2-3 pages (`start=0`, `start=50`, `start=100`), ensuring all relevant season releases across all video subforums (e.g. 1288, 2366, 189, etc.) are discovered before deduplication and season filtering.
- **Non-Video Clean Filtering**: Drops non-video media (audiobooks, music, PC games, software) in-memory via `hotlist.IsNonVideo`.

### NNM-Club (`pkg/tracker/nnmclub`)
- **Encoding**: **Windows-1251 (CP1251)**. All outgoing queries must be encoded to CP1251 and HTML responses decoded via `golang.org/x/text/encoding/charmap.Windows1251`.
- **Sorting & High-Seed Swarms**: Posts to `tracker.php` with `o=10&s=2` (seeders DESC) covering all categories, filtered and scored in-memory.
- **Strict Rate Limiting**: Sending $>2$ parallel requests triggers Cloudflare `503`.
  - Enforced by `nnmSemaphore = make(chan struct{}, 2)`.
  - Inter-request pacing: Minimum $75\text{ms} - 100\text{ms}$ delay between topic page fetches.

### 3.4 IMDb ID Title Auto-Resolution, Disambiguation & Candidate Scoring
- **No IMDb Support on Trackers**: RuTracker, RuTor, and NNM-Club do not index or search by IMDb ID (`tt...`). They only search by text in topic titles.
- **Empty Query Prevention**: `Aggregator.Search` strictly checks `if strings.TrimSpace(query.Query) == ""` and returns `nil` immediately. Querying trackers with empty strings is forbidden to avoid dumping the tracker's front page / newest releases into search results.
- **IMDb Indexer Title Auto-Resolution & Year Disambiguation**: When `imdb_id` is passed but `q` is omitted, `tracker-proxy` (`executeSearch` and `autoResolveTorrent`) queries `imdb-indexer` (`/api/movie/{tconst}/metadata`) to resolve `meta.Title`, `meta.OriginalTitle`, and `meta.Year`. For movies, it appends the release year (e.g. `Приглашение 2026`) to eliminate noise from older releases or prefix collisions (e.g. "Приглашение к убийству" vs "Приглашение (2026)"), falling back to search without year if zero results are found.
- **`ScoreCandidate` Multidimensional Relevance Ranking**: When selecting candidates in `autoResolveTorrent` or ranking search results, `stream.ScoreCandidate` scores releases considering:
  - Exact year match (+600 for movies), TV series air timeline spanning from show premiere to present (+600).
  - Original title match (+600) and conflicting title penalty (-3000).
  - Russian title precision match (+400).
  - Exact single-season target match (+400), complete series pack (+150).
  - Quality preference: 1080p Full HD (+300), 4K UHD (+250), 720p HD (+150).
  - Seed count health scaling with swarm size.
- **Cache Poisoning Prevention**: `Store.Set` in `pkg/cache/cache.go` refuses to cache entries if `query` is empty. `Store.Get` automatically invalidates and ignores any legacy cache entries where `entry.Query == ""`.

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

- `GET /api/home?platform=tv|web&refresh=true|false` (aliases: `/home`, `/api/hub`, `/hub`)  
  Unified Backend-For-Frontend (BFF) aggregator. Concurrently fetches Continue Watching (SQLite), Watchlist (SQLite), Fresh Releases (RuTor), Popular Swarms (RuTor), 4K UHD Swarms (RuTor), and Curated TMDB Feeds (`imdb-indexer:8090/api/feeds`) using `errgroup` in $<2$ms. Caches results in RAM for 60s and invalidates immediately upon user watch state or watchlist changes. Returns normalized `HomePayload` with `hero` and `shelves`.
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
  Queries SQLite database (`data/tracker-proxy/cineclaw.db`) for items currently in-progress (2% <= progress < 90%) and deduplicated next episodes for TV series. Automatically enriches missing titles, backdrops, and poster paths via `imdb-indexer` (`/api/movie/{tconst}/metadata`), resolves episode stills via TMDB episodes API, persists enriched attributes back to SQLite, and formats high-resolution 16:9 backdrop URLs (`https://image.tmdb.org/t/p/w780/...`) with guaranteed fallback to `/poster/{tconst}?size=w500`:
  ```json
  [
    {
      "item_id": "tt34564059",
      "tconst": "tt34564059",
      "title": "Бегущая",
      "series_name": "Бегущая",
      "media_type": "Movie",
      "duration_seconds": 5150.584,
      "resume_seconds": 743.836253,
      "played_percentage": 14.441784718004794,
      "image_url": "https://image.tmdb.org/t/p/w780/jzBWExXacS33rMQ2zLBrqIVweyG.jpg"
    }
  ]
  ```
- `DELETE /api/stream/resume` (aliases: `POST /api/stream/resume/remove`, `/stream/resume/remove`)  
  Removes watch progress records for a movie, episode, or series from SQLite. Accepts `{"item_id": "...", "tconst": "...", "season": N, "episode": M, "is_next_up": true/false, "all": true/false}` via JSON body or query parameters. Automatically clears all history for movies and next-up shows, or targets specific episode records.
- `GET /api/stream/player/info?tconst=...&season=N&episode=M` (alias: `/stream/player/info`)  
  Fetches comprehensive playback metadata for the embedded cinema player (`CinemaPlayerModal`). Surfaces all probed audio tracks (Russian dub, Original, etc.) and subtitles, resolves next episodes, and constructs:
  1. `stream_url`: `/gst/{hash}/master.m3u8?id={idx}&audio={audio}` for embedded web player with zero-transcode GStreamer remuxing and AAC conversion.
  2. `direct_stream_url`: `/torr/stream/<filename>?link={hash}&index={idx}&play` for external native players (VLC, IINA, Infuse) and Android TV Media3 ExoPlayer capable of multi-channel pass-through.
  3. `transcode_profiles`: List of available real-time transcoding profiles (`direct`, `1080p`, `720p`, `480p`, `360p`) for bandwidth-constrained playback.
- `GET /api/stream/transcode/profiles`  
  Returns array of available transcode profiles with label, bitrates, resolution caps, and direct-stream flags.
- `GET /api/stream/transcode/{hash}/master.m3u8?profile={id}&file_idx={idx}&audio={audio}&start={startSec}&s={sessionId}`  
  Spawns or retrieves an on-demand FFmpeg transcode session targeting TorrServer's HTTP stream with input seek (`-ss`), ultrafast x264 re-encoding, AAC stereo downmixing, and rolling HLS packaging (`-hls_time 3`). Rewrites segment references to `/api/stream/transcode/seg/{sessionId}/seg_{index}.ts`.
- `GET /api/stream/transcode/seg/{sessionId}/{filename}`  
  Serves generated MPEG-TS segment file and updates the session's last activity timestamp.
- `POST /api/stream/transcode/stop`  
  Immediately terminates active FFmpeg transcode processes for a specific torrent hash (or all sessions if hash is empty) and frees temporary directories (`os.RemoveAll`). Also invoked automatically when player closes or switches items.
- `GET /api/stream/stats?hash={hash}&tconst={tconst}&season=N&episode=M&duration={durSec}` (alias: `/stream/stats`)  
  Returns live BitTorrent swarm throughput and cellular signal metrics for video playback. Calculates video bitrate ($\text{VideoBitrate} = \frac{\text{fileLength} \times 8}{\text{duration}}$), speed ratio ($\frac{\text{DownloadSpeed}}{\text{VideoBitrate}}$), and 4-tier cellular signal level (0..4) with connected seeds and active peers.

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
  - `GET /torrents/hotlist?type=movie|tv|new_movie|new_tv|anime|doc&quality=4k&page=1&limit=20` (alias: `GET /api/stream/hotlist`)
  - Supports query parameter `?refresh=true` (or `?refresh_cache=true`) to force an immediate background re-scrape.
  - `type=new_movie`: Scrapes fresh movie releases from RuTor categories `1` (foreign), `5` (Russian), `7` (animation) sorted by publication date descending (`/browse/<page>/<cat>/0/0`), filtered strictly by `Year >= 2025`.
  - `type=new_tv`: Scrapes fresh TV series releases from RuTor categories `4` (foreign) and `16` (Russian) sorted by publication date descending (`/browse/<page>/<cat>/0/0`), filtered strictly by `Year >= 2025` and deduplicated by series title.
  - Returns `{ "id": "tracker_fresh" | "tracker_hotlist", "title": "...", "media_type": "...", "page": 1, "total_pages": ..., "total_results": ..., "items": [...] }`.

---

## 11. Native BitTorrent Streaming & SQLite Playback Engine (`pkg/stream`, `pkg/playback`)

- **TorrServer MatriX Orchestrator (`pkg/stream/torrclient.go`, `pkg/stream/service.go`)**:
  - Adds torrents directly to TorrServer via `POST /torrents` (`action: "add"`, `link: magnet`, `save_to_db: true`).
  - Fetches torrent file stats, file lists, and swarm health via `POST /torrents` (`action: "get"`).
  - **Multi-Season & Collection Pack File Mapping Engine (`MatchFile`, `ParseSeasonEpisodeRange`)**:
    - **Directory & Russian Folder Parsing**: Recursively extracts season numbers from directory structures from deepest to root, supporting `1 сезон`, `2 сезон`, `2-й сезон`, `2-ой сезон`, `Сезон 2`, `Сезон.2`, `Season.02`, `Show.S02.1080p`, `[S02]`, and Roman numerals (`Сезон II`, `II сезон`).
    - **Episode Range & 3-Digit Support**: Parses episode ranges (`S02E01-E02`, `01-02 серии`, `01-02.mkv`) mapping requests for either episode directly to the multi-episode file. Supports classic 3-digit episode formats (`204.mkv` -> S02E04).
    - **4-Pass Resolution Hierarchy**:
      1. *Pass 1 (Exact Match)*: Matches explicit season and episode/range (`pv.season == season && episode >= pv.epStart && episode <= pv.epEnd`).
      2. *Pass 2 (In-Season Search)*: Restricts search strictly to files within the detected season folder:
         - *Pass 2a*: In-season fuzzy token search (`e04`, `ep04`, `серия 4`).
         - *Pass 2b*: Continuous/absolute numbering offset (e.g. Season 2 with files `14.mkv..26.mkv` offsets to absolute index `minEp + episode - 1`).
         - *Pass 2c*: Alphanumeric natural sort fallback (`naturalLess`), correctly picking the $E$-th file of that season.
      3. *Strict Multi-Season Invariant*: If a torrent contains files across multiple seasons (`isMultiSeason == true`), cross-season matching is strictly forbidden. Any request for Season $N$ that cannot be satisfied returns an explicit error (`episode S%02dE%02d not found in multi-season pack`) and never leaks into Season 1.
      4. *Pass 3 (Single-Season Fallback)*: Only engaged when `!isMultiSeason`. For `season > 1`, requires season confirmation in the torrent title, eliminating movie and unrelated release leakage.
    - **Self-Healing Auto-Resolve**: If the current torrent lacks the requested season/episode, `GetPlayerInfo` automatically queries the aggregator specifically for that season, mounts the correct season pack into TorrServer, and streams without disruption.
  - **Self-Healing Season Auto-Mount**: If an episode of a TV show is requested before a torrent is mounted or if TorrServer was restarted, `GetPlayerInfo` automatically queries the bbolt cache/aggregator, selects the top-seeded release matching that season, resolves infohash/magnet, mounts it into TorrServer, and streams without error.
  - **Direct HTTP Range Streaming (`/torr/stream`)**: Direct zero-transcode HTTP streaming gateway from TorrServer (`/torr/stream/<filename>?link=<hash>&index=<idx>&play`). Supports standard HTTP Range requests (`206 Partial Content`), allowing the browser HTML5 `<video>` element to instantly seek to any keyframe (<0.8s load time) directly from TorrServer's cache without custom segmentation.
  - **TorrServer GStreamer 1.24 Distribution (`torrserver-gst/Dockerfile`)**:
    - Packaged inside Ubuntu 24.04 runtime with GStreamer 1.24 libraries (`gstreamer1.0-plugins-base`, `gstreamer1.0-plugins-good`, `gstreamer1.0-plugins-bad`, `gstreamer1.0-plugins-ugly`, `gstreamer1.0-libav`) and official `TorrServer-gst-linux-${arch}`.
    - Built-in GStreamer engine (`/gst/settings` -> `{"built_in": true}`) provides rapid media probing via `GET /gst/:hash/probe?id=<idx>` (~1.8s response time), returning all video, audio, and subtitle streams directly from the BitTorrent swarm header.
    - Codec normalizers (`cleanVideoCodec`, `cleanAudioCodec`) strip verbose GStreamer caps format into standard tokens (`H.264`, `HEVC`, `AV1`, `AC3`, `E-AC3`, `DTS`, `AAC`).
    - **Intelligent Audio Track Selection (`selectDefaultAudioTrack`)**: Scores audio tracks to prioritize Russian dubbing (DUB > MVO > Russian language tracks > 6-channel audio), eliminating accidental default selection of foreign audio pads.
    - **Dynamic HLS Audio Track Switching & Demux Isolation**: Exposes `/gst/:hash/master.m3u8?id=<fileId>&audio=<idx>` enabling Hls.js in web clients to switch audio tracks on the fly with zero transcoding. Generates segment URLs scoped with `?audio=<idx>` to eliminate segment cache pollution across track switches. Runner pipeline re-arms on track change with clean fMP4 initialization headers.
    - **Low-Peer Swarm Protection & Resilient Probing**: Guarded `churnIfUselessForWarmup` in `anacrolix-torrent` (`minConnsToChurn = 25`, complete seeders immune), preserving scarce seeders in Russian multi-season packs (e.g. *The Sopranos*). Extended TorrServer probe timeout to 35s in `TorrClient` and frontend polling retries to 30 attempts (45s total).
    - Exposes `direct_stream_url` for external players (VLC, IINA, Infuse).
- **Pure-Go SQLite Media Database (`pkg/db/sqlite.go`, `pkg/playback/store.go`)**:
  - Managed using `modernc.org/sqlite` (pure Go, zero CGo requirement).
  - WAL mode enabled for high-concurrency read/write operations without locking.
  - `watch_progress`: Stores watch time (`position_seconds`), runtime (`duration_seconds`), completion percentage (`playback_percent`), watched state (`is_completed`), torrent hash, link, and file index.
  - **Zero-Wipe Position Preservation**: `SaveProgress` guarantees that existing playback positions are never wiped to 0 when re-mounting releases:
    `position_seconds = CASE WHEN excluded.position_seconds > 0 THEN excluded.position_seconds ELSE watch_progress.position_seconds END`.
  - Seamless quality switching pipeline: `MountTorrent` accepts `position_seconds` and `episode`, automatically preserving watch progress in SQLite and passing the resume target to the player.
  - Deduplicated Resume shelf (`GetResumeList`) returning currently in-progress titles with accurate elapsed times.
  - 1-click removal (`DELETE /api/playback/progress?tconst=...`) with confirmation modal and optimistic UI updates.
  - Helper queries: `GetLatestWatchedEpisodeForSeason` and `GetWatchedSeasons` enabling exact per-season progress tracking and rich mount status responses.
- **Next Up Episode Engine (`pkg/playback/nextup.go`)**:
  - Compares user's watched episodes in SQLite with series season episode manifests from `imdb-indexer` (`/api/series/:tconst/episodes`).
  - Automatically identifies the next sequential episode (e.g. S01E04 when S01E03 finishes) or first episode of the next season.
  - Emits `ResumeItem` with `is_next_up: true` for immediate 1-click continuation on the home shelf.
- **External Player Launchers**:
  - Direct streams to TorrServer port `8092` (`http://<host>:8092/stream?link=<hash>&index=<idx>&play`).
  - Deep linking protocol schemes supported: VLC (`vlc://`), IINA (`iina://weblink?url=...`), Infuse (`infuse://x-callback-url/play?url=...`), and clipboard stream link copy.

---

## 12. Persistent Watchlist («Буду смотреть») (`pkg/playback/watchlist_store.go`)

- **Table Schema**:
  ```sql
  CREATE TABLE IF NOT EXISTS media_watchlist (
      imdb_id TEXT PRIMARY KEY,
      media_type TEXT NOT NULL,
      title TEXT NOT NULL,
      original_title TEXT,
      year INTEGER,
      rating REAL,
      poster_path TEXT,
      backdrop_path TEXT,
      added_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );
  CREATE INDEX IF NOT EXISTS idx_watchlist_added ON media_watchlist(added_at DESC);
  ```
- **Endpoints**:
  - `GET /api/watchlist` (alias: `/api/playback/watchlist`) — returns all saved titles ordered by `added_at DESC`.
  - `POST /api/watchlist` — saves title with metadata.
  - `DELETE /api/watchlist?imdb_id=...` — removes title from watchlist.
  - `GET /api/watchlist/check?imdb_id=...` — returns `{ "in_watchlist": true|false }`.

---

## 13. Direct HTTP Range Streaming & Transcode Profiles (`pkg/transcode/profiles.go`)

- **Profile List**:
  - `direct`: ⚡ Исходный (HLS Remux) — zero transcode, GStreamer HLS container remux with audio track selection.
  - `http_direct`: 🚀 Прямой HTTP (без сегментов) — native TorrServer single-stream HTTP Range request (`/torr/stream/<file>?link=<hash>&index=<idx>&play`, `HTTP 206 Partial Content`) directly into HTML5 `<video>`, completely bypassing HLS segment chopping and GStreamer.
  - `1080p`: 📱 1080p Full HD (6 Мбит/с) — on-the-fly FFmpeg transcoding for Wi-Fi.
  - `720p`: 📱 720p HD (3 Мбит/с) — on-the-fly FFmpeg transcoding for cellular (LTE/5G).
  - `480p`: 📶 480p SD (1.4 Мбит/с) — data-saving profile.
  - `360p`: 🔋 360p Эконом (700 Кбит/с) — minimal bandwidth profile.
- **Player Info Exposure**:
  `GET /api/stream/player/info` supplies `transcode_profiles` array with both `direct` and `http_direct` flags, along with `direct_stream_url` for one-click native HTTP playback.

---

## 14. Persistent Audio Voiceover Preferences (`pkg/playback/store.go`, `pkg/stream/service.go`)

- **Table Schema**:
  ```sql
  CREATE TABLE IF NOT EXISTS media_audio_preferences (
      imdb_id TEXT PRIMARY KEY,
      audio_title TEXT NOT NULL,
      audio_index INTEGER NOT NULL DEFAULT 0,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );
  ```
- **Endpoints & Ingestion**:
  - `POST /api/playback/audio`: Accepts `{"imdb_id": "...", "audio_title": "...", "audio_index": ...}` to store the user's voiceover choice for a show or movie.
  - Periodic watch progress reporting (`POST /api/playback/progress`) is strictly guarded: if `audio_title` is omitted or empty, existing preferences are never overwritten.
- **Semantic Voiceover Matching (`selectDefaultAudioTrackWithPreference`)**:
  - Automatically matches preferred voiceovers across episodes or different torrent releases based on author/studio keywords: Goblin (`Гоблин`, `Пучков`), Amedia (`Амедиа`), Fox Crime, Serbin (`Сербин`), HDRezka, LostFilm, Кубик в кубе, etc.
  - Injects matched track as `is_default: true` in `/api/stream/player/info` and dynamically configures `master.m3u8?audio=<idx>`.

---

## 15. Tracker Swarm Hotlist & Clean TMDB Relative Paths (`pkg/hotlist`)

- **Endpoints**:
  - `GET /torrents/hotlist?type=movie|tv|new_movie|new_tv|anime|doc&quality=4k&page=1&limit=20`
- **Zero-Disk Clean Path Pipeline**:
  - `IndexerHit` and `Item` store only pure TMDB relative paths (`poster_path: "/..."`, `backdrop_path: "/..."`).
  - Legacy `/poster/` prefixes and proxy query strings are completely ignored and stripped in `pkg/hotlist/matcher.go`.
- **Legacy Cache Auto-Purge**:
  - In `loadFromDB` and `getItems`, any cached bbolt item whose `poster_path` starts with `/poster/` is detected as legacy format, discarded, and automatically re-fetched and re-matched against the indexer.
- **bbolt Persistent Caching**:
  - Stored in bucket `hotlist_items` under keys `movie`, `tv`, `new_movie`, `new_tv`, `anime`, `doc` with a 24-hour TTL and periodic background refreshes.

---

## 16. Sub-Second TTFF, Swarm Re-prioritization & Fast-Probe Decoupling

- **Decoupled Stream Probing (`pkg/stream/service.go`)**:
  - Previously, `GetPlayerInfo` blocked synchronously on full GStreamer/FFprobe probing (`probeStreamDirect`), causing 5–15 second UI freezes on cold torrents while demuxing audio/subtitles.
  - Replaced with `probeStreamFast` which enforces a strict 500ms probe window. If metadata is not returned within 500ms, it falls back to safe default stream parameters (`audio: [{"index": 0, "title": "Основная дорожка"}]`) and warms the full probe asynchronously in the background.
  - Added background probe warming directly inside `MountTorrent` so tracks are probed before the user even opens the player.
- **TorrServer-Turbo Priority Inversion Fix**:
  - Removed cache-boundary checks in `cache.go` (`isIdInFileBE`) that previously caused piece requests near file start or boundary limits to be completely ignored by the scheduler.
  - Enabled unconditional `reader.SetResponsive()` and instant `cache.refreshPriorities()` on reader creation and seeking (`reader.Seek()`).
  - Swarm priority updates execute concurrently within <1ms, enabling sub-second seeks (185–580ms) and warm series episode switches (<900ms).


