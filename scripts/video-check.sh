#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CLIP_DURATION=6  # matches generate-test-bg.sh -t 6

PID=""
TMPOUT=""
SIGINT_CLEAN=0

cleanup() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -INT "$PID" 2>/dev/null || true
        sleep 0.4
        if kill -0 "$PID" 2>/dev/null; then
            kill -KILL "$PID" 2>/dev/null || true
        fi
        wait "$PID" 2>/dev/null || true
    fi
    [[ -n "$TMPOUT" ]] && rm -f "$TMPOUT" || true
}
trap cleanup EXIT

sigint_handler() {
    SIGINT_CLEAN=1
    exit 0
}
trap sigint_handler INT

echo "=== VIDEO-CHECK ==="

# Step 1: dependency check
for cmd in ffmpeg ffprobe screencapture; do
    if ! command -v "$cmd" &>/dev/null; then
        case "$cmd" in
            ffmpeg) echo "MISSING: ffmpeg. Install with: brew install ffmpeg" ;;
            ffprobe) echo "MISSING: ffprobe. Install with: brew install ffmpeg" ;;
            screencapture) echo "MISSING: screencapture (should be built in on macOS)" ;;
        esac
        exit 1
    fi
done

# Step 2: generate test clip
echo "[asset] Running generate-test-bg.sh..."
bash "$REPO_ROOT/scripts/generate-test-bg.sh"

CLIP_PATH="Sources/OnlyWallpapers/web/assets/bg.mp4"
if [[ ! -f "$CLIP_PATH" ]]; then
    echo "FAIL: expected clip not found at $CLIP_PATH"
    exit 1
fi
CLIP_ACTUAL="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$CLIP_PATH")"
echo "[asset] Clip actual duration: ${CLIP_ACTUAL}s"

# Step 3: build
echo "[build] Building with warnings-as-errors..."
swift build --product OnlyWallpapers -Xswiftc -warnings-as-errors 2>&1
BIN="$(swift build --product OnlyWallpapers --show-bin-path)/OnlyWallpapers"
echo "[build] Binary: $BIN"

# Step 4: launch
TMPOUT="$(mktemp)"
echo "[launch] Starting $BIN..."
env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE "$BIN" >"$TMPOUT" 2>&1 &
PID=$!
echo "[launch] PID=$PID"

# Step 5a: wait up to 8s for ONLYWALLPAPERS_WINDOWS count
echo "[wait] Polling for ONLYWALLPAPERS_WINDOWS count (up to 8s)..."
WIN_LINE=""
for i in $(seq 1 80); do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "FAIL: process exited before emitting windows count"
        cat "$TMPOUT" || true
        exit 1
    fi
    WIN_LINE="$(grep 'ONLYWALLPAPERS_WINDOWS count=' "$TMPOUT" 2>/dev/null | head -1 || true)"
    if [[ -n "$WIN_LINE" ]]; then
        WIN_COUNT="$(echo "$WIN_LINE" | sed 's/.*count=\([0-9]*\).*/\1/')"
        echo "[wait] Windows: $WIN_COUNT"
        break
    fi
    sleep 0.1
done

if [[ -z "$WIN_LINE" ]]; then
    echo "FAIL: ONLYWALLPAPERS_WINDOWS count line never appeared within 8s"
    cat "$TMPOUT" || true
    exit 1
fi

if [[ "$WIN_COUNT" -eq 0 ]]; then
    echo "FAIL: WIN_COUNT=0, no windows to test"
    cat "$TMPOUT" || true
    exit 1
fi

# Step 5b: wait up to 8s for loaded=ok lines; record wall-clock time of last ok
echo "[wait] Polling for $WIN_COUNT loaded=ok lines (up to 8s)..."
LOADED_OK_TIME=0
for i in $(seq 1 80); do
    OK_COUNT="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=ok' "$TMPOUT" 2>/dev/null || true)"
    if [[ "$OK_COUNT" -ge "$WIN_COUNT" ]]; then
        LOADED_OK_TIME=$(date +%s)
        echo "[wait] Got $OK_COUNT loaded=ok lines at $(date +%T)"
        break
    fi
    sleep 0.1
done

OK_COUNT="$(grep -c 'ONLYWALLPAPERS_WEB.*loaded=ok' "$TMPOUT" 2>/dev/null || true)"
if [[ "$OK_COUNT" -lt "$WIN_COUNT" ]]; then
    echo "FAIL: expected $WIN_COUNT loaded=ok lines, got $OK_COUNT within 8s"
    cat "$TMPOUT" || true
    exit 1
fi

# Parse win= values from loaded=ok lines (indexed arrays for bash 3.2 compat)
ALL_WINS=()
while IFS= read -r w; do
    ALL_WINS+=("$w")
done < <(grep 'ONLYWALLPAPERS_WEB.*loaded=ok' "$TMPOUT" 2>/dev/null | grep -oE 'win=[0-9]+' | sort -u | cut -d= -f2)

echo "[wait] Distinct windows: ${ALL_WINS[*]:-none}"
if [[ ${#ALL_WINS[@]} -eq 0 ]]; then
    echo "FAIL: no win= values parsed from loaded=ok lines"
    exit 1
fi
DISTINCT_WIN_COUNT="${#ALL_WINS[@]}"
if [[ "$DISTINCT_WIN_COUNT" -ne "$WIN_COUNT" ]]; then
    echo "HARD FAIL: distinct win= IDs from loaded=ok ($DISTINCT_WIN_COUNT) does not equal ONLYWALLPAPERS_WINDOWS count ($WIN_COUNT). A window is missing or a duplicate loaded=ok masked it."
    cat "$TMPOUT" || true
    exit 1
fi
echo "[wait] Distinct win count $DISTINCT_WIN_COUNT matches WIN_COUNT $WIN_COUNT (coverage verified)"

# Step 6: HARD GATE A - early media=playing (from +1.0s/+2.5s samples)
# These prove autostart. The late (+7.5s) sample has not fired yet.
echo "[gate-a] Polling for early media=playing per window (up to 4s)..."
WIN_GATE_A_OK=()
for win in "${ALL_WINS[@]}"; do
    WIN_GATE_A_OK+=("0")
done

for i in $(seq 1 40); do
    ALL_EARLY_PLAYING=1
    for idx in $(seq 0 $(( ${#ALL_WINS[@]} - 1 ))); do
        win="${ALL_WINS[$idx]}"
        if [[ "${WIN_GATE_A_OK[$idx]}" -eq 0 ]]; then
            if grep -E "ONLYWALLPAPERS_WEB.*win=${win}[^0-9].*media=playing" "$TMPOUT" 2>/dev/null | \
               awk -F't=' 'NF>1 { split($2,a," "); if (a[1]+0 <= 2.5) f=1 } END { exit !f }'; then
                WIN_GATE_A_OK[$idx]="1"
                echo "[gate-a] win=$win early media=playing confirmed"
            else
                ALL_EARLY_PLAYING=0
            fi
        fi
    done
    if [[ $ALL_EARLY_PLAYING -eq 1 ]]; then
        break
    fi
    sleep 0.1
done

GATE_A_FAIL=0
for idx in $(seq 0 $(( ${#ALL_WINS[@]} - 1 ))); do
    win="${ALL_WINS[$idx]}"
    if [[ "${WIN_GATE_A_OK[$idx]}" -ne 1 ]]; then
        echo "HARD FAIL (GATE A): win=$win never reached media=playing in early window (+1.0/+2.5s)"
        GATE_A_FAIL=1
    fi
done

if [[ $GATE_A_FAIL -ne 0 ]]; then
    echo "--- output ---"
    cat "$TMPOUT" || true
    exit 1
fi

# Step 7: HARD GATE B - late media=playing (from +7.5s sample, proving loop)
# A non-looping clip is paused/ended/none at t=7.5s. A looping clip stays playing.
# First verify the late sample (7.5s) is strictly past the actual clip duration so
# a playing result at t=7.5 proves the clip looped. Then wait for the sample to fire.
IS_PAST=$(awk "BEGIN { print (7.5 > $CLIP_ACTUAL + 0) ? 1 : 0 }")
if [[ "$IS_PAST" -ne 1 ]]; then
    echo "HARD FAIL: late media sample 7.5s is not past the clip duration ${CLIP_ACTUAL}s; cannot prove looping. Shorten the clip or increase the late sample time."
    exit 1
fi
echo "[gate-b] Self-consistency check: 7.5s > ${CLIP_ACTUAL}s (late sample is past clip end, loop proof is valid)"

LATE_READY=$(( LOADED_OK_TIME + CLIP_DURATION + 3 ))
NOW=$(date +%s)
LATE_SLEEP=$(( LATE_READY - NOW ))
if [[ $LATE_SLEEP -gt 0 ]]; then
    echo "[gate-b] Waiting ${LATE_SLEEP}s for late media sample (+7.5s after loaded)..."
    sleep "$LATE_SLEEP"
else
    echo "[gate-b] Late sample window already elapsed, checking now..."
fi

echo "[gate-b] Checking late media=playing per window..."
WIN_GATE_B_OK=()
GATE_B_FAIL=0
for idx in $(seq 0 $(( ${#ALL_WINS[@]} - 1 ))); do
    win="${ALL_WINS[$idx]}"
    if grep -E "ONLYWALLPAPERS_WEB.*win=${win}[^0-9].*media=playing" "$TMPOUT" 2>/dev/null | \
       awk -v clip="$CLIP_ACTUAL" -F't=' 'NF>1 { split($2,a," "); if (a[1]+0 > clip+0) f=1 } END { exit !f }'; then
        WIN_GATE_B_OK+=("1")
        echo "[gate-b] win=$win late sample playing (t > ${CLIP_ACTUAL}s confirmed, loop proven)"
    else
        WIN_GATE_B_OK+=("0")
        echo "HARD FAIL (GATE B): win=$win late sample not playing (no media=playing with t > ${CLIP_ACTUAL}s)"
        GATE_B_FAIL=1
    fi
done

if [[ $GATE_B_FAIL -ne 0 ]]; then
    echo "--- output ---"
    cat "$TMPOUT" || true
    exit 1
fi

# Step 8: pixel corroboration (non-gating)
# Saves PNGs for human inspection and prints differ/identical. Does NOT gate the
# verdict. When screencapture fails (TCC denied), sets PIXEL_TCC_FAIL and prints a
# NOTE at the end; it does NOT exit or fail the script. The native media=playing
# gates (GATE A early, GATE B late) are the authoritative acceptance oracle. The
# -l pixel band diffs are non-gating corroboration because -l of an
# occlusion-culled window returns a stale backing store, making identical bands
# unactionable as a failure signal.

band_diff() {
    local img1="$1" img2="$2"
    for img in "$img1" "$img2"; do
        if [[ ! -f "$img" ]] || [[ ! -s "$img" ]]; then
            echo "[band_diff] missing or empty: $img"
            return 2
        fi
    done
    local w h
    w="$(sips -g pixelWidth "$img1" 2>/dev/null | awk '/pixelWidth/{print $2}')"
    h="$(sips -g pixelHeight "$img1" 2>/dev/null | awk '/pixelHeight/{print $2}')"
    if [[ -z "$w" ]] || [[ -z "$h" ]] || [[ "$w" -le 0 ]] || [[ "$h" -le 0 ]]; then
        echo "[band_diff] sips could not read dimensions from $img1"
        return 2
    fi
    local band_y band_h
    band_y=$(( h * 3 / 10 ))
    band_h=$(( h * 2 / 5 ))
    if [[ $band_h -lt 10 ]]; then band_y=0; band_h=$h; fi
    local crop1="${img1%.png}_band.png" crop2="${img2%.png}_band.png"
    if ! sips -c "$band_h" "$w" --cropOffset "$band_y" 0 "$img1" --out "$crop1" >/dev/null 2>&1; then
        echo "[band_diff] sips crop failed on $img1"; return 2
    fi
    if ! sips -c "$band_h" "$w" --cropOffset "$band_y" 0 "$img2" --out "$crop2" >/dev/null 2>&1; then
        echo "[band_diff] sips crop failed on $img2"; return 2
    fi
    for crop in "$crop1" "$crop2"; do
        if [[ ! -f "$crop" ]] || [[ ! -s "$crop" ]]; then
            echo "[band_diff] crop missing or empty: $crop"; return 2
        fi
    done
    if cmp -s "$crop1" "$crop2"; then return 1; fi
    return 0
}

echo "[pixel] Starting pixel corroboration (non-gating, PNGs saved for inspection)..."

WIN_AB_RESULT=()
WIN_CD_RESULT=()
PIXEL_TCC_FAIL=0

for win in "${ALL_WINS[@]}"; do
    WIN_AB_RESULT+=("unknown")
    WIN_CD_RESULT+=("unknown")
done

for idx in $(seq 0 $(( ${#ALL_WINS[@]} - 1 ))); do
    win="${ALL_WINS[$idx]}"

    IMG_A="/tmp/ow-vc-a-${win}-$$.png"
    IMG_B="/tmp/ow-vc-b-${win}-$$.png"
    IMG_C="/tmp/ow-vc-c-${win}-$$.png"
    IMG_D="/tmp/ow-vc-d-${win}-$$.png"

    echo "[pixel] win=$win: capturing A..."
    if ! screencapture -l "$win" "$IMG_A" 2>/dev/null; then
        echo "INCONCLUSIVE (pixel): screencapture -l $win failed (TCC denied)"
        WIN_AB_RESULT[$idx]="screencap-fail"
        WIN_CD_RESULT[$idx]="screencap-fail"
        PIXEL_TCC_FAIL=1
        continue
    fi

    sleep 0.6

    echo "[pixel] win=$win: capturing B..."
    if ! screencapture -l "$win" "$IMG_B" 2>/dev/null; then
        echo "INCONCLUSIVE (pixel): screencapture -l $win failed for B (TCC denied)"
        WIN_AB_RESULT[$idx]="screencap-fail"
        WIN_CD_RESULT[$idx]="screencap-fail"
        PIXEL_TCC_FAIL=1
        continue
    fi

    bd_ab=0
    band_diff "$IMG_A" "$IMG_B" || bd_ab=$?
    if [[ $bd_ab -eq 0 ]]; then
        WIN_AB_RESULT[$idx]="differ"
        echo "[pixel] win=$win: A/B differ (animation corroborated)"
    elif [[ $bd_ab -eq 1 ]]; then
        WIN_AB_RESULT[$idx]="identical"
        echo "[pixel] win=$win: A/B identical (possible occlusion-culling stale frame; non-gating)"
    else
        WIN_AB_RESULT[$idx]="sips-error"
        echo "[pixel] win=$win: A/B band_diff error (non-gating)"
    fi

    # C/D: corroborate looping. We are already CLIP_DURATION+3s past loaded_ok (GATE B
    # wait), so we are past one clip cycle. Capture two frames 0.7s apart; a frozen
    # non-looping clip would be identical, a looping clip keeps advancing.
    echo "[pixel] win=$win: capturing C (loop corroboration)..."
    if ! screencapture -l "$win" "$IMG_C" 2>/dev/null; then
        echo "INCONCLUSIVE (pixel): screencapture -l $win failed for C (TCC denied)"
        WIN_CD_RESULT[$idx]="screencap-fail"
        PIXEL_TCC_FAIL=1
        continue
    fi

    sleep 0.7

    echo "[pixel] win=$win: capturing D..."
    if ! screencapture -l "$win" "$IMG_D" 2>/dev/null; then
        echo "INCONCLUSIVE (pixel): screencapture -l $win failed for D (TCC denied)"
        WIN_CD_RESULT[$idx]="screencap-fail"
        PIXEL_TCC_FAIL=1
        continue
    fi

    bd_cd=0
    band_diff "$IMG_C" "$IMG_D" || bd_cd=$?
    if [[ $bd_cd -eq 0 ]]; then
        WIN_CD_RESULT[$idx]="differ"
        echo "[pixel] win=$win: C/D differ (loop corroborated)"
    elif [[ $bd_cd -eq 1 ]]; then
        WIN_CD_RESULT[$idx]="identical"
        echo "[pixel] win=$win: C/D identical (possible occlusion-culling stale frame; non-gating)"
    else
        WIN_CD_RESULT[$idx]="sips-error"
        echo "[pixel] win=$win: C/D band_diff error (non-gating)"
    fi

    echo "[pixel] win=$win: screenshots saved: $IMG_A $IMG_B $IMG_C $IMG_D"
done

if [[ $PIXEL_TCC_FAIL -ne 0 ]]; then
    echo "[pixel] NOTE: TCC denied screencapture for one or more windows (pixel corroboration skipped; native gates are authoritative)"
fi

# Step 9: verdict
# PASS iff every win passed HARD GATE A (early media=playing) and
# HARD GATE B (late media=playing, proving loop). Pixel results are corroboration only.
echo ""
echo "=== VIDEO-CHECK VERDICT ==="
OVERALL_PASS=1
for idx in $(seq 0 $(( ${#ALL_WINS[@]} - 1 ))); do
    win="${ALL_WINS[$idx]}"
    GA="$([ "${WIN_GATE_A_OK[$idx]}" -eq 1 ] && echo playing || echo FAIL)"
    GB="$([ "${WIN_GATE_B_OK[$idx]}" -eq 1 ] && echo playing || echo FAIL)"
    AB="${WIN_AB_RESULT[$idx]}"
    CD="${WIN_CD_RESULT[$idx]}"
    printf "win=%-6s  gate-a(early)=%-10s  gate-b(late)=%-10s  pixel-anim=%-12s  pixel-loop=%s\n" \
        "$win" "$GA" "$GB" "$AB" "$CD"
    if [[ "${WIN_GATE_A_OK[$idx]}" -ne 1 ]] || [[ "${WIN_GATE_B_OK[$idx]}" -ne 1 ]]; then
        OVERALL_PASS=0
    fi
done

echo ""
if [[ $OVERALL_PASS -eq 1 ]]; then
    echo "VIDEO-CHECK: PASS (native media early+late confirmed; pixel corroboration printed above)"
    exit 0
else
    echo "VIDEO-CHECK: FAIL"
    exit 1
fi
