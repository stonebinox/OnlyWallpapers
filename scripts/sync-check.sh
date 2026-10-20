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
#   P  (ow-blz.8) the user's clip profile: 4K60 H.264, 1 s GOP, ~40 Mbit/s, 18 s, video only (see S and T).
#      Per-window health (corrective seeks/min, presented fps, rate exactly 1.0, no unexplained stall, seam hitch, absolute
#      error) plus the pairwise offset bar, on this machine's real displays. The fixture is cached in $TMPDIR.
#   F  (ow-blz.8) falsifiability: OW_SYNC_TEST_SEEKSTORM reproduces the ow-blz.5 behaviour (one seek per tick); the
#      corrective-seek budget and presented-fps assertions MUST fail on the 4K60 fixture with an audio track (slow seeks, as on the user's clip)
#   S  (ow-blz.8) soak (~80 s) on the user's REAL clip (copy of OW_SYNC_SOAK_CLIP, default
#      ~/Library/Application Support/OnlyWallpapers/web/assets/bg.mp4, never modified), as is. Same per-window assertions; the
#      pairwise bar is only a catastrophe bound because a clip with an audio track makes every seek slow and uneven (see wallpaper.js)
#   T  (ow-blz.8) the same real clip with the audio track stripped (stream copy): the full tight pairwise bar
# Phases P, S, T assert on VISIBLE windows only (a hidden page is throttled and paused by WebKit); the analyzer ignores hidden or
# paused samples and the 5 s after, and fails "windows-visible" if a display is covered. OW_SYNC_SINGLE_DISPLAY=1 runs them on
# two windows of the primary display instead (the fallback when another display has a maximized window on it).
# Run A also reloads one view after the swap (same path as a web content process restart): it must end on the latest rev, aligned.
# Hooks: OW_SYNC_TEST_IDLE=1 (join once, never correct: the ow-blz.8 baseline), OW_SYNC_TEST_SEEKSTORM=1, OW_SYNC_TEST=1, OW_SYNC_CMD_FILE (SIGUSR2 commands: desync, reload, swap, extra), OW_SYNC_TEST_BIAS_MS, OW_SYNC_TEST_PROBE_FAIL,
#        OW_SYNC_TEST_LIGHTNING_DELAY_MS, OW_REBUILD_TEST, OW_FAKE_SCREENS_FILE.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

for tool in ffmpeg ffprobe node python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: missing $tool"; exit 1; }
done

WORK="$(mktemp -d)"
# The display sleeping (or locking) hides every wallpaper window and the analysis can say nothing about hidden pages:
# keep the display awake for as long as this script runs (a no-op where caffeinate is missing).
if command -v caffeinate >/dev/null 2>&1; then caffeinate -d -i -w $$ >/dev/null 2>&1 & fi
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

# OW_SYNC_ONLY=B (debug aid): run only the named phases (any of 0 A B C D L X N R P F S T). Default: all.
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

# --- ow-blz.8 fixtures: the user's clip profile (cached) and the real clip ---
FIX_DIR="${TMPDIR:-/tmp}"
FIX_4K="${FIX_DIR%/}/ow-sync-fixture-4k60-v1.mp4"
# fixture_valid file want_audio(0|1): the file really has the user's clip profile (ffprobe): 3840x2160,
# 60 fps, keyframes every 1.0 s, 15 to 20 s, at least 25 Mbit/s, and an audio stream iff wanted.
fixture_valid() {
    [[ -f "$1" ]] || return 1
    { ffprobe -v error -show_entries stream=codec_type,width,height,r_frame_rate,bit_rate:format=duration,bit_rate -of json "$1"
      echo "@@KEYS"
      ffprobe -v error -select_streams v:0 -show_entries packet=pts_time,flags -of csv=p=0 "$1"; } 2>/dev/null | python3 -I -c '
import sys, json
raw = sys.stdin.read()
head, _, keys = raw.partition("@@KEYS")
try:
    j = json.loads(head)
    vs = [s for s in j["streams"] if s.get("codec_type") == "video"]
    au = [s for s in j["streams"] if s.get("codec_type") == "audio"]
    v = vs[0]
    n, d = v["r_frame_rate"].split("/")
    fps = float(n) / float(d)
    dur = float(j["format"]["duration"])
    br = float(j["format"]["bit_rate"])
    ks = sorted(float(l.split(",")[0]) for l in keys.splitlines() if l.strip() and "K" in l.split(",")[1])
    gaps = [b - a for a, b in zip(ks, ks[1:])]
    ok = (len(vs) == 1 and v["width"] == 3840 and v["height"] == 2160 and abs(fps - 60.0) < 0.01 and 15 <= dur <= 20 and
          br >= 25e6 and len(gaps) >= 10 and all(abs(g - 1.0) < 0.02 for g in gaps) and (len(au) >= 1) == (sys.argv[1] == "1"))
except Exception:
    ok = False
sys.exit(0 if ok else 1)' "$2"
}
make_profile_fixture() {
    if fixture_valid "$FIX_4K" 0; then return 0; fi
    rm -f "$FIX_4K"
    step "generating the 4K60 fixture (about a minute, cached in $FIX_4K)"
    local tmp="$FIX_4K.part.mp4"
    ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=3840x2160:rate=60,noise=alls=12:allf=t" -t 18 \
        -c:v libx264 -preset veryfast -pix_fmt yuv420p -b:v 40M -maxrate 45M -bufsize 80M -g 60 -keyint_min 60 -sc_threshold 0 \
        -an -movflags +faststart "$tmp" || return 1
    mv "$tmp" "$FIX_4K"
    fixture_valid "$FIX_4K" 0 || { echo "FAIL: generated 4K60 fixture does not match the user's clip profile"; return 1; }
}
# perf_env label: sets PERF_ENV (extra env for start_app) for the ow-blz.8 phases.
perf_env() {
    PERF_ENV=()
    if [[ "${OW_SYNC_SINGLE_DISPLAY:-0}" == "1" ]]; then
        # Two windows on the primary display, for a machine where another display is covered by a maximized window.
        printf '0,0,1280,720,1,101\n1280,0,1280,720,1,102\n' > "$WORK/fake-screens-$1.txt"
        PERF_ENV=(OW_FAKE_SCREENS_FILE="$WORK/fake-screens-$1.txt")
    fi
}

# run_perf_phase label clip dur seconds checks analyzer-extra...
run_perf_phase() {
    local label="$1" clip="$2" dur="$3" secs="$4" checks="$5"; shift 5
    WEB="$WORK/web-$label"; mkdir -p "$WEB/assets"
    cp Sources/OnlyWallpapers/web/index.html Sources/OnlyWallpapers/web/style.css Sources/OnlyWallpapers/web/wallpaper.js "$WEB/"
    cp "$clip" "$WEB/assets/bg.mp4"
    OUT="$WORK/run-$label.out"; MARKS="$WORK/marks-$label.jsonl"; : > "$MARKS"
    perf_env "$label"
    start_app "$OUT" ${PERF_ENV[@]+"${PERF_ENV[@]}"}
    wait_for "$OUT" "ONLYWALLPAPERS_READY" 20 || { echo "FAIL: app ($label) never became ready"; FAILS=$((FAILS + 1)); }
    sleep "$secs"
    mark end
    stop_app
    if python3 -I scripts/sync-check-analyze.py "$OUT" "$MARKS" --checks "$checks" --fps "$FPS_4K" --dur-a "$dur" --label "$label" --visible-only "$@" > "$WORK/analysis-$label.txt" 2>&1; then :; else FAILS=$((FAILS + 1)); fi
    cat "$WORK/analysis-$label.txt"
}

# --- (P) the user's clip profile, 4K60 with audio ---
FPS_4K=60
if want P; then
step "(P) 4K60 H.264 1 s GOP, video only: per-window health and pairwise offsets (about 85 s)"
make_profile_fixture || { echo "FAIL: ffmpeg 4K fixture"; FAILS=$((FAILS + 1)); }
if [[ -f "$FIX_4K" ]]; then
    run_perf_phase P "$FIX_4K" 18 82 "windows,steady,seams,perf"
fi
fi

# --- (F) falsifiability: the ow-blz.5 behaviour (a seek every tick) must fail the seek budget and the fps assertions ---
if want F; then
step "(F) falsifiability: seek-every-tick hook on the 4K60 fixture with audio (corrective-seek and presented-fps assertions MUST fail)"
make_profile_fixture || { echo "FAIL: ffmpeg 4K fixture"; FAILS=$((FAILS + 1)); }
if [[ -f "$FIX_4K" ]]; then
    WEB="$WORK/web-f"; mkdir -p "$WEB/assets"
    cp Sources/OnlyWallpapers/web/index.html Sources/OnlyWallpapers/web/style.css Sources/OnlyWallpapers/web/wallpaper.js "$WEB/"
    # With an audio track every seek is slow (the user's clip), which is what made the ow-blz.5 seek-per-tick loop glitchy.
    FIX_4K_A="${FIX_DIR%/}/ow-sync-fixture-4k60-audio-v1.mp4"
    if ! fixture_valid "$FIX_4K_A" 1; then
        rm -f "$FIX_4K_A"
        ffmpeg -y -loglevel error -i "$FIX_4K" -f lavfi -i "anoisesrc=d=18:c=pink:r=48000:a=0.001" -map 0:v -map 1:a -c:v copy -c:a aac -b:a 128k -shortest -movflags +faststart "$FIX_4K_A.part.mp4" && mv "$FIX_4K_A.part.mp4" "$FIX_4K_A"
        fixture_valid "$FIX_4K_A" 1 || { echo "FAIL: generated 4K60 audio fixture does not match the user's clip profile"; FAILS=$((FAILS + 1)); }
    fi
    cp "$FIX_4K_A" "$WEB/assets/bg.mp4"
    OUT="$WORK/run-f.out"; MARKS="$WORK/marks-f.jsonl"; : > "$MARKS"
    perf_env F
    start_app "$OUT" OW_SYNC_TEST_SEEKSTORM=1 ${PERF_ENV[@]+"${PERF_ENV[@]}"}
    wait_for "$OUT" "ONLYWALLPAPERS_READY" 20 || { echo "FAIL: app (F) never became ready"; FAILS=$((FAILS + 1)); }
    sleep 40
    mark end
    stop_app
    python3 -I scripts/sync-check-analyze.py "$OUT" "$MARKS" --checks "windows,perf" --fps 60 --dur-a 18 --label F --visible-only > "$WORK/analysis-f.txt" 2>&1
    grep 'SYNC_METRIC perf_w' "$WORK/analysis-f.txt"
    if grep -q 'SYNC_ASSERT FAIL perf-w[0-9]*-corrective-seeks' "$WORK/analysis-f.txt" && grep -q 'SYNC_ASSERT FAIL perf-w[0-9]*-presented-fps' "$WORK/analysis-f.txt"; then
        echo "SYNC_ASSERT pass falsifiability: a seek on every tick failed the corrective-seek budget and the presented-fps assertions, as required"
    else
        grep 'perf-w' "$WORK/analysis-f.txt"
        echo "SYNC_ASSERT FAIL falsifiability: a seek on every tick did NOT fail both the corrective-seek budget and the presented-fps assertions"; FAILS=$((FAILS + 1))
    fi
fi
fi

# --- (S, T) soak on the user's real clip (copy), as is and with the audio track stripped ---
SOAK_CLIP="${OW_SYNC_SOAK_CLIP:-$HOME/Library/Application Support/OnlyWallpapers/web/assets/bg.mp4}"
if want S || want T; then
    if [[ -f "$SOAK_CLIP" ]]; then
        SOAK_COPY="$WORK/soak-real.mp4"
        cp "$SOAK_CLIP" "$SOAK_COPY"
        SOAK_DUR="$(probe "$SOAK_COPY")"
        FPS_4K="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$SOAK_COPY" | python3 -I -c 'import sys; n,d=sys.stdin.read().strip().split("/"); print(float(n)/float(d))')"
        if want S; then
            step "(S) soak on the real clip as is (${SOAK_DUR}s, ${FPS_4K} fps, about 85 s)"
            # Slow uneven seeks (audio track, every seek costs 150 to 450 ms +-90): the no-storm assertions are unchanged; the offset bars
            # are only a catastrophe bound (the numbers are the report) because no WebKit control reaches better, see wallpaper.js.
            run_perf_phase S "$SOAK_COPY" "$SOAK_DUR" 82 "windows,steady,perf" --pair-p95-ms 1000 --pair-max-ms 2000 --perf-allow-seek-timeouts --perf-abs-p95-ms 500 --perf-seam-ms 800
        fi
        if want T; then
            step "(T) soak on the real clip with the audio track stripped (about 85 s)"
            SOAK_NA="$WORK/soak-real-noaudio.mp4"
            ffmpeg -y -loglevel error -i "$SOAK_COPY" -an -c:v copy -movflags +faststart "$SOAK_NA" || { echo "FAIL: ffmpeg strip audio"; FAILS=$((FAILS + 1)); }
            [[ -f "$SOAK_NA" ]] && run_perf_phase T "$SOAK_NA" "$(probe "$SOAK_NA")" 82 "windows,steady,seams,perf"
        fi
    else
        echo "SYNC_ASSERT FAIL soak-clip-missing: $SOAK_CLIP (set OW_SYNC_SOAK_CLIP)"; FAILS=$((FAILS + 1))
    fi
fi

echo
# Runs B, L, X and N fail their assertions by design, so only A, C, D and R feed the verdict.
VERDICT_FILES=("$WORK/analysis-a.txt" "$WORK/analysis-c.txt" "$WORK/analysis-d.txt" "$WORK/analysis-r.txt" "$WORK/analysis-P.txt" "$WORK/analysis-S.txt" "$WORK/analysis-T.txt")
PASSES="$(cat "${VERDICT_FILES[@]}" "$WORK/pure.out" 2>/dev/null | grep -c 'SYNC_ASSERT pass\|LIGHTNING_PURE pass' || true)"
if [[ "$FAILS" -eq 0 ]] && ! grep -h 'SYNC_ASSERT FAIL' "${VERDICT_FILES[@]}" >/dev/null 2>&1; then
    echo "sync-check PASS: $PASSES assertions passed (A + C + D + R + P + S + T + pure-function), falsifiability runs B, L, X, N and F confirmed"
    exit 0
fi
echo "sync-check FAIL: $(cat "${VERDICT_FILES[@]}" | grep -c 'SYNC_ASSERT FAIL') analysis assertion(s) failed, $FAILS gate failure(s), $PASSES passed"
exit 1
