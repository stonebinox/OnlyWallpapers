#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "=== OnlyWallpapers spike-check ==="

# 1. Build
echo "[build] Building with warnings-as-errors..."
swift build --product OnlyWallpapers -Xswiftc -warnings-as-errors
echo "[build] PASS"

# 2. Locate binary
BIN="$(swift build --product OnlyWallpapers --show-bin-path)/OnlyWallpapers"
echo "[bin] $BIN"

# 3. Launch with OW_SPIKE=1
TMPOUT="$(mktemp)"
PID=""
cleanup() {
    if [[ -n "${PID:-}" ]]; then
        if kill -0 "$PID" 2>/dev/null; then
            kill -INT "$PID" 2>/dev/null || true
            sleep 0.4
            if kill -0 "$PID" 2>/dev/null; then
                kill -KILL "$PID" 2>/dev/null || true
            fi
        fi
        wait "$PID" 2>/dev/null || true
    fi
    rm -f "$TMPOUT"
}
trap cleanup EXIT INT

echo "[launch] Starting with OW_SPIKE=1..."
OW_SPIKE=1 "$BIN" >"$TMPOUT" 2>&1 &
PID=$!
echo "[launch] PID: $PID"

# 4. Wait up to 5s for first OW_SPIKE heartbeat line
echo "[wait] Waiting for first OW_SPIKE heartbeat (up to 5s)..."
FOUND=0
for i in $(seq 1 50); do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "SPIKE-CHECK FAIL: process died before emitting heartbeat"
        echo "--- output ---"
        cat "$TMPOUT" || true
        exit 1
    fi
    if grep -q "^OW_SPIKE screen=" "$TMPOUT" 2>/dev/null; then
        FOUND=1
        break
    fi
    sleep 0.1
done

if [[ $FOUND -ne 1 ]]; then
    echo "SPIKE-CHECK FAIL: no OW_SPIKE heartbeat within 5s"
    echo "--- output ---"
    cat "$TMPOUT" || true
    exit 1
fi
echo "[wait] First heartbeat received."

# 5. Collect heartbeats for ~4s
sleep 4

HEARTBEATS="$(grep "^OW_SPIKE screen=" "$TMPOUT" 2>/dev/null || true)"
HB_COUNT="$(echo "$HEARTBEATS" | grep -c "^OW_SPIKE" || true)"
echo "[heartbeats] Collected $HB_COUNT heartbeat line(s):"
echo "$HEARTBEATS"

# 6. Parse OW_SPIKE SCREENS count=N to know how many displays were seen at launch.
EXPECTED_DISPLAY_COUNT="$(grep "^OW_SPIKE SCREENS count=" "$TMPOUT" 2>/dev/null | head -1 | grep -oE 'count=[0-9]+' | cut -d= -f2 || echo "")"
if [[ -z "$EXPECTED_DISPLAY_COUNT" ]]; then
    echo "SPIKE-CHECK FAIL: no 'OW_SPIKE SCREENS count=N' line found in output"
    exit 1
fi
echo "[displays] App reported $EXPECTED_DISPLAY_COUNT display(s) at launch."

# Count distinct did= values seen across all heartbeat lines.
DISTINCT_DIDS="$(echo "$HEARTBEATS" | grep -oE 'did=[0-9]+' | cut -d= -f2 | sort -u)"
DISTINCT_DID_COUNT="$(echo "$DISTINCT_DIDS" | grep -c "[0-9]" || true)"

if [[ "$DISTINCT_DID_COUNT" -ne "$EXPECTED_DISPLAY_COUNT" ]]; then
    echo "SPIKE-CHECK FAIL: expected $EXPECTED_DISPLAY_COUNT displays with windows, saw $DISTINCT_DID_COUNT"
    exit 1
fi
echo "[displays] Coverage OK: $DISTINCT_DID_COUNT distinct display ID(s) seen in heartbeats."

# 7. Per-display validation, keyed on did= (stable CGDirectDisplayID).
# Screen name is shown for human readability but not used as the primary key.

if [[ -z "$DISTINCT_DIDS" ]]; then
    echo "SPIKE-CHECK FAIL: no did= values found in heartbeat lines"
    exit 1
fi

# Expected window level: Int(CGWindowLevelForKey(.desktopWindow)) on macOS 26
EXPECTED_LEVEL=-2147483623

OVERALL_PASS=1

while IFS= read -r DID; do
    [[ -z "$DID" ]] && continue

    DID_LINES="$(echo "$HEARTBEATS" | grep "did=$DID " || true)"
    SCREEN_NAME="$(echo "$DID_LINES" | head -1 | sed -n 's/^OW_SPIKE screen=\([^ ]*\) .*/\1/p' || echo "unknown")"
    DC_COUNT="$(echo "$DID_LINES" | grep -c "^OW_SPIKE" || true)"

    if [[ "$DC_COUNT" -lt 2 ]]; then
        echo "SPIKE-CHECK FAIL: did=$DID (screen=$SCREEN_NAME) has only $DC_COUNT heartbeat line(s), need at least 2"
        OVERALL_PASS=0
        continue
    fi

    # Strict monotonicity of draws across every consecutive pair
    PREV_DRAWS=""
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        CUR_DRAWS="$(echo "$LINE" | grep -oE 'draws=[0-9]+' | cut -d= -f2 || true)"
        if [[ -z "$CUR_DRAWS" ]]; then
            echo "SPIKE-CHECK FAIL: did=$DID (screen=$SCREEN_NAME) line missing draws field"
            OVERALL_PASS=0
        elif [[ -n "$PREV_DRAWS" ]] && [[ "$CUR_DRAWS" -le "$PREV_DRAWS" ]]; then
            echo "SPIKE-CHECK FAIL: did=$DID (screen=$SCREEN_NAME) draws not strictly monotonic ($PREV_DRAWS -> $CUR_DRAWS)"
            OVERALL_PASS=0
        fi
        PREV_DRAWS="${CUR_DRAWS:-$PREV_DRAWS}"
    done <<< "$DID_LINES"

    # Strict monotonicity of ca across every consecutive pair
    PREV_CA=""
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        CUR_CA="$(echo "$LINE" | grep -oE 'ca=[0-9]+(\.[0-9]+)?' | cut -d= -f2 || true)"
        if [[ -z "$CUR_CA" ]]; then
            echo "SPIKE-CHECK FAIL: did=$DID (screen=$SCREEN_NAME) line missing ca field"
            OVERALL_PASS=0
        elif [[ -n "$PREV_CA" ]]; then
            CA_MONO="$(awk -v a="$PREV_CA" -v b="$CUR_CA" 'BEGIN { print (b > a) ? "1" : "0" }')"
            if [[ "$CA_MONO" -ne 1 ]]; then
                echo "SPIKE-CHECK FAIL: did=$DID (screen=$SCREEN_NAME) ca not strictly monotonic ($PREV_CA -> $CUR_CA)"
                OVERALL_PASS=0
            fi
        fi
        PREV_CA="${CUR_CA:-$PREV_CA}"
    done <<< "$DID_LINES"

    # Every line's level must equal EXPECTED_LEVEL
    while IFS= read -r LINE; do
        [[ -z "$LINE" ]] && continue
        LINE_LEVEL="$(echo "$LINE" | grep -oE 'level=-?[0-9]+' | cut -d= -f2 || true)"
        if [[ -z "$LINE_LEVEL" ]]; then
            echo "SPIKE-CHECK FAIL: did=$DID (screen=$SCREEN_NAME) line missing level field"
            OVERALL_PASS=0
        elif [[ "$LINE_LEVEL" != "$EXPECTED_LEVEL" ]]; then
            echo "SPIKE-CHECK FAIL: did=$DID (screen=$SCREEN_NAME) level=$LINE_LEVEL (expected $EXPECTED_LEVEL)"
            OVERALL_PASS=0
        fi
    done <<< "$DID_LINES"

    DC_FIRST="$(echo "$DID_LINES" | head -1)"
    DC_LAST="$(echo "$DID_LINES" | tail -1)"

    DC_ZORDER="$(echo "$DC_LAST" | grep -oE 'zorder_ok=[a-z]+' | cut -d= -f2 || echo unknown)"
    if [[ "$DC_ZORDER" != "true" ]]; then
        echo "SPIKE-CHECK FAIL: did=$DID (screen=$SCREEN_NAME) last heartbeat zorder_ok=$DC_ZORDER (expected true)"
        OVERALL_PASS=0
    fi

    DC_VIS="$(echo "$DC_LAST" | grep -oE 'vis=[a-z]+' | cut -d= -f2 || echo unknown)"
    if [[ "$DC_VIS" != "true" ]]; then
        echo "SPIKE-CHECK FAIL: did=$DID (screen=$SCREEN_NAME) last heartbeat vis=$DC_VIS (expected true)"
        OVERALL_PASS=0
    fi

    DC_FIRST_DRAWS="$(echo "$DC_FIRST" | grep -oE 'draws=[0-9]+' | cut -d= -f2 || echo 0)"
    DC_LAST_DRAWS="$(echo "$DC_LAST" | grep -oE 'draws=[0-9]+' | cut -d= -f2 || echo 0)"
    DC_FIRST_CA="$(echo "$DC_FIRST" | grep -oE 'ca=[0-9]+(\.[0-9]+)?' | cut -d= -f2 || echo 0)"
    DC_LAST_CA="$(echo "$DC_LAST" | grep -oE 'ca=[0-9]+(\.[0-9]+)?' | cut -d= -f2 || echo 0)"

    echo "[did=$DID screen=$SCREEN_NAME] draws: $DC_FIRST_DRAWS -> $DC_LAST_DRAWS, ca: $DC_FIRST_CA -> $DC_LAST_CA, zorder_ok=$DC_ZORDER, vis=$DC_VIS OK"

done <<< "$DISTINCT_DIDS"

if [[ "$OVERALL_PASS" -ne 1 ]]; then
    echo "SPIKE-CHECK FAIL: per-display assertions failed (see above)"
    exit 1
fi

echo "[assertions] All per-display assertions PASSED."

# 8. Pixel gate: coarse liveness hint via center-crop frame diff.
# Full-display frames are captured and SAVED for human inspection.
# Automated diff is performed on a 600x300 center crop to reduce confound
# from the menu-bar clock or foreground apps covering the spike.
# Result is reported as a COARSE LIVENESS HINT, not proof.
echo "[pixel] Capturing two full-display frames per display (saved for inspection) and comparing center crops..."
echo "[pixel] pixel diff is a coarse hint; authoritative rendered-output proof is human inspection of the saved full-display screenshots"

PIXEL_INCONCLUSIVE=0
ALL_PNG_PATHS=""
PIXEL_WARN=0

D=1
while true; do
    FRAME_A="/tmp/ow-spike-D${D}-a.png"

    if ! screencapture -x -D "$D" "$FRAME_A" 2>/dev/null; then
        if [[ "$D" -eq 1 ]]; then
            PIXEL_INCONCLUSIVE=1
        fi
        break
    fi

    if [[ ! -s "$FRAME_A" ]]; then
        if [[ "$D" -eq 1 ]]; then
            PIXEL_INCONCLUSIVE=1
        fi
        break
    fi

    ALL_PNG_PATHS="$ALL_PNG_PATHS $FRAME_A"
    echo "[pixel] Captured full display $D frame A: $FRAME_A"

    sleep 0.4

    FRAME_B="/tmp/ow-spike-D${D}-b.png"

    if ! screencapture -x -D "$D" "$FRAME_B" 2>/dev/null || [[ ! -s "$FRAME_B" ]]; then
        echo "[pixel] WARNING: display $D second frame capture failed; skipping crop diff for this display"
        PIXEL_WARN=1
    else
        ALL_PNG_PATHS="$ALL_PNG_PATHS $FRAME_B"
        echo "[pixel] Captured full display $D frame B: $FRAME_B"

        # Compute center-crop dimensions using sips.
        IMG_W="$(sips -g pixelWidth "$FRAME_A" 2>/dev/null | tail -1 | awk '{print $2}' || echo 0)"
        IMG_H="$(sips -g pixelHeight "$FRAME_A" 2>/dev/null | tail -1 | awk '{print $2}' || echo 0)"
        CROP_W=600; CROP_H=300
        LEFT_OFF=$(( (IMG_W - CROP_W) / 2 ))
        TOP_OFF=$(( (IMG_H - CROP_H) / 2 ))

        CROP_A="/tmp/ow-spike-D${D}-a-crop.png"
        CROP_B="/tmp/ow-spike-D${D}-b-crop.png"

        cp "$FRAME_A" "$CROP_A"
        sips --cropToHeightWidth "$CROP_H" "$CROP_W" --cropOffset "$TOP_OFF" "$LEFT_OFF" "$CROP_A" >/dev/null 2>&1 || true
        cp "$FRAME_B" "$CROP_B"
        sips --cropToHeightWidth "$CROP_H" "$CROP_W" --cropOffset "$TOP_OFF" "$LEFT_OFF" "$CROP_B" >/dev/null 2>&1 || true

        if cmp -s "$CROP_A" "$CROP_B"; then
            echo "[pixel] WARNING: display $D center-crop frames are identical (possible freeze or spike covered by a foreground app on that display)"
            PIXEL_WARN=1
        else
            echo "[pixel] Display $D center crop: frames differ (liveness hint: animation running). OK"
        fi
    fi

    D=$((D + 1))
done

# Helper: print per-display summary and the NOTE line
print_summary() {
    echo ""
    echo "=== SPIKE-CHECK SUMMARY ==="
    while IFS= read -r DID; do
        [[ -z "$DID" ]] && continue
        DID_LINES="$(echo "$HEARTBEATS" | grep "did=$DID " || true)"
        SCREEN_NAME="$(echo "$DID_LINES" | head -1 | sed -n 's/^OW_SPIKE screen=\([^ ]*\) .*/\1/p' || echo "unknown")"
        DC_FIRST="$(echo "$DID_LINES" | head -1)"
        DC_LAST="$(echo "$DID_LINES" | tail -1)"
        DC_FIRST_DRAWS="$(echo "$DC_FIRST" | grep -oE 'draws=[0-9]+' | cut -d= -f2 || echo 0)"
        DC_LAST_DRAWS="$(echo "$DC_LAST" | grep -oE 'draws=[0-9]+' | cut -d= -f2 || echo 0)"
        DC_FIRST_CA="$(echo "$DC_FIRST" | grep -oE 'ca=[0-9]+(\.[0-9]+)?' | cut -d= -f2 || echo 0)"
        DC_LAST_CA="$(echo "$DC_LAST" | grep -oE 'ca=[0-9]+(\.[0-9]+)?' | cut -d= -f2 || echo 0)"
        DC_ZORDER="$(echo "$DC_LAST" | grep -oE 'zorder_ok=[a-z]+' | cut -d= -f2 || echo unknown)"
        DC_VIS="$(echo "$DC_LAST" | grep -oE 'vis=[a-z]+' | cut -d= -f2 || echo unknown)"
        DC_OCC="$(echo "$DC_LAST" | grep -oE 'occ=[a-z]+' | cut -d= -f2 || echo unknown)"
        DRAWS_DELTA=$((DC_LAST_DRAWS - DC_FIRST_DRAWS))
        echo "did=$DID screen=$SCREEN_NAME: draws $DC_FIRST_DRAWS -> $DC_LAST_DRAWS (delta $DRAWS_DELTA), ca $DC_FIRST_CA -> $DC_LAST_CA, zorder_ok=$DC_ZORDER, vis=$DC_VIS, occ=$DC_OCC"
    done <<< "$DISTINCT_DIDS"
    if [[ -n "$ALL_PNG_PATHS" ]]; then
        echo "screenshots (full display, for human inspection):$ALL_PNG_PATHS"
    fi
    echo ""
    echo "NOTE: pixel diff is a COARSE LIVENESS HINT, not proof. Authoritative rendered-output proof is human inspection of the saved full-display screenshots."
    echo "NOTE: this script verifies window placement (behind icons via zorder), continuous in-process and rendered animation (ca and pixel diff). It does NOT verify click-through or all-Spaces behavior; those require the manual Phase 5 checklist."
}

# 9. SIGINT and verify clean exit
sigint_check() {
    echo "[sigint] Sending SIGINT to $PID..."
    kill -INT "$PID"
    GONE=0
    for i in $(seq 1 20); do
        sleep 0.05
        if ! kill -0 "$PID" 2>/dev/null; then
            GONE=1
            break
        fi
    done

    if [[ $GONE -ne 1 ]]; then
        echo "SPIKE-CHECK FAIL: process did not exit within 1s of SIGINT"
        exit 1
    fi

    STATUS=0; wait "$PID" || STATUS=$?
    if [[ "$STATUS" -ne 0 ]]; then
        echo "SPIKE-CHECK FAIL: process exited with status $STATUS after SIGINT (expected 0)"
        exit 1
    fi
    PID=""
}

if [[ "$PIXEL_INCONCLUSIVE" -eq 1 ]]; then
    print_summary
    sigint_check
    echo "SPIKE-CHECK INCONCLUSIVE: screencapture unavailable (grant Screen Recording permission to this terminal, then rerun). In-process liveness assertions PASSED but rendered-output pixel proof could not be collected."
    exit 2
fi

sigint_check

print_summary

if [[ "$PIXEL_WARN" -eq 1 ]]; then
    echo "[pixel] WARNING: one or more displays had identical center-crop frames or a failed second capture. This may indicate a freeze or a foreground app covering the spike. Inspect the saved screenshots above."
fi

echo ""
echo "SPIKE-CHECK: PASS"
