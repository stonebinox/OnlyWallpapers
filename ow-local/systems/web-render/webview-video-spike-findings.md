# WKWebView Video De-risk Findings (ow-94b.5)

Date: 2026-10-05. Host: macOS 26.5.2 (Tahoe), Apple Silicon, two displays, AC power.
De-risks the DEC-001 render path (a looping `<video>` in a transparent WKWebView)
at the desktop window layer, which ow-mbw.1 did NOT cover (it proved AppKit +
CoreAnimation only). Spike code is `WebSpikeWindow.swift` + `web/webspike/` (gated
by `OW_WEBSPIKE=1`); keep it until ow-94b.1 copies the config, then remove it.

## Verdict: PASS (with a benign occlusion nuance)
A looping, muted, filtered `<video>` in a WKWebView pinned at the desktop window
level keeps presenting new frames continuously on Tahoe whenever its Space is
visible. The WebKit Page-Visibility / background throttle (the main feared failure)
does NOT occur: `requestVideoFrameCallback` presented-frame count kept advancing at
roughly 15 to 40 fps for a 125s watch even with `document.visibilityState=hidden`,
`media=playing` throughout, no WebContent process termination. Proven on the glass:
an `screencapture -l` of the window's backing store showed the burned-in frame
counter advancing (e.g. F35 with an advancing timecode).

## The occlusion nuance (important, benign)
- When the wallpaper window is VISIBLE (including with another window maximized over
  part of it in the same Space), it animates normally.
- When the wallpaper window is FULLY hidden (an app taken into its own full-screen
  Space, or a window fully covering the display), macOS (WindowServer) stops
  compositing that window (occlusion culling), so its on-screen backing store goes
  stale. The WebKit media PIPELINE keeps running (RVFC advances), so on reveal it
  RESUMES live, not frozen. Confirmed by direct observation (Anoop): paused while in
  a separate full-screen Space, animating again on return to the desktop Space.
- This is correct, power-saving behavior for a wallpaper: you never see a fully
  hidden wallpaper, and it is live the moment it is visible again.
- Therefore `screencapture -l` of a 100%-occluded window is NOT a valid freeze
  oracle (it measures compositor culling). The authoritative liveness signals are
  RVFC presented-frame count, `WKMediaPlaybackState=playing`, and the band of a
  VISIBLE window advancing. A real freeze would be a VISIBLE window that is static.

## Validated WKWebView configuration (seed for ow-94b.1)
- Window: the ow-mbw.1 factory, but isOpaque=false + backgroundColor=.clear.
- `WKWebViewConfiguration.mediaTypesRequiringUserActionForPlayback = []` for autoplay.
  Do NOT use `allowsInlineMediaPlayback` (iOS-only, does not compile on macOS); use
  the HTML `playsinline` attribute.
- `video.muted = true` then `video.play()`, retried on `loadeddata` / `canplay`.
- `loadFileURL(_:allowingReadAccessTo:)` with an ABSOLUTE directory URL. A relative
  path silently fails to load (blank page, no JS, no video). Resolve to an absolute
  standardized file URL.
- Transparency: use public API (`underPageBackgroundColor = .clear` + transparent
  CSS). Do NOT use `setValue(false, forKey: "drawsBackground")` (private). Whether
  the public path is fully transparent on macOS 26 was checked in a dedicated clear
  mode and is a detail for ow-94b.1 (the liveness clip is full-bleed, so transparency
  does not affect the liveness result).
- The CSS `filter` on the video (e.g. `brightness(1.01)`) matters: DEC-001 chose
  WKWebView FOR live CSS filters, and a filter forces the video into a recomposited
  backing store (the path production uses). The spike tests WITH a filter by default.

## Throwaway-check limitations (the authoritative oracle is direct observation)
The verdict rests on direct evidence: RVFC presented-frame count advancing with
`visibility=hidden`, an `screencapture -l` showing the burned-in counter advancing,
and Anoop's live observation (visible wallpaper animates; full-screen Space pauses
then resumes live). `scripts/webspike-check.sh` is throwaway support with known
gaps, acceptable because it is deleted at ow-94b.1 and the human oracle is primary:
- JS telemetry (presentedFrames) carries no per-window id, so the RVFC gate is
  global; a frozen display could be masked there. Mitigated by the per-window `-l`
  pixel gate, which fails a visible-but-frozen display independently.
- The pixel diff uses `cmp` on PNG bytes (works empirically here: identical for a
  frozen window, differs for an animating one), not a decoded-pixel compare.
- The watch asserts occlusion (`occ=false` sustained) but not that a specific
  foreground app is frontmost; the accessory app is never active anyway.
- A fully-occluded window's stale `-l` backing store is classified EXPECTED (not a
  freeze) when RVFC and media are healthy (see the occlusion nuance above).

## What this did NOT cover (follow-ups)
- Multi-display SLICE SYNC across pause/resume: ow-blz.5. The spanned canvas is one
  screen-sized window per display (each a slice), each with its own decode. When one
  display is in a full-screen Space and pauses, does its slice resume frame-synced
  with the still-running slice? Needs a shared playback clock / resync.
- True multi-minute idle App Nap (display off / no HID): not exercised (the watch ran
  with the system active, UserIsActive held). Occlusion / Page-Visibility is de-risked;
  deep idle sleep/wake is ow-aad.1 territory.
- Real product `bg.mp4` sourcing (ow-94b.4). The spike uses a generated ffmpeg test
  clip with a burned-in counter.
