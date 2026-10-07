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
     -c 'mcp_servers={}' --sandbox danger-full-access -m gpt-5.6-luna -o /tmp/ow-codex-scope.md 2>&1 < /dev/null
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
  -c 'mcp_servers={}' --sandbox danger-full-access -m gpt-5.6-luna -o /tmp/ow-codex-review.md 2>&1 < /dev/null
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
commands with `2>&1 < /dev/null` (without it `codex exec` hangs and exits 144). Always
pass `-c 'mcp_servers={}'` to `codex exec`: the user's `~/.codex/config.toml` registers
remote MCP servers (Linear via `mcp-remote`, openaiDeveloperDocs) that Codex connects to
at startup; those network/OAuth connections can hang the run (also surfacing as exit
144). We do not need MCP for scoping/review, so disable them. (`--ignore-user-config`
also works but drops all user config.) Also keep co-scope prompts LEAN AND BOUNDED:
name the specific files Codex should read, forbid whole-repo grep, and cap the length.
Open-ended "analyze everything" co-scopes run so long they also die at 144; focused
prompts (and the git-diff reviews) complete reliably.

---

## Repository Map
```
OnlyWallpapers/
├── CLAUDE.md  AGENTS.md  README.md   # governance + hub (Opus-owned)
├── Package.swift                     # SwiftPM executable
├── Sources/OnlyWallpapers/
│   ├── main.swift  AppDelegate.swift
│   ├── WallpaperController.swift     # NSScreen union -> per-screen slice geometry
│   ├── WebDirectoryResolver.swift    # WALLPAPER_WEB_DIR / app-storage / Bundle.module (ow-94b.3, ow-aqx.2)
│   ├── AppStorageManager.swift       # seed web dir + merge-based config.json: framing + weather cache + lat/lon (ow-aqx.2, ow-aqx.15)
│   ├── StatusItemController.swift    # menu-bar icon + Quit + Choose video + location opt-in (ow-aad.5, ow-aqx.2, ow-aqx.15)
│   ├── MoodController.swift          # time-of-day + live-weather mood brain: CoreLocation + Open-Meteo + openMeteoURL (ow-aqx.15)
│   ├── MoodMapper.swift              # pure moodParams + cssFilter + weather hysteresis (ow-aqx.15)
│   ├── WallpaperWindow.swift         # borderless desktop-layer, click-through window
│   ├── WebWallpaperView.swift        # WKWebView (opaque base + black fallback, local file access); applies framing + mood
│   └── web/                          # render layer; hot-editable via WALLPAPER_WEB_DIR
│       ├── index.html  style.css  wallpaper.js
│       └── assets/                   # bg.mp4 etc (gitignored)
├── scripts/                          # smoke-run, webdir-check, package-app/check, rebuild-check, video-check, framing-check, mood-check, overlay-check, lightning-check
└── ow-local/                         # knowledge repo (folder, same git history)
```

## Build & Run
- Build: `swift build`
- Run: `swift run OnlyWallpapers`
- Live-edit web without rebuild: `WALLPAPER_WEB_DIR=$PWD/Sources/OnlyWallpapers/web swift run OnlyWallpapers`
- Package a standalone app: `scripts/package-app.sh` produces `dist/OnlyWallpapers.app` (ow-aad.5)

## Testing
Every code change ships with tests. UI/visual behavior is verified in Phase 5.

## Knowledge
Durable design knowledge lives in `ow-local/` (see `ow-local/README.md`). Update
it when decisions change. Decisions are append-only `DEC-NNN-*.md` files.


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
