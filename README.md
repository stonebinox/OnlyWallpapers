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
- Live-edit the web layer without rebuilding Swift (edits take effect on next launch, no file watcher):
  ```bash
  WALLPAPER_WEB_DIR=$PWD/Sources/OnlyWallpapers/web swift run OnlyWallpapers
  ```
- Production runs with the variable unset. The bundled web layer (copied at build time via `resources: [.copy("web")]`) is used automatically.
- Drop your clip at `Sources/OnlyWallpapers/web/assets/bg.mp4` and rebuild.
- Verification scripts: `scripts/smoke-run.sh` (basic launch), `scripts/webdir-check.sh` (web-dir resolver gates), `scripts/package-check.sh` (standalone .app), `scripts/rebuild-check.sh` (display hot-plug rebuild), `scripts/video-check.sh` (video asset check).

## Build and install the app

Run `scripts/package-app.sh` to produce `dist/OnlyWallpapers.app`:

```bash
scripts/package-app.sh
```

Drag `dist/OnlyWallpapers.app` to `/Applications` and open it. Because the app
is locally built and unsigned (not downloaded or AirDropped), macOS does not
quarantine it and Gatekeeper will not block it. If you ever zip the app or
AirDrop it, clear the quarantine flag first:

```bash
xattr -dr com.apple.quarantine /Applications/OnlyWallpapers.app
```
(Point the path at wherever the `.app` actually lives, for example
`dist/OnlyWallpapers.app` before you move it.)

Once running, the app appears as a small icon in the menu bar. Click it and
choose "Quit OnlyWallpapers" to stop it.

To use your own video: drop `bg.mp4` into
`OnlyWallpapers.app/OnlyWallpapers_OnlyWallpapers.bundle/web/assets/bg.mp4`
inside the bundle, or place your clip at
`Sources/OnlyWallpapers/web/assets/bg.mp4` in the source tree and re-run
`scripts/package-app.sh`.

Note: arm64 (Apple Silicon) only; unsigned, for local personal use.

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
