# System: Web Render Layer

Where the wallpaper actually looks like something. The native shell loads this
local page into a transparent WKWebView per screen. All visual control lives here
and can be edited without recompiling Swift.

Status: planned, not yet implemented. This describes the intended design.

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

## Transparency
The shell sets the WKWebView to not draw its background; the page keeps a solid
fallback color only until the video loads. Use public API for this
(`underPageBackgroundColor = .clear` plus transparent CSS), not the private
`setValue(false, forKey: "drawsBackground")` KVC. See
`webview-video-spike-findings.md`.

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

## Live Editing
Point `WALLPAPER_WEB_DIR` at this folder and edits show on next launch (or on
reload) without rebuilding the Swift package.

## Assets
`assets/bg.mp4` is the base clip. Large media is gitignored; keep a small sample
or document where to fetch one.
