# System: Swift Shell

The native layer. Its only jobs are: open the right windows in the right places,
keep them on the desktop layer, and hand each one its slice of the canvas. It is
meant to be small and stable. Creative work happens in the web layer instead.

Status: planned, not yet implemented. This describes the intended design.

## Components
- **main.swift**: sets up `NSApplication`, activation policy `.accessory` (no Dock
  icon, a background utility, no Info.plist needed), runs the app.
- **AppDelegate**: on launch builds the wallpaper, and rebuilds on
  `NSApplication.didChangeScreenParametersNotification` (display plug/unplug,
  arrangement or resolution change).
- **WallpaperController**: the geometry brain. Builds the union of all
  `NSScreen.screens` frames (one logical canvas), derives each screen's slice
  offset, and creates one window per screen. Resolves the web asset directory
  (env `WALLPAPER_WEB_DIR` override, else the bundled copy).
- **WallpaperWindow**: a borderless `NSWindow` holding the WebWallpaperView. The
  desktop-layer trick lives here.
- **WebWallpaperView**: configures the `WKWebView` (transparent, local file read
  access) and injects the per-screen slice geometry.

## The Desktop-Layer Trick
A normal window becomes a wallpaper with these settings:
- `level = CGWindowLevelForKey(.desktopWindow)` (sits below the desktop icons).
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`.
- `ignoresMouseEvents = true` (clicks pass through to icons and Finder).
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`.
No private API. The OS treats it as an ordinary window, so it renders forever.

## Coordinate Math (the one tricky part)
`NSScreen` frames live in a shared, bottom-left-origin global space that already
encodes the Displays arrangement. For each screen:
- `unionRect` = union of all screen frames = canvas size.
- `offX = screen.minX - union.minX`.
- Bottom offset `offYBottom = screen.minY - union.minY`.
- CSS is top-left, so flip: `offYTop = union.height - offYBottom - screen.height`.
Pass `{stageW, stageH, offX, offY: offYTop}` to the web layer. Geometry is in
points, which map 1:1 to CSS px, so Retina is handled by the backing scale.

## Web Asset Resolution
`WALLPAPER_WEB_DIR` env var wins (live editing without a rebuild). Otherwise load
the copy bundled into the build via `Bundle.module`. Load `index.html` with
`loadFileURL(_:allowingReadAccessTo:)` scoped to the web directory.

## Open Questions
- Does a desktop-level window need any extra handling under Stage Manager?
- Behavior across fast user switching and lock/unlock.
