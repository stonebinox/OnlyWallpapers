# ow-local — OnlyWallpapers Knowledge

The design memory for OnlyWallpapers: what we are building, how the pieces work,
and why we made the calls we made. Code lives in the parent repo; this folder is
the durable knowledge that is not obvious from the code.

This is a folder inside the OnlyWallpapers repo, not a separate git history.

## What Goes Where
| Question | Folder / file |
|----------|---------------|
| What are we building, and why? | `product/overview.md` |
| What exists today? | `product/current-state.md` |
| What can we not (yet) do? | `product/known-limitations.md` |
| How does a technical area work? | `systems/<area>/overview.md` |
| Why did we choose X over Y? | `decisions/DEC-NNN-*.md` (append-only) |
| How do we work here? | `process/documentation-rules.md` |

## Start Here (AI agents)
1. `product/current-state.md` for the live status.
2. `product/overview.md` for the shape of the thing.
3. The relevant `systems/*/overview.md` before touching that area.
4. Skim `decisions/` so you do not relitigate settled calls.

## Systems
- `systems/swift-shell/overview.md`: AppKit windows, screen geometry, the
  desktop-layer trick.
- `systems/web-render/overview.md`: the HTML/CSS/JS render layer and the
  per-screen slice transform.
