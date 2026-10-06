# OnlyWallpapers

A continuously animated desktop wallpaper for macOS. Because the fun should not
be a Windows-only thing.

A base video is wrapped in a local HTML/CSS/JS layer so you get live control
(filters, time-of-day moods, overlays) over an always-moving desktop. A tiny
Swift/AppKit shell pins a borderless, click-through window to the desktop layer
(behind your icons, present on all Spaces) and spans the whole multi-monitor
arrangement. No private APIs: it is just a normal window that never stops
rendering.

## For Humans
- Build: `swift build`
- Run: `swift run OnlyWallpapers`
- Hot-edit the look without rebuilding Swift (planned, ow-94b.3; not wired yet, the
  default run currently loads `Sources/OnlyWallpapers/web` from a `#filePath` dev path):
  ```bash
  WALLPAPER_WEB_DIR=$PWD/Sources/OnlyWallpapers/web swift run OnlyWallpapers
  ```
- Drop your clip at `Sources/OnlyWallpapers/web/assets/bg.mp4`.

## For AI Agents
Read, in order:
1. `CLAUDE.md` (Opus) or `AGENTS.md` (Codex) at the repo root.
2. `ow-local/README.md` then `ow-local/product/current-state.md`.
3. The relevant `ow-local/systems/*/overview.md`.

## How It Works (the two interesting bits)
- **Always-animated wallpaper:** a window at the desktop window level, not a
  wallpaper API. See `ow-local/decisions/DEC-001-html-wrapped-video.md`.
- **Multi-monitor spanning:** the union of all `NSScreen` frames is one logical
  canvas; each screen shows its slice. See
  `ow-local/decisions/DEC-002-multimonitor-spanning.md`.

## Knowledge
Design docs and decisions live in `ow-local/`. It is a folder in this repo, not a
separate git history.
