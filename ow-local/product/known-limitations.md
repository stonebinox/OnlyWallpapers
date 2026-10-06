# Known Limitations

Trade-offs we have accepted, with the reason. Revisit these as the project grows.

## Rendering
- **N video decodes on N monitors.** Each screen gets its own window and WKWebView,
  so a spanned video is decoded once per screen. Fine for two or three displays on
  Apple Silicon. Revisit if it becomes a battery or thermal problem.
- **N union-sized composited layers (ow-blz.2).** With spanning, each per-screen
  WKWebView now composites a `#stage` the size of the WHOLE union canvas (not just
  its screen), with the video filling it. So a 3-display arrangement composites three
  union-wide filtered video layers, and a Retina display rasterizes the full union at
  2x. Accepted for the two-display target; revisit if GPU, thermal, or memory shows up
  in Phase 5. A single shared decoder is a later idea, not pursued here.
- **Cover crop is computed in union space (ow-blz.2).** The base video uses
  `object-fit: cover` against the union canvas, so an extreme union aspect ratio
  (for example a 16:9 clip across a 32:9 span) keeps only a thin center band of the
  source. The crop is continuous across the bezel, but the source content shown is a
  band, not the whole frame. A different `object-position` or per-arrangement framing
  is a future refinement.
- **WKWebView video vs raw AVPlayer.** WKWebView uses hardware decode for `<video>`
  on Apple Silicon, but is slightly heavier than a bare AVPlayer. We accept the
  cost for the live-control flexibility of the web layer. See DEC-001.

## Multi-Monitor
- **No bezel-gap correction.** The spanned canvas ignores the physical gap between
  monitors, so a panning image is continuous in pixels, not in physical space.
  Later refinement.
- **Mixed Retina scales.** Screens with different backing scale factors are handled
  because geometry is expressed in points (CSS px map to points); verify visually.

## Platform
- **No persistence or settings UI.** Which video, moods, and options are set in the
  web layer and env vars for now.
- **Unsigned, local, arm64 only (ow-aad.5).** The packaged `OnlyWallpapers.app` is
  built locally and unsigned (App Store distribution and Developer ID signing are
  non-goals). A locally built, non-downloaded app has no quarantine so it runs without
  a Gatekeeper prompt; a copy that is zipped or AirDropped needs
  `xattr -dr com.apple.quarantine`. The binary is arm64 (Apple Silicon); no universal
  build.
- **Setting a video in the installed app is clunky.** A double-clicked `.app` gets no
  shell environment, so `WALLPAPER_WEB_DIR` only helps when launched from a terminal.
  In the installed app you drop `bg.mp4` inside the bundle
  (`OnlyWallpapers.app/OnlyWallpapers_OnlyWallpapers.bundle/web/assets/`) or re-run the
  package script. A friendlier fixed location is deferred to ow-aqx.2.
- **Launch at login not wired up.** Manual run for now (ow-aad.3). The menu-bar Quit
  item (ow-aad.5) is the only in-app way to stop it.
- **Autoplay quirk.** The `<video>` must be `muted` + `playsinline` with a JS
  `.play()` kick or it will not start on its own.
