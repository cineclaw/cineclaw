---
name: android-tv
description: >-
  Official Jetpack Compose for Android TV best practices, architecture patterns,
  focus management, and performance guidelines based on Google's JetStreamCompose reference.
---

# Android TV & Jetpack Compose TV Best Practices Guide

This skill provides design standards, architectural guidelines, and optimization rules for developing native 10-foot Living Room cinema interfaces using **Jetpack Compose for TV** (`androidx.tv:tv-material` and `androidx.tv:tv-foundation`).

---

## 1. Core TV Architecture Invariants

1. **Use Official TV Material 3 Components**:
   - Never roll custom implementations of navigation drawers or cards with manual `animateDpAsState` or `Modifier.scale()`.
   - Use `androidx.tv.material3.ModalNavigationDrawer` and `androidx.tv.material3.NavigationDrawerItem` for navigation rails/drawers.
   - Use `androidx.tv.material3.ClassicCard` and `androidx.tv.material3.WideClassicCard` (or `StandardCardContainer`) for movie cards and horizontal shelves.
2. **Prevent Layout Thrashing & Bounding Box Resizing**:
   - Scaling an entire card container (`Column`) changes the layout measurement bounds, causing the parent list (`LazyColumn`) to micro-scroll or jitter vertically.
   - Scale must be applied strictly to the hardware visual surface (`CardDefaults.scale(focusedScale = 1.05f)`), leaving text labels and shelf heights completely deterministic.
3. **Hardware Acceleration & Native Shaders**:
   - Avoid `Modifier.shadow()` and conditional `.then(Modifier.border())` during focus animations.
   - Use `CardDefaults.glow()` and `CardDefaults.border()` provided by `androidx.tv.material3`, which render directly in the GPU render pipeline without allocating Modifier chains.

---

## 2. Navigation Drawer Pattern

Use `ModalNavigationDrawer` to ensure zero layout-resizing of the main catalog:

```kotlin
val drawerState = rememberDrawerState(initialValue = DrawerValue.Closed)

ModalNavigationDrawer(
    drawerState = drawerState,
    drawerContent = { currentDrawerValue ->
        Column(
            modifier = Modifier
                .fillMaxHeight()
                .background(ObsidianSurface)
                .padding(12.dp),
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            // Header / Logo
            ...
            // Items using NavigationDrawerItem
            NavigationDrawerItem(
                selected = currentScreen == "home",
                onClick = { onNavigate("home") },
                leadingContent = { Icon(Icons.Default.Home, contentDescription = "Главная") },
                content = { Text("Главная") }
            )
        }
    }
) {
    // Main Cinema Content (LazyColumn / Catalog)
}
```

---

## 3. Movie Cards & Shelves Pattern

### Poster Cards (2:3 Aspect Ratio)
Use `ClassicCard` for vertical poster cards with title and metadata below:

```kotlin
ClassicCard(
    onClick = { onClick() },
    modifier = modifier.width(160.dp),
    image = {
        AsyncImage(
            model = posterUrl,
            contentDescription = title,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize()
        )
    },
    title = {
        Text(
            text = title,
            color = TextPrimary,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    },
    subtitle = {
        if (year != null && year > 0) {
            Text(text = year.toString(), color = TextMuted, fontSize = 11.sp)
        }
    },
    scale = CardDefaults.scale(focusedScale = 1.05f),
    border = CardDefaults.border(
        focusedBorder = Border(
            border = BorderStroke(2.dp, EmeraldPrimary),
            shape = RoundedCornerShape(16.dp)
        )
    ),
    glow = CardDefaults.glow(
        focusedGlow = Glow(
            elevationColor = EmeraldGlow,
            elevation = 14.dp
        )
    )
)
```

### Shelf Focus Grouping & Focus Restorer
Group focus within each `LazyRow` and save focused child:

```kotlin
Column(modifier = modifier.focusGroup()) {
    Text(text = shelf.title, ...)
    LazyRow(
        contentPadding = PaddingValues(start = 32.dp, end = 48.dp, top = 8.dp, bottom = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        modifier = Modifier.focusRestorer()
    ) {
        items(shelf.items, key = { it.tconst }) { item ->
            TvCinemaCard(media = item, onClick = { onSelect(item) })
        }
    }
}
```

---

## 4. Smooth Vertical Scroll & BringIntoViewSpec

To eliminate abrupt snaps when moving D-Pad vertically between shelves:

```kotlin
@OptIn(ExperimentalFoundationApi::class)
val tvSmoothScrollSpec = object : BringIntoViewSpec {
    override val scrollAnimationSpec: AnimationSpec<Float> = tween(
        durationMillis = 250,
        easing = FastOutSlowInEasing
    )

    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
        val trailingEdge = offset + size
        val leadingEdge = offset
        // Smooth center pivot keeping focused shelf comfortably in upper-middle zone
        val pivot = containerSize * 0.35f
        return leadingEdge - pivot
    }
}

CompositionLocalProvider(LocalBringIntoViewSpec provides tvSmoothScrollSpec) {
    LazyColumn(...) { ... }
}
```

---

## 5. Performance, DEX Optimization & AOT Compilation

1. **Interpreter Mode Hazard**:
   - Debug builds installed via `adb install` default to `run-from-apk` / interpreter mode.
   - On TV ARM SoCs (MediaTek / Realtek), interpreted Compose causes severe frame drops (< 25 FPS).
2. **Speed-Profile Compilation**:
   After installing to TV, always run Ahead-Of-Time (AOT) compilation:
   ```bash
   adb shell cmd package compile -m speed -f <package-name>
   ```
3. **Release & R8 Verification**:
   - Production builds must use `minifyEnabled = true` with R8 rules.
   - Verifying framerate stability:
     ```bash
     adb shell dumpsys gfxinfo <package-name> framestats
     ```
