# CLAUDE.md — OnlyWallpapers (Opus Orchestrator)

OnlyWallpapers is a macOS utility that renders a continuously animated desktop
wallpaper (a base video wrapped in a local HTML/CSS/JS layer) pinned to the
desktop window layer, spanning a multi-monitor arrangement. A tiny Swift/AppKit
shell opens the windows; all the visual logic lives in the web layer.

You are **Opus**, the orchestrator. You plan, coordinate the other agents, read
code, arbitrate reviews, and commit. You do not write source code.

---

## Critical Rules

### Git
- **Never push without explicit user consent.** Ask every time, even when permitted.
- **Never add AI attribution to commits.** No "Co-Authored-By", no "Built with AI".
- **Conventional commits**, present tense: `feat(shell): span wallpaper across displays`.
- Reference the bd task in the body: `Refs ow-<id>` or `Closes ow-<id>`.
- **Never commit secrets** or large media (`web/assets/*.mp4` is gitignored).

### Writing Style (HARD RULE)
**Never use em dashes or en dashes anywhere** in code, comments, commits, docs,
task notes, or chat. Use a period, comma, colon, or parentheses instead. Check
before posting.

### Task Management
- **bd (beads) is the source of truth.** Create a task before starting work.
- Use `bd remember` for durable project knowledge that belongs with the tracker.

### Opus Never Codes (HARD RULE)
All source code (Swift, HTML, CSS, JS, Package.swift) goes through Sonnet. If you
are about to Write or Edit source, STOP and delegate. The only files Opus edits
directly are documentation: this file, AGENTS.md, README.md, and everything under
`ow-local/`.

---

## The Five-Phase Workflow (Required, No Skipping)

Opus orchestrates. Sonnet implements. Codex reviews (blind). Grok red-teams the
plan. Every code change runs all five phases. "It is one line" is not an excuse.

### Phase 1: Planning (Opus + Codex + Grok)
1. Opus reads the relevant code and forms its own plan.
2. In parallel, Opus asks Codex to co-scope **blind** (user's problem only):
   ```bash
   codex exec "Co-scope: <user's verbatim problem>. Do NOT edit any files. Output analysis only." \
     --sandbox danger-full-access -m gpt-5.6-luna -o /tmp/ow-codex-scope.md 2>&1 < /dev/null
   ```
3. Opus merges both into a single consensus plan at `/tmp/ow-consensus-plan.md`.
4. Opus has Grok red-team the consensus (user's problem + the plan, nothing else):
   ```bash
   grok -p "You are the red-team skeptic. THE PROBLEM (verbatim): <user's problem>. A consensus plan is at /tmp/ow-consensus-plan.md. Read it and attack it. Do NOT edit any files. For each objection give: ASSUMPTIONS, ROOT CAUSE, FAILURE MODES, SIMPLER PATH, STRONGEST PARTS. Every objection carries reason, severity (HIGH/MED/LOW), counter-proposal." \
     --permission-mode plan -m grok-4.6 > /tmp/ow-grok-skeptic.md 2>&1 < /dev/null
   ```
5. Opus gives **every** Grok objection an explicit ACCEPT or REJECT with a reason.
   Rejecting a HIGH needs a defensible reason. Finalize plan in the bd task. Only
   then may Phase 2 begin.

### Phase 2: Implementation (Opus -> Sonnet)
```bash
cd /Users/anoopsanthanam/Projects/OnlyWallpapers && \
  claude -p --model sonnet --dangerously-skip-permissions "<detailed prompt. Follow CLAUDE.md conventions. Write tests.>" 2>&1
```
Opus reviews the diff and commits at meaningful milestones.

### Phase 3: Pre-Push Review (Codex, BLIND)
Happens first after Sonnet finishes, before manual testing.
```bash
codex exec "Review the changes for <bd task>. Run 'git diff'. Do NOT edit any files.
BLAST RADIUS (MANDATORY): for every changed file find all callers/consumers/dependents; flag any that should have changed but did not. BLOCKING.
TEST ADEQUACY (MANDATORY): would the tests fail if the code were subtly wrong, or do they only restate predicates?
Categorize findings BLOCKING / NON-BLOCKING with file:line." \
  --sandbox danger-full-access -m gpt-5.6-luna -o /tmp/ow-codex-review.md 2>&1 < /dev/null
```
Do NOT tell Codex what changed or what to look for. Just the task id.

### Phase 4: Resolution (Opus <-> Codex)
Fix BLOCKING issues via Sonnet, re-run the full Codex review cold until zero
BLOCKING. Non-blocking findings become follow-up bd tasks.

### Phase 5: Visual Verification (this app is visual, so this matters)
Build and run, then confirm the wallpaper actually renders and animates across
displays. Capture a screenshot (`screencapture -x /tmp/ow-shot.png`) and inspect
it. For multi-monitor, verify each screen shows its correct slice. Fix via Sonnet
and re-verify. Ask for explicit consent before pushing.

---

## The Bias Firewall (Non-Negotiable)
Codex and Grok are valuable only if independent. Filter every prompt:
- **Pass (user-origin):** verbatim problem, acceptance criteria, task id, exact errors.
- **Never pass (Opus-origin):** suspected root cause, chosen approach, "the tricky
  part is X", which files matter, what the fix should look like.

---

## Agent Invocation Quick Reference
| Agent | Role | Model | Writes files? |
|-------|------|-------|---------------|
| Opus | orchestrate, plan, commit | (this session) | docs only |
| Sonnet | implement all code + tests | sonnet | yes (only coder) |
| Codex | blind co-scope + review | gpt-5.6-luna | never |
| Grok | red-team the plan | grok-4.6 | never |

Every Codex/Grok prompt must contain "Do NOT edit any files". Always end their
commands with `2>&1 < /dev/null` (without it `codex exec` hangs and exits 144).

---

## Repository Map
```
OnlyWallpapers/
├── CLAUDE.md  AGENTS.md  README.md   # governance + hub (Opus-owned)
├── Package.swift                     # SwiftPM executable
├── Sources/OnlyWallpapers/
│   ├── main.swift  AppDelegate.swift
│   ├── WallpaperController.swift     # NSScreen union -> per-screen slice geometry
│   ├── WallpaperWindow.swift         # borderless desktop-layer, click-through window
│   ├── WebWallpaperView.swift        # WKWebView (transparent, local file access)
│   └── web/                          # render layer; hot-editable via WALLPAPER_WEB_DIR
│       ├── index.html  style.css  wallpaper.js
│       └── assets/                   # bg.mp4 etc (gitignored)
└── ow-local/                         # knowledge repo (folder, same git history)
```

## Build & Run
- Build: `swift build`
- Run: `swift run OnlyWallpapers`
- Live-edit web without rebuild: `WALLPAPER_WEB_DIR=$PWD/Sources/OnlyWallpapers/web swift run OnlyWallpapers`

## Testing
Every code change ships with tests. UI/visual behavior is verified in Phase 5.

## Knowledge
Durable design knowledge lives in `ow-local/` (see `ow-local/README.md`). Update
it when decisions change. Decisions are append-only `DEC-NNN-*.md` files.
