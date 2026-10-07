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
- Production runs with the variable unset. On launch the app seeds a writable copy of the web layer into `~/Library/Application Support/OnlyWallpapers/web/` from the bundle (code files re-seeded when the bundle changes; your chosen video preserved), and loads from there. If app storage is unwritable it falls back to the bundled copy.
- Set your video from the menu-bar icon ("Choose video...", see below). For dev, drop a clip at `Sources/OnlyWallpapers/web/assets/bg.mp4` and use `WALLPAPER_WEB_DIR`.
- Verification scripts: `scripts/smoke-run.sh` (basic launch), `scripts/webdir-check.sh` (web-dir resolver gates), `scripts/package-check.sh` (standalone .app), `scripts/rebuild-check.sh` (display hot-plug rebuild), `scripts/video-check.sh` (video asset check), `scripts/framing-check.sh` (zoom/pan framing inject, nudge, clamp, zoom-liveness, hot-plug), `scripts/mood-check.sh` (adaptive mood: hook inject, broadcast, weather-fixture, applied-filter readback, no network/location), `scripts/overlay-check.sh` (overlay canvas engine: sized-to-stage backing, rAF loop animates, inert when no effect, per-window DPR), `scripts/lightning-check.sh` (storm lightning: active registers + draws, inert off-storm, real weather-fixture trigger, JS envelope, reduced-motion), `scripts/mood-live-check.sh` (network-gated: hits the real Open-Meteo API and fails on error).

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

To set your own video: click the menu-bar icon and choose "Choose video...",
then pick an `.mp4` file (MPEG-4/H.264). The app copies it into its own storage
(`~/Library/Application Support/OnlyWallpapers/web/assets/bg.mp4`, a single slot that
is overwritten on each new pick) and plays it immediately. The choice persists across
launches and reboots, and you can delete the original file afterward.

Note: universal binary (Apple Silicon arm64 + Intel x86_64); requires macOS 14 (Sonoma) or newer; unsigned, for local personal use. On Intel Macs, video decode runs hotter, especially at 4K across multiple displays.

## Adaptive mood (time of day + weather)

The wallpaper can gently tint itself to match the local time of day and the live
weather (a subtle CSS filter: cooler and dimmer at night, warmer at dawn and
dusk, muted and dim on cloudy or stormy days). The tint is the same on every
screen and eases smoothly when it changes.

By default the app is fully local and does time-of-day tinting only. Weather is
opt-in: the app only asks for your location (and only then touches the network)
after you click the menu-bar icon and choose "Use location for weather tint," OR
if you hand-set `lat`/`lon` in `config.json` (see below). With neither, it never
leaves your machine.

Privacy and network, in plain terms:
- Location is used only after you opt in, at roughly kilometer accuracy, and the
  coordinates are rounded before any request. It is never inferred from your IP.
- With location granted (or a manual `lat`/`lon` in
  `~/Library/Application Support/OnlyWallpapers/config.json`), the app fetches the
  local forecast over HTTPS from `api.open-meteo.com` (free, no account, no API
  key) roughly every 15 to 20 minutes, caching the last result for cold start and
  offline. No other data leaves your machine.
- Deny the prompt or go offline and it falls back cleanly to time-of-day
  tinting only. It never crashes and never blocks the wallpaper.
- A plain `swift run` (no packaged Info.plist) cannot prompt for location, so it
  is time-of-day only by default. If you still want weather there, hand-edit
  `lat`/`lon` into `config.json` and it will fetch the forecast for those
  coordinates.

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
