# System: Web Render Layer

Where the wallpaper actually looks like something. The native shell loads this
local page into a transparent WKWebView per screen. All visual control lives here
and can be edited without recompiling Swift.

Status: partially implemented. `WebWallpaperView` (ow-94b.1) is a `WKWebView`
subclass used as the WallpaperWindow content view, loading the local page via
`loadFileURL`. The real looping-video page (ow-94b.2) is now in place: a looping
muted video fills the window and starts on its own, with a black fallback. The slice
positioning (ow-blz.2) is in place: the one video is sliced across all displays via
injected per-screen geometry and `left/top` positioning of `#stage`. Still planned:
the asset-dir resolution (ow-94b.3, WALLPAPER_WEB_DIR + Bundle.module) and mood logic
(Epic D).

## Files
- **index.html**: a `#stage` containing the `<video id="bg">` (muted, playsinline,
  loop, autoplay) and an overlay `<canvas>` reserved for future effects (inert).
- **style.css**: full-bleed video with `object-fit: cover`; a `filter` on the video
  (currently `brightness(1.01)`, the validated recomposite path) is the live-control
  knob for the look (saturate, brightness, hue-rotate, blur). Black fallback until
  the video decodes (the WKWebView base is opaque on macOS 26, see Transparency).
- **wallpaper.js**: two IIFEs. A geometry IIFE reads `window.__wallpaper` and
  positions `#stage` by `left/top` to this screen's slice (recording the real applied
  rect in `window.__wallpaperApplied`); then an autoplay IIFE kicks `play()` with
  `canplay`/`loadeddata` retries and an `ended` belt. Mood logic is still Epic D.

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

## Live Editing (planned, ow-94b.3)
The intent: point `WALLPAPER_WEB_DIR` at this folder and edits show on next launch
without rebuilding the Swift package. Not wired yet: ow-94b.1 loads the web dir from
a `#filePath` dev path, and ow-94b.3 adds the `WALLPAPER_WEB_DIR` override plus
`Bundle.module` resources.

## Assets
`assets/bg.mp4` is the base clip. Large media is gitignored; keep a small sample
or document where to fetch one.
