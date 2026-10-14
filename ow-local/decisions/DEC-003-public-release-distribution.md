# DEC-003: Public release as an ad-hoc signed download with a black default

- **Date:** 2026-10-13
- **Status:** accepted
- **Deciders:** Anoop Santhanam (user), Opus

## Context
People who saw the wallpaper wanted to run it. The user has no Apple Developer
account. The dev build bundled a personal, copyrighted video clip into the app because
`Package.swift` copies the whole `web/` folder, including the gitignored
`web/assets/bg.mp4`. The audience is technical and comfortable with the Privacy and
Security "Open Anyway" step.

## Decision
- Ship v0.1.0 ad-hoc signed (`codesign --sign -`), not notarized, as a zip on GitHub
  Releases, linked from anoopsanthanam.com. Each release also carries an unversioned
  `OnlyWallpapers.zip` so `releases/latest/download/OnlyWallpapers.zip` is stable.
- Release builds contain no video and start black. Users pick their own `.mp4`.
- The app is a regular Dock app with an icon (user request), keeping the menu-bar item.
- An About panel credits the author and links anoopsanthanam.com and Open-Meteo.

## Alternatives Considered
- **Developer ID + notarization:** clean first launch, but needs a paid account.
  Revisit if the audience grows beyond technical users.
- **Bundle a free sample video:** nicer first impression, but adds size and licensing
  checks; black plus a first-run hint is enough for v0.1.0.
- **Menu-bar-only accessory app:** the original design; the user wants a Dock icon.

## Consequences
- First launch is blocked by Gatekeeper until the user approves it; README documents
  both the System Settings path and `xattr -dr com.apple.quarantine`.
- The bundle id changed to `com.anoopsanthanam.onlywallpapers`, so a previously granted
  location permission is asked again once.
- Windows must be built under `.accessory` and only then flipped to `.regular`, or
  secondary-display windows land off the active Space (see swift-shell overview).
