# System: Web Render Layer

Where the wallpaper actually looks like something. The native shell loads this
local page into a per-screen WKWebView (the base is opaque with a black fallback on
macOS 26, see Transparency; the full-bleed video covers it). All visual control lives
here and can be edited without recompiling Swift.

Status: partially implemented. `WebWallpaperView` (ow-94b.1) is a `WKWebView`
subclass used as the WallpaperWindow content view, loading the local page via
`loadFileURL`. The real looping-video page (ow-94b.2) is now in place: a looping
muted video fills the window and starts on its own, with a black fallback. The slice
positioning (ow-blz.2) is in place: the one video is sliced across all displays via
injected per-screen geometry and `left/top` positioning of `#stage`. The asset-dir
resolution (ow-94b.3 + ow-aqx.2) is wired: `WALLPAPER_WEB_DIR`, else a seeded
app-storage web dir (set via the "Choose video..." menu), else the `Bundle.module`
bundled copy. The adaptive mood tint (ow-aqx.15 Stage 1) is implemented: the native
layer drives a time-of-day + live-weather CSS filter that the page applies to `#bg`,
identical on every screen (see Adaptive Mood). Still planned: overlay-canvas particle
effects (Epic D, ow-aqx.3).

## Files
- **index.html**: a `#stage` containing the `<video id="bg">` (muted, playsinline,
  loop, autoplay) and an overlay `<canvas>` reserved for future effects (inert).
- **style.css**: full-bleed video with `object-fit: cover`; the `filter` on `#bg` is
  the live-control knob for the look. Its default is now the mood identity 5-tuple
  `brightness(1.01) saturate(1) contrast(1.01) hue-rotate(0deg) sepia(0)` (same five
  functions the mood mapper always emits, so changes interpolate instead of snapping),
  with `transition: filter 2s ease` so mood shifts ease. The contrast >= 1.01 floor
  keeps the validated recomposite path live (ow-94b.5). Black fallback until the video
  decodes (the WKWebView base is opaque on macOS 26, see Transparency).
- **wallpaper.js**: four IIFEs. A geometry IIFE reads `window.__wallpaper` and
  positions `#stage` by `left/top` to this screen's slice (recording the applied rect
  in `window.__wallpaperApplied`); a framing IIFE applies `window.__wallpaperFraming`;
  an autoplay IIFE kicks `play()` with `canplay`/`loadeddata` retries and an `ended`
  belt; and a MOOD IIFE (ow-aqx.15) exposes `window.__setWallpaperMood`, validates the
  incoming filter against the 5-function shape, applies it to `#bg.style.filter`
  (transition off on the first apply, then re-enabled so it does not snap on load), and
  records the parsed numbers in `window.__moodApplied`.

## The Slice Transform (ow-blz.2, done)
The shell injects, at document start, a per-screen payload via a `WKUserScript`:
```js
window.__wallpaper = { stageW, stageH, offX, offY }
```
`wallpaper.js` then (in a geometry IIFE separate from the autoplay IIFE):
- sizes `#stage` to the full canvas: `width = stageW`, `height = stageH`;
- shifts it so this screen shows only its slice by POSITIONING, not a transform:
  `#stage { position: fixed; left: -offX px; top: -offY px }`.
We use `left`/`top` rather than `transform: translate` on purpose: an ancestor
`transform` on the `<video>` parent can blank or freeze the hardware video layer.
The video fills `#stage` (the union size), so `object-fit: cover` crops the image
ONCE in union space and each screen shows an adjacent slice (continuous across the
bezel). Each screen's window stays screen-sized (`screen.frame`); the offsets are
data only, never applied to any AppKit rect; `overflow: hidden` clips the oversized
stage to the viewport. Verification: the native `ONLYWALLPAPERS_WEB applied` log
(read from `getBoundingClientRect` on `#stage`) asserts `left == -offX` per screen.
Temporal frame sync across displays is a separate concern (ow-blz.5).

## Framing: reposition + zoom (ow-aqx.6, done)
The user repositions and zooms the video from the menu bar. NO CSS transform (see the
Slice Transform note: a transform blanks the hardware video layer). REPOSITION uses
`#bg { object-position: X% Y% }` AND a left/top zoom-slack offset, both driven by ONE
pan pair (panX/panY in -1..1): at zoom 1 it is pure object-position (the chopped-crop
fix); when zoomed, the offset `left/top = 50*(1-z)*(1+pan)%` adds, so a full stage-sized
window slides over the cover-scaled source (so Move Left/Right works on a wide union
once zoomed, which object-position alone cannot do). ZOOM sizes `#bg`:
`width = height = 100*z %` (percent of `#stage`, so it auto-tracks hot-plug resizes),
object-fit cover, `#stage` clips the enlarged video; z in [1,2] (below 1 would expose
black). `#bg` is pulled off the `inset:0` rule with explicit `right/bottom:auto` so the
box math is not overconstrained. `wallpaper.js` exposes `window.__setWallpaperFraming(cfg)`
(a pure setter, clamped) and applies the injected `window.__wallpaperFraming` at
document-start; it is NOT called from the geometry IIFE (percent sizing reflows on stage
resize, and touching `#bg` on the hot-plug survivor path risks a blank). Settings persist
in `config.json` and inject identically on every screen, so framing stays continuous
across the bezel. See swift-shell/overview.md for persistence + injection.

## Adaptive Mood (ow-aqx.15 Stage 1, done)
The wallpaper tints itself to the local time of day and the live weather: cooler and
dimmer at night, warmer at dawn/dusk, muted and dim on cloudy/stormy days. The native
`MoodController` owns all inputs (see swift-shell/overview.md): opt-in CoreLocation,
Open-Meteo, and a pure mapper. The web layer only APPLIES a pre-validated CSS filter
string to `#bg`, identically on every screen, so every slice of the one video matches.
- The native side injects `window.__wallpaperMood` at document-start (so a newcomer
  screen never paints bare identity) and broadcasts runtime updates via
  `window.__setWallpaperMood`. The mapper always emits the SAME five functions in the
  same order; the only property touched is `filter`, which composes cleanly with
  framing (size/position) and geometry (`left/top`) since those are different
  properties.
- The filter is the only validated-safe dynamic knob (ow-94b.5, static case). An
  ANIMATED filter (the 2s ease) across N union-sized layers was NOT covered by that
  spike and is a Phase-5 real-hardware watch (confirm the video does not blank/hitch
  through a transition on two displays).
- Verification: `window.__moodApplied` (parsed numbers) plus the inline
  `bg.style.filter` read-back are logged per window as `ONLYWALLPAPERS_MOOD_APPLIED`,
  and asserted identical across screens by `scripts/mood-check.sh`.

## Autoplay
The `<video>` needs `muted` + `playsinline` and an explicit `.play()` call (retried
on the `canplay` event) or macoS will not start it unprompted.

## Transparency (finding from ow-94b.1)
The public WKWebView transparency path on macOS 26 (`underPageBackgroundColor =
.clear` plus transparent CSS) does NOT make the base transparent: the WKWebView
renders an OPAQUE page background (an `screencapture -l` of an empty page region
comes back opaque, not the black a truly transparent buffer yields). The de-facto
macOS fix is the semi-private `setValue(false, forKey: "drawsBackground")` KVC,
which the project chose to avoid. Decision (Anoop): keep public APIs only, accept an
opaque base, and give the page a BLACK fallback. The full-bleed video (`object-fit:
cover`) covers the base, so the wallpaper itself is unaffected, and black is the
right pre-video fallback. True desktop-through transparency (needed only for Epic D
overlay/blend effects) is deferred to ow-aqx.4. So: WebWallpaperView keeps
`underPageBackgroundColor = .clear` (harmless, future-relevant) and the page owns the
backdrop (black until the video loads).

## Video Liveness at the Desktop Layer (validated: ow-94b.5)
A looping `<video>` in a WKWebView at the desktop window level keeps presenting new
frames continuously on Tahoe whenever its Space is visible: WebKit does NOT throttle
playback for an occluded/hidden desktop-level page (RVFC frames keep advancing with
`document.visibilityState=hidden`). A fully hidden wallpaper (app in its own
full-screen Space, or fully covered) pauses via macOS occlusion culling and resumes
live on reveal, which is fine. Load the page via `loadFileURL` with an ABSOLUTE
directory URL (a relative path silently fails), use
`mediaTypesRequiringUserActionForPlayback = []` with `muted` + `playsinline` for
autoplay, and keep a CSS `filter` on the video (that recomposite path is what
production ships). Multi-display slice sync across pause/resume is still open:
ow-blz.5.

## Live Editing (ow-94b.3, done)
Point `WALLPAPER_WEB_DIR` at a web folder (absolute path) and edits show on the next
launch without rebuilding the Swift package (there is no file watcher). With the var
unset, the app loads a seeded writable copy in
`~/Library/Application Support/OnlyWallpapers/web/` (ow-aqx.2; seeded from the bundle,
which is where the "Choose video..." picker writes), falling back to the
`Bundle.module` bundled copy if app storage is unwritable (`Package.swift` ships `web/`
as `resources: [.copy("web")]`). A set-but-invalid override fails fast (`exit(1)`)
rather than silently falling back. See
swift-shell/overview.md for the resolver contract and log grammar.

## Assets
`assets/bg.mp4` is the base clip. Large media is gitignored; keep a small sample
or document where to fetch one.
