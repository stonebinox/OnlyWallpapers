# Current State

Last updated: 2026-10-05

## Status: desktop-layer + WKWebView video both de-risked on Tahoe (ow-mbw.2, ow-mbw.1, ow-94b.5 done)

### Done
- Single git repo created at `~/Projects/OnlyWallpapers`.
- Governance in place: root `CLAUDE.md` (Opus workflow), `AGENTS.md` (Codex),
  `README.md`.
- Knowledge folder `ow-local/` seeded: product docs, system overviews, the first
  two decisions, documentation rules.
- Directory skeleton for the Swift package and web layer exists.
- ow-mbw.2 (SwiftPM package skeleton + app lifecycle): `Package.swift`
  (swift-tools 6.2, `.macOS(.v14)`, `.defaultIsolation(MainActor.self)`),
  `main.swift`, and `AppDelegate.swift`. The app builds clean under
  warnings-as-errors, launches as a `.accessory` (UIElement) process with no Dock
  icon and no Info.plist, stays running, and exits cleanly on SIGINT. Verified in
  the live session: the OS reports `ApplicationType=UIElement`. Behavioral gate is
  `scripts/smoke-run.sh` (there is no XCTest target by design).
- ow-mbw.1 (spike, done): a borderless desktop-layer `NSWindow` renders
  continuously behind desktop icons on Tahoe and does NOT freeze, even while macOS
  reports it occluded. Confirmed on two displays and two Spaces (behind icons,
  click-through, all Spaces, continuous animation proven by pixel screenshots and a
  real-time CoreAnimation probe). The spike (`SpikeWindow.swift`) was superseded and
  REMOVED in ow-mbw.3. Measured config and oracle lessons:
  `systems/swift-shell/desktop-layer-spike-findings.md`.
- ow-mbw.3 (done): the production `WallpaperWindow` (a `final NSWindow` subclass,
  borderless desktop-layer, content-agnostic, `canBecomeKey`/`canBecomeMain` false).
  The default run now creates one per `NSScreen.screens` with a temporary placeholder
  content view (deep-teal fill), verified behind icons on both displays
  (`zorder_ok=true`) by smoke. The ow-mbw.1 spike was removed. ow-94b.1 swaps the
  placeholder for `WebWallpaperView`.

- ow-94b.1 (done): WebWallpaperView, a `WKWebView` subclass used as the
  WallpaperWindow content view, loads a local page via `loadFileURL` and fills the
  window (verified behind icons on both displays). The default run now shows a
  black-fallback stub page; ow-94b.2 adds the real looping-video page. Finding: the
  public WKWebView transparency path is opaque on macOS 26, so the base is opaque with
  a black fallback (the full-bleed video covers it); true transparency deferred to
  ow-aqx.4. The env-gated webspike is kept as the A/B (retirement deferred).
- ow-94b.2 (done): the real looping-video web page (index.html + style.css +
  wallpaper.js) replaces the stub. A looping muted video fills the window
  (object-fit: cover), starts on its own (autoplay + synchronous play() kick), with a
  black fallback and the validated brightness(1.01) filter. An overlay canvas is in
  the DOM but inert (Epic D). WebWallpaperView logs a native WKMediaPlaybackState
  sample at +1.0/+2.5/+7.5s; verified media=playing early (autostart) AND at the late
  +7.5s sample past the clip (looping) on both displays. Verification:
  scripts/generate-test-bg.sh (gitignored test clip) + scripts/video-check.sh (native
  media gates are authoritative; screencapture -l pixels are non-gating corroboration
  because -l is flaky under occlusion culling).

### Not Done
- Remaining Swift sources: `WallpaperController` (ow-blz.1).
- A real sample `bg.mp4` in `web/assets/` (ow-94b.4; a generated test clip is used now).
- Asset-dir resolution: WALLPAPER_WEB_DIR + Bundle.module (ow-94b.3).
- The spanned-canvas slice transform (ow-blz.2); retiring the webspike (deferred).

### Also de-risked
- ow-94b.5 (done): a looping `<video>` in a transparent WKWebView at the desktop
  layer keeps presenting frames continuously on Tahoe whenever its Space is visible
  (WebKit does not throttle the hidden/occluded page; it pauses only when fully
  hidden and resumes live). Spike code is `WebSpikeWindow.swift` + `web/webspike/`
  (gated by `OW_WEBSPIKE=1`). Findings:
  `systems/web-render/webview-video-spike-findings.md`. Open follow-up: multi-display
  slice sync across pause/resume (ow-blz.5).

- ow-blz.1 (done): the `WallpaperController` owns the per-screen windows and computes
  the union canvas + per-screen slice geometry (`offX`, and the bottom-left to
  top-left `offY` flip), in points, logged and smoke-verified (a recompute oracle).
  The geometry is data only (windows stay at `screen.frame`); nothing spans visually
  yet. Pure `computeLayout([CGRect])` is ready for ow-blz.4 unit tests.

### Next Step
ow-blz.2 (inject the slice geometry into the web layer + the CSS stage transform, so
the one video spans all displays, each showing its slice) and ow-blz.3 (rebuild the
windows on display hot-plug, a flicker-safe swap). ow-blz.4 adds geometry unit tests.
ow-94b.3 adds WALLPAPER_WEB_DIR + Bundle.module web-dir resolution; ow-94b.4 sources a
real sample video; ow-mbw.4 adds the fuller window-config run check. Retiring the
env-gated webspike A/B is a deferred cleanup.

### Decisions So Far
- DEC-001: HTML-wrapped video over raw AVPlayer or Metal.
- DEC-002: multi-monitor via a single spanned canvas (union rect, per-screen
  slice transform).
