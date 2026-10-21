# DEC-004: Cross-display sync with a shared clock, rate 1.0 and guarded seeks

- **Date:** 2026-10-21
- **Status:** accepted
- **Deciders:** Anoop Santhanam (user), Opus

## Context
DEC-002 gives every display its own WKWebView and its own video decoder. Independent
decoders started at different moments, so the user saw three timestamps of one clip and
in-video lightning split across screens. A first fix (ow-blz.5) corrected drift with
frame-based seeks and +/-1 percent playbackRate nudges; on the user's 4K 60 fps clip
(keyframe every 1 s) it caused a seek storm (about 95 seeks/min per display, 6 to 9
presented fps). Measurements on real hardware (ow-blz.8) then showed: natural drift at
rate 1.0 is zero; ANY playbackRate change loses 105 to 170 ms of presented timeline in
WebKit; an audio track, even muted, makes every seek cost 150 to 450 ms.

## Decision
- One playback session owned natively (epoch wall clock, source revision, probed
  duration, seed), injected into every view; each view targets
  ((now - epoch) mod duration) and measures the presented frame (requestVideoFrameCallback).
- playbackRate is always exactly 1.0. Correction is by seeks only: on join, wrap, source
  change, visibility resume and persistent error; one native seek in flight per window
  with request ids; at most 2 re-seeks per event; cooldown with backoff.
- The wrap is an explicit shared-instant seek to 0 (a keyframe); no native `loop`.
- Chosen videos are stored video-only (passthrough, no re-encode), with a one-time
  migration of an existing slot.
- Storm overlay lightning is a pure function of (seed, wall clock) in union stage points.

## Alternatives Considered
- **Rate nudges / phase-locked loop:** unusable; every rate change costs 105 to 170 ms.
- **Hold-paused keyframe preroll for join:** rejected in red-team as a fragile second
  control plane; one accurate seek with a learned lead lands within a few ms on video-only
  clips.
- **Native gapless `loop`:** per-element and unsynchronized across views; revisit with a
  double-buffered seamless wrap (ow-blz.11).
- **Keeping the audio track:** makes precise sync physically unreachable with seeks.

## Consequences
- Measured on the user's 4K60 clip across two displays: pairwise p50 about 2 ms, p95 about
  12 ms, 0 corrective seeks, 54 to 57 presented fps; user confirmed smooth and in sync.
- A short stutter remains at the wrap (ow-blz.11).
- The sync gate needs an unlocked screen, uncovered desktops and no other running
  instance, and must include a user-profile fixture (4K60, 1 s GOP).
