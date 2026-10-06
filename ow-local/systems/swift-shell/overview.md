# System: Swift Shell

The native layer. Its only jobs are: open the right windows in the right places,
keep them on the desktop layer, and hand each one its slice of the canvas. It is
meant to be small and stable. Creative work happens in the web layer instead.

Status: partially implemented. The process skeleton (`main.swift` and
`AppDelegate`, ow-mbw.2) runs as a `.accessory` app, the production `WallpaperWindow`
(ow-mbw.3) exists, `WebWallpaperView` (ow-94b.1) fills each window with a `WKWebView`
playing the real looping-video page (ow-94b.2), and the `WallpaperController`
(ow-blz.1) now owns the per-screen windows and computes the union canvas + per-screen
slice geometry. The per-screen slice geometry is now injected into the web layer and applied by left/top positioning (ow-blz.2). The app can be packaged as a standalone, unsigned `.app` with a menu-bar Quit item (ow-aad.5), and rebuilds its windows IN PLACE when displays are attached, detached, or rearranged (ow-blz.3). Still planned: launch at login (ow-aad.3).

## Components
- **main.swift**: sets up `NSApplication`, activation policy `.accessory` (no Dock
  icon, a background utility). The bare `swift run` binary needs no Info.plist; the
  packaged `.app` ships one with `LSUIElement` (see Packaging).
- **AppDelegate**: sets the accessory policy (guarded: it only calls
  `setActivationPolicy(.accessory)` when not already accessory, since `LSUIElement`
  sets it pre-launch in the `.app`), installs the SIGINT handler, and (in the default
  run) creates a `WallpaperController`, calls `initialBuild()` (which also registers the
  display-change observers), and creates the `StatusItemController`. It no longer
  creates windows itself.
- **WallpaperController** (ow-blz.1 + ow-blz.3, done): the geometry brain. On `initialBuild()` it
  snapshots `NSScreen.screens`, computes the union canvas and each screen's slice
  geometry (a pure `nonisolated computeLayout([CGRect])`: `offX = minX - union.minX`,
  `offY = union.maxY - screen.maxY`, points, union seeded from `CGRect.null`), creates
  and owns one `WallpaperWindow` per screen (each window stays at `screen.frame`; the
  slice `offX/offY` are data only, never applied to any AppKit rect), passes the web
  dir resolved by `WebDirectoryResolver` (ow-94b.3 + ow-aqx.2: `WALLPAPER_WEB_DIR`,
  else the seeded app-storage copy, else the `Bundle.module` bundle), and logs the
  geometry. Records are stored by `CGDirectDisplayID` (not
  `NSScreen`). Injecting the geometry into the web layer (via a document-start WKUserScript) is done (ow-blz.2). It also rebuilds IN PLACE on display changes (ow-blz.3, done): it observes `didChangeScreenParametersNotification` plus wake, coalesces (a debounce plus an empty-confirm so a transient zero-screen snapshot during sleep/wake cannot blank the desktop), decides via a pure generation-guarded reducer, diffs by `displayID`, and updates survivors (`setFrame` plus a runtime `window.__applyWallpaperGeometry` left/top re-apply, so the video keeps playing, designed for no black flash and to be confirmed on real hardware in Phase 5) while only creating or closing windows for added or removed displays. The decision logic (reducer, `arrangementChanged`, `computeLayout`) is pure and unit-tested via `OW_SELFTEST`.
- **WallpaperWindow** (ow-mbw.3, done): a `final NSWindow` subclass, borderless at
  the desktop level, content-agnostic (holds whatever content view it is given),
  `canBecomeKey`/`canBecomeMain` false. The desktop-layer trick lives here. It holds
  the `WebWallpaperView` (ow-94b.1).
- **WebWallpaperView** (ow-94b.1, done): a `WKWebView` subclass used directly as the
  WallpaperWindow content view. Configures media autoplay
  (`mediaTypesRequiringUserActionForPlayback = []`) and loads a local page via
  `loadFileURL(_:allowingReadAccessTo:)` (read root is the directory). Base is opaque
  on macOS 26 via public API (black CSS fallback; true transparency deferred, see
  web-render overview and ow-aqx.4). It injects the per-screen slice geometry
  (`window.__wallpaper`) via a document-start `WKUserScript` (ow-blz.2) and logs a
  `getBoundingClientRect`-based applied read-back. Loads the real looping-video page
  (ow-94b.2).
- **StatusItemController** (ow-aad.5, done): a minimal menu-bar `NSStatusItem`
  (template SF Symbol) with a disabled title and a "Quit OnlyWallpapers" item that
  calls `NSApp.terminate`. Created only in the default production path and retained by
  `AppDelegate`. Logs `ONLYWALLPAPERS_STATUSITEM created=<bool>`. It is the only way
  to quit the installed accessory app without Activity Monitor.

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

## Web Asset Resolution (ow-94b.3 + ow-aqx.2, done)
`AppStorageManager.seedWebDirIfNeeded(...)` runs ONCE at launch (from
`applicationDidFinishLaunching`, BEFORE `initialBuild()`; never from `resolve()` or
`performCommit`, which run on every hot-plug rebuild). It seeds a WRITABLE web dir at
`~/Library/Application Support/OnlyWallpapers/web/` (override root via
`OW_APP_SUPPORT_DIR` for tests): the three code files (`index.html`, `style.css`,
`wallpaper.js`) are copied from the bundle when missing or when a content-hash marker
differs (self-healing; the marker is written LAST so an interrupted seed re-seeds next
launch), while `assets/` (the user's chosen video) is preserved. Leftover `*.partial`
is swept (no storage growth).
`WebDirectoryResolver.resolve()` (MainActor; `computeLayout` stays nonisolated) then
picks the web dir in tiers: (1) `WALLPAPER_WEB_DIR` if set (dev live-edit; tilde
expanded, absolute, must hold `index.html`, fail-fast + `exit(1)` on a bad override,
no silent fallback). (2) the seeded app-storage web dir if COMPLETE (all three code
files are regular readable files). (3) the `Bundle.module` bundled copy as a FALLBACK
if the seed failed or the app-storage tree is incomplete (so an unwritable Application
Support still wallpapers instead of going black). Logs
`ONLYWALLPAPERS_WEB_RESOLVE status=ok source=env|appstore|bundle dir=<abs>`. Loading
uses `loadFileURL(_:allowingReadAccessTo:)` scoped to that one dir (video + code are
co-located in app storage, which is why the whole web dir moved there: a single read
subtree cannot cover both `/Applications` and `~/Library`). The "Choose video..."
picker (StatusItemController) writes the single slot `web/assets/bg.mp4` in app storage
and is enabled only when the resolved source is `appstore`. NOTE: the env-gated
webspike path in `AppDelegate` keeps its OWN older `WALLPAPER_WEB_DIR` contract; the
tiered resolution above applies only to the default, non-webspike path.

## Packaging (ow-aad.5, done)
`scripts/package-app.sh` produces a standalone, local, UNSIGNED `dist/OnlyWallpapers.app`:
`swift build -c release`, then the binary into `Contents/MacOS/` and an `Info.plist`
(CFBundle* + `LSMinimumSystemVersion 14.0` + `LSUIElement true`) into `Contents/`.
CRUX: the SwiftPM resource bundle goes at the `.app` ROOT
(`OnlyWallpapers.app/OnlyWallpapers_OnlyWallpapers.bundle`), NOT `Contents/Resources`
and NOT `Contents/MacOS`, because the synthesized `Bundle.module` accessor resolves
via `Bundle.main.bundleURL.appendingPathComponent("OnlyWallpapers_OnlyWallpapers.bundle")`
and for a `.app` `Bundle.main.bundleURL` is the `.app` root (verified from the generated
`resource_bundle_accessor.swift`; it also has a HARDCODED `.build` fallback, so the
gate must prove the app resolves inside its OWN bundle, not `.build`). `scripts/package-check.sh`
is the gate: it copies the `.app` to a temp dir outside the repo, runs it (with
`OW_APP_SUPPORT_DIR` pointed at a temp) with cwd outside the tree, and asserts the app
seeds from its OWN bundle (the seed source path is inside the temp `.app`, no `.build`)
and resolves `source=appstore` from the temp app-storage, plus `policy=accessory`, the
status item, and per-screen `loaded=ok`. Unsigned
local builds have no quarantine so they run without a Gatekeeper prompt (an
`xattr -dr com.apple.quarantine` escape hatch is documented for transferred copies).
arm64 only; the binary links only the OS Swift runtime (`/usr/lib/swift`), so no dylib
bundling. Launch at login is separate (ow-aad.3).

## Lifecycle (verified, ow-aad.1)
Lock/unlock, sleep/wake, and screensaver all behave correctly on real hardware: the
desktop-layer wallpaper is not drawn on the lock screen or over the screensaver (the
system surfaces sit above it), the app survives the event, and the wallpaper + video
return cleanly on unlock/wake/dismiss with no black flash or freeze. The brief
old-wallpaper flash during Space/full-screen transitions is the separate ow-aad.4.

## Open Questions
- Does a desktop-level window need any extra handling under Stage Manager? (ow-aad.2)
- Fast user switching behavior (untested; low priority).
