# System: Swift Shell

The native layer. Its only jobs are: open the right windows in the right places,
keep them on the desktop layer, and hand each one its slice of the canvas. It is
meant to be small and stable. Creative work happens in the web layer instead.

Status: partially implemented. The process skeleton (`main.swift` and
`AppDelegate`, ow-mbw.2) runs as a `.accessory` app, the production `WallpaperWindow`
(ow-mbw.3) exists, `WebWallpaperView` (ow-94b.1) fills each window with a `WKWebView`
playing the real looping-video page (ow-94b.2), and the `WallpaperController`
(ow-blz.1) now owns the per-screen windows and computes the union canvas + per-screen
slice geometry. Still planned: injecting that geometry into the web layer and the CSS
slice transform (ow-blz.2), and the display hot-plug rebuild (ow-blz.3).

## Components
- **main.swift**: sets up `NSApplication`, activation policy `.accessory` (no Dock
  icon, a background utility, no Info.plist needed), runs the app.
- **AppDelegate**: sets the accessory policy, installs the SIGINT handler, and (in
  the default run) creates a `WallpaperController` and calls `build()`. It no longer
  creates windows itself.
- **WallpaperController** (ow-blz.1, done): the geometry brain. On `build()` it
  snapshots `NSScreen.screens`, computes the union canvas and each screen's slice
  geometry (a pure `nonisolated computeLayout([CGRect])`: `offX = minX - union.minX`,
  `offY = union.maxY - screen.maxY`, points, union seeded from `CGRect.null`), creates
  and owns one `WallpaperWindow` per screen (each window stays at `screen.frame`; the
  slice `offX/offY` are data only, never applied to any AppKit rect), passes the web
  dir (`#filePath` dev path for now; `WALLPAPER_WEB_DIR` + `Bundle.module` are
  ow-94b.3), and logs the geometry. Records are stored by `CGDirectDisplayID` (not
  `NSScreen`). Injecting the geometry into the web layer is ow-blz.2; the display
  hot-plug rebuild is ow-blz.3 (a flicker-safe swap, not a destructive teardown).
- **WallpaperWindow** (ow-mbw.3, done): a `final NSWindow` subclass, borderless at
  the desktop level, content-agnostic (holds whatever content view it is given),
  `canBecomeKey`/`canBecomeMain` false. The desktop-layer trick lives here. It holds
  the `WebWallpaperView` (ow-94b.1).
- **WebWallpaperView** (ow-94b.1, done): a `WKWebView` subclass used directly as the
  WallpaperWindow content view. Configures media autoplay
  (`mediaTypesRequiringUserActionForPlayback = []`) and loads a local page via
  `loadFileURL(_:allowingReadAccessTo:)` (read root is the directory). Base is opaque
  on macOS 26 via public API (black CSS fallback; true transparency deferred, see
  web-render overview and ow-aqx.4). Slice-geometry injection is added in ow-blz.1.
  Currently loads a stub page; ow-94b.2 adds the real looping-video page.

## The Desktop-Layer Trick
A normal window becomes a wallpaper with these settings:
- `level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))`
  (sits below the desktop icons; the `Int()` cast matters for Int32 sign extension).
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`.
- `ignoresMouseEvents = true` (clicks pass through to icons and Finder).
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`.
- Create the window borderless directly (do not mutate the style mask), retain it,
  and show with `orderFrontRegardless()` (not `makeKeyAndOrderFront`).
No private API. The OS treats it as an ordinary window, so it renders forever.

This was validated on Tahoe by the ow-mbw.1 spike: the window renders continuously
behind icons and does not freeze, even while macOS reports it occluded. See
`desktop-layer-spike-findings.md` for the measured configuration and the oracle
lessons. The video (WKWebView) render path is a separate de-risk: bd ow-94b.5.

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
Intended (ow-94b.3): `WALLPAPER_WEB_DIR` env var wins (live editing without a
rebuild), otherwise load the copy bundled into the build via `Bundle.module`. Loading
uses `loadFileURL(_:allowingReadAccessTo:)` scoped to the web directory (already in
place since ow-94b.1). For now, ow-94b.1 resolves the web dir from a `#filePath` dev
path only; `WALLPAPER_WEB_DIR` and `Bundle.module` are not wired yet (ow-94b.3).

## Open Questions
- Does a desktop-level window need any extra handling under Stage Manager?
- Behavior across fast user switching and lock/unlock.
