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
│   ├── flaresolverr/
│   │   └── client.go         # FlareSolverr v1 JSON API client
│   ├── stream/
│   │   └── mounter.go        # Tiramisu GoStorm registration, stub writer & Jellyfin notification
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
- **Search Query**: Formats query as `"<title> <year>"` or `"<ru_title> <year>"`.

### RuTracker (`pkg/trackers/rutracker`)
- **Protection**: Protected by Cloudflare Turnstile.
- **Authentication**: Uses FlareSolverr (`http://flaresolverr:8191/v1`) with `request.post` to solve Turnstile and authenticate with RuTracker login/password.
- **Session**: Caches and reuses the `bb_session` cookie across requests until expired.
- **InfoHash Resolution**: Search results contain Topic IDs but no InfoHash. The scraper fetches the topic page to extract the InfoHash, caching the result in bbolt's `topic_hashes` bucket.

### NNM-Club (`pkg/trackers/nnmclub`)
- **Encoding**: **Windows-1251 (CP1251)**. All outgoing queries must be encoded to CP1251 and HTML responses decoded via `golang.org/x/text/encoding/charmap.Windows1251`.
- **Strict Rate Limiting**: Sending $>2$ parallel requests triggers Cloudflare `503`.
  - Enforced by `nnmSemaphore = make(chan struct{}, 2)`.
  - Inter-request pacing: Minimum $75\text{ms} - 100\text{ms}$ delay between topic page fetches.

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

