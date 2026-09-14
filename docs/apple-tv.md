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

1. **Direct Stream Priority**: Raw Matroska files (`.mkv`) are streamed directly to KSPlayer via HTTP Range requests. Never transcode to HLS unless playing in a web browser.
2. **Watched State Synchronization**:
   - Continuous playback progress is pushed to `/api/playback/progress` every 5 seconds.
   - Reaching $\ge 90\%$ triggers automatic completion and advances Next Up to the succeeding episode.
   - Long-press / Context Menu on remote provides instant manual toggling of watched status for individual episodes, entire seasons, or all prior episodes.
3. **AI Critics Consensus Engine**:
   - Asynchronous, non-blocking fetching in `DetailsViewModel` via dedicated 60-second `aiSession` URLSession.
   - Resilient decoding with safe default values for all properties (`cached`, `scores`, `pros`, `cons`, `targetAudience`).
   - Server-side bbolt cache integrity (`cineclaw-ai`): only successful LLM syntheses are persisted; errors and cancellations are never cached.
