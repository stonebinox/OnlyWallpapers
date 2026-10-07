#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PID=""
TMPOUT=""
OW_SUPPORT_TMP=""
FAKE_SCREENS=""

cleanup() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -INT "$PID" 2>/dev/null || true
        sleep 0.4
        kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    [[ -n "$TMPOUT" ]] && rm -f "$TMPOUT" || true
    [[ -n "$OW_SUPPORT_TMP" ]] && rm -rf "$OW_SUPPORT_TMP" || true
    [[ -n "$FAKE_SCREENS" ]] && rm -f "$FAKE_SCREENS" || true
}
trap cleanup EXIT

echo "[overlay-check] building..."
swift build -c release 2>&1 | tail -5
BINARY="$(swift build -c release --show-bin-path 2>/dev/null)/OnlyWallpapers"

PASS=0
FAIL=0
SKIP=0
WINDOW_VERIFIED=0

kill_app() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill -INT "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    PID=""
}

get_win_count() {
    grep 'ONLYWALLPAPERS_WINDOWS' "$1" | tail -1 | sed 's/.*count=//;s/ .*//' 2>/dev/null || echo '0'
}

# --- (a) ACTIVE: OW_OVERLAY_TEST=1 registers test effect and starts rAF loop ---
echo "[overlay-check] running (a) ACTIVE..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
  OW_OVERLAY_TEST=1 \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 6

win_count=$(get_win_count "$TMPOUT")
active_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[active] SKIP: 0 windows (genuine headless)"
    active_ok=2
else
    WINDOW_VERIFIED=1
    active_ok=1

    # Collect all OVERLAY lines.
    overlay_out=$(grep 'ONLYWALLPAPERS_OVERLAY' "$TMPOUT" || true)
    overlay_count=$(printf '%s\n' "$overlay_out" | grep -c . || true); overlay_count=${overlay_count:-0}

    if [[ $overlay_count -eq 0 ]]; then
        echo "[active] FAIL: no ONLYWALLPAPERS_OVERLAY lines found"
        active_ok=0
    else
        # Collect distinct window numbers from OVERLAY lines.
        overlay_wins=$(printf '%s\n' "$overlay_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
        overlay_win_count=$(printf '%s\n' "$overlay_wins" | grep -c . || true); overlay_win_count=${overlay_win_count:-0}

        if [[ $overlay_win_count -ne $win_count ]]; then
            echo "[active] FAIL: OVERLAY win count=$overlay_win_count != window count=$win_count"
            active_ok=0
        else
            echo "[active] OVERLAY lines present for all $win_count window(s)"
        fi

        # Per-window assertions.
        while IFS= read -r wnum; do
            [[ -z "$wnum" ]] && continue
            win_lines=$(printf '%s\n' "$overlay_out" | grep "win=${wnum} " || true)
            win_line_count=$(printf '%s\n' "$win_lines" | grep -c . || true); win_line_count=${win_line_count:-0}

            # At least 2 OVERLAY lines per window (didFinish + delayed).
            if [[ $win_line_count -lt 2 ]]; then
                echo "[active] FAIL: win=$wnum has only $win_line_count OVERLAY line(s) (need >=2)"
                active_ok=0
            else
                echo "[active] win=$wnum: $win_line_count OVERLAY lines (ok)"
            fi

            # sizedW and sizedH > 0.
            first_line=$(printf '%s\n' "$win_lines" | head -1)
            sw=$(printf '%s' "$first_line" | grep -oE 'sizedW=[0-9]+' | sed 's/sizedW=//' || echo "0")
            sh=$(printf '%s' "$first_line" | grep -oE 'sizedH=[0-9]+' | sed 's/sizedH=//' || echo "0")
            if [[ "$sw" -le 0 ]]; then
                echo "[active] FAIL: win=$wnum sizedW=$sw is not > 0"
                active_ok=0
            fi
            if [[ "$sh" -le 0 ]]; then
                echo "[active] FAIL: win=$wnum sizedH=$sh is not > 0"
                active_ok=0
            fi

            # running=true on at least one line.
            if ! printf '%s\n' "$win_lines" | grep -q 'running=true'; then
                echo "[active] FAIL: win=$wnum never reported running=true"
                active_ok=0
            else
                echo "[active] win=$wnum: running=true confirmed"
            fi

            # Frames must strictly increase between first and last OVERLAY line (hard fail).
            first_frames=$(printf '%s\n' "$win_lines" | head -1 | grep -oE 'frames=[0-9]+' | sed 's/frames=//' || echo "0")
            last_frames=$(printf '%s\n' "$win_lines" | tail -1 | grep -oE 'frames=[0-9]+' | sed 's/frames=//' || echo "0")
            if [[ "$last_frames" -le "$first_frames" && $win_line_count -ge 2 ]]; then
                echo "[active] FAIL: win=$wnum frames did not strictly increase (first=$first_frames last=$last_frames)"
                active_ok=0
            else
                echo "[active] win=$wnum: frames increased from $first_frames to $last_frames"
            fi

            # Per-window DPR verification: sizedW/sizedH must equal round(stageW * dpr).
            dpr_val=$(printf '%s\n' "$win_lines" | head -1 | grep -oE 'dpr=[0-9.]+' | sed 's/dpr=//' || echo "1")
            geo_line=$(grep "ONLYWALLPAPERS_WEB_GEOMETRY.*win=${wnum} " "$TMPOUT" | head -1 || true)
            stage_w=$(printf '%s' "$geo_line" | grep -oE 'gW=[0-9.]+' | sed 's/gW=//' || echo "0")
            stage_h=$(printf '%s' "$geo_line" | grep -oE 'gH=[0-9.]+' | sed 's/gH=//' || echo "0")
            expected_w=$(printf '%.0f' "$(echo "$stage_w * $dpr_val" | bc -l 2>/dev/null || echo 0)")
            expected_h=$(printf '%.0f' "$(echo "$stage_h * $dpr_val" | bc -l 2>/dev/null || echo 0)")
            if [[ "$sw" -ne "$expected_w" || "$sh" -ne "$expected_h" ]]; then
                echo "[active] FAIL: win=$wnum sizedW=$sw sizedH=$sh expected=${expected_w}x${expected_h} (stageW=$stage_w stageH=$stage_h dpr=$dpr_val)"
                active_ok=0
            else
                echo "[active] win=${wnum}: sizedW=$sw sizedH=$sh dpr=$dpr_val stageW=$stage_w expected=${expected_w}x${expected_h} (ok)"
            fi

            # emptyAlpha==0 and markerAlpha>0: verify transparent compositing.
            last_line=$(printf '%s\n' "$win_lines" | tail -1)
            ea=$(printf '%s' "$last_line" | grep -oE 'emptyAlpha=[0-9]+' | sed 's/emptyAlpha=//' || echo "")
            ma=$(printf '%s' "$last_line" | grep -oE 'markerAlpha=[0-9]+' | sed 's/markerAlpha=//' || echo "")
            if [[ -z "$ea" || -z "$ma" ]]; then
                echo "[active] FAIL: win=$wnum emptyAlpha/markerAlpha missing from OVERLAY lines (pixel sampling not reported)"
                active_ok=0
            elif [[ "$ea" -ne 0 ]]; then
                echo "[active] FAIL: win=$wnum emptyAlpha=$ea (expected 0: canvas not transparent where nothing drawn)"
                active_ok=0
            elif [[ "$ma" -le 0 ]]; then
                echo "[active] FAIL: win=$wnum markerAlpha=$ma (expected >0: test effect did not draw)"
                active_ok=0
            else
                echo "[active] win=$wnum: emptyAlpha=$ea (ok) markerAlpha=$ma (ok)"
            fi
        done <<< "$overlay_wins"

        # Every window must report media=playing. Hard fail if any window does not.
        while IFS= read -r wnum; do
            [[ -z "$wnum" ]] && continue
            if grep -qE "ONLYWALLPAPERS_(WEB|FRAMING_MEDIA).*win=${wnum}.*media=playing" "$TMPOUT"; then
                echo "[active] win=$wnum: media=playing confirmed"
            else
                echo "[active] FAIL: win=$wnum media=playing not found (hard fail)"
                active_ok=0
            fi
        done <<< "$overlay_wins"
    fi
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $active_ok -eq 2 ]]; then
    echo "[overlay-check] SKIP (a) ACTIVE"
    SKIP=$((SKIP+1))
elif [[ $active_ok -eq 1 ]]; then
    echo "[overlay-check] PASS (a) ACTIVE"
    PASS=$((PASS+1))
else
    echo "[overlay-check] FAIL (a) ACTIVE"
    FAIL=$((FAIL+1))
fi

# --- (b) INERT: without OW_OVERLAY_TEST, OVERLAY lines must appear with running=false and hasEffect=false ---
echo "[overlay-check] running (b) INERT..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON -u OW_OVERLAY_TEST \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!
sleep 6

win_count=$(get_win_count "$TMPOUT")
inert_ok=0

if [[ "$win_count" -eq 0 ]]; then
    echo "[inert] SKIP: 0 windows (genuine headless)"
    inert_ok=2
else
    WINDOW_VERIFIED=1
    inert_ok=1

    overlay_out=$(grep 'ONLYWALLPAPERS_OVERLAY' "$TMPOUT" || true)
    overlay_count=$(printf '%s\n' "$overlay_out" | grep -c . || true); overlay_count=${overlay_count:-0}

    if [[ $overlay_count -eq 0 ]]; then
        echo "[inert] FAIL: 0 OVERLAY lines found (expected one per window reporting running=false hasEffect=false)"
        inert_ok=0
    else
        inert_wins=$(printf '%s\n' "$overlay_out" | sed 's/.*win=//;s/ .*//' | sort -u | grep -v '^$' || true)
        inert_win_count=$(printf '%s\n' "$inert_wins" | grep -c . || true); inert_win_count=${inert_win_count:-0}
        if [[ $inert_win_count -ne $win_count ]]; then
            echo "[inert] FAIL: OVERLAY win count=$inert_win_count != window count=$win_count"
            inert_ok=0
        else
            echo "[inert] OVERLAY lines present for all $win_count window(s)"
        fi
        while IFS= read -r wnum; do
            [[ -z "$wnum" ]] && continue
            win_line=$(printf '%s\n' "$overlay_out" | grep "win=${wnum} " | head -1 || true)
            if printf '%s' "$win_line" | grep -q 'running=false'; then
                echo "[inert] win=$wnum: running=false (ok)"
            else
                echo "[inert] FAIL: win=$wnum running is not false"
                inert_ok=0
            fi
            if printf '%s' "$win_line" | grep -q 'hasEffect=false'; then
                echo "[inert] win=$wnum: hasEffect=false (ok)"
            else
                echo "[inert] FAIL: win=$wnum hasEffect is not false"
                inert_ok=0
            fi
        done <<< "$inert_wins"
    fi
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $inert_ok -eq 2 ]]; then
    echo "[overlay-check] SKIP (b) INERT"
    SKIP=$((SKIP+1))
elif [[ $inert_ok -eq 1 ]]; then
    echo "[overlay-check] PASS (b) INERT"
    PASS=$((PASS+1))
else
    echo "[overlay-check] FAIL (b) INERT"
    FAIL=$((FAIL+1))
fi

# --- (c) GEOMETRY-RESIZE: surviving view's overlay must update both W and H when union changes ---
echo "[overlay-check] running (c) GEOMETRY-RESIZE..."
OW_SUPPORT_TMP="$(mktemp -d)"
TMPOUT="$(mktemp)"
FAKE_SCREENS="$(mktemp)"

# Initial: two displays side-by-side. id=1 (1920x1080) will survive the rebuild; id=2 will be retired.
printf '0,0,1920,1080,2.0,1\n1920,0,1920,1080,2.0,2\n' > "$FAKE_SCREENS"

env -u OW_MOOD_TEST -u OW_MOOD_WEATHER_JSON \
  OW_OVERLAY_TEST=1 \
  OW_FAKE_SCREENS_FILE="$FAKE_SCREENS" \
  OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" \
  WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" \
  "$BINARY" > "$TMPOUT" 2>&1 &
PID=$!

RESIZE_READY=0
for i in $(seq 1 100); do
    if grep -q 'ONLYWALLPAPERS_READY' "$TMPOUT" 2>/dev/null; then
        RESIZE_READY=1; break
    fi
    sleep 0.1
done

resize_ok=0
if [[ "$RESIZE_READY" -ne 1 ]]; then
    echo "[resize] SKIP: ONLYWALLPAPERS_READY never appeared (genuine headless)"
    resize_ok=2
else
    sleep 4.0

    # Find window number for display id=1 (the survivor) from SLICE telemetry.
    survivor_win=$(grep "ONLYWALLPAPERS_SLICE.*did=1 " "$TMPOUT" | head -1 | grep -oE 'win=[0-9]+' | sed 's/win=//' || echo "")

    # Initial OVERLAY stats for the survivor window.
    init_overlay=$(grep "ONLYWALLPAPERS_OVERLAY.*win=${survivor_win} " "$TMPOUT" | head -1 || true)
    init_sw=$(printf '%s' "$init_overlay" | grep -oE 'sizedW=[0-9]+' | sed 's/sizedW=//' || echo "0")
    init_sh=$(printf '%s' "$init_overlay" | grep -oE 'sizedH=[0-9]+' | sed 's/sizedH=//' || echo "0")
    init_dpr=$(printf '%s' "$init_overlay" | grep -oE 'dpr=[0-9.]+' | sed 's/dpr=//' || echo "1")

    if [[ -z "$survivor_win" || "$init_sw" -le 0 || "$init_sh" -le 0 ]]; then
        echo "[resize] FAIL: cannot establish survivor baseline (survivor_win='$survivor_win' init_sw=$init_sw init_sh=$init_sh)"
        resize_ok=0
    else
        echo "[resize] survivor win=$survivor_win initial sizedW=$init_sw sizedH=$init_sh dpr=$init_dpr"

        # Keep display id=1 (survivor) with new dimensions (2560x1440); retire id=2.
        printf '0,0,2560,1440,2.0,1\n' > "$FAKE_SCREENS"
        kill -USR1 "$PID"

        # Wait for the rebuild to fire.
        for i in $(seq 1 80); do
            if grep -qE 'ONLYWALLPAPERS_REBUILD gen=[1-9]' "$TMPOUT" 2>/dev/null; then break; fi
            sleep 0.1
        done

        # Wait for the survivor's geo-resize OVERLAY line (emitted 0.5s after applyGeometry).
        for i in $(seq 1 80); do
            if grep -qE "ONLYWALLPAPERS_OVERLAY win=${survivor_win} .*label=geo-resize" "$TMPOUT" 2>/dev/null; then break; fi
            sleep 0.1
        done
        sleep 0.5

        new_overlay=$(grep "ONLYWALLPAPERS_OVERLAY.*win=${survivor_win}.*label=geo-resize" "$TMPOUT" | tail -1 || true)
        new_dpr=$(printf '%s' "$new_overlay" | grep -oE 'dpr=[0-9.]+' | sed 's/dpr=//' || echo "1")
        new_sw=$(printf '%s' "$new_overlay" | grep -oE 'sizedW=[0-9]+' | sed 's/sizedW=//' || echo "0")
        new_sh=$(printf '%s' "$new_overlay" | grep -oE 'sizedH=[0-9]+' | sed 's/sizedH=//' || echo "0")

        expected_new_w=$(printf '%.0f' "$(echo "2560 * $new_dpr" | bc -l 2>/dev/null || echo 0)")
        expected_new_h=$(printf '%.0f' "$(echo "1440 * $new_dpr" | bc -l 2>/dev/null || echo 0)")

        if [[ "$new_sw" -eq "$expected_new_w" && "$new_sh" -eq "$expected_new_h" && "$new_sw" -ne "$init_sw" && "$new_sh" -ne "$init_sh" ]]; then
            echo "[resize] survivor overlay resized: sizedW ${init_sw}->${new_sw} sizedH ${init_sh}->${new_sh} (expected ${expected_new_w}x${expected_new_h}) (ok)"
            resize_ok=1
        elif [[ "$new_sw" -eq "$expected_new_w" && "$new_sh" -eq "$expected_new_h" ]]; then
            echo "[resize] WARN: sizedW=$new_sw sizedH=$new_sh match expected but same as init; ok if union unchanged"
            resize_ok=1
        else
            echo "[resize] FAIL: survivor sizedW=$new_sw (expected $expected_new_w) sizedH=$new_sh (expected $expected_new_h) init=${init_sw}x${init_sh}"
            resize_ok=0
        fi
    fi
fi

kill_app
rm -f "$TMPOUT"; TMPOUT=""
rm -f "$FAKE_SCREENS"; FAKE_SCREENS=""
rm -rf "$OW_SUPPORT_TMP"; OW_SUPPORT_TMP=""

if [[ $resize_ok -eq 2 ]]; then
    echo "[overlay-check] SKIP (c) GEOMETRY-RESIZE"
    SKIP=$((SKIP+1))
elif [[ $resize_ok -eq 1 ]]; then
    echo "[overlay-check] PASS (c) GEOMETRY-RESIZE"
    PASS=$((PASS+1))
else
    echo "[overlay-check] FAIL (c) GEOMETRY-RESIZE"
    FAIL=$((FAIL+1))
fi

echo ""
# If all integration sub-checks skipped and no windows were verified, exit 1.
if [[ $WINDOW_VERIFIED -eq 0 && $SKIP -gt 0 ]]; then
    echo "[overlay-check] ALL-SKIPPED: no integration sub-check verified windows (PASS=$PASS FAIL=$FAIL SKIP=$SKIP)"
    exit 1
fi
echo "[overlay-check] Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
