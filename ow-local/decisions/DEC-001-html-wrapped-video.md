# DEC-001: HTML-wrapped video for the render layer

- **Date:** 2026-10-05
- **Status:** accepted
- **Deciders:** Anoop, Opus

## Context
We want a continuously animated desktop wallpaper with live control over the look
(filters, time-of-day moods, overlays), and fast iteration. The author is newer to
Swift and comfortable in web tech. Three render approaches were on the table.

## Decision
Render a base video inside a local HTML page (a `<video>` element) shown in a
transparent WKWebView, with the look controlled by CSS/JS. The Swift shell stays
small; all visual logic lives in the web layer and is hot-editable without a
rebuild.

## Alternatives Considered
- **Raw AVPlayer video.** Most battery-efficient and simplest to loop, but gives
  almost no live control (no filters, overlays, or reactive logic) without a lot
  more native code.
- **Metal shader.** Prettiest and lightest on CPU, but the steepest native graphics
  learning curve and the slowest to iterate for this author.

## Consequences
- Easy: iterate on the look in a familiar language, no recompile; CSS filters,
  canvas/WebGL overlays, time-of-day logic are all straightforward.
- Hard / owed: slightly higher cost than bare AVPlayer (accepted); one video decode
  per screen (see DEC-002 and known-limitations); must handle the autoplay quirk
  (muted + playsinline + JS kick) and WKWebView transparency.
