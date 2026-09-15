# Android TV & Living Room Cinema Client (`android-tv`)

The **CineClaw Android TV** application (`com.cineclaw.tv`) is a modern, native Android TV / Google TV client engineered specifically for 10-foot living room cinema experiences.

---

## 1. Technical Stack & Dependencies

- **Language & Runtime**: Kotlin 2.1, Target SDK 35, Min SDK 28 (Android 9.0 Pie+).
- **UI Framework**: Jetpack Compose for TV (`androidx.tv:tv-material:1.0.0`, `androidx.tv:tv-foundation:1.0.0-alpha12`).
- **Media Engine**: AndroidX Media3 (`androidx.media3:media3-exoplayer:1.5.1`, `media3-ui`, `media3-datasource-okhttp`).
- **Networking & Serialization**: OkHttp 4.12 with Retrofit 2.11 and Kotlinx Serialization JSON.
- **Image Pipeline**: Coil 3 (`io.coil-kt.coil3:coil-compose:3.0.4`) with memory caching and HTTP disk persistence.
- **Preferences & State**: Jetpack DataStore Preferences for session credentials, server URLs, audio passthrough flags, and quality preferences.

---

## 2. Living Room UI & 10-Foot Ergonomics

- **Obsidian Cinema Theme**: Unified `#07090E` background (`ObsidianBackground`) matching the CineClaw Web UI, eliminating seams and OLED backlight flicker.
- **Hardware-Accelerated Focus Interaction**:
  - `StandardCardContainer` with `ClickableSurfaceDefaults`: hardware scale (1.05x), focused emerald border (`#10B981`) and glow (`#10B98133`) rendered directly via GPU shaders without allocating Modifier chains or shifting measured text bounds.
  - Text titles and subtitles are strictly decoupled from the scaled surface, ensuring completely deterministic shelf heights and zero vertical jitter during horizontal navigation.
- **Decoupled BringIntoView Architecture**:
  - `tvVerticalBringIntoViewSpec`: 80ms ultra-snappy shelf transition anchoring focused shelves to the upper-middle viewing zone (~28%) with micro-jitter thresholding (< 8px).
  - `tvHorizontalBringIntoViewSpec`: 75ms edge-only scroll, keeping the entire shelf completely static when navigating between cards already in view and only smoothly sliding when approaching screen boundaries.
- **Modal Navigation Rail**: Official `androidx.tv.material3.ModalNavigationDrawer` utilizing hardware layer translation and clipping, completely eliminating layout thrashing and text clipping artifacts.
- **Living Room Search Experience (`SearchScreen`)**:
  - **Native Android TV System Input**: Eliminated cumbersome custom on-screen alphabet keyboards in favor of the native Android TV Leanback IME / Gboard. Supports multilingual typing, phone remote app input, and predictive completion.
  - **Dedicated Voice Search**: Prominent mic action button triggering system voice recognition (`RecognizerIntent.ACTION_RECOGNIZE_SPEECH`) with Russian language preference.
  - **Popular Suggestion Chips**: Instant one-click query chips («Мэйдэй», «Дюна», «Сёгун», «4K UHD», «Пингвин», «Медведь») for rapid living room navigation.
  - **Fast Tantivy Index Integration**: Queries `GET /search?q={query}&limit=30` against `imdb-indexer` (<5ms), mapping hits into `MediaItem` models with direct TMDB CDN image paths (`resolveImageUrl` pointing to `https://image.tmdb.org/t/p/w500/{path}`).
  - **Full-Width Cinema Grid**: Multi-column `LazyVerticalGrid` displaying 2:3 vertical poster cards with rating badges, release years, and smooth D-Pad focus scaling into details.
- **Default Action Auto-Focus**: Details screens automatically request focus on the primary `▶ Смотреть` button upon entry, enabling 1-click playback without manual navigation.
- **In-Player OSD & Remote D-Pad Navigation**:
  - **Dual-Mode Focus & Key Handling**:
    - *HUD Hidden*: Intercepts DPAD_CENTER / UP / DOWN to wake controls; DPAD_LEFT / RIGHT triggers fast ±10s relative seeks with centered animated bubble toast (`-10с` / `+10с`); BACK exits the player.
    - *HUD Visible*: Children handle directional focus. Users can navigate horizontally across `[Смотреть / Пауза]`, `[-10с]`, `[+10с]`, `[Качество]`, `[Аудио]`, and `[Субтитры]`.
  - **Interactive TV Timeline Scrubber (`TvTimelineScrubber`)**:
    - Pressing DPAD_UP from any action button focuses the timeline scrubber.
    - Displays glowing emerald thumb with white border ring, emerald-highlighted timecode preview, and scrubbing delta badge (`+30с`, `-45с`).
    - DPAD_LEFT / DPAD_RIGHT scrubs time with adaptive 15s (standard) or 30s (long media) step increments.
    - Commit seek via DPAD_CENTER, ENTER, or DPAD_DOWN. Pressing BACK cancels pending scrub.
  - **Categorized Quality Switcher Dialog (`QualityDialog`)**:
    - **Single-Expanded Accordion Architecture**: Groups all tracker releases under interactive collapsible tier headers (`4K UHD`, `1080p FHD`, `720p HD`, `SD`). Exactly one accordion is open at a time; expanding another accordion collapses the previous one.
    - **Instant Top-Element Focus**: When an accordion opens or expands, focus is automatically transferred to its top/first release via `FocusRequester` (`topItemRequester.requestFocus()`), enabling instant 1-click playback with D-Pad center.
    - **Strict Seed-Descending Ranking**: Inside each quality tier, releases are strictly ranked by `seeds DESC` (with bitrate and file size as secondary tiebreakers), showing live seed badges (`🌱 {seeds} сидов`).
    - **Preserved Playback Timestamp**: Switching quality in-player retains the exact playback position (`currentTime`) seamlessly.
    - Seamless switching: mounts target release on backend, updates stream URL, and preserves exact timestamp (`position_seconds`).
  - **Audio & Subtitle Track Selectors (`PlayerTracksDialog`)**:
    - **Audio Dialog**: Displays all embedded audio streams parsed directly from ExoPlayer's container tracks (`format.label`), enriched with backend probe metadata (e.g. "HDrezka Studio", "Bravo Records") when container labels are generic. Includes standardized language badges (RU, EN, UA, HE, PT, RO, etc.), codec badges (E-AC3, AC3, AAC, DTS, MPEG, MP2), channel configurations (5.1, 7.1, stereo), and active track checkmarks.
    - **Subtitle Dialog**: Full subtitle track management including "Выключить субтитры" (disabled) and all embedded text/bitmap streams.
    - **Physical Stream Synchronization**: Container streams in ExoPlayer are the single source of truth for audio and subtitle track indices, eliminating order inversion with server probes and ensuring instantaneous (<150ms) crash-free track switching.
    - **Instant Russian Status**: Method `prepare(...)` detects the first Russian audio track at startup and immediately configures the HUD with `[🔊 Аудио (RU)]`.
  - **Accurate Initial Quality Display**: Constructor-level quality propagation initializes `PlayerUiState.currentQualityTier` immediately with the selected/resolved quality tier (e.g. `4K UHD`), eliminating the flash of "1080p".
  - **Intelligent Inactivity Auto-Hide**: 12-second timeout resets on any user interaction, and is automatically suspended while scrubbing, when playback is paused, or when any dialog is open.

---

## 3. Streaming Engine & BitTorrent Playback

1. **Direct Zero-Transcode Streaming (`direct_stream_url` Priority)**:
   - Android TV strictly prioritizes `direct_stream_url` (`/torr/stream/<file>?link=<hash>&index=<idx>&play`) over web browser GStreamer HLS (`stream_url` `/gst/<hash>/master.m3u8`). Web HLS muxes only 1 single audio track at a time, whereas direct MKV streaming exposes all embedded audio and subtitle tracks directly to ExoPlayer's Matroska demuxer.
   - BitTorrent piece transport uses OkHttp with `readTimeout(0, MILLISECONDS)` so seeking/buffering over HTTP Range requests (`206 Partial Content`) never prematurely times out during peer swarm piece retrieval.
   - Hardware decoding via Android `MediaCodec` for H.264, HEVC (H.265, Dolby Vision, HDR10+), and AV1 with `setEnableDecoderFallback(true)`.
   - **Resilient Audio Pipeline (`DefaultAudioSink` + `AudioCapabilities`)**:
     - Explicit 2-channel 16-bit PCM output (`AudioCapabilities(..., 2)`) with `ChannelMixingAudioProcessor` implementing ITU-R BS.775 downmix matrices for 5.1/7.1 audio tracks (E-AC3, AC3, AAC, DTS) down to stereo TV speakers when `audioPassthrough = false`.
     - Audio Offload strictly disabled (`AudioOffloadSupport.DEFAULT_UNSUPPORTED`), eliminating MediaTek/Realtek HAL driver write buffer timeouts (`utils_out_write_data: timeout`, `AudioTrack: start: -1`).
     - Multi-channel bitstream passthrough over HDMI ARC/eARC available when explicitly enabled in TV Settings.
2. **Watch Progress Sync**:
   - Exact playback timestamps periodically synced to `POST /api/playback/progress`.
   - Persisted in pure-Go SQLite (`cineclaw.db`) across restarts and shared across Web UI and Android TV.
3. **Resume & Continue Watching Shelf**:
   - Dynamic «Продолжить просмотр» carousel on the Home screen.
   - Instant resumption seeking to exact timestamps upon clicking resume cards.

---

## 4. Build, Deployment & Testing Automation (`Makefile`)

- **Fast Incremental TV Deployment (`make tv-fast` / `make tv-dev`)**:
  - Incremental Debug build (`assembleDebug`) without R8, resource shrinking, or dex2oat overhead.
  - Deploys to Android TV via ADB (`TV_IP ?= 192.168.88.127:5555`) in **~3-5 seconds**.
  - Shares package name `com.cineclaw.tv` with release builds, preserving session tokens, pairing, and DataStore settings.
  - Automatically launches `com.cineclaw.tv/.MainActivity`.
- **Heavy Production Release with Max Optimizations (`make tv-release` / `make tv-prod`)**:
  - Full Release build (`assembleRelease`) with R8 full-mode minification, Proguard rules, and resource shrinking.
  - Installs release APK to TV and runs on-device Ahead-Of-Time (AOT) speed compilation (`adb shell cmd package compile -m speed -f com.cineclaw.tv`).
- **Additional TV Commands**:
  - `make tv-build-fast`: Compile Debug APK without installing.
  - `make tv-build-release`: Compile optimized Release APK without installing.
  - `make tv-connect [TV_IP=...]`: Connect ADB to TV IP over Wi-Fi.
  - `make tv-logs`: Live logcat streaming for `CineClaw`, `ExoPlayer`, and `MediaCodec`.
  - `make tv-stop`: Force stop the app on TV.
- **Automated Host Testing**: Roborazzi + Robolectric for JVM-based 1920x1080 visual regression testing.

---

## 5. Web Parity Features (v1 Parity Release)

- **AI Critics Consensus (`AiCriticsCard.kt`)**:
  - Rotating-phase animated shimmering skeleton during generation (*«Анализируем рецензии критиков...»* -> *«Сравниваем оценки Rotten Tomatoes & Metacritic...»* -> *«Формируем консенсус...»*).
  - Smooth transition to Rotten Tomatoes 🍅 %, Metacritic, IMDb ★ rating & votes, awards badges, Russian verdict, Pros/Cons, and target audience.
  - Transparent bbolt caching via `cineclaw-ai` (`:9120`) powered by Gemini 2.5 Flash.
- **Rich Metadata, Crew Badges & Person Profiles (`PersonScreen.kt`)**:
  - Horizontal carousels for Cast («В главных ролях») and Crew («Съёмочная группа») with avatars and roles.
  - 1-click drill-down into `PersonScreen.kt`: biographic photo, department, bio, tabs for "В ролях" and "Съёмочная группа", sort toggle ("Новые" / "Лучшие"), and 1-click return drill-down into movie details.
- **Dedicated Catalog Screens (`CatalogScreen.kt`)**:
  - "Фильмы" (Movies): Fresh on trackers, Popular swarms, 4K UHD cinema, and Trending.
  - "Сериалы" (Series): Popular series, fresh tracker TV swarms, Apple TV+, HBO Max, and series swarms.
  - "4K UHD": Pure 2160p HDR/DV movie and fresh swarms.
- **Watchlist Engine (`WatchlistScreen.kt`)**:
  - 5-column grid with live count and empty state.
  - Interactive «Буду смотреть» / «✓ В списке» action button on `DetailsScreen` with instant backend synchronization against SQLite `media_watchlist`.
- **Shelf Pagination & Drill-Down (`ShelfScreen.kt`)**:
  - «Ещё →» header button on all home and catalog shelves, plus trailing «Все релизы →» cards.
  - Full 5-column grid with «Загрузить ещё (+20)» pagination.
  - URLDecoder integration ensuring clean Cyrillic titles without `+` signs.
- **Backdrop Vignette & Gradient**:
  - 4-stop vertical gradient (`0.0f` -> `0.35f` -> `0.70f` -> `1.0f` solid `#07090E`) completely eliminating harsh horizontal cutoffs.

---

## 6. Living Room Focus Ergonomics & Torrent Resolution (v1.1)

- **Single-Click D-Pad Season Switching**:
  - Resolved Compose TV focus collision where switching season tabs required two remote D-Pad clicks.
  - Eliminated redundant chained `.focusable()` and `.clickable` modifiers on season tab chips.
  - Implemented explicit low-level `onKeyEvent` handling for `KEYCODE_DPAD_CENTER`, `KEYCODE_ENTER`, and `KEYCODE_NUMPAD_ENTER` on `KeyEventType.KeyDown`, mutating `selectedSeason` instantaneously on the very first remote press.
- **Specials Purge (`seasonNumber > 0`)**:
  - TMDB specials (`season_number: 0` / «Спецматериалы») are strictly filtered out during series season initialization in `AppNavigation.kt`: `sResp.seasons.filter { it.seasonNumber > 0 }`.
  - Ensures clean 1-based season index matching the web UI (`SeriesEpisodeBrowser.tsx`) and eliminates phantom "Сезон 0" from shows like *The Sopranos*.
- **`effectiveTconst` & `effectiveId` Route Navigation**:
  - All navigation routes from `HomeScreen`, `SearchScreen`, `ShelfScreen`, `CatalogScreen`, and `WatchlistScreen` route using `media.effectiveTconst` and `media.effectiveId`.
  - Guarantees valid IMDb IDs (`tt...`) are passed to Details and Player screens instead of empty strings or TMDB IDs.
  - Added query title fallback (`query = title`) to `api.getTorrents` in `Screen.Details` and `Screen.Player`, ensuring recent releases without indexed IMDb IDs (e.g. *The Invite* 2026) immediately resolve torrent swarms.
- **Hardware Codec Compatibility & H.264 10-bit (Hi10P) Exclusion (`isHardwareIncompatible`)**:
  - Android TV MediaCodec hardware decoders (`c2.mtk.avc.decoder`, Amlogic, Realtek) strictly support H.264 8-bit only. H.264 10-bit (Hi10P) crashes hardware decoders with `Error 0x80000000` / `ERROR_CODE_DECODING_FAILED`.
  - Added strict hardware incompatibility filter: releases matching H.264/AVC/x264 with 10-bit are excluded from auto-selection in `selectBestReleaseForQuality` and sorted to the bottom with `⚠️ 10-bit AVC` warning badge in `QualityDialog`.
  - H.265 (HEVC), AV1, and VP9 10-bit remain fully supported as standard modern TV hardware codecs.
  - Added intelligent decoder error interception in `CinemaPlayer.kt` with dynamic auto-fallback (`onDecoderFallback`): if an unindexed or mislabeled release triggers a hardware decoder crash on startup, the player immediately intercepts the failure, blacklists the failing hash, and auto-mounts the next best compatible release seamlessly without user intervention.

---

## 7. Voiceover Memory, Pre-Playback Resume & In-Tree Dialog Stability (v1.2)

- **Persistent Voiceover Track Memory**:
  - Saved audio track choice is reported to `POST /api/playback/audio` upon user selection in `AudioTracksDialog`.
  - Backend SQLite table `media_audio_preferences` stores preferences per `imdb_id`.
  - On opening next episodes or alternative releases, `CinemaPlayer` auto-matches the preferred voiceover title (e.g. Goblin, Amedia, Fox Crime, Serbin) and switches ExoPlayer track without manual user intervention.
- **Zero-Load Pre-Playback Resume Prompt (`ResumeConfirmDialog.kt`)**:
  - Halts all stream preparation and TorrServer chunk fetching when watch progress exists (`hasResume = true`).
  - Presents high-contrast fullscreen dialog with 1-click `[ ▶ Продолжить с MM:SS ]` and `[ ↺ С начала ]`.
  - Zero bytes are downloaded from BitTorrent swarms until the user explicitly confirms their playback intent.
- **In-Tree Dialog Architecture & D-Pad OSD Stability**:
  - Replaced buggy `androidx.compose.ui.window.Dialog` in `PlayerTracksDialog.kt` and `QualityDialog.kt` with in-tree obsidian modal overlays (`Box(modifier = Modifier.fillMaxSize().background(Color(0xB3000000))) { BackHandler { ... } }`).
  - Solves Android TV window boundary focus loss and layout clipping on Media3 `PlayerView`.
  - Extended player OSD controls auto-hide timeout to 15 seconds, resetting on every remote D-Pad key down event.
  - Suspends autohide when tracks or quality dialogs are open, video is paused, or timeline scrubber is focused.

---

## 8. Cinema Ergonomics, Interactive Carousel, Preloaders & TV Series Controls (v1.3)

- **Universal Loading Preloaders**:
  - **Details Metadata Skeleton (`DetailsScreen.kt`)**: Shimmering skeleton lines and an animated `Загрузка данных...` badge while TMDB/IMDb metadata, cast/crew, and torrents are resolving.
  - **Streaming Startup Preloader (`PlayerScreen.kt`)**: A floating obsidian cinema card with an emerald spinner and live status text (*«Подготовка видеопотока...»*, *«Поиск пиров в сети TorrServer и запуск воспроизведения»*) during cold starts and peer discovery, completely eliminating blank black screens.
- **Movie & Series Runtime Display**:
  - `imdb-indexer` extracts `runtime_minutes` from TMDB metadata (`runtime` for films, `episode_run_time[0]` for series).
  - Displayed in `DetailsScreen.kt` badges row formatted as `2 ч 35 мин` or `48 мин`.
- **AI Critics Consensus Tone Badge & Focusability (`AiCriticsCard.kt`)**:
  - Prominent verdict tone pill (*«Восторженный приём»*, *«Положительный приём»*, *«Смешанные отзывы»*, *«Сдержанный / Спорный»*) matching the Web UI design language.
  - Card container made focusable with `tvFocusable` and glowing emerald border so D-Pad down scrolls smoothly through the AI critique instead of skipping past it.
- **Flippable Hero Carousel (`TvHeroCarousel` in `HomeScreen.kt`)**:
  - Replaced static single-item hero banner with a dynamic carousel cycling through the top 5 weekly trending titles (`🔥 Тренды недели #1`).
  - Smooth 600ms crossfade between backdrops and titles, 8-second auto-cycle timer (suspended on focus), dot indicator pills, and `<` / `>` remote buttons for instant manual browsing.
- **Navigation Drawer Focus Isolation**:
  - Navigation drawer content guarded with `.focusProperties { canFocus = currentDrawerValue == DrawerValue.Open }`.
  - Prevents the closed navigation drawer from intercepting focus when returning from `DetailsScreen` or pressing Back.
- **In-Player TV Series Next Episode & Episodes Selector (`EpisodesDialog.kt`)**:
  - Dedicated `[ ▶| След. серия ]` transport button in the in-player OSD controls for 1-click progression.
  - Interactive `[ 📺 Серии ]` button opening `EpisodesDialog.kt`: multi-season pill selector, horizontal episode cards with still images, air dates, and *«Сейчас играет»* highlight badge.
- **Two-Step Back Navigation from Continue Watching**:
  - Clicking a continue watching item routes through `DetailsScreen` before launching `PlayerScreen`, ensuring pressing Back returns cleanly to the media details card rather than abruptly jumping to the Home screen.
- **Home State Retention & Deep Shelf Focus Restoration (`HomeViewModel.kt`, `HomeScreen.kt`)**:
  - Scoped home catalog state (`shelves`, `featured`, `continueWatching`, `trackerFresh`, `uhd4k`) to `HomeViewModel` retained across navigation backstack entries.
  - Eliminates data-wiping recomposition when navigating `Home -> Details -> Home`, preserving `LazyColumn` scroll position without clamping to index 0.
  - Implements Google JetStream focus restoration standard: `lazyRow.saveFocusedChild()` on card click and `.focusRestorer { firstItem }` on `LazyRow`.
  - Multi-frame focus retry in `LifecycleEventEffect(ON_RESUME)` guaranteeing instant, rock-solid focus restoration to the exact originating card across all shelves (Hero, Continue Watching, Watchlist, 4K UHD, Tracker Fresh, TMDB Feeds).

---

## 9. Unified Backend-For-Frontend (BFF) & Single-Request Home Load (v1.4)

- **Elimination of Client-Side Multi-Request Polling Waterfall**:
  - Previously, Android TV launched 6 concurrent coroutines (`getFeeds`, `getContinueWatching`, `getWatchlist`, `getHotlist(new_movie)`, `getHotlist(movie)`, `getHotlist(4k)`), hitting multiple backend microservices across a high-latency Wi-Fi connection.
  - Replaced with a single call to `GET /api/home?platform=tv` powered by `tracker-proxy` BFF aggregator.
  - On application startup and `ON_RESUME`, `HomeViewModel` makes **exactly 1 network request** (~58ms round-trip), receiving a unified `HomePayload` with `hero` and pre-sorted `shelves`.
  - Reduces Wi-Fi request volume by 83% and network serialization overhead down to sub-60ms.
- **Normalized Server-Driven UI Contract**:
  - `HomeShelf` (`id`, `title`, `type`, `badge`, `action_route`, `items: List<HomeItem>`).
  - `HomeItem` contains both playback progress fields (`playback_percent`, `position_seconds`, `timecode`, `is_next_up`) and swarm metadata (`seeds`, `quality_badge`), allowing transparent mapping to `MediaItem` and `ResumeItem` while maintaining zero UI regressions in `HomeScreen` and focus restoration.

---

## 10. In-App YouTube Trailers & Fullscreen Gallery (v1.5)

- **Official In-App YouTube Player Integration (`TrailerPlayerDialog.kt`)**:
  - Integrated `com.pierfrancescosoffritti.androidyoutubeplayer:core:13.0.0`, running Google's official IFrame Player API inside a sandboxed WebView with bidirectional JavaScriptInterface bridge.
  - **Google Referer & Origin Compliance**: Configured `IFramePlayerOptions.Builder(ctx).origin("https://com.cineclaw.tv")`, strictly adhering to Google's required Referer format and eliminating Error 153 and Error 152-4 ("Video unavailable").
  - **10-Foot Living Room Controls & OSD**:
    - D-Pad Center / Enter / Media Play-Pause: toggles playback (`youTubePlayer.play()`, `youTubePlayer.pause()`).
    - D-Pad Left / Right / Fast Forward / Rewind: ±10s seeking (`youTubePlayer.seekTo()`).
    - Back button: safely releases player and returns to movie details.
    - Auto-hiding HUD with glowing emerald progress bar, timecodes (`MM:SS / MM:SS`), pause badge, and remote hints.
  - **Graceful Fallback**: If a studio or rights-holder completely prohibits embedded playback, displays an actionable banner with 1-click fallback to launch the system YouTube application (`vnd.youtube:{id}`).
- **High-Resolution Movie & Series Gallery (`GalleryViewerDialog.kt`)**:
  - TMDB backdrops proxy via `imdb-indexer` extracting up to 25 widescreen 16:9 backdrops.
  - Horizontal shelf «Галерея кадров» on `DetailsScreen` with 1.06x focus scale and glowing emerald border.
  - Fullscreen viewer with smooth D-Pad Left / Right slide navigation, position badge (`X / N`), and instant dismiss on Back.

---

## 11. D-Pad Long-Press Actions & Home Shelf Quality Curation (v1.6)

- **Home Shelf Low-Score Filtering**:
  - Home shelves automatically filter out media with ratings below 6.0 (`rating < 6.0`), eliminating low-quality clutter while preserving items explicitly added by the user.
  - Shelf navigation streamlined by removing redundant «Ещё» buttons from shelf headers, eliminating vertical D-Pad focus conflicts and routing pagination exclusively through trailing shelf cards.
- **Contextual D-Pad Long-Press Remote Actions**:
  - Long-pressing remote D-Pad OK / Center button on any card opens a contextual action sheet:
    - On Continue Watching: 1-click «Удалить из продолжить просмотр» with instant backend sync (`DELETE /api/playback/progress/{id}`).
    - On Watchlist cards: «Удалить из списка буду смотреть» with backend sync (`DELETE /api/watchlist/{id}`).
    - On Catalog & Home shelf cards: «Добавить в буду смотреть» with instant badge toggle.

---

## 12. Server Switching, Live Ping Indicator & Explicit Authentication (v1.7)

- **Dedicated «Сервер и авторизация» Settings Card (`SettingsScreen.kt`)**:
  - Displays current connected server URL and real-time connectivity status (`● На связи` in emerald, `● Не отвечает` in red) determined via lightweight `HEAD /` ping (200..401 status check).
  - Displays authorized username profile (`● Авторизован: {username}`).
  - **«Сменить сервер» Button**: Prompts an in-tree confirmation dialog explaining that the current session will be cleared and redirects cleanly to `AuthScreen`.
  - **«Выйти из аккаунта» Button**: In-tree confirmation dialog to safely sign out of the active user profile (`SessionManager.clearSession()`).
- **Enhanced Living Room Login & Server Selection (`AuthScreen.kt`)**:
  - **Quick Server Presets**: 1-click D-Pad buttons for common servers: `NAS (192.168.88.19:3000)` and `Local (127.0.0.1:3000)`.
  - **Real-Time Server Ping**: Live ping check indicator updating on input (`● В сети` / `● Недоступен`).
  - **Automated QR & PIN Pairing**: Displays generated 6-digit PIN and QR code URL (`/tv?code=...`), with a background coroutine polling `/api/auth/pair/status` every 2.5 seconds.
  - **Error Feedback Banner**: High-visibility error notification displayed when credentials or server endpoints are invalid.
- **Robust URL Normalization (`SessionManager.kt`)**:
  - Automatically enforces `http://` scheme, trims whitespace and trailing slashes, and maintains separate storage for auth token and server host.

---

## 13. Real-Time Swarm Throughput & Cellular Signal Indicator (v1.8)

- **Header OSD Placement**:
  - Integrated into the top-right header row of `PlayerScreen.kt` preceding `[4K UHD]` and `[DIRECT STREAM]` badges.
- **Cellular 4-Bar Stepped Badge (`TvSignalStrengthBadge`)**:
  - 4 stepped vertical rounded bars (heights 4dp, 7dp, 10dp, 13dp) reflecting the ratio of BitTorrent download speed to required video bitrate ($\text{SpeedRatio} = \frac{\text{DownloadSpeed}}{\text{VideoBitrate}}$):
    - 4 bars ($\ge 1.5\times$ bitrate): Emerald green (`#10B981`)
    - 3 bars ($1.0\times - 1.5\times$ bitrate): Lime green (`#34D399`)
    - 2 bars ($0.5\times - 1.0\times$ bitrate): Amber (`#F59E0B`)
    - 1 bar ($< 0.5\times$ bitrate): Red (`#EF4444`)
    - 0 bars (0 B/s / buffering): Muted gray (`#6B7280`)
- **Live Swarm Metrics**:
  - Monospaced download speed label (e.g. `12.4 МБ/с`, `850 КБ/с`).
  - Active seeders pill badge (`🌱 {seeds}`) displayed whenever $\text{seeds} > 0$.
- **Background Smart Polling (`CinemaPlayer.kt`)**:
  - `startStatsPolling()` coroutine runs every 3 seconds while `isPlaying || isBuffering`, querying `GET /api/stream/stats` via `CineClawApi.getStreamStats` and safely updating `PlayerUiState.streamStats`.






