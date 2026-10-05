# Current State

Last updated: 2026-10-05

## Status: shell skeleton builds and runs (ow-mbw.2 done)

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

### Not Done
- Remaining Swift sources: `WallpaperController`, `WallpaperWindow`,
  `WebWallpaperView`.
- Web layer files (`index.html`, `style.css`, `wallpaper.js`).
- A sample `bg.mp4` in `web/assets/`.
- Verifying the wallpaper renders and spans correctly (Phase 5 of later tasks).

### Next Step
ow-mbw.1 (spike: desktop-layer window renders continuously on Tahoe) is now
unblocked, then ow-mbw.3 (the desktop-layer window itself).

### Decisions So Far
- DEC-001: HTML-wrapped video over raw AVPlayer or Metal.
- DEC-002: multi-monitor via a single spanned canvas (union rect, per-screen
  slice transform).
