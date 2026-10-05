# Known Limitations

Trade-offs we have accepted, with the reason. Revisit these as the project grows.

## Rendering
- **N video decodes on N monitors.** Each screen gets its own window and WKWebView,
  so a spanned video is decoded once per screen. Fine for two or three displays on
  Apple Silicon. Revisit if it becomes a battery or thermal problem.
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
- **Launch at login not wired up.** Manual run for now.
- **Autoplay quirk.** The `<video>` must be `muted` + `playsinline` with a JS
  `.play()` kick or it will not start on its own.
