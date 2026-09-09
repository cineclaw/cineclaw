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


### 8. Priority Poster Loading & Socket Preservation (`MoviePoster`)
- **HTTP/1.1 Socket Protection**: Browsers limit concurrent connections to 6 per domain. In `MovieList.tsx`, the top 8 matches (Rank 1..8 nearest thumb) receive `priority={true}`.
- **Eager vs Lazy**: Priority cards render with `loading="eager"` and `fetchPriority="high"`, immediately claiming available browser sockets for the cards in front of the user, while off-screen cards use `loading="lazy"`.
- **Instant Scroll Anchoring**: On arrival of search results, `window.scrollTo({ top: scrollHeight, behavior: "instant" })` positions the viewport at Rank 1 without sweeping across and triggering lazy loads for off-screen cards.
- **Watchdog Safety Timeout**: A 12-second timer in `MoviePoster.tsx` transitions `hasError = true` if network stalls, ensuring skeletons never hang indefinitely.
- **Late Image Arrival & Error Reset**: When the image finishes downloading, `onLoad` explicitly clears `hasError = false` and sets `isLoaded = true`, seamlessly fading in the loaded poster even if the watchdog had temporarily activated.
- **Automatic Retries**: If `onError` triggers on transient network hiccups, `MoviePoster` automatically retries up to 2 times with a 2-second delay and cache-buster (`&r=1`, `&r=2`), giving the backend time to finish writing to disk.

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

---

## 7. UI Guidelines & Design System

- **Theme**: Dark cinema aesthetic (`bg-neutral-950`, `border-neutral-800`, `text-neutral-100`).
- **Icons**: Standardized on [Lucide React](https://lucide.dev/icons).
- **Tracker Badges**:
  - Combined / Merged releases display multi-tracker badges (e.g. `RuTracker` + `RuTor` + `NNM-Club`).
  - Hovering over seeder counts displays an interactive tooltip with per-tracker seed breakdowns.
- **Responsiveness**: Mobile-first flex layout with swipeable horizontally scrollable filters (`no-scrollbar`) preventing layout blowout.

---

## 8. Build & Lint Commands

```bash
# Start local Vite dev server
npm run dev

# Typecheck and production bundle build
npm run build

# Run fast linter (oxlint)
npm run lint
```

