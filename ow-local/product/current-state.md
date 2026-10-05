# Current State

Last updated: 2026-10-05

## Status: desktop-layer technique de-risked on Tahoe (ow-mbw.2, ow-mbw.1 done)

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
  real-time CoreAnimation probe). Spike code is `SpikeWindow.swift` (gated by
  `OW_SPIKE=1`, kept until ow-mbw.3 copies the factory). Measured config and oracle
  lessons: `systems/swift-shell/desktop-layer-spike-findings.md`.

### Not Done
- Remaining Swift sources: `WallpaperController`, `WallpaperWindow`,
  `WebWallpaperView`.
- Web layer files (`index.html`, `style.css`, `wallpaper.js`).
- A sample `bg.mp4` in `web/assets/`.
- De-risk the WKWebView `<video>` render path at desktop level (ow-94b.5): the
  spike validated AppKit + CoreAnimation, not the actual video path.
- Verifying the wallpaper renders and spans correctly (Phase 5 of later tasks).

### Next Step
ow-mbw.3 (the real desktop-layer WallpaperWindow, seeding from the spike findings),
and ow-94b.5 (de-risk WKWebView video at desktop level) before the web render layer
relies on it.

### Decisions So Far
- DEC-001: HTML-wrapped video over raw AVPlayer or Metal.
- DEC-002: multi-monitor via a single spanned canvas (union rect, per-screen
  slice transform).
