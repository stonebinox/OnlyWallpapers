# Overview

## What
OnlyWallpapers is a macOS desktop utility that renders a wallpaper which keeps
animating all the time (not just as a screensaver, not just on login). The
wallpaper is a base video wrapped in a local web page, so the look is controlled
live in HTML/CSS/JS: filters, time-of-day tints, overlays, future reactive
effects.

## Why
macOS has no public API for an always-animated wallpaper. The built-in dynamic
wallpapers play once then freeze. Windows users get Wallpaper Engine. The goal is
that same always-moving desktop on macOS, built the way the existing third-party
apps do it (a window pinned to the desktop layer), plus a web render layer we
control and can hack on.

## Shape
- A small Swift/AppKit shell opens the windows and handles screen geometry. It is
  intended to be written once and rarely touched.
- All the creative and visual logic lives in the web layer, which can be
  hot-edited without recompiling Swift.

## Primary Goals
1. A wallpaper that animates continuously behind the desktop icons, click-through,
   on every Space.
2. Multi-monitor that respects the Displays arrangement: one logical canvas
   spanning all screens, each screen showing its slice (Fresco-style), not N
   independent copies.
3. Live control of the look from the web layer with fast iteration.

## Non-Goals (for now)
- A GUI settings app or menu-bar controls.
- App Store distribution and code signing.
- Bezel-gap correction between monitors.
- Per-screen independent wallpapers (we are doing one spanned canvas first).

See `known-limitations.md` for the trade-offs we have accepted.
