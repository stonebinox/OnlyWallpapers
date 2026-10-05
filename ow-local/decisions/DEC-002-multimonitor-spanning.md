# DEC-002: Multi-monitor via a single spanned canvas

- **Date:** 2026-10-05
- **Status:** accepted
- **Deciders:** Anoop, Opus

## Context
The wallpaper must cover multiple monitors and respect the Displays arrangement,
like the author's current tool (Fresco) which spreads one image across screens.
Two models exist: per-screen independent copies, or one logical canvas spanning
all screens with each showing its slice.

## Decision
Treat the union of all `NSScreen.screens` frames as one logical canvas. Create one
window per screen and show that screen's slice of the canvas, positioned using the
screen's offset within the union. This respects the arrangement for free, because
`NSScreen` frames already live in a shared global coordinate space that encodes
the layout.

## Alternatives Considered
- **Per-screen independent copies.** Simpler, but every monitor shows the same full
  image with no continuity across the arrangement. Not what Fresco does, not what
  we want.
- **One window spanning all displays.** A single desktop-level window across
  multiple screens and Spaces is fragile; per-screen windows are the robust pattern
  the existing wallpaper apps use.

## Consequences
- Easy: arrangement is respected with no extra config; adding or moving a display
  just recomputes the union on `didChangeScreenParametersNotification`.
- Hard / owed: one video decode per screen (known-limitations); a bottom-left to
  top-left Y flip in the slice math that must be correct; no bezel-gap correction
  yet.
