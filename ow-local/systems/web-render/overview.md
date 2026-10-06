# System: Web Render Layer

Where the wallpaper actually looks like something. The native shell loads this
local page into a transparent WKWebView per screen. All visual control lives here
and can be edited without recompiling Swift.

Status: partially implemented. `WebWallpaperView` (ow-94b.1) is a `WKWebView`
subclass used as the WallpaperWindow content view, loading a local page via
`loadFileURL`; the default run currently loads a black-fallback stub. The real
looping-video page (index.html/style.css/wallpaper.js), the slice transform, and the
asset resolution below are still planned (ow-94b.2, ow-blz.1, ow-94b.3).

## Files
- **index.html**: a `#stage` containing the `<video id="bg">` and an overlay
  `<canvas>` for future effects.
- **style.css**: full-bleed video with `object-fit: cover`; the `filter` property
  on the video is the live-control knob (saturate, brightness, hue-rotate, blur).
- **wallpaper.js**: reads the injected geometry, sizes and positions the stage,
  kicks off autoplay, and runs any live logic (for example a time-of-day mood).

## The Slice Transform
The shell injects, at document start:
```js
window.__wallpaper = { stageW, stageH, offX, offY }
```
`wallpaper.js` then:
- sizes `#stage` to the full canvas: `width = stageW`, `height = stageH`;
- shifts it so this screen shows only its slice:
  `transform: translate(-offX px, -offY px)`.
Each screen's window is screen-sized; the oversized stage is scrolled under it.

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
