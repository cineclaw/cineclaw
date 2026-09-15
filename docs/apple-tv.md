# Apple TV Living Room Cinema Client (`apple-tv`)

The **CineClaw Apple TV** application (`com.andvikt.cineclaw`) is a native tvOS 18+ client engineered specifically for 10-foot living room cinema experiences on Apple TV 4K and Apple TV HD.

---

## 1. Technical Stack & Dependencies

- **Language & Runtime**: Swift 6, tvOS 18.0+ deployment target.
- **UI Framework**: SwiftUI with custom tvOS focus engines (`@FocusState`, `TVCardButtonStyle`, `.focusSection()`).
- **Media Engine**: KSPlayer (FFmpeg 7.x + Apple Metal zero-copy hardware rendering) for raw MKV, DTS-HD MA, Dolby TrueHD, E-AC3 Atmos, and embedded PGS/ASS/SRT subtitles.
- **Image Pipeline**: NukeUI (`LazyImage`) with edge TMDB CDN resolution and in-memory caching.
- **Networking**: URLSession with async/await, streaming TorrServer MatriX direct HTTP Range requests (`/torr/stream/<file>?link=<hash>&index=<idx>&play`).

---

## 2. Living Room UI & 10-Foot Ergonomics (1080p HD & 4K Calibrated)

On Apple TV HD (1080p, `AppleTV5,3`), the display scale is 1x (1pt = 1 physical pixel). Small typography (<20pt) is illegible from standard living room couch distances (~3 meters). CineClaw tvOS enforces high-contrast, scaled typography and edge-to-edge layouts:

### Edge-to-Edge Hero Banner & Backdrop Design
- **Safe Area Insets Overridden**: Standard tvOS `ScrollView` applies `(top: 60, left: 90, right: 90)` margins. Both `HomeView` and `DetailsView` declare `.ignoresSafeArea(edges: [.horizontal, .top])`.
- **Hero & Detail Backdrop Bleed (1920x880 with `.top` Alignment)**: Backdrops span full 1920pt width and expanded 880pt height (`frame(width: 1920, height: 880, alignment: .top)`). Aligning to `.top` guarantees that human heads, faces, hair, and vertical scene compositions are 100% preserved and never chopped off.
- **Natural, High-Luminance Cinematic Vignettes**:
  - **Top Vignette**: Soft translucent gradient (`opacity(0.45) -> opacity(0.15) -> clear` at 0.25) ensuring pristine TabBar / Back button contrast while keeping the top of the photo bright and visible.
  - **Bottom Gradient**: Clear across the upper 45% of the frame, gradually transitioning (`opacity(0.35)` at 0.70 to pure `#07090E` at 1.0) into the obsidian canvas behind the buttons.
  - **Leading Vignette**: Soft lateral falloff (`opacity(0.65) -> opacity(0.1) -> clear` at 0.70) keeping typography legible while leaving the center and right artwork vibrant and un-darkened.

### 10-Foot Typography & Card Standards
- **Hero Title**: 56–60pt Black with deep drop shadow (`radius: 12`).
- **Section & Shelf Headers**: 36pt Bold (`Home`, `ContinueWatching`, `Seasons & Episodes`, `Watchlist`).
- **Card Titles**: 24–26pt Semi-bold.
- **Overviews / Plot Synopses**: 22–24pt Regular with comfortable `lineSpacing(6)` and `lineLimit(4)`.
- **Badges & Metadata**: Minimum font size is $\ge 18\text{pt}$ (Release year 22pt, runtime 22pt, ratings 24pt, seeds 20pt bold).
- **Primary Buttons (`EmeraldButtonStyle`)**: 26pt Bold with glowing emerald focus ring and white hover fill.
- **Poster Cards (`MediaCardView`, `SearchResultCard`)**: Scaled up to **280x420pt** (from 230x345pt) with 18pt corner radii.
- **Widescreen 16:9 Cards (`ContinueWatchingCard`)**: Scaled up to **420x236pt** with 6pt emerald watch-progress bar.
- **Episode Cards (`EpisodeCardView`)**: Scaled up to **400x225pt** (16:9) with HD still previews, episode titles (22pt), and plot summaries (18pt).

### Focus Card Design & Glow Clipping Prevention
- **Decoupled Poster Surface**: Only the visual artwork card (poster/thumbnail) receives scale, white focus stroke, and ambient backlight glow. Metadata text (title, subtitle, episode info) sits cleanly outside the border, dynamically highlighting to bright white on focus without an enclosing box.
- **Centered Backlight Glow**: Rather than an aggressive downward shadow offset (`y: 12`), the ambient halo is centered (`radius: 18-20, x: 0, y: 4, opacity: 0.4-0.45`), providing an even Apple TV backlight bloom without bleeding deeply into adjacent text.
- **Zero ScrollView Clipping (`scrollClipDisabled`)**: Horizontal `ScrollView`s naturally clip content at their bounding box (`UIScrollView.clipsToBounds = true`). All horizontal shelves (`ShelfRowView`, `ContinueWatchingRow`, `SeasonPickerView`, and `DetailsView` cast carousel) declare `.scrollClipDisabled()` and generous vertical padding (`.padding(.vertical, 32-36)`), ensuring scaling and ambient glows fade seamlessly into the `#07090E` obsidian canvas with zero razor-cut edges.

---

## 3. Operations Cheatsheet

### Compilation & Device Deployment
```bash
# Build Debug app for physical Apple TV
xcodebuild -project apple-tv/CineClawTV.xcodeproj -scheme CineClawTV -destination "id=2C8A3405-B038-5A13-AD87-0B2B7C6AADBE" -configuration Debug build

# Install to Apple TV
xcrun devicectl device install app --device "2C8A3405-B038-5A13-AD87-0B2B7C6AADBE" "/Users/admin/Library/Developer/Xcode/DerivedData/CineClawTV-bxgktqkiebgsvpdoeqkwgiytqkgt/Build/Products/Debug-appletvos/CineClaw.app"

# Launch / Terminate & Relaunch on Apple TV
xcrun devicectl device process launch --device "2C8A3405-B038-5A13-AD87-0B2B7C6AADBE" --terminate-existing com.andvikt.cineclaw
```

---

## 4. Key Architectural Invariants

1. **Direct Stream Priority & Legacy Hardware Fallback**:
   - On hardware supporting HEVC (Apple TV 4K, A10X/A12/A15), raw Matroska files (`.mkv`) are streamed directly to KSPlayer via HTTP Range requests without transcoding.
   - On legacy hardware without hardware HEVC decoding (Apple TV HD, `AppleTV5,3` with Apple A8) or when the user enables Transcode mode in Settings/Player, video is transcoded on-the-fly on the server to H.264 (`/api/stream/transcode/.../master.m3u8`), allowing smooth hardware decoding at 60fps with zero frame drops.
2. **Watched State Synchronization**:
   - Continuous playback progress is pushed to `/api/playback/progress` every 5 seconds.
   - Reaching $\ge 90\%$ triggers automatic completion and advances Next Up to the succeeding episode.
   - Long-press / Context Menu on remote provides instant manual toggling of watched status for individual episodes, entire seasons, or all prior episodes.
3. **AI Critics Consensus Engine**:
   - Asynchronous, non-blocking fetching in `DetailsViewModel` via dedicated 60-second `aiSession` URLSession.
   - Resilient decoding with safe default values for all properties (`cached`, `scores`, `pros`, `cons`, `targetAudience`).
   - Server-side bbolt cache integrity (`cineclaw-ai`): only successful LLM syntheses are persisted; errors and cancellations are never cached.
4. **Server Switching & Authentication State Engine**:
   - `CineClawTVApp` observes `SessionManager.shared.isPaired`. When unauthenticated or after sign out, it transitions to `AuthView`.
   - `AuthView` provides full tvOS living room onboarding: quick-select server presets (NAS `192.168.88.19:3000`, Local `127.0.0.1:3000`), manual host/port input with real-time ping detection (`HEAD /`), login & password authentication (`POST /api/auth/login`), and camera QR code / PIN pairing.
   - `SettingsView` features an explicit «Сервер и авторизация» card with live ping status badge, «Сменить сервер» and «Выйти из аккаунта» action buttons with confirmation alerts that cleanly reset session credentials (`clearSession()`) and route directly to `AuthView`.
5. **Server-Remembered Source Synchronization**:
   - Before falling back to automatic release cascades, `HomeViewModel` and `DetailsViewModel` query `getPlayerInfo` (`GET /api/stream/player/info?tconst=...&season=...&episode=...`).
   - If `mediaSourceId` exists (i.e. release was already chosen/mounted on Web or another client), Apple TV immediately reuses that exact torrent hash and file index, eliminating desynchronization across devices.
6. **Persistent Transcoding & Quality Memory (`UserDefaults`)**:
7. **Real-Time Swarm Throughput & Cellular Signal Indicator**:
   - `NativeVLCPlayerViewController` renders a top-right OSD header containing `TvSignalStrengthView` and quality/mode badges (`[4K UHD]`, `[DIRECT STREAM]` / `[H.264]`).
   - Features a cellular 4-bar stepped indicator (heights 4pt, 7pt, 10pt, 13pt) with color grading based on the ratio of BitTorrent download speed to video bitrate ($\text{SpeedRatio} = \frac{\text{DownloadSpeed}}{\text{VideoBitrate}}$):
     - 4 bars ($\ge 1.5\times$ bitrate): Emerald green
     - 3 bars ($1.0\times - 1.5\times$ bitrate): Lime green
     - 2 bars ($0.5\times - 1.0\times$ bitrate): Amber
     - 1 bar ($< 0.5\times$ bitrate): Red
     - 0 bars: Muted white/gray
   - Displays live download speed (e.g. `12.4 МБ/с`) and active seeders (`🌱 {seeds}`).
   - Fades smoothly in/out with the bottom transport controls and auto-hiding OSD scrim.
   - `PlayerViewModel` queries `GET /api/stream/stats` every 2 seconds via `CineClawClient.getStreamStats` during active playback.


