# CLAUDE.md — ow-local

This is the knowledge folder. The operational workflow (the five phases, agent
invocation, the bias firewall, commit rules) lives in the repo-root `CLAUDE.md`.
Read that first. This file only covers documentation discipline.

## Rules for This Folder
- Keep `product/current-state.md` honest. It is the single source of truth for
  what actually exists. Update it when reality changes, not when you intend to.
- Decisions are append-only. To change a past call, add a new `DEC-NNN` that
  supersedes the old one and note the supersession in both. Never edit history.
- One concept per file. Prefer linking to duplicating.
- No em dashes or en dashes (house rule).
- When a system's behavior changes in code, update its `systems/*/overview.md` in
  the same change set.
