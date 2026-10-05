# Desktop-Layer Spike Findings (ow-mbw.1)

Date: 2026-10-05. Host: macOS 26.5.2 (Tahoe), Apple Silicon, Swift 6.3.3. Two
displays (BenQ EW2880U, BenQ EL2870U). This records what the spike actually
validated so ow-mbw.3 can seed the real WallpaperWindow from measured fact, not
guesswork. The spike code is `Sources/OnlyWallpapers/SpikeWindow.swift` (gated by
`OW_SPIKE=1`); keep it in-tree until ow-mbw.3 copies the factory, then remove it.

## Verdict
A borderless desktop-layer NSWindow renders CONTINUOUSLY behind desktop icons on
Tahoe and does NOT freeze, including while macOS reports the window occluded. The
core project premise is de-risked for an AppKit + CoreAnimation window. The video
render path (WKWebView `<video>`) is NOT covered here: see ow-94b.5.

## Validated window configuration (seed for ow-mbw.3)
| Property | Value | Why / what we saw |
|----------|-------|-------------------|
| construction | `NSWindow(styleMask: [.borderless], backing: .buffered, defer: false)` | Create borderless directly. Do not mutate the style mask later (Tahoe 26.3 regressions). |
| level | `NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))` | Resolved to -2147483623. `Int()` matters (Int32 sign extension). |
| measured z-order | self layer -2147483623 < Finder icon layer -2147483603 | Confirmed via `CGWindowListCopyWindowInfo`. Window sits strictly below the desktop-icon window, so icons and widgets draw on top. |
| collectionBehavior | `[.canJoinAllSpaces, .stationary, .ignoresCycle]` | Do not add `.canJoinAllApplications` / `.fullScreenAuxiliary` / `.screenSaver`. |
| input | `ignoresMouseEvents = true` | Click-through. Rests on this documented flag (not re-proven by pixels). |
| appearance | `hidesOnDeactivate = false`, `hasShadow = false` | |
| lifetime | `isReleasedWhenClosed = false`, retained by the delegate | A non-retained window vanishes. |
| show | `orderFrontRegardless()` | NOT `makeKeyAndOrderFront` (that would activate the accessory app). |
| frame | `screen.frame` (not `visibleFrame`) | Covers Dock and menu-bar areas. |
| screen | iterate `NSScreen.screens` (not `NSScreen.main`) | `main` can be nil for an accessory app. One window per display. |

## Animation / anti-freeze findings
- The compositor keeps animating the window. In two real `screencapture` frames of
  display 1 taken ~1s apart, the on-screen counter advanced (draws 366 -> 424, ca
  1056.6 -> 1217.7, clock 44:36.386 -> 44:37.352). This is composited-pixel proof,
  not just an in-process counter.
- CoreAnimation is NOT throttled under occlusion. A long-period monotonic
  `CABasicAnimation` sampled from `presentation()` advanced at the real-time rate
  (~167 units/sec of a 100000/600s ramp) even when `occlusionState` lacked
  `.visible`.
- `occlusionState` is dynamic and unreliable as a health signal: the two displays
  reported different and changing occ values (one `occ=true`, one `occ=false`)
  while both kept animating. Do not gate anything on occlusion being visible.
- App Nap: the spike holds
  `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)`. We have not
  isolated whether it is strictly required; a longer (>= 2 min) occluded watch is
  the remaining manual confirmation.

## Oracle lessons (why the test is shaped as it is)
- A `drawRect` draw counter advancing does NOT prove the composited desktop
  animates (AppKit can call `drawRect` under occlusion on a frozen surface). The
  real oracle is composited pixels changing (screenshot diff) plus the human eye.
- `NSView.displayLink` can stall for an occluded view, which would read as a false
  freeze. The spike drives redraws with a `Timer` added to `RunLoop.main` in
  `.common` mode instead, and uses the CA `presentation()` value plus the pixel
  diff for the rendered-output proof.
- A short repeating CA animation sampled near its period ALIASES. Use a long-period
  monotonic animation for a liveness probe.
- `screencapture` needs Screen Recording (TCC) permission for the terminal, and a
  full-desktop diff is confounded by the menu-bar clock. The pixel diff is also
  confounded when a foreground app covers the spike (seen on display 2). Capture
  per display and read the window region.

## Manual Phase 5 results (confirmed by Anoop on the live desktop, 2 displays, 2 Spaces)
- Behind icons: PASS. Dragging icons works, icons stay on top of the magenta.
- Click-through: PASS. Clicks and drags reach Finder, the window never grabs input.
- All-Spaces: PASS. Present on both Spaces.
- Keeps animating: PASS (also pixel-proven on display 1).
- Per-screen, not spanned: each display shows its OWN probe window and counter (a
  duplicated look), NOT one canvas spanned across displays. This is expected: the
  spanned single-canvas (union rect, per-screen slice) is Epic C (ow-blz), not this
  spike. ow-mbw.3 builds one window per screen; the slicing comes later.
- EDGE FINDING (ow-aad.4): while DRAGGING a desktop widget (clock, calendar), the
  real system wallpaper is briefly revealed (dimmed) in place of the magenta for the
  duration of the drag, then the magenta returns on drop. This is macOS widget-edit
  behavior revealing the true desktop during manipulation. Transient and cosmetic,
  but note it for the real wallpaper: during widget rearrange the user will see the
  underlying desktop, not our content.

## Not covered (follow-ups)
- WKWebView `<video>` continuous rendering at desktop level: ow-94b.5.
- Click-through and all-Spaces were not re-proven by pixels; they rest on the
  documented flags above. A 20-second manual check (click desktop icons, switch
  Spaces, watch the counter stay monotonic) is the only full confirmation.
- Lock / sleep / wake / Stage Manager / display hot-plug: Epic E follow-ups.
