# Frontend — Subsystem Documentation

## 1. Overview
The Cine-Claw v2 frontend is a fast, responsive Single Page Application (SPA) built with React 19, Vite 8, Tailwind CSS, and Redux Toolkit Query. It connects to `imdb-indexer` (`:8090`) for title search and TMDB season breakdowns, and `tracker-proxy` (`:9118`) for aggregated torrent releases.

---

## 2. Directory Structure

```
frontend/
├── src/
│   ├── api/
│   │   ├── moviesApi.ts             # RTK Query client for imdb-indexer (:8090)
│   │   ├── torrentsApi.ts           # RTK Query client for tracker-proxy (:9118) & mount API
│   │   └── types.ts                 # Shared TypeScript interfaces & DTOs
│   ├── components/
│   │   ├── home/
│   │   │   └── HomeShelves.tsx      # Curated TMDB horizontal carousels
│   │   ├── layout/
│   │   │   └── Header.tsx           # Navigation bar with Jellyfin link
│   │   ├── movie/
│   │   │   ├── MovieCard.tsx        # Poster grid item with rating & badges
│   │   │   ├── MovieList.tsx        # Search results virtual/responsive grid
│   │   │   ├── MovieModal.tsx       # Detail modal / full-screen screen with seasons & torrents
│   │   │   ├── MovieMetadataSection.tsx # Synopsis, crew badges, trailers & cast
│   │   │   ├── MoviePoster.tsx      # Proxied image loader with fallback
│   │   │   ├── PersonModal.tsx      # In-app person card & filmography
│   │   │   ├── TrailerModal.tsx     # Embedded YouTube trailer player
│   │   │   └── TorrentList.tsx      # Deduped torrents, filters, and "Смотреть" button
│   │   ├── search/
│   │   │   ├── FilterBar.tsx        # Year / rating / genre filters & bottom drawer
│   │   │   ├── QuickChips.tsx       # Quick search recommendation chips
│   │   │   └── SearchBar.tsx        # Instant debounced search input (bottom dock)
│   │   └── ui/                      # Base UI primitives (Badge, Button, Dialog, etc.)
│   ├── store/
│   │   ├── searchSlice.ts           # Client search state
│   │   └── store.ts                 # Redux store configuration
│   ├── App.tsx                      # Root application component
│   └── main.tsx                     # React 19 entry point
├── package.json
└── vite.config.ts
```

---

## 3. Client-Side Instant Filtering

To keep the UI responsive, torrent filtering is performed **entirely in memory** on the client:

### Season Range Matching
Torrents often bundle multiple seasons (e.g. `"Сезоны 1-2"` or `"S01-S03"`).
- The parser extracts all available seasons as a `number[]` array for each release.
- Supported patterns:
  - Single: `Сезон:?\s*(\d+)`, `\bS(\d+)\b`, `(\d+)-й сезон`.
  - Ranges: `Сезоны?:?\s*(\d+)-(\d+)`, `S(\d+)-S?(\d+)`, `(\d+)-(\d+)\s+сезон`.
- When filtering by a specific season (e.g. `Season 2`), a release covering `Seasons 1-3` matches and remains visible.

### Resolution Categorization
Releases are categorized into three distinct buckets:
- **`4K`**: `2160p`, `4k`, `uhd`.
- **`1080p`**: `1080p`, `1080i`, `fhd`.
- **`LQ`** (Low Quality / Other): `720p`, `hdrip`, `web-dlrip`, `dvdrip`, `satrip`, etc.

---

## 4. State Management & Cache Refresh (RTK Query)

### Force Refresh Workflow (`torrentsApi.ts`)
When the user clicks the "Refresh" button in the torrents header:
1. `useForceRefreshTorrentsMutation` triggers `POST /api/torrents/refresh?tconst=...`.
2. Inside `onQueryStarted`, upon successful response from the proxy, RTK Query directly mutates the cached query state via `updateQueryData`:
   ```ts
   dispatch(
     torrentsApi.util.updateQueryData('getTorrents', tconst, () => freshTorrents)
   );
   ```
3. The UI re-renders immediately without flash of unstyled content (FOUC) or redundant network roundtrips.

---

## 5. Instant Streaming ("Смотреть" in Jellyfin)

Inside `TorrentList.tsx`, each torrent card features a high-visibility **"Смотреть"** button:
1. Rendered for all releases that have either a synthesized `magnet` link or a tracker `id` (allowing on-the-fly InfoHash resolution).
2. The button transitions dynamically through states:
   - **Idle**: Indigo button (`Добавить` with `Plus` icon).
   - **Mounting**: Spinner icon with label `Монтирование...`.
   - **Success**: Emerald badge with check icon (`В Jellyfin`), opening `http://localhost:8096` in a new tab.
   - **Error**: Reverts to retryable error state.
3. **Conflict Detection & `MountConflictDialog`**:
   - When the user clicks `Добавить`, the UI checks the live `useGetMountedStatusQuery(imdbId)`.
   - If the movie is already mounted, or if the series season is already mounted, the `MountConflictDialog` opens instead of directly mounting:
     - **Option A: "Добавить как версию" (Recommended)**: User can enter/confirm a version label (e.g. `4K UHD`, `1080p Remux`). Sends `mode: "add_version"` with `version_name`.
     - **Option B: "Заменить"**: Sends `mode: "replace"`, cleanly unmounting old swarms and files before adding the new release.
   - If no conflict exists (e.g. adding Season 2 when only Season 1 is mounted), mounts directly with `mode: "add"`.
4. **Library Mount Status & Unmount Button**:
   - `MovieModal.tsx` checks `useGetMountedStatusQuery(movie.tconst)`.
   - When mounted, displays an emerald status badge showing total mounted video files, directory name, active versions (`Версии: 4K UHD, SD`), and active seasons (`Сезоны: 1, 2`).
   - Provides an inline `Удалить из библиотеки` button with a two-step confirmation toggle (`Точно удалить?` / `Отмена`) that calls `useUnmountTorrentMutation` to cleanly unmount and wipe the item across all microservices.

---

## 6. Mobile-First Architecture & UI Ergonomics

CineClaw v2 is architected around a **mobile-first cinema experience**:

### 1. Bottom-Docked Search (`SearchBar` & `QuickChips`)
- Positioned fixed at the bottom (`fixed bottom-0 inset-x-0 z-40 bg-cinema-950/95 backdrop-blur-2xl`) directly within the thumb zone.
- Incorporates iOS/Android safe area insets: `pb-[max(0.75rem,env(safe-area-inset-bottom))]`.
- Includes instant clear (`X`) button, instant hotkey `/` for desktop, and integrated Filter Drawer toggle with active filter count badge.
- Main content container uses safe bottom padding (`pb-[calc(7.5rem+env(safe-area-inset-bottom))]`) so results are never obscured.

### 2. Bottom-Up Results Flow (`MovieList`)
- Results use `flex-col-reverse` so **Rank 1** (the #1 best search match) is anchored directly above the user's thumb and bottom search dock.
- Scrolling upwards reveals lower-ranked titles.
- Automatic smooth scroll to bottom upon query completion ensures Rank 1 is instantly visible without manual scrolling.
- Empty state suggestions ("Популярные тайтлы") are similarly anchored right above the bottom dock.

### 3. Dedicated Full-Screen Screen View on Mobile (`MovieModal`)
- On mobile devices (`< md` / `useIsMobile`), the movie card opens as a **dedicated native-feeling full-screen screen** (`fixed inset-0 z-50 bg-cinema-950 overflow-y-auto`):
  - **Sticky Top Bar**: `pt-[max(0.5rem,env(safe-area-inset-top))]` with a large touch `< Назад` button, title/year, IMDb external link, and unmount action.
  - **Hero Section**: Poster, rating badge, year, runtime, type, IMDb vote counts, and genres.
  - **Jellyfin Status Banner**: Emerald card showing mounted file count, active versions, seasons, and a direct "Смотреть" button to Jellyfin.
  - **Rich Metadata & Synopsis (`MovieOverview`)**: Expandable synopsis ("Читать далее" / "Свернуть") with localized Russian text.
  - **Crew Badges (`MovieCrewBadges`)**: Key roles mapped to Russian labels (Создатель, Режиссёр, Сценарий, Исполнительный продюсер, Продюсер, Композитор, Оператор).
    - **Dynamic TV Hierarchy**: For TV series, promotes `Создатель` (Creator) to top priority, followed by episodic `Режиссёр` and `Сценарий`, and automatically deduplicates creators/writers from repeating under `Исполнительный продюсер` so other prominent figures (such as lead actors/stars) are spotlighted.
    - **Baseline Alignment**: Badges use `items-baseline` to preserve neat typographic alignment on narrow mobile screens.
    - Clicking any creator or crew member opens their in-app **Person Card** (`PersonModal`).
  - **Trailers & Teasers Gallery (`MovieTrailers`)**: Horizontally swipeable video cards with YouTube thumbnails, play overlays, and badges. Clicking opens `TrailerModal` with an embedded YouTube player without leaving the application. On mobile, the modal hooks into browser history (`history.pushState`), allowing back swipe/gesture to dismiss the player.
  - **Cast Avatar Carousel (`MovieCast`)**: Horizontally swipeable circular avatars (`w-14 h-14` / `w-16 h-16`) with TMDB actor photos, names, and character roles. Clicking any actor opens their in-app **Person Card** (`PersonModal`).
  - **Swipeable Season Selector**: Horizontally swipeable season pills (`overflow-x-auto no-scrollbar`) with per-season release counts.
  - **Unified Page Scrolling (No Nested Scrollbars)**:
    - On mobile, `TorrentList` has no `max-h-96` or `overflow-y-auto` — all releases flow naturally in the document flow, scrolling together with the poster, metadata, trailers, cast, and torrents.
    - Background body scrolling is locked (`document.body.style.overflow = "hidden"`) while the movie screen is open, preventing background scroll leaks.
    - Custom scrollbars are strictly scoped to desktop (`@media (min-width: 768px)`), allowing mobile browsers to render native disappearing touch scrollbars.
  - **Browser History & Gesture Navigation**: Integrates `history.pushState` and `popstate` so mobile swipe-back gestures or hardware/browser back buttons cleanly dismiss the movie screen.
- On desktop (`md:`), renders a centered `Dialog` modal with the rich metadata, crew badges, full-width trailers carousel, cast carousel, and dedicated scrollable release container (`md:max-h-96 md:overflow-y-auto`).

### 4. In-App Person Card & Filmography (`PersonModal`)
- **Native Experience**: Rather than navigating away to TMDB, clicking any actor in `MovieCast` or creator in `MovieCrewBadges` opens an in-app **Person Card** (`PersonModal`):
  - **Mobile View**: Dedicated full-screen screen (`fixed inset-0 z-[60] bg-background flex flex-col`) with a sticky top bar (`< Назад`, person name, close `X`), browser back-gesture handling (`popstate`), and fluid `framer-motion` slide transitions.
  - **Desktop View**: Sleek `Dialog` modal (`max-w-4xl max-h-[88vh] overflow-y-auto`).
- **Rich Personal Metadata**:
  - High-resolution profile photo with department badge (e.g. «Актёрское искусство», «Режиссура», «Продюсирование»).
  - Localized Russian name with original title fallback.
  - Date and place of birth with automatically computed age and lifespan (e.g. `18 декабря 1963 (62 года), Shawnee, Oklahoma, USA`).
  - Expandable Russian biography with fallback to English if missing.
- **Interactive Filmography & Sorting**:
  - Displays complete filmography with tab filters: **«Все»**, **«В кадре»** (acting credits), and **«За кадром»** (directing, writing, producing credits).
  - Two sorting modes:
    - **«Лучшие»**: Ranks by weighted quality score `(vote_average * log10(vote_count + 1))` to feature iconic, acclaimed works first.
    - **«Новые»**: Ranks by release date / year descending.
- **Instant Movie Drill-Down**:
  - Clicking any filmography card calls `/api/tmdb/:media_type/:id/movie` to resolve the full `MovieDoc`.
  - Dispatches `setSelectedMovie(doc)` and seamlessly transitions the user directly to Cine-Claw's dedicated movie screen for that title, loading its torrent releases and 1-click streaming options.

### 5. Bottom Sheet Filter Drawer (`FilterBar`)
- Sliding bottom sheet on mobile (`fixed inset-0 z-50 flex items-end animate-in slide-in-from-bottom duration-200`) with drag indicator, year range, minimum votes select, and reset button.

### 6. Input Debouncing & Fluid Framer-Motion Animations
1. **Search Input Debouncing**:
   - `SearchBar.tsx` uses local input state (`inputValue`) for instant 120Hz typing without state latency.
   - Debounces dispatch to Redux (`setQuery`, `setDebouncedQuery`) by 400ms to eliminate redundant network queries while typing.
   - Pressing `Enter` or clicking a popular chip triggers `setImmediateQuery` immediately, bypassing the timer.
   - Immediate wipe of search state when input is cleared.
   - `MovieList.tsx` checks `debouncedQuery`, eliminating premature "Ничего не найдено" flashes during active keystrokes.
2. **Top-Down Search Results Cascade ("Вылет сверху")**:
   - Individual movie cards animate into view from the top (`y: -36 -> 0`, `opacity: 0 -> 1`) with physical spring dynamics (`damping: 24, stiffness: 280`).
   - Cards in `MovieList.tsx` are staggered (`staggerChildren: 0.04s`), creating a cascading deck effect.
3. **Smooth Results Replacement Transitions**:
   - `MovieList` wraps the results list in `<AnimatePresence mode="wait">` keyed by query and filter state.
   - When searching for a new term, previous results smoothly fade and settle down (`y: 12, opacity: 0`), followed by the incoming set cascading from the top.
4. **Screen Push & Slide Navigation Animations**:
   - On mobile, `MovieModal` utilizes `AnimatePresence` with `motion.div`:
     - **Open**: Springs in smoothly from the right (`x: "100%" -> x: 0`).
     - **Back**: Springs smoothly back to the right (`x: 0 -> x: "100%"`), revealing the search results underneath.
     - Uses `activeMovie` cache ref so all content and posters remain perfectly rendered throughout the exit transition.

### 7. Curated TMDB Discovery Shelves & Full View (`HomeShelves`, `ShelfModal`)
- **Shelves**:
  - «В тренде на этой неделе» (`Flame` icon)
  - «Свежие цифровые релизы» (`Film` icon)
  - «Популярные сериалы» (`Tv` icon)
  - «Шедевры всех времён» (`Sparkles` icon)
- **Cards**: High-res TMDB posters, ratings (★), TV badges, and localized Russian titles.
- **Shelf Pagination & Full View (`ShelfModal`)**:
  - Each shelf header includes a prominent **«Ещё →»** button.
  - Clicking «Ещё →» opens a dedicated modal/screen displaying a responsive grid (`grid-cols-2` on mobile, up to `grid-cols-5` on desktop).
  - Includes a **«Загрузить ещё (+20)»** pagination button backed by `useLazyGetShelfPageQuery` (`/api/feeds/:shelf_id?page=N`).
  - Total catalog and displayed item count badges.
  - **Mobile Navigation Stack**: Native full-screen `motion.div` with sticky `< Назад` bar, browser popstate back-gesture support (`cineclawShelf` vs `cineclawMovie`), allowing users to drill into movie details and return back to the exact shelf scroll position and loaded pages.
- **Instant Drill-Down**: Clicking any item calls `lazyResolveTmdbMovie` (`/api/tmdb/:media_type/:id/movie`) and sets `selectedMovie`, immediately launching Cine-Claw's movie screen with torrent aggregations and Jellyfin streaming.
- **Instant Clear Integration**: Emptying the search query instantly wipes search results and cleanly reveals the shelves via `AnimatePresence`.


### 8. Direct Edge TMDB CDN Streaming & Responsive Images (`tmdbImages.ts`, `MoviePoster`)
- **Direct Cloudflare Edge CDN**: All image requests bypass the server proxy and fetch directly from `https://image.tmdb.org/t/p/${size}/${cleanPath}` via `getTmdbImageUrl`.
- **Responsive Resolution (`srcset`)**: `getTmdbImageSrcSet` produces responsive 1x/2x descriptors (`w342 1x, w500 2x`) for crisp rendering on high-DPI Retina displays and mobile screens without over-fetching.
- **Zero-Delay Fallbacks**: Removed legacy 2-second retry loops and cache-busting counters (`&r=1`, `&r=2`), since images stream immediately from TMDB's edge network rather than waiting for backend disk writes.
- **Priority Loading**: The top search matches receive `loading="eager"` and `fetchPriority="high"`, while off-screen shelf cards use `loading="lazy"`.
- **Graceful Cinema Placeholder**: If an item lacks a TMDB poster path or the CDN returns an error, `MoviePoster` immediately renders a sleek obsidian SVG placeholder with film reel branding and title metadata.

### 9. Progressive Web App (PWA) & Unified Cinema Theme
- **Branding & Vector Icons**:
  - Custom CineClaw vector brand icon (`favicon.svg`) featuring dark obsidian squircle, beveled gold border, film reel perforations, and 3 luminous golden claw marks (`#f5c518`).
  - High-res PNG suite in `/icons/`: `icon-512x512.png`, `icon-192x192.png`, Android maskable variants with 80% safe zone (`icon-512x512-maskable.png`, `icon-192x192-maskable.png`), iOS `apple-touch-icon.png` (180x180), and `favicon-32x32.png`.
- **Web App Manifest (`manifest.webmanifest`)**:
  - Application name: `CineClaw`.
  - `display: "standalone"`, `orientation: "portrait"`, `background_color: "#07090e"`, `theme_color: "#07090e"`.
- **Service Worker (`sw.js`)**:
  - Registered in `main.tsx`. Pre-caches app shell (`/`, `/index.html`, `/manifest.webmanifest`, CSS/JS bundles).
  - **Strict Streaming Bypass**: Explicitly bypasses `/torrents/*`, `/stream/*`, `/api/*`, `/search*`, `/poster/*`, `/series/*` so range requests, video streams, and dynamic tracker scrapes are never intercepted or cached in CacheStorage.
- **Unified Background & Safe-Area Insets**:
  - Unified `#07090e` (exact match to `--background: 223 33% 4.1%` and `bg-cinema-950`) across `html`, `body`, `#root`, and modals.
  - `overscroll-behavior-y: none` prevents white rubber-banding overscroll flashes on iOS Safari/PWA.
  - `viewport-fit=cover` in `index.html` combined with `apple-mobile-web-app-status-bar-style: black-translucent`.
  - Headers and sticky top bars include `pt-[env(safe-area-inset-top)]` ensuring edge-to-edge immersion behind iOS Dynamic Island and notch without content clipping.

### 10. Web Authentication & Session Handling
- **State Management (`authSlice.ts`)**:
  - Manages `token`, `username`, `isAuthenticated`, and `rememberMe`.
  - Persists credentials into `localStorage` (if "Remember Me" is enabled, 30 days) or `sessionStorage` (for temporary browser sessions).
- **Automated Request Authorization (`baseQuery.ts`)**:
  - Custom base query wrapper automatically attaches `Authorization: Bearer <token>` to all RTK Query API calls.
  - Intercepts `401 Unauthorized` responses and automatically dispatches `logout()` to prompt re-authentication.
- **Login Modal (`LoginModal.tsx`)**:
  - Dark cinema-themed modal matching `#07090e` obsidian aesthetic.
  - Smooth password visibility toggle, error display, and "Запомнить меня на этом устройстве" checkbox.
- **User Profile & Logout (`Header.tsx`)**:
  - User badge displaying active username.
  - One-click logout button triggering `POST /api/auth/logout` to invalidate server cookie and client storage.

### 11. Catalog Discovery Hub & On-Demand Shelves
- **Catalog Launcher Grid (`CatalogTilesGrid.tsx`)**:
  - Replaces heavy initial loading of 4 eager shelves with interactive 12-tile hub.
  - Displays top media toggle `[ 🎬 Фильмы | 📺 Сериалы ]` allowing user to switch global catalog focus before opening any list.
  - Supported catalogs: «Популярно на трекерах» (`tracker_hotlist`), «4K UHD Кинозал» (`uhd_4k`), «Аниме & Мультипликация» (`anime_hub`), «Документальное кино» (`doc_hub`), «Apple TV+ Originals» (`apple_tv`), «HBO / Max Originals» (`hbo_max`), «Netflix Хиты» (`netflix`), «Amazon Prime Video» (`amazon_prime`), «В тренде на этой неделе» (`trending`), «Свежие цифровые релизы» (`digital`), «Шедевры всех времён» (`top_rated`), and «Умный каталог & Фильтр» (`catalog_filter`).
- **Interactive Multi-Criteria Filter Bar (`CatalogFilterBar.tsx`)**:
  - Quick-filter chips for Countries (US, KR, JP, GB, FR, RU), Genres (Action, Sci-Fi, Thriller, Comedy, Drama, Criminal, Anime/Cartoons, Horror), Release Years (2025-2026, 2020-2024, 2010s, 2000s, 90s), and Ratings (Any, 7.0+, 7.5+, 8.0+).
  - Dynamically passes query parameters to `/api/catalog/discover`.
- **Dedicated Shelf Screen (`ShelfModal.tsx`)**:
  - Desktop modal / mobile full-screen screen with infinite pagination (`+20` button).
  - Displays live BitTorrent seeds badge (`🌱 {seeds} сидов`) on tracker hotlist items.
  - Includes quality filter toggle `[ Все качества | ✨ Только 4K UHD ]` for live swarm hotlists.
  - Fast-paths items with resolved IMDb `tconst` directly into the cinema movie screen without TMDB roundtrips.
  - Synchronized with browser history stack (`pushState` / `popstate`) for flawless back-gesture navigation.

---

## 7. UI Guidelines & Design System

- **Theme**: Dark cinema aesthetic (`bg-neutral-950`, `border-neutral-800`, `text-neutral-100`).
- **Icons**: Standardized on [Lucide React](https://lucide.dev/icons).
- **Tracker Badges**:
  - Combined / Merged releases display multi-tracker badges (e.g. `RuTracker` + `RuTor` + `NNM-Club`).
  - Hovering over seeder counts displays an interactive tooltip with per-tracker seed breakdowns.
- **Responsiveness**: Mobile-first flex layout with swipeable horizontally scrollable filters (`no-scrollbar`) preventing layout blowout.

---

## 8. Embedded Cinema Player (`CinemaPlayerModal.tsx`)

- **Root Level Portal Rendering**: Rendered via `createPortal(..., document.body)` at `z-[100]` with `pointer-events-auto`, ensuring seamless pointer and touch interaction without interference or event interception from parent modals.
- **Radix UI Dialog Coexistence**: When `isCinemaPlayerOpen` is active, the underlying `MovieModal` sets `open={!!movie && !isCinemaPlayerOpen}` to unmount/suspend the Radix dialog overlay, focus traps, and body pointer locks.
- **Auto-Retry & Library Index Polling**: When newly mounted titles (especially multi-episode TV series) are still being processed by Jellyfin, the player displays a non-blocking pulsing sync state (`"Монтирование в Jellyfin... Jellyfin регистрирует видеопоток (попытка N/8)"`) and polls every 1.5s until episodes and streams are ready.
- **Episode Switching & Stream Isolation**:
  - `PlaySessionId` is freshly generated on every episode change, preventing Jellyfin's `DynamicHlsController` from reusing the previous episode's transcoding worker and `.ts` cache.
  - The `<video>` element is keyed dynamically (`key={`video-${tconst}-${currentSeason ?? 0}-${currentEpisode ?? 0}`}`), guaranteeing full flush of hardware decoders and buffer isolation between episodes.
  - During episode switching, `reportStop` passes `close_player: false` so that GoStorm maintains the series torrent in memory while reporting the previous episode's watch progress to Jellyfin. When the user explicitly closes the player (`close_player: true`), torrent resources are released.
- **fMP4 HLS Pipeline & Web Compatibility**:
  - Streams are requested with `SegmentContainer=mp4&MinSegments=2&BreakOnNonKeyFrames=True&VideoCodec=h264&AudioCodec=aac`.
  - `EnableAutoStreamCopy=true` is strictly omitted to prevent Jellyfin from forcing video stream copy with `-bsf:v h264_mp4toannexb` on 4K HEVC / Dolby Vision content. This ensures Jellyfin automatically remuxes standard H.264 streams without re-encoding while seamlessly hardware/CPU transcoding 4K HEVC HDR streams into browser-playable H.264 fMP4 chunks.
- **Natural Russian Episode Nomenclature**:
  - Player header and drawer display natural Russian episode titles: `Сезон {N}, серия {M} — {Название}` (e.g. `Сезон 2, серия 3 — Соло`).
  - Completely eliminates raw filename strings (`S02E00`) and unparsed metadata tags.
- **Error Recovery**: Dedicated error view with elevated `z-50 pointer-events-auto` and `stopPropagation` controls for «Повторить» (immediate retry), «Выбрать по сидам» (opens alternate releases modal), and «Вернуться назад» (return to details).
- **Dynamic Video Quality Ladder & Bitrate Presets**:
  - **Dynamic Swarm & Quality Selector**:
    - Replaces artificial server-side transcode presets with actual available BitTorrent releases from trackers.
    - Computes real-time approximate stream bitrate for every release based on file size and title duration:
      $$\text{Bitrate (Mbps)} = \frac{\text{size\_in\_bytes} \times 8}{\text{duration\_in\_seconds} \times 10^6}$$
      (for TV series season packs, divides season pack size by episode count).
    - Formats bitrates clearly (e.g. `28.5 Мбит/с`, `11.5 Мбит/с`, `2.4 Мбит/с`).
    - Quality options sorted descending by resolution tier (4K UHD -> 1080p FHD -> 720p HD -> SD) and bitrate.
    - Displays resolution badge (`4K` in amber, `1080p` in emerald, `720p` in blue), computed bitrate, size in GB, live seeder count (`🌱 501`), audio dubbing tags (`Дубляж`, `Многоголосый`), and tracker source.
    - Highlights currently active release with `Текущая` badge and checkmark.
    - Bottom player control bar pill displays active resolution and bitrate (e.g. `1080p • 10.5 Мбит/с`).
    - **Seamless In-Player Release Switching**: Clicking another release mounts it instantly, preserves current playback position (`video.currentTime`) to the exact second, and resumes streaming without leaving the player.
  - **30-Second Stall Detection & Alternate Release Switcher**:
    - Built-in timer monitors continuous waiting/buffering (`(isBuffering || isPreparingStream) && !isPlaying`).
    - If buffering exceeds 30 seconds, an obsidian cinema banner appears: *"Долгая буферизация (>30 сек). Похоже, текущая раздача медленно отдает данные. Хотите переключиться на раздачу с максимальным количеством сидов?"*
    - User can snooze («Подождать»), open the Quality / Swarm selector («Сменить качество»), or open the **Alternate Release Picker** (`showAlternateModal`), strictly sorted by seeds descending (`seeds desc`) with live seed count (`🌱 N сидов`), leechers, file size, tracker, and audio tag.
    - Selecting a release mounts it via `mode: 'add_version'`, updates player info, and resumes playback seamlessly from the exact timestamp.

---

## 10. Standalone Cinema Experience & Episode Browser

### Intelligent Quality & Action Selector (`QualityActionButtons.tsx`)
- Replaces raw torrent lists by default with two primary action buttons on titles:
  - **«Смотреть»**: Launches playback immediately in the embedded cinema player. If the release is already in Jellyfin, playback begins instantly with 0 wait time. If not yet mounted, automatically mounts the best matching torrent with `mode: 'add_version'` and starts playback without interrupting the user.
  - **«Добавить»**: Silently mounts the chosen quality release into Jellyfin in the background, displaying an inline confirmation badge without navigating away.
- **Quality Selector Tabs**: `4K UHD`, `1080p FHD`, `720p HD`, and `SD`. Each tier displays availability, live Jellyfin library presence (`● В Jellyfin`), seeder count, file size, and audio dubbing label (e.g. `Дубляж`, `Red Head Sound`, `MVO`).

### Automated Torrent Selection Heuristic (`torrentSelector.ts`)
- **`classifyResolution`**: Buckets releases into `4k`, `1080p`, `720p`, or `sd`.
- **`scoreTorrent`**: Multi-factor scoring algorithm prioritizing swarm vitality:
  - **Seeders (Primary Metric)**: High linear and logarithmic weight: $\min(\text{seeds}, 50) \times 3 + \ln(1 + \text{seeds}) \times 25$.
  - **Dead / Low-Seed Penalties**: Severe penalties for dead or low-seed torrents: $\text{seeds} = 0$ (-250), $\text{seeds} < 3$ (-100), $\text{seeds} < 6$ (-40).
  - **Audio Dubbing (Minor Tiebreaker)**: Secondary bonus if seeds are comparable: Dub / Red Head Sound / iTunes (+10), professional multi-voice MVO (+8), dual-voice DVO (+4), author voiceovers (+2). Popular original/MVO releases with high seeds always take precedence over low-seed dubs.
  - **Encode Type**: Clean encodes get a bonus: Remux / BDRemux / Blu-ray / WEB-DL / BDRip (+15).
  - **Penalty for Screeners**: Severe penalty (-300) for CAMRip, TS, Telesync.
  - **TV Season Matching**: Strict season alignment (+120 for target season, +30 for complete season pack, -500 if explicitly for a different season).

### Continue Watching Shelf (`ContinueWatchingShelf.tsx`)
- Renders at the top of the home screen, fetching in-progress items via `useGetResumeItemsQuery` from `/api/stream/resume`.
- Features 16:9 thumbnail previews, season/episode pills, remaining time calculation, visual progress bar, and instant 1-click playback continuation.

### TV Series Episode Browser (`SeriesEpisodeBrowser.tsx`)
- **Active Season Showcase Card**: Displays the vertical 2:3 season poster cover (`poster_path`), season name, Russian pluralized episode count (`13 серий`), air year (`1999 г.`), season rating (`★ 8.0`), library readiness badge, and full Russian season synopsis with collapsible toggle («Подробнее / Свернуть»).
- **Season Selection Tabs**: Clean cinema pills with season name, episode counts, star ratings, and library presence indicator dots.
- **Enriched 16:9 Episode Cards**: High-definition TMDB episode still previews (`still_path` via `getTmdbImageUrl` with local `/poster` proxy fallback, eliminating SVG placeholder failures), episode numbers, episode titles, runtime badges (`Clock` icon + `58 мин`), episode star ratings (`★ 7.7` with vote counts), season finale badges (`ФИНАЛ`), Russian air dates, plot synopses, watch progress bars, and 1-click episode playback.
- Embeds `QualityActionButtons` directly within the active season card.

### Collapsible Manual Torrent Picker
- Retains the granular `TorrentList` within a collapsible `<details>` accordion at the bottom of the modal, allowing power users to inspect trackers, hashes, and individual files whenever needed.

---

## 11. Watchlist Shelf & Fresh BitTorrent Releases

### Watchlist Shelf («Буду смотреть») (`WatchlistShelf.tsx`)
- Renders as a dedicated carousel shelf on the home screen (`HomeShelves.tsx`) beneath «Продолжить просмотр».
- Displays live counter badge (`{items.length}`), 2:3 posters, rating, media type badge, and title.
- **1-Click Card Removal**: Quick `✕` button on hover/tap in the top-right corner of each card removes the item from SQLite (`DELETE /api/watchlist?imdb_id=...`) with optimistic cache invalidation in RTK Query. If empty, the shelf automatically collapses without empty space.
- **Movie Modal Bookmark Button**: Interactive «📌 Буду смотреть» button in `MovieModal.tsx` (both desktop and mobile viewports) toggling to «🔖 В списке» with live state sync.

### Fresh BitTorrent Releases («Новинки на трекерах») (`CatalogTilesGrid.tsx`, `ShelfModal.tsx`)
- Highlighted tile in the Catalog Hub (`tracker_fresh` with Flame icon and rose accent).
- Sourced from `/torrents/hotlist?type=new_movie|new_tv`, presenting the freshest torrent releases by upload date (`PublishDate DESC`) filtered for `Year >= 2025`.
- Seamless switching between `🎬 Фильмы` and `📺 Сериалы` within `ShelfModal.tsx`.
- Television series are deduplicated by title and IMDb ID, preventing episode flooding and surfacing genuine series premieres and latest seasons.
- Displays live seed counts (`🌱 {seeds} сидов`), quality tags, release year, and IMDb ratings.

---

## 12. Streamlined Cinema UI, Season Posters & Poster Quick Play

### Clean Cinema Action Area (Replacing Quality Clutter)
- Eliminated pre-playback technical quality grids and gigabyte badges (`QualityActionButtons`) from movie and TV series screens.
- **Movies**: A single, prominent emerald-gradient hero button **«Смотреть (1080p)»** paired with the **«Буду смотреть»** watchlist bookmark. If the title is already mounted in the library, an unobtrusive status pill is displayed with an optional unmount button.
- Quality selection and adjustment is handled during playback directly inside the embedded `CinemaPlayerModal`.

### All-Season Visual Poster Showcase (`SeriesEpisodeBrowser.tsx`)
- All seasons are rendered simultaneously in a responsive, horizontal scrollable shelf of **Season Poster Cards**:
  - Each card displays a vertical 2:3 season poster (`poster_path`, proxy fallback), season number/title, pluralized episode counts, release year, and TMDB star rating (`★ 8.4`).
  - Active season card features an emerald border, outer glow ring, and visual selection highlight.
  - Clicking any season card immediately focuses that season and loads its episode list below.
- Active season showcase card includes Russian synopsis with expandable toggle («Подробнее о сезоне / Свернуть») and a clean **«Смотреть сезон» / «Продолжить с N серии»** hero play button.
- 16:9 episode cards feature still previews, runtimes, finale badges, ratings, progress bars, and instant 1-click play.

### Client-Side Quality Preferences (`userSettings.ts`, `Header.tsx`)
- Preference stored in browser `localStorage` (`cineclaw_default_quality`), defaulting to **`1080p`**.
- Reactive synchronization via custom window events (`cineclaw_quality_changed`).
- Accessible from the header navigation bar via an obsidian popover selector (`[ 1080p ▾ ]`) allowing users to choose between `1080p Full HD`, `4K Ultra HD`, `720p HD`, and `SD Качество`.
- `selectPreferredTorrent` automatically prioritizes the user's preferred tier, gracefully falling back to adjacent resolutions if no releases exist in that tier.

### 1-Click Quick Play from Posters (`useQuickPlay.ts`, `MovieCard.tsx`)
- Poster cards across search results (`MovieCard`), featured carousels (`HomeShelves`), and catalog modals (`ShelfModal`) feature a floating circular Play button:
  - Visible on touch/mobile devices; smooth hover reveal and scale on desktop.
  - Clicking the play button triggers playback directly without opening the details modal (`e.stopPropagation()`).
  - **Movies**: Automatically selects the best torrent for preferred quality (1080p), mounts if necessary, and opens the player.
---

## 13. Mobile-First Cinema Video Player & Bottom Sheet Overhaul (`CinemaPlayerModal.tsx`)

### Problem Solved
On mobile viewports (<640px, iPhones with notch / Dynamic Island), the cinema video player previously broke after buffering began:
1. Top bar headers jammed into the notch due to missing safe-area insets.
2. Bottom controls row wrapped into multiple jagged lines, truncating the timecode.
3. Quality, audio, subtitles, and speed buttons triggered desktop `absolute bottom-12 right-0 w-72` popovers that projected ~70px off the left screen edge.
4. Tapping the video element unintentionally paused playback rather than toggling UI controls.

### Implementation Details
- **Safe-Area Inset Integration**:
  Top bar (`pt-[max(0.75rem,env(safe-area-inset-top))]`), bottom bar (`pb-[max(1rem,env(safe-area-inset-bottom))]`), and horizontal insets (`pl-[max(0.75rem,env(safe-area-inset-left))] pr-[max(0.75rem,env(safe-area-inset-right))]`).
- **Mobile Gesture Engine**:
  - Single-tap on screen toggles player controls overlay visibility without accidental pauses.
  - Double-tap on left 35% of screen seeks -10s with animated circular ripple.
  - Double-tap on right 35% of screen seeks +10s with animated circular ripple.
  - Fullscreen button with Safari iOS fallback to `video.webkitEnterFullscreen()`.
- **Dual-Tier Layout**:
  - Center-screen transport controls (`[ -10s ]`, `[ ▶ / ❚❚ ]`, `[ +10s ]`) rendered on mobile during control visibility.
  - Separate mobile timecode row above action bar with zero line wrapping.
  - Clean single-row mobile action bar:
    `[ 📺 Серии ]` · `[ 🌐 Звук ]` · `[ 💬 Субтитры ]` · `[ ⚙️ 1080p ]` · `[ ⚡ 1x ]` · `[ ⛶ ]`.
- **Native Mobile Bottom Sheets**:
  Desktop popovers are restricted to `sm:block`. On mobile, menus open as full-width bottom sheets (`fixed inset-x-0 bottom-0 z-50 rounded-t-3xl bg-zinc-950/98 backdrop-blur-2xl animate-slide-up`):
  - **Quality & Torrents**: Accordion groups (4K UHD, 1080p FHD, 720p HD, SD) with large touch targets, active checkmarks, bitrates, sizes, and seeds.
  - **Audio Tracks**: Scrollable list of audio streams with track titles and instant switching.
  - **Subtitles**: List of subtitle options with "Отключены".
  - **Playback Speed**: 3x2 grid of speeds (0.5x – 2x).
  - **External Player**: Touch cards for VLC, IINA, Infuse, and stream link copying.
- **Episodes Drawer & Modals**:
  Slide-out episodes drawer features mobile backdrop and safe-area insets. Stalling prompt and seed picker modal feature vertical button stacks for easy thumb tapping.
- **Cleaned Nested Button HTML Violations**:
  Converted outer poster cards in `HomeShelves.tsx` and `ShelfModal.tsx` from `<button>` to `<div role="button" tabIndex={0}>`, eliminating Vite DOM nesting errors and ensuring reliable mobile touch propagation.

---

## 14. Mobile Edge-to-Edge Carousel Architecture & Viewport Unclipping

### Problem Solved
On mobile devices (e.g. iOS Safari / iPhone):
1. **Mid-Screen Card Cutoff**: Shelves (`ContinueWatchingShelf`, `WatchlistShelf`, `HomeShelves` preview strip) were nested inside `App.tsx` `<section className="container max-w-3xl px-3 sm:px-6">`. Carousels had their scrollports clipped at 12–16px inside the screen, causing cards to hit an invisible wall and chop off before reaching the screen bezel.
2. **Void Margins on Peeking Cards**: Off-screen cards peeking from the right margin had an awkward empty gutter instead of bleeding to the phone edge.
3. **Vertical Bottom Dock Collision**: Main container had insufficient bottom padding (`pb-[calc(7.5rem+...)]`) relative to the fixed bottom search dock height (152px), permanently obscuring the bottom 30–40px of content (titles, ratings, catalog launcher tiles).

### Implementation Details
- **Decoupled Home Section Width (`App.tsx` & `HomeShelves.tsx`)**:
  When `debouncedQuery` is empty, `<section>` switches from restrictive `container max-w-3xl px-3 sm:px-6 justify-end` to `w-full py-2 justify-start` (removing `overflow-x-hidden` which creates unwanted WebKit scroll clipping contexts). In `HomeShelves.tsx`, root container is `w-full text-left` (removing restrictive `max-w-4xl mx-auto` that capped carousels at 896px on desktop/tablets).
- **Full-Bleed Right Edge-to-Edge Architecture (`pl-4 sm:pl-6 pr-0`)**:
  Eliminated the 16px/24px right-side clipping dead zone caused by `px-4`/`px-6` (`padding-right`) on overflow containers.
  All horizontal scrollable rows (`ContinueWatchingShelf`, `WatchlistShelf`, `HomeShelves` preview strip, `SeriesEpisodeBrowser` seasons, `MovieMetadataSection` cast/trailers, `QuickChips`, `CatalogFilterBar`, and `TorrentList` filter tabs) use:
  `pl-4 sm:pl-6 pr-0 scroll-pl-4 sm:scroll-pl-6 snap-x snap-mandatory`.
  - **Left alignment at rest (scroll = 0)**: First card starts at 16px (`pl-4`), perfectly aligned with the shelf title.
  - **Right edge at rest and during scroll**: With `pr-0`, the scroll container's clipping box touches 100% of the screen width (0px right gap). Peeking and overflowing cards bleed completely to the physical bezel with zero blank black void.
  - **End of scroll breathing room**: Added dedicated trailing spacers `<div className="shrink-0 w-4 sm:w-6 pointer-events-none" aria-hidden="true" />` at the end of each track, giving the last card comfortable 16px/24px margin without hard bezel collisions.
  - **Unblocked Desktop Vertical Window Scrolling (`index.css`)**: Removed `overflow-x: hidden` from `html, body, #root` and decoupled `#root` from `overscroll-behavior-y: none`. This completely eliminates mouse wheel / trackpad scroll trapping, restoring natural native vertical window scrolling across all desktop browsers.
- **Vertical Bottom Clearance**:
  Increased `<main>` bottom padding to `pb-[calc(11.5rem+env(safe-area-inset-bottom))]`. All cards, titles, ratings, and catalog tiles can now be scrolled completely into view above the fixed bottom search dock.

---

## 15. Buffer Discontinuity Auto-Recovery, Gap Watchdog & Direct Range-Based HTTP Playback

### Problem Solved
1. **GStreamer MP4 Keyframe Split Discontinuity**: In certain torrents (e.g. *Silo S03E01* at `01:01`), GStreamer remuxing splits video and audio packets on keyframe boundaries with minor timestamp offsets (e.g. video ended at 62.395s, audio ended at 62.202s). This created a 193ms micro-hole in the browser's Media Source Extensions (MSE) `SourceBuffer`.
2. **False Buffering Trap**: The HTML5 `<video>` element emitted `'waiting'`, which previously triggered naive `setIsBuffering(true)`. Because the playhead sat at the micro-gap without advancing, the player stayed permanently stalled displaying "Буферизация потока...", even though the buffer bar showed 90+ seconds loaded ahead (e.g. up to 02:30).
3. **Unhandled Hls.js Stalls**: Hls.js default `maxBufferHole` was 0.1s (< 193ms) and non-fatal `BUFFER_STALLED_ERROR` was unhandled in `CinemaPlayerModal.tsx`.

### Implementation Details
- **Aggressive Hls.js Gap Controller Configuration**:
  ```typescript
  maxBufferHole: 0.5,
  detectStallWithCurrentTimeMs: 600,
  highBufferWatchdogPeriod: 1,
  nudgeOffset: 0.15,
  nudgeMaxRetry: 10,
  nudgeOnVideoHole: true,
  skipBufferHolePadding: 0.15,
  ```
- **Non-Fatal Stall & Hole Recovery**: Handled `Hls.ErrorDetails.BUFFER_STALLED_ERROR`, `BUFFER_SEEK_OVER_HOLE`, and `BUFFER_NUDGE_ON_STALL` to dynamically jump micro-holes (up to 2.5s) instead of halting playback.
- **Active 500ms Stall Watchdog**:
  Monitors playback progression: if `isPlaying` and `!video.paused`, but `currentTime` fails to advance for $\ge 750$ms:
  - **Hole Detection**: Inspects `video.buffered`. If a hole $\le 2.5$s exists ahead, leaps the gap (`currentTime = nextStart + 0.05`) and calls `video.play()`.
  - **Buffer Ahead**: If buffer is already present ($>0.3$s ahead), nudges $+0.08$s to clear decoder frame locks and immediately clears `isBuffering`.
  - **Live Buffer Clearance**: In `handleTimeUpdate`, automatically clears `isBuffering` when frames are actively rendering.
- **Intelligent `handleWaiting`**:
  Replaced naive `onWaiting={() => setIsBuffering(true)}` with intelligent buffer inspector: checks if buffer already exists ahead before setting `isBuffering(true)`, preventing blocking spinner flashes when data is already resident in RAM.
- **Direct HTTP Range Stream (`http_direct`)**:
  Exposed TorrServer's native zero-transcode HTTP Range streaming (`/torr/stream/<file>?link=<hash>&index=<idx>&play`, `HTTP 206 Partial Content`) directly as a selectable profile in the player format menu (`🚀 Прямой HTTP (без сегментов)`), providing standard Range-based single-stream playback without HLS segmentation, with automatic graceful fallback to `direct` HLS remux if the browser cannot decode the container or codec natively.

---

## 16. Mobile Header Viewport Isolation & Right Void Elimination

### Problem Solved
- On mobile viewports ($\le 430\text{px}$, including iPhone 14/15 Pro Max and iPhone 12/13/14), the right cluster of the top navigation bar (`Header.tsx`) contained uncompressed items:
  - An 8-digit document counter string (e.g. `11 296 451`).
  - The quality selector button (`1080p`).
  - The user logout button (`admin`).
- Combined with header padding, this cluster pushed out to $x = 479.2\text{px}$, which was $\sim 49\text{px}$ wider than the mobile screen.
- In mobile Safari / WebKit, an element exceeding the viewport widens `document.documentElement.scrollWidth` to $479\text{px}$.
- Because `<main>`, `<section>`, and the shelf containers were styled with `w-full` ($100\%$ width of their parent container, $430\text{px}$), they terminated at $x = 430\text{px}$.
- This created a stark $\sim 49\text{px}$ empty black void along the right edge of the screen, truncating horizontal shelves and preventing cards from bleeding edge-to-edge.

### Implementation Details
- **Compact Mobile Document Formatting (`Header.tsx`)**:
  - Implemented `formatDocumentCount`: formats document counts compactly on mobile (`< sm`) as `11.3M` or `125k`, and retains full formatted numbers (`11 296 451`) on desktop (`sm:`).
  - Compacted mobile button paddings and icons: `px-2.5 sm:px-3` on status button, `px-2 sm:px-3` on quality button, and `p-1.5 sm:px-2.5` on the logout icon button.
  - Added `shrink-0` to the right cluster and `min-w-0` to the left branding to ensure flex children do not expand uncontrollably.
- **Strict Non-Scrolling Horizontal Viewport Guard (`index.css` & `App.tsx`)**:
  - Added `max-width: 100vw; overflow-x: clip;` to `html, body` in `index.css`.
  - Added `w-full max-w-full overflow-x-clip` to the root container in `App.tsx`.
  - **Why `overflow-x: clip` instead of `overflow-x: hidden`**:
    Unlike `overflow: hidden`, CSS `overflow: clip` does **not** create a scroll container, meaning it does not trap mouse wheel or trackpad events and completely avoids breaking native vertical window scrolling on desktop browsers, while strictly forbidding horizontal expansion of the document on mobile.
- **Verification Results**:
  - Tested across $430\text{px}$, $390\text{px}$, and $375\text{px}$ mobile viewports: `docScrollWidth` exactly equals `window.innerWidth` with 0 leaking elements.
  - Tested on desktop $1440 \times 900$: vertical window scrolling functions smoothly (`scrollY` progresses from 0 to 400 with `scrollHeight = 2379px`).
  - Verified edge-to-edge card flow: horizontal carousels touch 100% of the screen width with $0\text{px}$ phantom void.
