#!/usr/bin/env bash
# sync-check (ow-blz.5 video sync, ow-blz.6 lightning sync).
# Real WKWebViews, real generated clip. Three app runs:
#   A  real displays: steady state, seams, forced +2 s desync, rebuild (SIGUSR1), video swap, lightning identity
#   B  real displays, +80 ms bias on one window: the offset assertion MUST fail (falsifiability)
#   C  fake screens 2 -> 3: a hot-plugged newcomer joins aligned
#   D  native duration probe forced to fail: one shared duration adopted from the first view, then swap
#   L  one window's lightning delayed 200 ms: the first-draw spread assertion MUST fail (falsifiability)
#   X  one window draws one extra independent strike: the event-set identity assertion MUST fail (falsifiability)
#   N  a NO-OP desync hook ("desync 1 0"): the desync-hook-took-effect assertion MUST fail (falsifiability)
#   R  fake screens 3 -> 2 (first display removed): the retired view stops emitting, survivors re-index, a routed command lands
# Run A also reloads one view after the swap (same path as a web content process restart): it must end on the latest rev, aligned.
# Hooks: OW_SYNC_TEST=1, OW_SYNC_CMD_FILE (SIGUSR2 commands: desync, reload, swap, extra), OW_SYNC_TEST_BIAS_MS, OW_SYNC_TEST_PROBE_FAIL,
#        OW_SYNC_TEST_LIGHTNING_DELAY_MS, OW_REBUILD_TEST, OW_FAKE_SCREENS_FILE.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

for tool in ffmpeg ffprobe node python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: missing $tool"; exit 1; }
done

WORK="$(mktemp -d)"
PID=""
cleanup() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -INT "$PID" 2>/dev/null || true
        sleep 0.4
        kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    if [[ "${OW_SYNC_KEEP:-0}" == "1" ]]; then echo "[sync-check] kept $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

echo "[sync-check] building..."
if ! swift build > "$WORK/build.out" 2>&1; then
    tail -20 "$WORK/build.out"
    echo "FAIL: swift build failed (aborting; never run a stale executable)"
    exit 1
fi
tail -3 "$WORK/build.out"
BIN="$(swift build --show-bin-path 2>/dev/null)/OnlyWallpapers"
[[ -x "$BIN" ]] || { echo "FAIL: binary missing"; exit 1; }

FAILS=0
step() { echo "[sync-check] $*"; }
nowms() { python3 -I -c 'import time; print(int(time.time()*1000))'; }
mark() { printf '{"name":"%s","t":%s}\n' "$1" "$(nowms)" >> "$MARKS"; }

# --- Generated clips: 30 fps, GOP 5 (cheap, frame-accurate seeks), short so seams are crossed often ---
CLIP_A="$WORK/clip-a.mp4"
CLIP_B="$WORK/clip-b.mp4"
ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=640x360:rate=30" -t 4 \
    -c:v libx264 -pix_fmt yuv420p -g 5 -keyint_min 5 -sc_threshold 0 -movflags +faststart -an "$CLIP_A" || { echo "FAIL: ffmpeg clip A"; exit 1; }
ffmpeg -y -loglevel error -f lavfi -i "smptebars=size=640x360:rate=30" -t 2.5 \
    -c:v libx264 -pix_fmt yuv420p -g 5 -keyint_min 5 -sc_threshold 0 -movflags +faststart -an "$CLIP_B" || { echo "FAIL: ffmpeg clip B"; exit 1; }
probe() { ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1"; }
DUR_A="$(probe "$CLIP_A")"
DUR_B="$(probe "$CLIP_B")"
FPS="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$CLIP_A" | python3 -I -c 'import sys; n,d=sys.stdin.read().strip().split("/"); print(float(n)/float(d))')"
step "clip A ${DUR_A}s, clip B ${DUR_B}s, ${FPS} fps"

new_web_dir() {
    local d="$1"
    mkdir -p "$d/assets"
    cp Sources/OnlyWallpapers/web/index.html Sources/OnlyWallpapers/web/style.css Sources/OnlyWallpapers/web/wallpaper.js "$d/"
    cp "$CLIP_A" "$d/assets/bg.mp4"
}

wait_for() { # file pattern timeout_s
    local i=0
    while (( i < $3 * 10 )); do
        grep -q "$2" "$1" 2>/dev/null && return 0
        sleep 0.1; i=$((i + 1))
    done
    return 1
}

start_app() { # outfile, extra env...
    local out="$1"; shift
    env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
        OW_SYNC_TEST=1 OW_WGT_TEST=1 OW_SUPPRESS_FIRST_RUN=1 \
        OW_APP_SUPPORT_DIR="$WORK/support-$$-$RANDOM" \
        WALLPAPER_WEB_DIR="$WEB" \
        "$@" "$BIN" > "$out" 2>&1 &
    PID=$!
}

stop_app() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -INT "$PID" 2>/dev/null || true
        local i=0
        while kill -0 "$PID" 2>/dev/null && (( i < 30 )); do sleep 0.1; i=$((i + 1)); done
        kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    PID=""
}

analyze() { # label checks extra...
    local label="$1" checks="$2"; shift 2
    python3 -I scripts/sync-check-analyze.py "$OUT" "$MARKS" --checks "$checks" --fps "$FPS" --dur-a "$DUR_A" --dur-b "$DUR_B" --label "$label" "$@"
}

# OW_SYNC_ONLY=B (debug aid): run only the named phases (any of 0 A B C D L X N R). Default: all.
want() { [[ -z "${OW_SYNC_ONLY:-}" || "${OW_SYNC_ONLY}" == *"$1"* ]]; }

# --- (0) pure lightning function, frozen timestamps ---
step "(0) pure lightning function (frozen timestamps)"
if node scripts/lightning-pure-check.js > "$WORK/pure.out" 2>&1; then
    echo "$(tail -1 "$WORK/pure.out")"
else
    cat "$WORK/pure.out" | grep -v ' pass ' ; echo "FAIL: lightning pure-function check"; FAILS=$((FAILS + 1))
fi

# --- (A) full run ---
if want A; then
step "(A) real displays: steady state, seams, desync, rebuild, swap, lightning"
WEB="$WORK/web-a"; new_web_dir "$WEB"
OUT="$WORK/run-a.out"; MARKS="$WORK/marks-a.jsonl"; : > "$MARKS"
CMD="$WORK/cmd-a.txt"; : > "$CMD"
start_app "$OUT" OW_SYNC_CMD_FILE="$CMD" OW_REBUILD_TEST=1
if ! wait_for "$OUT" "ONLYWALLPAPERS_READY" 20; then echo "FAIL: app never became ready"; cat "$OUT" | tail -20; FAILS=$((FAILS + 1)); fi
sleep 26                      # settle (4 s) + about 5 seams of the 4 s clip
mark desync
echo "desync 1 2000" > "$CMD"; kill -USR2 "$PID"
sleep 7
mark rebuild
kill -USR1 "$PID"
sleep 8
mark swap
echo "swap $CLIP_B" > "$CMD"; kill -USR2 "$PID"
sleep 12
mark reload
echo "reload 1" > "$CMD"; kill -USR2 "$PID"
sleep 9
mark end
stop_app
if analyze "A" "windows,steady,seams,desync,rebuild,swap,reload,lightning"; then :; else FAILS=$((FAILS + 1)); fi > "$WORK/analysis-a.txt"
cat "$WORK/analysis-a.txt"
# Existing one-pixel readback path (pollStormMaxAlpha) on every window.
px_lines="$(grep 'ONLYWALLPAPERS_STORM_PIXEL' "$OUT" | grep -v unavailable || true)"
px_wins="$(printf '%s\n' "$px_lines" | grep -c maxRenderedAlpha=[1-9] || true)"
live_wins="$(grep '^ONLYWALLPAPERS_STORM ' "$OUT" | sed 's/.*win=//;s/ .*//' | sort -u | wc -l | tr -d ' ')"
if [[ "$px_wins" -ge 2 && "$px_wins" -ge "$live_wins" ]] && ! printf '%s\n' "$px_lines" | grep -q 'postFlashIdleAlpha=[1-9]'; then
    echo "SYNC_ASSERT pass lightning-storm-pixel-all-windows windows_with_flash=$px_wins windows=$live_wins"
else
    echo "SYNC_ASSERT FAIL lightning-storm-pixel-all-windows windows_with_flash=$px_wins windows=$live_wins"; FAILS=$((FAILS + 1))
fi
if grep -q 'ONLYWALLPAPERS_JS kind=\(error\|rejection\)' "$OUT"; then
    echo "SYNC_ASSERT FAIL no-js-errors"; grep 'ONLYWALLPAPERS_JS' "$OUT" | head -5; FAILS=$((FAILS + 1))
else
    echo "SYNC_ASSERT pass no-js-errors"
fi

fi

# --- (B) falsifiability: +80 ms constant bias on window idx 1; the offset assertion must fail ---
if want B; then
step "(B) falsifiability: +80 ms bias on one window (offset assertion MUST fail)"
WEB="$WORK/web-b"; new_web_dir "$WEB"
OUT="$WORK/run-b.out"; MARKS="$WORK/marks-b.jsonl"; : > "$MARKS"
start_app "$OUT" OW_SYNC_TEST_BIAS_MS=80
wait_for "$OUT" "ONLYWALLPAPERS_READY" 20 || { echo "FAIL: app (B) never became ready"; FAILS=$((FAILS + 1)); }
sleep 14
mark end
stop_app
if analyze "B" "windows,steady" > "$WORK/analysis-b.txt" 2>&1; then
    cat "$WORK/analysis-b.txt"
    echo "SYNC_ASSERT FAIL falsifiability: +80 ms bias did NOT fail the offset assertion"; FAILS=$((FAILS + 1))
else
    grep 'steady-state-pairwise\|SYNC_METRIC' "$WORK/analysis-b.txt"
    if grep -q 'SYNC_ASSERT FAIL steady-state-pairwise' "$WORK/analysis-b.txt"; then
        echo "SYNC_ASSERT pass falsifiability: +80 ms bias made the offset assertion fail, as required"
    else
        cat "$WORK/analysis-b.txt"
        echo "SYNC_ASSERT FAIL falsifiability: run B failed for a reason other than the offset assertion"; FAILS=$((FAILS + 1))
    fi
fi

fi

# --- (C) hot-plug newcomer via fake screens ---
if want C; then
step "(C) fake screens 2 -> 3: newcomer joins aligned"
WEB="$WORK/web-c"; new_web_dir "$WEB"
OUT="$WORK/run-c.out"; MARKS="$WORK/marks-c.jsonl"; : > "$MARKS"
FAKE="$WORK/fake-screens.txt"
printf '0,0,1280,720,1,101\n1280,0,1280,720,1,102\n' > "$FAKE"
start_app "$OUT" OW_FAKE_SCREENS_FILE="$FAKE"
wait_for "$OUT" "ONLYWALLPAPERS_READY" 20 || { echo "FAIL: app (C) never became ready"; FAILS=$((FAILS + 1)); }
sleep 9
printf '0,0,1280,720,1,101\n1280,0,1280,720,1,102\n2560,0,1280,720,1,103\n' > "$FAKE"
mark newcomer
kill -USR1 "$PID"
sleep 14
mark end
stop_app
if analyze "C" "windows,newcomer" --min-windows 3 > "$WORK/analysis-c.txt" 2>&1; then :; else FAILS=$((FAILS + 1)); fi
cat "$WORK/analysis-c.txt"
fi

# --- (D) native probe failure: ONE shared duration adopted from the first view's metadata ---
if want D; then
step "(D) native duration probe forced to fail: one shared duration, then swap"
WEB="$WORK/web-d"; new_web_dir "$WEB"
OUT="$WORK/run-d.out"; MARKS="$WORK/marks-d.jsonl"; : > "$MARKS"
CMD="$WORK/cmd-d.txt"; : > "$CMD"
start_app "$OUT" OW_SYNC_CMD_FILE="$CMD" OW_SYNC_TEST_PROBE_FAIL=1
wait_for "$OUT" "ONLYWALLPAPERS_READY" 20 || { echo "FAIL: app (D) never became ready"; FAILS=$((FAILS + 1)); }
sleep 12
mark swap
echo "swap $CLIP_B" > "$CMD"; kill -USR2 "$PID"
sleep 12
mark end
stop_app
if analyze "D" "probefail,lightning" > "$WORK/analysis-d.txt" 2>&1; then :; else FAILS=$((FAILS + 1)); fi
cat "$WORK/analysis-d.txt"
fi

# --- (L) falsifiability: one window's lightning delayed 200 ms; the spread assertion must fail ---
if want L; then
step "(L) falsifiability: 200 ms lightning delay on one window (first-draw spread assertion MUST fail)"
WEB="$WORK/web-l"; new_web_dir "$WEB"
OUT="$WORK/run-l.out"; MARKS="$WORK/marks-l.jsonl"; : > "$MARKS"
start_app "$OUT" OW_SYNC_TEST_LIGHTNING_DELAY_MS=200
wait_for "$OUT" "ONLYWALLPAPERS_READY" 20 || { echo "FAIL: app (L) never became ready"; FAILS=$((FAILS + 1)); }
sleep 20
mark end
stop_app
analyze "L" "lightning" > "$WORK/analysis-l.txt" 2>&1
grep 'lightning-first-draw-spread\|lightning_first_draw_spread' "$WORK/analysis-l.txt"
if grep -q 'SYNC_ASSERT FAIL lightning-first-draw-spread' "$WORK/analysis-l.txt"; then
    echo "SYNC_ASSERT pass falsifiability: a 200 ms lightning delay made the first-draw spread assertion fail, as required"
else
    echo "SYNC_ASSERT FAIL falsifiability: a 200 ms lightning delay did NOT fail the first-draw spread assertion"; FAILS=$((FAILS + 1))
fi
fi

# --- (X) falsifiability: one window draws an extra independent strike; the event-set assertion must fail ---
if want X; then
step "(X) falsifiability: one extra strike on one window (event-set identity assertion MUST fail)"
WEB="$WORK/web-x"; new_web_dir "$WEB"
OUT="$WORK/run-x.out"; MARKS="$WORK/marks-x.jsonl"; : > "$MARKS"
CMD="$WORK/cmd-x.txt"; : > "$CMD"
start_app "$OUT" OW_SYNC_CMD_FILE="$CMD"
wait_for "$OUT" "ONLYWALLPAPERS_READY" 20 || { echo "FAIL: app (X) never became ready"; FAILS=$((FAILS + 1)); }
sleep 10
mark extra
echo "extra 1" > "$CMD"; kill -USR2 "$PID"
sleep 12
mark end
stop_app
analyze "X" "lightning" > "$WORK/analysis-x.txt" 2>&1
grep 'lightning-event-sets-identical' "$WORK/analysis-x.txt"
if grep -q 'SYNC_ASSERT FAIL lightning-event-sets-identical' "$WORK/analysis-x.txt" && grep -q 'extra-' "$WORK/analysis-x.txt"; then
    echo "SYNC_ASSERT pass falsifiability: one extra strike on one window made the event-set identity assertion fail, as required"
else
    echo "SYNC_ASSERT FAIL falsifiability: one extra strike did NOT fail the event-set identity assertion"; FAILS=$((FAILS + 1))
fi
fi

# --- (N) falsifiability: a no-op desync hook (0 ms); the observed-presented-frame-deviation assertion must fail ---
if want N; then
step "(N) falsifiability: no-op desync hook (desync-hook-took-effect MUST fail)"
WEB="$WORK/web-n"; new_web_dir "$WEB"
OUT="$WORK/run-n.out"; MARKS="$WORK/marks-n.jsonl"; : > "$MARKS"
CMD="$WORK/cmd-n.txt"; : > "$CMD"
start_app "$OUT" OW_SYNC_CMD_FILE="$CMD"
wait_for "$OUT" "ONLYWALLPAPERS_READY" 20 || { echo "FAIL: app (N) never became ready"; FAILS=$((FAILS + 1)); }
sleep 10
mark desync
echo "desync 1 0" > "$CMD"; kill -USR2 "$PID"
sleep 6
mark end
stop_app
analyze "N" "desync" > "$WORK/analysis-n.txt" 2>&1
grep 'desync-hook-took-effect' "$WORK/analysis-n.txt"
if grep -q 'SYNC_ASSERT FAIL desync-hook-took-effect' "$WORK/analysis-n.txt"; then
    echo "SYNC_ASSERT pass falsifiability: a no-op desync hook made desync-hook-took-effect fail, as required"
else
    echo "SYNC_ASSERT FAIL falsifiability: a no-op desync hook did NOT fail desync-hook-took-effect"; FAILS=$((FAILS + 1))
fi
fi

# --- (R) retire + reorder: fake screens 3 -> 2, first display removed ---
if want R; then
step "(R) fake screens 3 -> 2: retired view stops emitting, survivors re-index, routed command lands"
WEB="$WORK/web-r"; new_web_dir "$WEB"
OUT="$WORK/run-r.out"; MARKS="$WORK/marks-r.jsonl"; : > "$MARKS"
CMD="$WORK/cmd-r.txt"; : > "$CMD"
FAKE="$WORK/fake-screens-r.txt"
printf '0,0,1280,720,1,101\n1280,0,1280,720,1,102\n2560,0,1280,720,1,103\n' > "$FAKE"
start_app "$OUT" OW_FAKE_SCREENS_FILE="$FAKE" OW_SYNC_CMD_FILE="$CMD"
wait_for "$OUT" "ONLYWALLPAPERS_READY" 20 || { echo "FAIL: app (R) never became ready"; FAILS=$((FAILS + 1)); }
sleep 9
printf '1280,0,1280,720,1,102\n2560,0,1280,720,1,103\n' > "$FAKE"
mark retire
kill -USR1 "$PID"
sleep 5
mark cmd
echo "desync 0 2000" > "$CMD"; kill -USR2 "$PID"
sleep 6
mark end
stop_app
if analyze "R" "retire" > "$WORK/analysis-r.txt" 2>&1; then :; else FAILS=$((FAILS + 1)); fi
cat "$WORK/analysis-r.txt"
fi

echo
# Runs B, L, X and N fail their assertions by design, so only A, C, D and R feed the verdict.
VERDICT_FILES=("$WORK/analysis-a.txt" "$WORK/analysis-c.txt" "$WORK/analysis-d.txt" "$WORK/analysis-r.txt")
PASSES="$(cat "${VERDICT_FILES[@]}" "$WORK/pure.out" 2>/dev/null | grep -c 'SYNC_ASSERT pass\|LIGHTNING_PURE pass' || true)"
if [[ "$FAILS" -eq 0 ]] && ! grep -h 'SYNC_ASSERT FAIL' "${VERDICT_FILES[@]}" >/dev/null 2>&1; then
    echo "sync-check PASS: $PASSES assertions passed (A + C + D + R + pure-function), falsifiability runs B, L, X and N confirmed"
    exit 0
fi
echo "sync-check FAIL: $(cat "${VERDICT_FILES[@]}" | grep -c 'SYNC_ASSERT FAIL') analysis assertion(s) failed, $FAILS gate failure(s), $PASSES passed"
exit 1
