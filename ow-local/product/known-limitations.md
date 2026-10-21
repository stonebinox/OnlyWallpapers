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
- **Minimal settings UI.** The menu-bar menu now has a "Choose video..." item that
  sets and persists the wallpaper video (ow-aqx.2); moods and other options are still
  set in the web layer for now (a fuller controls surface is ow-aqx.7).
- **Ad-hoc signed, not notarized (ow-t4r.3); universal binary (ow-aad.5.1).** The
  release `OnlyWallpapers.app` is ad-hoc signed (`codesign --sign -`) with no Apple
  Developer ID and no notarization (App Store distribution and Developer ID signing are
  non-goals for now). Downloaded copies are quarantined, so Gatekeeper blocks the first
  launch; users approve it once via System Settings > Privacy & Security > Open Anyway,
  or run `xattr -dr com.apple.quarantine` on the app. A locally built copy is not
  quarantined and opens directly. The binary is universal (Apple Silicon arm64 +
  Intel x86_64) and needs macOS 14 (Sonoma) or newer; on Intel Macs video decode runs
  hotter, especially at 4K across multiple displays.
- **Setting a video (ow-aqx.2, done).** The menu-bar "Choose video..." item copies the
  picked `.mp4` into a single slot in app storage
  (`~/Library/Application Support/OnlyWallpapers/web/assets/bg.mp4`, overwritten each
  pick), persists it, and plays it immediately; the original can be deleted. v1 accepts
  MPEG-4 only (a `.mov` on the mp4 slot paints black), and the on-screen swap is an
  in-place `<video>` source change (a brief transition, no crossfade yet). A `.mov`/
  transcode path and a "Reset to default" are future niceties.
- **Launch at login not wired up.** Manual run for now (ow-aad.3). The menu-bar Quit
  item (ow-aad.5) is the only in-app way to stop it.
- **Autoplay quirk.** The `<video>` must be `muted` + `playsinline` with a JS
  `.play()` kick or it will not start on its own. (Since ow-blz.5 there is no autoplay
  or loop attribute; the sync controller owns play() and the wrap.)
- **Loop stutter (ow-blz.11).** The sync controller wraps by seeking every display to 0
  at the same instant; even a keyframe seek drops a few frames, visible on 4K60 clips.
- **Sync depends on video-only storage (ow-blz.9).** With an audio track present every
  WebKit seek costs 150 to 450 ms, limiting cross-display sync to about 0.2 s. Chosen
  videos are stored video-only; if the strip ever fails the app falls back to the
  original copy (logged) and sync degrades gracefully without a seek storm.
- **No playbackRate correction.** Any playbackRate change in WebKit loses 105 to 170 ms of
  presented timeline instantly, so the controller never nudges speed; residual error is
  corrected only by guarded seeks.
- **Weather is model-based (ow-aqx.17).** Open-Meteo current conditions miss small local
  convective rain; on 2026-10-18 the model, both Bengaluru airport METARs and RainViewer
  radar all showed nothing during real rain at the user's location.
