# IMDb Indexer — Subsystem Documentation

## 1. Overview
`imdb-indexer` is a high-performance Rust service running on port `8090`. It indexes official IMDb datasets using **Tantivy** (a Lucene-like full-text search engine in Rust), proxies movie posters with disk caching, and provides TMDB TV series seasons metadata.

---

## 2. Architecture & File Structure

```
imdb-indexer/
├── src/
│   ├── main.rs               # Server startup, CLI parsing, Axum router
│   ├── lib.rs                # Library exports
│   ├── indexer/
│   │   ├── tantivy_index.rs  # Tantivy schema definition, writer, and commit management
│   │   └── ingest.rs         # Streaming TSV ingestion using redb (zero-RAM disk store)
│   ├── search/
│   │   └── query.rs          # Prefix, fuzzy, and multi-language search execution
│   ├── tmdb/
│   │   └── seasons.rs        # TMDB API client (IMDb tconst -> TMDB ID -> seasons breakdown)
│   └── poster/
│       └── proxy.rs          # Poster fetcher and local disk cache
└── Cargo.toml                # Rust dependencies & release profile (LTO = true)
```

---

## 3. Ingestion & Search Engine (Tantivy + redb)

### Zero-RAM Disk Ingestion
The IMDb datasets (`title.basics.tsv.gz`, `title.ratings.tsv.gz`, `title.akas.tsv.gz`) contain over 10 million rows:
- To prevent Out-Of-Memory (OOM) errors during indexing, the ingester streams lines through `redb` (an embedded ACID key-value disk store).
- Once intermediate tables are built on disk, the records are bulk-indexed into **Tantivy**.
- Storage directory: `data/fdb/`.

### Tantivy Full-Text Index
- Schema fields:
  - `tconst` (Facet / String)
  - `primary_title`, `original_title`, `russian_title` (Text, indexed with tokenization)
  - `start_year`, `end_year` (Numeric)
  - `title_type` (String: `movie`, `tvSeries`, `tvMiniSeries`, etc.)
  - `rating`, `num_votes` (Numeric, used for search relevance ranking)
- Performance: Queries execute in $<5\text{ms}$ even under load.

---

## 4. TMDB Seasons, Episodes & Movie Metadata Resolver

### Purpose
Supports instant local metadata generation and asset pre-downloading for Jellyfin without triggering slow remote scraper scans:
1. **Find by External ID**:
   - `GET https://api.themoviedb.org/3/find/{tconst}?external_source=imdb_id&language=ru-RU`
   - Maps IMDb `tconst` to TMDB `id`.
2. **Fetch TV Details & Seasons**:
   - `GET /series/:tconst/seasons`
   - Returns full breakdown of seasons with localized Russian names and `poster_path`, plus `backdrop_path`, `logo_path` (prioritizing Russian logos), `overview`, `genres`, `studio`, `premiered`, `rating`, `status`.
3. **Fetch Episodes Metadata**:
   - `GET /series/:tconst/episodes`
   - Concurrently fetches all episodes across all seasons in parallel (`futures_util::future::join_all`) with in-memory LRU caching.
   - Response Payload:
     ```json
     [
       {
         "season_number": 1,
         "episode_number": 1,
         "name": "Пилот",
         "overview": "Во время семейного барбекю...",
         "air_date": "1999-01-10",
         "still_path": "/path-to-screenshot.jpg"
       }
     ]
     ```
   - Used by `tracker-proxy` during FUSE mounting to write exact per-episode XML `.nfo` files and download `-thumb.jpg` preview screenshots directly into Jellyfin season folders.
4. **Fetch Rich Movie/Series Metadata & Trailers**:
   - `GET /api/movie/:tconst/metadata`
   - Supports both movies and TV series by resolving TMDB external IDs (`movie_results` / `tv_results`).
   - Fetches TMDB details with `append_to_response=credits,videos,images&include_image_language=ru,en,null&include_video_language=ru,en,null`.
   - Returns:
     - Russian synopsis/overview with English fallback if missing.
     - Russian synopsis/overview with English fallback if missing.
     - Top 15 cast members (`id`, `name`, `character`, `profile_path`, `order`).
     - Key crew members:
       - **TV Series Creators**: Extracted from top-level `created_by` array with `job: "Creator"` (e.g. Jonathan Tropper, Vince Gilligan, David Chase).
       - **TV Episodic Directors & Writers**: Extracted from `aggregate_credits.crew` sorted by episode count descending, surfacing the real creative directors and writers of the show.
       - **General Crew**: Screenplay, Executive Producer, Producer, Composer, Cinematographer from `credits.crew`.
       - **Deduplication**: Automatically suppresses creators, directors, and writers from repeating in `Executive Producer` to spotlight other notable producers and stars (like Jon Hamm).
     - Filtered YouTube trailers & teasers prioritized by Russian localization and official status.
     - Image paths (`poster_path`, `backdrop_path`, `logo_path`).
   - Used by frontend for synopsis, cast avatars, crew badges, and embedded YouTube trailer playback.
5. **Fetch Person Metadata & Filmography**:
   - `GET /api/person/:person_id`
   - Fetches TMDB person profile with `append_to_response=combined_credits,external_ids&language=ru-RU` (with English fallback for biography if Russian is absent).
   - In-memory LRU cache (`persons_cache`, capacity 500).
   - Returns full biography, birthday, deathday, place of birth, department, profile image, and complete cast & crew credits with release dates, ratings, and character/job tags.
6. **Resolve TMDB Media to MovieDoc**:
   - `GET /api/tmdb/:media_type/:tmdb_id/movie`
   - Maps TMDB credit items back to Cine-Claw `MovieDoc` structures with IMDb `tconst`, Russian titles, genres, ratings, and runtimes for seamless in-app movie drill-down.
   - In-memory LRU cache (`resolved_cache`, capacity 1,000).
7. **Curated Home Cinema Feeds & Paginated Deep Dive**:
   - `GET /api/feeds` (alias: `/feeds`)
   - Aggregates 4 curated cinema discovery shelves (page 1, 20 items per shelf):
     - **«В тренде на этой неделе»** (`trending`): `GET /3/trending/all/week?language=ru-RU`
     - **«Свежие цифровые релизы»** (`digital`): `GET /3/discover/movie?language=ru-RU&sort_by=primary_release_date.desc&with_release_type=4|5&vote_count.gte=30` (guarantees movies that already dropped on VOD/streaming with high-quality WEB-DL torrent swarms)
     - **«Популярные сериалы»** (`popular_series`): `GET /3/tv/popular?language=ru-RU`
     - **«Шедевры всех времён»** (`top_rated`): `GET /3/movie/top_rated?language=ru-RU&vote_count.gte=1000`
   - In-memory cache with 2-hour TTL (`feeds_cache: Arc<SyncMutex<Option<(Instant, Vec<FeedShelf>)>>>`).
   - `GET /api/feeds/:shelf_id?page=N` (alias: `/feeds/:shelf_id`):
     - Fetches page `N` (1-indexed, 20 items per page) for the given `shelf_id`.
     - Returns `FeedShelf` with `page`, `total_pages`, `total_results`, and `items`.
     - In-memory LRU cache (`shelf_pages_cache`, capacity 10,000, 1h TTL).
   - Returns localized Russian titles, original titles, poster paths, release years, vote averages, and media types.

---

## 5. Poster Caching Proxy (`/api/poster/:tconst`)

Directly loading poster images from external CDNs causes CORS restrictions and rate limits:
- `imdb-indexer` proxies poster images through `GET /poster/:tconst` and `GET /api/poster/:tconst`.
- **In-Memory URL Caching**: `poster_paths_cache` (LRU, 10k items) stores `tconst -> tmdb_poster_path`, allowing all sizes (`w92`, `w154`, `w185`, `w342`) to download immediately without redundant `/find` and `/images` API queries.
- **Concurrency Limiting**: Uses a `tokio::sync::Semaphore` (capacity 6) to limit simultaneous TMDB downloads and prevent API rate-limiting or socket stalls.
- **Fail-Fast Timeout**: 6-second timeout prevents long connection queue stalls.
- **Atomic Temp Files**: Unique per-task temp files (`tmp.{pid}.{atomic_counter}`) prevent write collisions across sizes.
- **Disk Caching**: Images are cached to disk under `data/posters/{shard}/{tconst}_{size}.jpg`.
- **Cache-Control**: Served directly from disk with `Cache-Control: public, max-age=2592000, immutable` and ETag support.

---

## 6. Build & Operational Rules

```bash
# Build binary with maximum optimizations
cargo build --release

# Run the indexer
./target/release/imdb-indexer
```

> [!IMPORTANT]
> **Always compile in `--release` mode**. Tantivy and CSV decompression run up to $10\times$ slower in debug mode.
