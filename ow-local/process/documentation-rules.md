# Documentation Rules

Where knowledge lives, so it stays findable and does not rot.

## The Split
- **Code comments:** why a specific line is the way it is.
- **`systems/*/overview.md`:** how a technical area works, its key files, gotchas.
  Update in the same change set that changes the behavior.
- **`product/*`:** what we are building and its current reality.
  `current-state.md` is the single source of truth for what exists; keep it honest.
- **`decisions/DEC-NNN-*.md`:** why we chose one path over another. Append-only.
- **bd tasks:** the work to be done and its status. Not a knowledge store.

## Rules
- One concept per file. Link instead of duplicating.
- Decisions are never edited to change their meaning. Supersede with a new DEC and
  cross-link both.
- No em dashes or en dashes anywhere (house rule).
- When in doubt about where something goes, use the table in `../README.md`.

## When to Write a Decision
Write a DEC when a choice closes off alternatives that a future reader might
otherwise reopen: architecture, a dependency, a platform trade-off, a convention.
Do not write one for routine implementation detail.
