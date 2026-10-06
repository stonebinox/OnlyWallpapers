#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CLIP_DURATION=6  # matches generate-test-bg.sh -t 6

PID=""
TMPOUT=""
SIGINT_CLEAN=0

OW_SUPPORT_TMP=""
CLIP_B=""
COPYHOOK_PID=""
COPYHOOK_TMP=""
COPYHOOK_OUT=""
COPY_SRC_FILE=""
SOURCE_BG="Sources/OnlyWallpapers/web/assets/bg.mp4"
SOURCE_BG_BACKUP=""
SOURCE_BG_PRESENT_ON_ENTRY=0
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
    [[ -n "$OW_SUPPORT_TMP" ]] && rm -rf "$OW_SUPPORT_TMP" || true
    # Restore original source bg.mp4.
    if [[ -n "$SOURCE_BG_BACKUP" ]] && [[ -f "$SOURCE_BG_BACKUP" ]]; then
        # Verified backup exists: restore then remove backup.
        cp "$SOURCE_BG_BACKUP" "$SOURCE_BG"
        rm -f "$SOURCE_BG_BACKUP" 2>/dev/null || true
    elif [[ "$SOURCE_BG_PRESENT_ON_ENTRY" -eq 1 ]]; then
        # Original was present on entry but backup file is missing (backup intended but failed).
        # Do NOT delete or overwrite the original.
        echo "[asset] WARNING: backup file for $SOURCE_BG is missing; leaving original untouched" >&2
    else
        # File was absent on entry; delete any test-generated clip.
        rm -f "$SOURCE_BG" 2>/dev/null || true
        # Clobber-check assertion: SOURCE_BG must be absent after this path.
        if [[ -f "$SOURCE_BG" ]]; then
            echo "[clobber-check] FAIL: $SOURCE_BG persists after no-backup-entry cleanup (user tree clobbered)" >&2
        fi
    fi
    [[ -n "$CLIP_B" ]] && rm -f "$CLIP_B" 2>/dev/null || true
    [[ -n "$COPY_SRC_FILE" ]] && rm -f "$COPY_SRC_FILE" 2>/dev/null || true
    if [[ -n "$COPYHOOK_PID" ]] && kill -0 "$COPYHOOK_PID" 2>/dev/null; then
        kill -INT "$COPYHOOK_PID" 2>/dev/null || true
        sleep 0.4
        if kill -0 "$COPYHOOK_PID" 2>/dev/null; then
            kill -KILL "$COPYHOOK_PID" 2>/dev/null || true
        fi
        wait "$COPYHOOK_PID" 2>/dev/null || true
    fi
    [[ -n "$COPYHOOK_OUT" ]] && rm -f "$COPYHOOK_OUT" || true
    [[ -n "$COPYHOOK_TMP" ]] && rm -rf "$COPYHOOK_TMP" || true
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

# Step 2: generate test clip (back up source-tree bg.mp4 first so it is restored on exit)
if [[ -f "$SOURCE_BG" ]]; then
    SOURCE_BG_PRESENT_ON_ENTRY=1
    _bak="${SOURCE_BG}.video-check-bak-$$"
    if cp "$SOURCE_BG" "$_bak" 2>/dev/null && [[ -f "$_bak" ]] && [[ -s "$_bak" ]]; then
        SOURCE_BG_BACKUP="$_bak"
        echo "[asset] Backed up $SOURCE_BG -> $SOURCE_BG_BACKUP"
    else
        rm -f "$_bak" 2>/dev/null || true
        echo "[asset] FAIL: backup of $SOURCE_BG failed; aborting to protect user content" >&2
        exit 1
    fi
fi
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
OW_SUPPORT_TMP="$(mktemp -d)"
OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" env -u WALLPAPER_WEB_DIR -u OW_SPIKE -u OW_WEBSPIKE OW_VIDEO_TEST=1 "$BIN" >"$TMPOUT" 2>&1 &
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

# Step 9: MEDIA-SWITCH gate (FIX 6: proves clip B replaced clip A, not a no-op reload)
# Asserts (a) ONLYWALLPAPERS_VIDEO applied with new durationMs confirming clip B on EVERY view,
# AND (b) ONLYWALLPAPERS_VIDEO media state=playing 1s after the reload.
echo "[media-switch] Starting media-switch gate..."

CLIP_B="/tmp/ow-vc-clip-b-$$.mp4"
CLIP_B_DURATION=3

# Generate a distinct clip B (blue, shorter duration to distinguish from clip A)
ffmpeg -y -f lavfi -i "color=c=blue:size=320x240:rate=30" -t "$CLIP_B_DURATION" \
    -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$CLIP_B" >/dev/null 2>&1

ASSETS_DIR="$OW_SUPPORT_TMP/web/assets"

if [[ ! -d "$ASSETS_DIR" ]]; then
    echo "HARD FAIL (media-switch): assets dir '$ASSETS_DIR' not present; cannot exercise the reload path. The gate must not pass without actually running the media-switch."
    cat "$TMPOUT" || true
    exit 1
fi

SLOT="$ASSETS_DIR/bg.mp4"
PARTIAL="$ASSETS_DIR/bg.mp4.partial"
cp "$CLIP_B" "$PARTIAL"
mv -f "$PARTIAL" "$SLOT"

BEFORE_RELOAD_COUNT="$(grep -c 'ONLYWALLPAPERS_VIDEO reload' "$TMPOUT" 2>/dev/null || true)"
kill -USR2 "$PID" 2>/dev/null || true

# Wait for new ONLYWALLPAPERS_VIDEO reload line and capture rev token
RELOAD_SAW=0
REV_TOKEN=""
RELOAD_LINE=""
for i in $(seq 1 30); do
    AFTER_RELOAD_COUNT="$(grep -c 'ONLYWALLPAPERS_VIDEO reload' "$TMPOUT" 2>/dev/null || true)"
    if [[ "$AFTER_RELOAD_COUNT" -gt "$BEFORE_RELOAD_COUNT" ]]; then
        RELOAD_SAW=1
        RELOAD_LINE="$(grep 'ONLYWALLPAPERS_VIDEO reload' "$TMPOUT" | tail -1)"
        REV_TOKEN="$(echo "$RELOAD_LINE" | grep -oE 'rev=[0-9]+' | head -1 | sed 's/rev=//')"
        echo "[media-switch] reload confirmed: $RELOAD_LINE (rev=$REV_TOKEN)"
        break
    fi
    sleep 0.1
done

if [[ $RELOAD_SAW -ne 1 ]]; then
    echo "HARD FAIL (media-switch): ONLYWALLPAPERS_VIDEO reload not seen within 3s after SIGUSR2"
    cat "$TMPOUT" || true
    exit 1
fi

if [[ -z "$REV_TOKEN" ]]; then
    echo "HARD FAIL (media-switch): could not parse rev= from reload line: $RELOAD_LINE"
    cat "$TMPOUT" || true
    exit 1
fi

# Wait for applied lines from ALL views (WIN_COUNT) for this rev token.
# A swap that updated only one of N screens must FAIL.
CH_DUR_EXPECTED=$(( CLIP_B_DURATION * 1000 ))
CH_DUR_LOW=$(( CH_DUR_EXPECTED - 500 ))
CH_DUR_HIGH=$(( CH_DUR_EXPECTED + 500 ))

MS_APPLIED_LINES=()
for i in $(seq 1 80); do
    MS_APPLIED_LINES=()
    while IFS= read -r _ms_l; do [[ -z "$_ms_l" ]] && continue; MS_APPLIED_LINES+=("$_ms_l"); done \
        < <(grep -E "ONLYWALLPAPERS_VIDEO applied.*rev=${REV_TOKEN}( |$)" "$TMPOUT" 2>/dev/null || true)
    if [[ "${#MS_APPLIED_LINES[@]}" -ge "$WIN_COUNT" ]]; then break; fi
    sleep 0.1
done

if [[ "${#MS_APPLIED_LINES[@]}" -lt "$WIN_COUNT" ]]; then
    echo "HARD FAIL (media-switch): expected $WIN_COUNT applied rev=${REV_TOKEN} lines (one per view), got ${#MS_APPLIED_LINES[@]}"
    cat "$TMPOUT" || true
    exit 1
fi

MS_DISTINCT_WINS="$(printf '%s\n' "${MS_APPLIED_LINES[@]}" | grep -o 'win=[0-9]*' | sort -u | wc -l | tr -d ' ')"
if [[ "$MS_DISTINCT_WINS" -lt "$WIN_COUNT" ]]; then
    echo "HARD FAIL (media-switch): $MS_DISTINCT_WINS distinct win= values in applied lines, expected $WIN_COUNT"
    cat "$TMPOUT" || true
    exit 1
fi

MS_DUR_FAIL=0
for _ms_line in "${MS_APPLIED_LINES[@]}"; do
    _ms_win="$(echo "$_ms_line" | grep -oE 'win=[0-9]+' | head -1)"
    _ms_dur="$(echo "$_ms_line" | grep -oE 'durationMs=[0-9]+' | head -1 | sed 's/durationMs=//' || true)"
    if [[ -z "$_ms_dur" ]]; then
        echo "HARD FAIL (media-switch): no durationMs in applied line: $_ms_line"
        MS_DUR_FAIL=1
        continue
    fi
    if [[ "$_ms_dur" -lt "$CH_DUR_LOW" ]] || [[ "$_ms_dur" -gt "$CH_DUR_HIGH" ]]; then
        echo "HARD FAIL (media-switch): $_ms_win durationMs=$_ms_dur not in [${CH_DUR_LOW},${CH_DUR_HIGH}] for ${CLIP_B_DURATION}s clip B"
        MS_DUR_FAIL=1
    fi
done
if [[ $MS_DUR_FAIL -ne 0 ]]; then
    cat "$TMPOUT" || true
    exit 1
fi
echo "[media-switch] PASS (a): durationMs on all $WIN_COUNT view(s) confirms clip B (not a no-op reload)"

# (b) Wait for ONLYWALLPAPERS_VIDEO media state=playing on EVERY window for this rev.
# One paused window while another plays must HARD FAIL.
MS_PLAY_WIN_OK=()
for _mspw in "${ALL_WINS[@]}"; do MS_PLAY_WIN_OK+=("0"); done

for i in $(seq 1 20); do
    _ms_all_play=1
    for _mspi in $(seq 0 $(( ${#ALL_WINS[@]} - 1 ))); do
        _mspw="${ALL_WINS[$_mspi]}"
        if [[ "${MS_PLAY_WIN_OK[$_mspi]}" -eq 0 ]]; then
            if grep -qE "ONLYWALLPAPERS_VIDEO media win=${_mspw}[^0-9].*rev=${REV_TOKEN}.*state=playing" "$TMPOUT" 2>/dev/null; then
                MS_PLAY_WIN_OK[$_mspi]="1"
                echo "[media-switch] win=${_mspw} state=playing confirmed for rev=${REV_TOKEN}"
            else
                _ms_all_play=0
            fi
        fi
    done
    if [[ $_ms_all_play -eq 1 ]]; then break; fi
    sleep 0.3
done

MS_PLAY_FAIL=0
for _mspi in $(seq 0 $(( ${#ALL_WINS[@]} - 1 ))); do
    _mspw="${ALL_WINS[$_mspi]}"
    if [[ "${MS_PLAY_WIN_OK[$_mspi]}" -ne 1 ]]; then
        echo "HARD FAIL (media-switch): win=${_mspw} no state=playing for rev=${REV_TOKEN} within 6s"
        MS_PLAY_FAIL=1
    fi
done
if [[ $MS_PLAY_FAIL -ne 0 ]]; then
    cat "$TMPOUT" || true
    exit 1
fi
echo "[media-switch] PASS (b): state=playing confirmed on all $WIN_COUNT window(s) for rev=${REV_TOKEN}"

# Step 10 (copy-hook): Exercise the first-video-no-slot and replace branches
# of copyVideoFile via the OW_VIDEO_TEST_SRC_FILE hook. Uses a separate process
# so we can control OW_VIDEO_TEST_SRC_FILE at signal time.
echo "[copy-hook] Starting copy-hook gate (first-install + replace)..."

COPYHOOK_TMP="$(mktemp -d)"
COPYHOOK_OUT="$(mktemp)"
COPY_SRC_FILE="$(mktemp)"

CLIP_A_ABS="$REPO_ROOT/Sources/OnlyWallpapers/web/assets/bg.mp4"
CLIP_A_DUR_MS=$(( 6 * 1000 ))
CLIP_B_DUR_MS=$(( CLIP_B_DURATION * 1000 ))

OW_APP_SUPPORT_DIR="$COPYHOOK_TMP" env -u WALLPAPER_WEB_DIR OW_VIDEO_TEST=1 \
    OW_VIDEO_TEST_SRC_FILE="$COPY_SRC_FILE" \
    "$BIN" >"$COPYHOOK_OUT" 2>&1 &
COPYHOOK_PID=$!
echo "[copy-hook] PID=$COPYHOOK_PID"

# Wait for loaded=ok
CH_LOADED=0
for i in $(seq 1 80); do
    if ! kill -0 "$COPYHOOK_PID" 2>/dev/null; then
        echo "HARD FAIL (copy-hook): process exited before loaded=ok"
        cat "$COPYHOOK_OUT" || true
        exit 1
    fi
    if grep -q 'ONLYWALLPAPERS_WEB.*loaded=ok' "$COPYHOOK_OUT" 2>/dev/null; then
        CH_LOADED=1
        break
    fi
    sleep 0.1
done
if [[ $CH_LOADED -ne 1 ]]; then
    echo "HARD FAIL (copy-hook): loaded=ok never appeared"
    cat "$COPYHOOK_OUT" || true
    exit 1
fi

# Wait for initial media=playing (proves app is running normally)
CH_INIT_PLAY=0
for i in $(seq 1 40); do
    if grep -qE 'ONLYWALLPAPERS_WEB.*media=playing' "$COPYHOOK_OUT" 2>/dev/null; then
        CH_INIT_PLAY=1
        break
    fi
    sleep 0.1
done
# Non-fatal: initial play check only confirms the app is alive; copy-hook is the real gate.
if [[ $CH_INIT_PLAY -eq 1 ]]; then
    echo "[copy-hook] initial media=playing confirmed"
else
    echo "[copy-hook] initial media=playing not yet seen (continuing)"
fi

# Derive the actual window set from the copy-hook process output.
CH_ALL_WINS=()
while IFS= read -r _chw; do
    CH_ALL_WINS+=("$_chw")
done < <(grep 'ONLYWALLPAPERS_WEB.*loaded=ok' "$COPYHOOK_OUT" 2>/dev/null | grep -oE 'win=[0-9]+' | sort -u | cut -d= -f2)
CH_WIN_COUNT="${#CH_ALL_WINS[@]}"
if [[ "$CH_WIN_COUNT" -eq 0 ]]; then
    echo "HARD FAIL (copy-hook): no win= values parsed from loaded=ok lines"
    cat "$COPYHOOK_OUT" || true
    exit 1
fi
echo "[copy-hook] Actual windows: ${CH_ALL_WINS[*]} (count=$CH_WIN_COUNT)"

# --- First-install branch: delete the seeded slot, then SIGUSR2 to copy clip A ---
CH_ASSETS_DIR="$COPYHOOK_TMP/web/assets"
rm -f "$CH_ASSETS_DIR/bg.mp4" 2>/dev/null || true
echo "[copy-hook] slot deleted, testing first-install branch..."

# Write clip A path to the src file
printf '%s' "$CLIP_A_ABS" > "$COPY_SRC_FILE"

CH_BEFORE_SLOT_A="$(grep -c 'ONLYWALLPAPERS_VIDEO slot=ok' "$COPYHOOK_OUT" 2>/dev/null || true)"
kill -USR2 "$COPYHOOK_PID"

# Wait for slot=ok
CH_SLOT_A_SEEN=0
for i in $(seq 1 60); do
    CH_AFTER_SLOT="$(grep -c 'ONLYWALLPAPERS_VIDEO slot=ok' "$COPYHOOK_OUT" 2>/dev/null || true)"
    if [[ "$CH_AFTER_SLOT" -gt "$CH_BEFORE_SLOT_A" ]]; then
        CH_SLOT_A_SEEN=1
        break
    fi
    sleep 0.1
done
if [[ $CH_SLOT_A_SEEN -ne 1 ]]; then
    echo "HARD FAIL (copy-hook first-install): ONLYWALLPAPERS_VIDEO slot=ok not seen within 6s"
    cat "$COPYHOOK_OUT" || true
    exit 1
fi
echo "[copy-hook] first-install slot=ok confirmed"

# Wait for reload and applied line
CH_RELOAD_A_SEEN=0
CH_REV_A=""
for i in $(seq 1 30); do
    CH_RELOAD_LINE="$(grep 'ONLYWALLPAPERS_VIDEO reload' "$COPYHOOK_OUT" | tail -1 || true)"
    if [[ -n "$CH_RELOAD_LINE" ]]; then
        CH_REV_A="$(echo "$CH_RELOAD_LINE" | grep -oE 'rev=[0-9]+' | head -1 | sed 's/rev=//')"
        CH_RELOAD_A_SEEN=1
        break
    fi
    sleep 0.1
done
if [[ $CH_RELOAD_A_SEEN -ne 1 ]] || [[ -z "$CH_REV_A" ]]; then
    echo "HARD FAIL (copy-hook first-install): reload line or rev token not found"
    cat "$COPYHOOK_OUT" || true
    exit 1
fi

# Wait for applied line with correct durationMs for EACH actual window.
CH_DUR_A_LOW=$(( CLIP_A_DUR_MS - 500 ))
CH_DUR_A_HIGH=$(( CLIP_A_DUR_MS + 500 ))

CH_APPLIED_A_WIN_OK=()
for _caw in "${CH_ALL_WINS[@]}"; do CH_APPLIED_A_WIN_OK+=("0"); done

for i in $(seq 1 50); do
    _ca_all_ok=1
    for _cai in $(seq 0 $(( ${#CH_ALL_WINS[@]} - 1 ))); do
        _caw="${CH_ALL_WINS[$_cai]}"
        if [[ "${CH_APPLIED_A_WIN_OK[$_cai]}" -eq 0 ]]; then
            _ca_line="$(grep -E "ONLYWALLPAPERS_VIDEO applied.*win=${_caw}[^0-9].*rev=${CH_REV_A}( |$)" "$COPYHOOK_OUT" 2>/dev/null | head -1 || true)"
            if [[ -n "$_ca_line" ]]; then
                _ca_dur="$(echo "$_ca_line" | grep -oE 'durationMs=[0-9]+' | head -1 | sed 's/durationMs=//' || true)"
                if [[ -z "$_ca_dur" ]]; then
                    echo "HARD FAIL (copy-hook first-install): no durationMs for win=${_caw} in: $_ca_line"
                    cat "$COPYHOOK_OUT" || true
                    exit 1
                fi
                if [[ "$_ca_dur" -lt "$CH_DUR_A_LOW" ]] || [[ "$_ca_dur" -gt "$CH_DUR_A_HIGH" ]]; then
                    echo "HARD FAIL (copy-hook first-install): win=${_caw} durationMs=$_ca_dur not in [${CH_DUR_A_LOW},${CH_DUR_A_HIGH}] for 6s clip A"
                    cat "$COPYHOOK_OUT" || true
                    exit 1
                fi
                CH_APPLIED_A_WIN_OK[$_cai]="1"
                echo "[copy-hook] win=${_caw} applied rev=${CH_REV_A} durationMs=$_ca_dur confirmed (first-install)"
            else
                _ca_all_ok=0
            fi
        fi
    done
    if [[ $_ca_all_ok -eq 1 ]]; then break; fi
    sleep 0.1
done

for _cai in $(seq 0 $(( ${#CH_ALL_WINS[@]} - 1 ))); do
    _caw="${CH_ALL_WINS[$_cai]}"
    if [[ "${CH_APPLIED_A_WIN_OK[$_cai]}" -ne 1 ]]; then
        echo "HARD FAIL (copy-hook first-install): win=${_caw} no applied rev=${CH_REV_A} within 5s"
        cat "$COPYHOOK_OUT" || true
        exit 1
    fi
done
echo "[copy-hook] PASS (first-install): durationMs confirmed for all ${CH_WIN_COUNT} window(s), applied rev=${CH_REV_A}"

# Wait for state=playing for EACH actual window (first-install).
CH_PLAY_A_WIN_OK=()
for _cpaw in "${CH_ALL_WINS[@]}"; do CH_PLAY_A_WIN_OK+=("0"); done

for i in $(seq 1 20); do
    _cpa_all_play=1
    for _cpai in $(seq 0 $(( ${#CH_ALL_WINS[@]} - 1 ))); do
        _cpaw="${CH_ALL_WINS[$_cpai]}"
        if [[ "${CH_PLAY_A_WIN_OK[$_cpai]}" -eq 0 ]]; then
            if grep -qE "ONLYWALLPAPERS_VIDEO media win=${_cpaw}[^0-9].*rev=${CH_REV_A}.*state=playing" "$COPYHOOK_OUT" 2>/dev/null; then
                CH_PLAY_A_WIN_OK[$_cpai]="1"
                echo "[copy-hook] win=${_cpaw} state=playing confirmed for rev=${CH_REV_A} (first-install)"
            else
                _cpa_all_play=0
            fi
        fi
    done
    if [[ $_cpa_all_play -eq 1 ]]; then break; fi
    sleep 0.3
done

CH_PLAY_A_FAIL=0
for _cpai in $(seq 0 $(( ${#CH_ALL_WINS[@]} - 1 ))); do
    _cpaw="${CH_ALL_WINS[$_cpai]}"
    if [[ "${CH_PLAY_A_WIN_OK[$_cpai]}" -ne 1 ]]; then
        echo "HARD FAIL (copy-hook first-install): win=${_cpaw} no state=playing for rev=${CH_REV_A}"
        CH_PLAY_A_FAIL=1
    fi
done
if [[ $CH_PLAY_A_FAIL -ne 0 ]]; then
    cat "$COPYHOOK_OUT" || true
    exit 1
fi
echo "[copy-hook] PASS (first-install): state=playing confirmed for all ${CH_WIN_COUNT} window(s)"

# --- Replace branch: slot now has clip A; SIGUSR2 with clip B path ---
echo "[copy-hook] Testing replace branch (slot exists, replacing with clip B)..."

printf '%s' "$CLIP_B" > "$COPY_SRC_FILE"

CH_BEFORE_SLOT_B="$(grep -c 'ONLYWALLPAPERS_VIDEO slot=ok' "$COPYHOOK_OUT" 2>/dev/null || true)"
kill -USR2 "$COPYHOOK_PID"

# Wait for new slot=ok
CH_SLOT_B_SEEN=0
for i in $(seq 1 60); do
    CH_AFTER_SLOT_B="$(grep -c 'ONLYWALLPAPERS_VIDEO slot=ok' "$COPYHOOK_OUT" 2>/dev/null || true)"
    if [[ "$CH_AFTER_SLOT_B" -gt "$CH_BEFORE_SLOT_B" ]]; then
        CH_SLOT_B_SEEN=1
        break
    fi
    sleep 0.1
done
if [[ $CH_SLOT_B_SEEN -ne 1 ]]; then
    echo "HARD FAIL (copy-hook replace): ONLYWALLPAPERS_VIDEO slot=ok (second) not seen within 6s"
    cat "$COPYHOOK_OUT" || true
    exit 1
fi
echo "[copy-hook] replace slot=ok confirmed"

# Wait for new reload with new rev
CH_REV_B=""
for i in $(seq 1 30); do
    CH_NEW_RELOAD="$(grep 'ONLYWALLPAPERS_VIDEO reload' "$COPYHOOK_OUT" | tail -1 || true)"
    CH_REV_B_CANDIDATE="$(echo "$CH_NEW_RELOAD" | grep -oE 'rev=[0-9]+' | head -1 | sed 's/rev=//')"
    if [[ -n "$CH_REV_B_CANDIDATE" ]] && [[ "$CH_REV_B_CANDIDATE" != "$CH_REV_A" ]]; then
        CH_REV_B="$CH_REV_B_CANDIDATE"
        break
    fi
    sleep 0.1
done
if [[ -z "$CH_REV_B" ]]; then
    echo "HARD FAIL (copy-hook replace): new reload rev not found"
    cat "$COPYHOOK_OUT" || true
    exit 1
fi

# Wait for applied line with correct durationMs for EACH actual window (replace).
# A swap that updated only one of N screens must FAIL.
CH_DUR_B_LOW=$(( CLIP_B_DUR_MS - 500 ))
CH_DUR_B_HIGH=$(( CLIP_B_DUR_MS + 500 ))

CH_APPLIED_B_WIN_OK=()
for _cbaw in "${CH_ALL_WINS[@]}"; do CH_APPLIED_B_WIN_OK+=("0"); done

for i in $(seq 1 80); do
    _cba_all_ok=1
    for _cbai in $(seq 0 $(( ${#CH_ALL_WINS[@]} - 1 ))); do
        _cbaw="${CH_ALL_WINS[$_cbai]}"
        if [[ "${CH_APPLIED_B_WIN_OK[$_cbai]}" -eq 0 ]]; then
            _cb_line="$(grep -E "ONLYWALLPAPERS_VIDEO applied.*win=${_cbaw}[^0-9].*rev=${CH_REV_B}( |$)" "$COPYHOOK_OUT" 2>/dev/null | head -1 || true)"
            if [[ -n "$_cb_line" ]]; then
                _cb_dur="$(echo "$_cb_line" | grep -oE 'durationMs=[0-9]+' | head -1 | sed 's/durationMs=//' || true)"
                if [[ -z "$_cb_dur" ]]; then
                    echo "HARD FAIL (copy-hook replace): no durationMs for win=${_cbaw} in: $_cb_line"
                    cat "$COPYHOOK_OUT" || true
                    exit 1
                fi
                if [[ "$_cb_dur" -lt "$CH_DUR_B_LOW" ]] || [[ "$_cb_dur" -gt "$CH_DUR_B_HIGH" ]]; then
                    echo "HARD FAIL (copy-hook replace): win=${_cbaw} durationMs=$_cb_dur not in [${CH_DUR_B_LOW},${CH_DUR_B_HIGH}] for ${CLIP_B_DURATION}s clip B"
                    cat "$COPYHOOK_OUT" || true
                    exit 1
                fi
                CH_APPLIED_B_WIN_OK[$_cbai]="1"
                echo "[copy-hook] win=${_cbaw} applied rev=${CH_REV_B} durationMs=$_cb_dur confirmed (replace)"
            else
                _cba_all_ok=0
            fi
        fi
    done
    if [[ $_cba_all_ok -eq 1 ]]; then break; fi
    sleep 0.1
done

for _cbai in $(seq 0 $(( ${#CH_ALL_WINS[@]} - 1 ))); do
    _cbaw="${CH_ALL_WINS[$_cbai]}"
    if [[ "${CH_APPLIED_B_WIN_OK[$_cbai]}" -ne 1 ]]; then
        echo "HARD FAIL (copy-hook replace): win=${_cbaw} no applied rev=${CH_REV_B} within 8s"
        cat "$COPYHOOK_OUT" || true
        exit 1
    fi
done
echo "[copy-hook] PASS (replace): durationMs confirmed for all ${CH_WIN_COUNT} window(s), applied rev=${CH_REV_B}"

# Wait for state=playing for EACH actual window (replace).
# One paused window while another plays must HARD FAIL.
CH_PLAY_B_WIN_OK=()
for _cpbw in "${CH_ALL_WINS[@]}"; do CH_PLAY_B_WIN_OK+=("0"); done

for i in $(seq 1 20); do
    _cpb_all_play=1
    for _cpbi in $(seq 0 $(( ${#CH_ALL_WINS[@]} - 1 ))); do
        _cpbw="${CH_ALL_WINS[$_cpbi]}"
        if [[ "${CH_PLAY_B_WIN_OK[$_cpbi]}" -eq 0 ]]; then
            if grep -qE "ONLYWALLPAPERS_VIDEO media win=${_cpbw}[^0-9].*rev=${CH_REV_B}.*state=playing" "$COPYHOOK_OUT" 2>/dev/null; then
                CH_PLAY_B_WIN_OK[$_cpbi]="1"
                echo "[copy-hook] win=${_cpbw} state=playing confirmed for rev=${CH_REV_B} (replace)"
            else
                _cpb_all_play=0
            fi
        fi
    done
    if [[ $_cpb_all_play -eq 1 ]]; then break; fi
    sleep 0.3
done

CH_PLAY_B_FAIL=0
for _cpbi in $(seq 0 $(( ${#CH_ALL_WINS[@]} - 1 ))); do
    _cpbw="${CH_ALL_WINS[$_cpbi]}"
    if [[ "${CH_PLAY_B_WIN_OK[$_cpbi]}" -ne 1 ]]; then
        echo "HARD FAIL (copy-hook replace): win=${_cpbw} no state=playing for rev=${CH_REV_B}"
        CH_PLAY_B_FAIL=1
    fi
done
if [[ $CH_PLAY_B_FAIL -ne 0 ]]; then
    cat "$COPYHOOK_OUT" || true
    exit 1
fi
echo "[copy-hook] PASS (replace): state=playing confirmed for all ${CH_WIN_COUNT} window(s) for rev=${CH_REV_B}"

# Terminate copy-hook process
kill -INT "$COPYHOOK_PID" 2>/dev/null || true
sleep 0.5
if kill -0 "$COPYHOOK_PID" 2>/dev/null; then
    kill -KILL "$COPYHOOK_PID" 2>/dev/null || true
fi
wait "$COPYHOOK_PID" 2>/dev/null || true
COPYHOOK_PID=""

echo "[copy-hook] PASS: first-install and replace branches verified"

# Step 11: verdict
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
