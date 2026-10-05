# Current State

Last updated: 2026-10-05

## Status: scaffolding complete, no code yet

### Done
- Single git repo created at `~/Projects/OnlyWallpapers`.
- Governance in place: root `CLAUDE.md` (Opus workflow), `AGENTS.md` (Codex),
  `README.md`.
- Knowledge folder `ow-local/` seeded: product docs, system overviews, the first
  two decisions, documentation rules.
- Directory skeleton for the Swift package and web layer exists (empty of code).

### Not Done (pending Phase 1 planning)
- `Package.swift` and all Swift sources (`main`, `AppDelegate`,
  `WallpaperController`, `WallpaperWindow`, `WebWallpaperView`).
- Web layer files (`index.html`, `style.css`, `wallpaper.js`).
- A sample `bg.mp4` in `web/assets/`.
- Any tests.
- Verifying the wallpaper renders and spans correctly (Phase 5).

### Next Step
Run Phase 1 for the initial Swift shell plus web layer: Opus plan, blind Codex
co-scope, consensus, Grok red-team, then Sonnet implements.

### Decisions So Far
- DEC-001: HTML-wrapped video over raw AVPlayer or Metal.
- DEC-002: multi-monitor via a single spanned canvas (union rect, per-screen
  slice transform).
