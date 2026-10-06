# Current State

Last updated: 2026-10-06

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
- A real sample `bg.mp4` in `web/assets/` (ow-94b.4; a generated test clip is used now).
- Geometry unit tests (ow-blz.4); slice sync across pause/resume (ow-blz.5); retiring
  the webspike (deferred).

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
  top-left `offY` flip), in points. Pure `computeLayout([CGRect])` is ready for
  ow-blz.4 unit tests.
- ow-blz.2 (done): the per-screen geometry is injected into the web layer
  (`window.__wallpaper` via a document-start `WKUserScript`) and `wallpaper.js`
  positions `#stage` (the union-sized canvas) by `left/top` so each screen shows its
  slice of the ONE video (not N independent copies). We use `left/top` not a CSS
  transform (a transform on the video parent can blank the hardware layer). Verified:
  the native applied read-back (`getBoundingClientRect` on `#stage`) shows `left ==
  -offX` per screen (e.g. the right display at `left=-3840` on a 7680 union). Temporal
  frame sync across displays is still open (ow-blz.5).
- ow-94b.3 (done): web asset resolution. `WebDirectoryResolver.resolve()` (MainActor)
  picks the web dir: `WALLPAPER_WEB_DIR` env override (tilde-expanded, must be absolute
  and hold `index.html`) else the copy bundled via `Bundle.module` (`Package.swift`
  ships `web/` as `resources: [.copy("web")]`). Logs
  `ONLYWALLPAPERS_WEB_RESOLVE status=ok|fail source=env|bundle ...`; a set-but-invalid
  override `exit(1)`s rather than silently falling back. `#filePath` is gone. Gates:
  `smoke-run.sh` asserts the default run resolves `source=bundle`; `webdir-check.sh`
  (requires a display) asserts, with exact-token and per-screen load checks,
  bundle-consumed and override-ok (every `WebWallpaperView` loaded the resolved dir,
  one `loaded=ok` per screen, no `loaded=fail`), plus override-fail and
  relative-override (fail-fast, nonzero exit, no window created), and bundle hygiene.
  Unblocks packaging (ow-aad.5).
- ow-aad.5 (done): the app packages as a standalone, local, UNSIGNED
  `dist/OnlyWallpapers.app` via `scripts/package-app.sh`, with a menu-bar status item
  (SF Symbol) whose Quit item terminates the app. The SwiftPM resource bundle is
  placed at the `.app` ROOT (where the generated `Bundle.module` accessor looks;
  Contents/Resources would not be found). `AppDelegate` now guards
  `setActivationPolicy(.accessory)` (the `.app` sets it via `LSUIElement` pre-launch).
  Gate `scripts/package-check.sh` copies the `.app` to a temp dir outside the repo,
  runs it with cwd outside the tree, and proves it resolves `source=bundle` from
  INSIDE its own bundle (not `.build`), with `policy=accessory`, the status item, and
  per-screen `loaded=ok`, then a clean SIGINT and no orphan process. Unsigned/local,
  arm64 only. To set a video in the installed app: drop `bg.mp4` into the bundle or
  re-run the package script (a friendlier path is ow-aqx.2). Launch at login is
  ow-aad.3.
- ow-blz.3 (done): the wallpaper rebuilds IN PLACE when displays are attached,
  detached, or rearranged (no relaunch; the in-place video keeps playing, so it is
  designed for no black flash, to be confirmed visually in Phase 5 on real hardware).
  WallpaperController observes
  `didChangeScreenParametersNotification` + wake, coalesces via a pure
  generation-guarded reducer (debounce + an empty-confirm so a transient zero-screen
  snapshot during sleep/wake does not blank the desktop), diffs by `displayID`, and
  updates survivors (`setFrame` + a runtime `window.__applyWallpaperGeometry` left/top
  re-apply, keeping the video playing) while only creating/closing windows for
  added/removed displays. Rejected the recreate-and-swap approach (a hidden new WebView
  has its backing store culled, so revealing it flashes the opaque black base; also
  restarts the video at t=0). The decision logic is pure and unit-tested (`OW_SELFTEST`,
  38 cases incl. the T-shape); `scripts/rebuild-check.sh` adds a fake-screens inject
  (3-screen T-shape math), a real-display forced re-commit (the applied-oracle
  `left==-offX` re-validated on real glass), and the empty-confirm cases. The real
  hot-plug seamlessness on a physical T-arrangement is a manual Phase 5 check.

### Next Step
ow-aad.3 (launch at login) makes the packaged `.app` auto-start, and ow-aad.1 verifies
the lock/unlock, sleep/wake, screensaver, and Spaces behavior on the real machine
(the perfect moment is while a live instance is running). ow-blz.4 (geometry unit
tests, now partly covered by the ow-blz.3 OW_SELFTEST cases) and ow-94b.4 (a real
sample video). ow-mbw.4 adds the fuller window-config run check; ow-blz.5 handles slice
sync across pause/resume. Retiring the env-gated webspike A/B is a deferred cleanup.

### Decisions So Far
- DEC-001: HTML-wrapped video over raw AVPlayer or Metal.
- DEC-002: multi-monitor via a single spanned canvas (union rect, per-screen slice
  applied by CSS left/top positioning, not a CSS transform).
